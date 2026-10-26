#!/usr/bin/env python3
"""为被拒版本新建一条 reviewSubmission（App 版本 + 内购），可选择性立即提交。

背景：Apple 拒审后，旧的 reviewSubmission 处于 UNRESOLVED_ISSUES，
对它 PATCH submitted=true 会返回 409（appStoreVersions ... not in valid state）。
API 侧的正确做法是**新建一条提交**再把条目加进去。

用法:
    # 只建草稿（不提交），最后打印新提交 id
    ASC_KEY_ID=... ASC_ISSUER_ID=... python3 tools/asc_new_submission.py
    # 建好并立即送审
    ... --submit
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
IAP_ID = "f44adf38-1dbe-4ba6-97a5-ec5d5d2db64b"  # wavelink_pro
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
            return " | ".join(f"{e.get('code')}: {e.get('detail')}" for e in errs)
    return str(body)[:300]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--version-id", default=None)
    ap.add_argument("--submit", action="store_true")
    ap.add_argument("--submission-id", default=None,
                    help="复用/指定已有的草稿提交 id（不给则新建）")
    ap.add_argument("--detach-from", default=None,
                    help="先把这个旧提交里的条目全部删除（被拒的 UNRESOLVED_ISSUES 提交）")
    ap.add_argument("--delete-submission", default=None,
                    help="直接删除这条旧提交（条目已 submitted 无法单独删时用）")
    args = ap.parse_args()

    global TOKEN
    TOKEN = asc.make_token(
        asc.find_key(os.environ["ASC_KEY_ID"]),
        os.environ["ASC_KEY_ID"],
        os.environ["ASC_ISSUER_ID"],
    )

    ver_id = args.version_id
    if not ver_id:
        st, b = req("GET", f"/v1/apps/{APP}/appStoreVersions?filter[platform]=IOS&limit=10")
        for v in b.get("data", []):
            if v["attributes"].get("appStoreState") == "REJECTED":
                ver_id = v["id"]
                print(f"被拒版本 {v['attributes'].get('versionString')} = {ver_id}")
    if not ver_id:
        print("找不到 REJECTED 版本")
        return 1

    # 0) 先把旧提交（被拒那条）里的条目摘掉，否则同一资源不能在两条提交里
    if args.delete_submission:
        st, b = req("DELETE", f"/v1/reviewSubmissions/{args.delete_submission}")
        if st not in (200, 204):
            print(f"✗ 删除旧提交失败 {st} {err_text(b)}")
            return 1
        print(f"✓ 已删除旧提交 {args.delete_submission}")

    if args.detach_from:
        st, b = req("GET", f"/v1/reviewSubmissions/{args.detach_from}/items?limit=20")
        old_items = b.get("data", [])
        print(f"旧提交 {args.detach_from} 有 {len(old_items)} 个条目，开始摘除")
        for it in old_items:
            st, bb = req("DELETE", f"/v1/reviewSubmissionItems/{it['id']}")
            if st not in (200, 204):
                print(f"  ✗ 删除失败 {st} {err_text(bb)}")
                return 1
            print(f"  ✓ 已删除 {it['id'][:16]}…")

    # 1) 新建提交
    if args.submission_id:
        sub_id = args.submission_id
        print(f"复用提交 {sub_id}")
    else:
        st, b = req("POST", "/v1/reviewSubmissions", {
            "data": {
                "type": "reviewSubmissions",
                "attributes": {"platform": "IOS"},
                "relationships": {"app": {"data": {"type": "apps", "id": APP}}},
            }
        })
        if st not in (200, 201):
            print(f"✗ 新建提交失败 {st} {err_text(b)}")
            return 1
        sub_id = b["data"]["id"]
        print(f"✓ 新提交 {sub_id} state={b['data']['attributes'].get('state')}")

    # 2) 加 App 版本
    st, b = req("POST", "/v1/reviewSubmissionItems", {
        "data": {
            "type": "reviewSubmissionItems",
            "relationships": {
                "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": sub_id}},
                "appStoreVersion": {"data": {"type": "appStoreVersions", "id": ver_id}},
            },
        }
    })
    if st not in (200, 201):
        print(f"✗ 加 App 版本失败 {st} {err_text(b)}")
        return 1
    print(f"✓ 已加 App 版本条目 {b['data']['id'][:20]}…")

    # 3) 加内购
    st, b = req("POST", "/v1/reviewSubmissionItems", {
        "data": {
            "type": "reviewSubmissionItems",
            "relationships": {
                "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": sub_id}},
                "inAppPurchaseV2": {"data": {"type": "inAppPurchases", "id": IAP_ID}},
            },
        }
    })
    if st not in (200, 201):
        print(f"✗ 加内购失败 {st} {err_text(b)}")
        print("  （App 版本条目已加好；内购关系名可能需要调整）")
        return 1
    print(f"✓ 已加内购条目 {b['data']['id'][:20]}…")

    # 4) 校验条目
    st, b = req("GET", f"/v1/reviewSubmissions/{sub_id}/items?limit=20")
    print(f"条目数 {len(b.get('data', []))}")

    if not args.submit:
        print(f"\n[dry] 已建好草稿提交 {sub_id}，加 --submit 送审")
        return 0

    st, b = req("PATCH", f"/v1/reviewSubmissions/{sub_id}", {
        "data": {"type": "reviewSubmissions", "id": sub_id,
                 "attributes": {"submitted": True}}
    })
    if st not in (200, 201):
        print(f"✗ 送审失败 {st} {err_text(b)}")
        return 1
    print(f"✓ 已送审 state={b['data']['attributes'].get('state')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
