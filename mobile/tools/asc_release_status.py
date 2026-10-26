#!/usr/bin/env python3
"""审核通过后的放行前状态核查（只读）。

检查三块：
  1. App 版本状态 + 发布方式（MANUAL / AFTER_APPROVAL）
  2. 内购商品状态
  3. App 当前价格（是否为付费）

用法：
    ASC_KEY_ID=xxx ASC_ISSUER_ID=yyy python3 tools/asc_release_status.py
"""
import json
import os
import sys

sys.path.insert(0, os.path.expanduser("~/.workbuddy/skills/asc-readonly-query"))
import asc  # noqa: E402

APP = "6802973339"


def auth():
    key_id = os.environ["ASC_KEY_ID"]
    issuer = os.environ["ASC_ISSUER_ID"]
    asc.TOKEN = asc.make_token(asc.find_key(key_id), key_id, issuer)


def show_versions():
    print("=" * 62)
    print("① App 版本")
    print("=" * 62)
    r = asc.get(f"/v1/apps/{APP}/appStoreVersions?limit=10&include=build")
    if r.get("_err"):
        print("  查询失败:", r["_err"])
        return None
    builds = {}
    for inc in r.get("included", []):
        a = inc["attributes"]
        builds[inc["id"]] = f"build {a.get('version')} ({a.get('processingState')})"

    latest = None
    for v in r.get("data", []):
        a = v["attributes"]
        state = a.get("appStoreState")
        vstate = a.get("appVersionState")
        rel_type = a.get("releaseType")
        created = (a.get("createdDate") or "")[:19]
        bid = (v.get("relationships", {}).get("build", {}).get("data") or {}).get("id")
        ver = a.get("version") or "?"
        print(f"  {ver:<8} state={state} vstate={vstate}")
        print(f"           releaseType={rel_type}  build={builds.get(bid, bid)}  created={created}")
        if a.get("version") == "1.0.3":
            latest = {"id": v["id"], "state": state, "vstate": vstate, "releaseType": rel_type}
    return latest


def show_iap():
    print()
    print("=" * 62)
    print("② 内购商品")
    print("=" * 62)
    r = asc.get(f"/v1/apps/{APP}/inAppPurchasesV2?limit=20")
    if r.get("_err"):
        print("  查询失败:", r["_err"])
        return
    for p in r.get("data", []):
        a = p["attributes"]
        print(f"  {a.get('productId'):<24} state={a.get('state')}")
        print(f"    name={(a.get('name') or '')[:40]}  type={a.get('inAppPurchaseType')}")

    # 历史遗留（v2 看不到已删商品，需查旧版接口）
    r2 = asc.get(f"/v1/apps/{APP}/inAppPurchases?limit=20")
    legacy = [x["attributes"].get("productId") for x in r2.get("data", [])]
    if legacy:
        print(f"  [旧版接口] {legacy}")


def show_price():
    print()
    print("=" * 62)
    print("③ App 价格")
    print("=" * 62)
    # 价格点
    r = asc.get(f"/v1/appPriceSchedules/{APP}/manualPrices?limit=10&include=appPricePoint")
    if not r.get("_err"):
        for inc in r.get("included", []):
            a = inc["attributes"]
            print(f"  当前价格点: {a.get('customerPrice')}  ({a.get('proceeds')} 分成)")
        if not r.get("data"):
            print("  manualPrices 为空（可能走自动价格）")

    # 备用：直接读 appPricePoints 关联
    r2 = asc.get(f"/v1/apps/{APP}/appPricePoints?limit=5")
    if r2.get("_err"):
        print("  价格点查询:", r2["_err"])
    else:
        for p in r2.get("data", []):
            a = p["attributes"]
            print(f"  pricePoint {p['id']}: {a.get('customerPrice')} {a.get('currency')}")


def main():
    auth()
    latest = show_versions()
    show_iap()
    show_price()

    print()
    print("=" * 62)
    print("结论")
    print("=" * 62)
    if not latest:
        print("  未找到 1.0.3 版本")
        return
    print(f"  1.0.3 state      : {latest['state']}")
    print(f"  1.0.3 releaseType: {latest['releaseType']}")
    if latest["state"] == "PENDING_DEVELOPER_RELEASE":
        print("  → 已过审，等人工放行（可调 API 放行）")
    elif latest["state"] == "READY_FOR_SALE":
        print("  → 已上线")
    elif latest["state"] == "WAITING_FOR_REVIEW":
        print("  → 仍在审核中")
    else:
        print(f"  → 当前状态：{latest['state']} / {latest['vstate']}")


if __name__ == "__main__":
    main()
