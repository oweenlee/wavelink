#!/usr/bin/env python3
"""放行一个「过审待发布」的 App 版本（PENDING_DEVELOPER_RELEASE → READY_FOR_SALE）。

用法:
    # 只看现状（不写任何东西）
    ASC_KEY_ID=<你的 Key ID> ASC_ISSUER_ID=<你的 Issuer ID> \
      python3 tools/asc_release_status.py

    # 真正放行（可加 --wait 轮询到上线）
    ... python3 tools/asc_release_1_0_3.py --apply --wait

注意:
  - 这个动作会让该版本立即进入 App Store，**不可撤销**
  - 放行前请确认价格/门控已就绪；如果是「先免费再上线」的策略，
    顺序必须反过来（先上线，再改价）
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request

sys.path.insert(0, "/Users/qin/.workbuddy/skills/asc-readonly-query")
import asc  # noqa: E402

APP = "6802973339"
TARGET_VERSION = "1.0.3"

TOKEN = ""


def auth() -> None:
    global TOKEN
    k = os.environ["ASC_KEY_ID"]
    TOKEN = asc.make_token(asc.find_key(k), k, os.environ["ASC_ISSUER_ID"])
    asc.TOKEN = TOKEN


def req(method: str, path: str, payload=None):
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


def find_version() -> dict | None:
    r = asc.get(f"/v1/apps/{APP}/appStoreVersions?limit=20")
    if r.get("_err"):
        print(f"✗ 查版本失败: {r['_err']}")
        return None
    for v in r.get("data", []):
        a = v["attributes"]
        # Apple 已把 appStoreVersions 的 version 字段改名为 versionString，两个都认
        if (a.get("versionString") or a.get("version")) == TARGET_VERSION:
            return {"id": v["id"], **a}
    return None


def version_state(vid: str) -> str:
    r = asc.get(f"/v1/appStoreVersions/{vid}")
    if r.get("_err"):
        return f"ERR({r['_err']})"
    return r["data"]["attributes"].get("appStoreState", "?")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true", help="真正执行放行")
    ap.add_argument("--wait", action="store_true", help="放行后轮询到 READY_FOR_SALE")
    ap.add_argument("--timeout", type=int, default=1800, help="轮询超时（秒）")
    args = ap.parse_args()

    auth()
    ver = find_version()
    if not ver:
        print(f"✗ 未找到版本 {TARGET_VERSION}")
        return 1

    state = ver.get("appStoreState")
    print(f"版本 {TARGET_VERSION}  id={ver['id']}")
    print(f"  appStoreState : {state}")
    print(f"  releaseType   : {ver.get('releaseType')}")
    print(f"  platform      : {ver.get('platform')}")

    if state == "PENDING_DEVELOPER_RELEASE":
        pass
    elif state == "READY_FOR_SALE":
        print("\n✓ 已经是上线状态，无需放行")
        return 0
    else:
        print(f"\n✗ 当前状态 {state} 不是待放行状态，不处理")
        return 1

    if not args.apply:
        print("\n[dry-run] 将调用 POST /v1/appStoreVersionReleaseRequests")
        print("          加 --apply 真正执行")
        return 0

    st, body = req("POST", "/v1/appStoreVersionReleaseRequests", {
        "data": {
            "type": "appStoreVersionReleaseRequests",
            "relationships": {
                "appStoreVersion": {"data": {"type": "appStoreVersions", "id": ver["id"]}}
            },
        }
    })
    if st not in (200, 201):
        print(f"\n✗ 放行失败 HTTP {st}")
        print(f"  {err_text(body)}")
        return 1

    print(f"\n✓ 放行请求已受理 HTTP {st}")
    if body.get("data"):
        print(f"  id={body['data'].get('id')}  type={body['data'].get('type')}")

    if not args.wait:
        return 0

    print("\n轮询上线状态…")
    deadline = time.time() + args.timeout
    last = None
    while time.time() < deadline:
        s = version_state(ver["id"])
        if s != last:
            print(f"  {time.strftime('%H:%M:%S')}  {s}")
            last = s
        if s == "READY_FOR_SALE":
            print("\n✓ 已上线 READY_FOR_SALE")
            print("  下一步：确认 App Store 页面已是 1.0.3，再改价免费")
            return 0
        time.sleep(30)
    print(f"\n⚠ 超时（{args.timeout}s）仍未 READY_FOR_SALE，当前={last}")
    print("  继续等或去 ASC 网页查看")
    return 2


if __name__ == "__main__":
    sys.exit(main())
