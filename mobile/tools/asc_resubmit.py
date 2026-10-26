#!/usr/bin/env python3
"""把现有 reviewSubmission 重新提交送审（默认 dry-run）。

用法:
    ASC_KEY_ID=<你的 Key ID> ASC_ISSUER_ID=<你的 Issuer ID> python3 tools/asc_resubmit.py
    ... --apply          # 真正提交（提交后条目冻结，不能再增删）
    ... --submission <id>  # 指定提交（默认取 UNRESOLVED_ISSUES 那条）
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request

sys.path.insert(0, "/Users/qin/.workbuddy/skills/asc-readonly-query")
import asc  # noqa: E402

APP = "6802973339"
TOKEN = ""


def req(method, path, payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    r = urllib.request.Request(asc.BASE + path, data=data, method=method)
    r.add_header("Authorization", "Bearer " + TOKEN)
    if data is not None:
        r.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(r) as resp:
            raw = resp.read().decode()
            return resp.status, (json.loads(raw) if raw.strip() else {})
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, raw


def err_text(body) -> str:
    if isinstance(body, dict):
        errs = body.get("errors", [])
        if errs:
            e = errs[0]
            return f"{e.get('code')} / {e.get('title')} / {e.get('detail')}"
    return str(body)[:300]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--submission")
    ap.add_argument("--apply", action="store_true")
    args = ap.parse_args()

    global TOKEN
    TOKEN = asc.make_token(
        asc.find_key(os.environ["ASC_KEY_ID"]),
        os.environ["ASC_KEY_ID"],
        os.environ["ASC_ISSUER_ID"],
    )

    sub_id = args.submission
    if not sub_id:
        st, b = req("GET", f"/v1/reviewSubmissions?filter[app]={APP}&limit=10")
        if st != 200:
            print("取提交列表失败:", err_text(b))
            return 1
        pending = [s for s in b.get("data", [])
                   if s["attributes"].get("state") == "UNRESOLVED_ISSUES"]
        if len(pending) != 1:
            print(f"找到 {len(pending)} 条 UNRESOLVED_ISSUES 提交，需要 --submission 指定")
            for s in pending:
                print("  ", s["id"])
            return 1
        sub_id = pending[0]["id"]

    print(f"提交 {sub_id}")

    # 条目
    st, b = req("GET", f"/v1/reviewSubmissions/{sub_id}/items?limit=20")
    if st != 200:
        print("取条目失败:", err_text(b))
        return 1
    items = b.get("data", [])
    print(f"条目 {len(items)} 个:")
    has_version = False
    has_iap = False
    for it in items:
        rid = it["id"]
        # id = base64("<sub>|<n>|<resourceId>")
        import base64
        try:
            plain = base64.b64decode(rid + "==").decode(errors="replace")
            resource = plain.rsplit("|", 1)[-1]
        except Exception:
            resource = "?"
        kind = "App版本" if resource.isdigit() else "内购"
        if kind == "App版本":
            has_version = True
        else:
            has_iap = True
        print(f"  - {kind}  state={it['attributes'].get('state')}  resource={resource}")

    # 版本 + 构建
    st, b = req("GET", f"/v1/apps/{APP}/appStoreVersions"
                       "?filter[platform]=IOS&limit=10")
    ver = None
    for v in b.get("data", []):
        if v["attributes"].get("appStoreState") == "REJECTED":
            ver = v
    if ver:
        print(f"版本 {ver['attributes'].get('versionString')} state={ver['attributes'].get('appStoreState')}")
        st, b = req("GET", f"/v1/appStoreVersions/{ver['id']}?include=build")
        for inc in b.get("included", []):
            if inc["type"] == "builds":
                print(f"  构建 build {inc['attributes'].get('version')}  "
                      f"state={inc['attributes'].get('processingState')} "
                      f"expired={inc['attributes'].get('expired')}")

    # 内购审核截图
    st, b = req("GET", f"/v1/apps/{APP}/inAppPurchasesV2?limit=20&include=appStoreReviewScreenshot")
    for p in b.get("data", []):
        shot = None
        for inc in b.get("included", []):
            if inc["type"] == "inAppPurchaseAppStoreReviewScreenshots":
                shot = inc
        a = p["attributes"]
        if shot:
            sa = shot["attributes"]
            print(f"内购 {a.get('productId')} state={a.get('state')} "
                  f"审核截图={sa.get('fileName')} "
                  f"{(sa.get('assetDeliveryState') or {}).get('state')}")
        else:
            print(f"内购 {a.get('productId')} state={a.get('state')} 审核截图=无 ⚠️")

    if not (has_version and has_iap):
        print("\n⚠️ 条目不全（版本 + 内购都必须在内），不要提交")
        return 1

    if not args.apply:
        print("\n[dry-run] 一切就绪，加 --apply 提交")
        return 0

    print("\n提交中…")
    st, b = req("PATCH", f"/v1/reviewSubmissions/{sub_id}", {
        "data": {"type": "reviewSubmissions", "id": sub_id,
                 "attributes": {"submitted": True}}
    })
    if st not in (200, 201):
        print(f"✗ 提交失败 {st} {err_text(b)}")
        return 1
    print(f"✓ 已提交，state={b['data']['attributes'].get('state')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
