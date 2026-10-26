#!/usr/bin/env python3
"""改 App 价格为指定价格点（例如改成免费）。

Apple 在 App Store Connect API 2.3+ 提供了 `POST /v1/appPriceSchedules`，
所以「改价」**可以**用 API 做（旧结论「只能网页」已过时）。

用法:
    # 只看现状 + 将要提交的 payload（不写）
    ASC_KEY_ID=... ASC_ISSUER_ID=... \
      python3 tools/asc_set_price.py --app 6802973339 --to 0

    # 真正执行
    ... tools/asc_set_price.py --app 6802973339 --to 0 --apply

安全设计:
  - 默认 dry-run，打印完整 payload
  - 只对基准地区（baseTerritory）下发 manualPrice，其他地区由 Apple 按汇率自动推导
  - 执行后立即回读校验
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
            extra = e.get("meta", {}).get("associatedErrors") or e.get("source", {})
            return f"{e.get('code')} / {e.get('title')} / {e.get('detail')} {json.dumps(extra, ensure_ascii=False)[:200]}"
    return str(body)[:400]


def current_prices(app: str) -> list[dict]:
    g = asc.get(f"/v1/appPriceSchedules/{app}/manualPrices?include=appPricePoint&limit=20")
    if g.get("_err"):
        return [{"_err": g["_err"]}]
    pts = {i["id"]: i["attributes"] for i in g.get("included", [])}
    out = []
    for p in g.get("data", []):
        pid = (p.get("relationships", {}).get("appPricePoint", {}).get("data") or {}).get("id")
        at = pts.get(pid, {})
        out.append({
            "appPriceId": p["id"],
            "pricePointId": pid,
            "customerPrice": at.get("customerPrice"),
            "currency": at.get("currency"),
        })
    return out


def find_price_point(app: str, territory: str, target: float) -> dict | None:
    url = f"/v1/apps/{app}/appPricePoints?filter[territory]={territory}&limit=200"
    while url:
        g = asc.get(url)
        if g.get("_err"):
            print("✗ 查价格点失败:", g["_err"])
            return None
        for p in g.get("data", []):
            cp = p["attributes"].get("customerPrice")
            if cp is not None and abs(float(cp) - target) < 1e-6:
                return {"id": p["id"], **p["attributes"]}
        nxt = (g.get("links") or {}).get("next")
        url = nxt.replace(asc.BASE, "") if nxt else None
    return None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", required=True, help="App Store Connect app id")
    ap.add_argument("--to", required=True, type=float, help="目标价格（0 = 免费）")
    ap.add_argument("--territory", default="USA")
    ap.add_argument("--apply", action="store_true")
    args = ap.parse_args()

    auth()

    print(f"App {args.app}")
    print("=== 当前价格（手动价）===")
    for p in current_prices(args.app):
        if "_err" in p:
            print("  err:", json.dumps(p["_err"], ensure_ascii=False)[:200])
        else:
            print(f"  {p['currency']} {p['customerPrice']}   point={p['pricePointId']}")

    pp = find_price_point(args.app, args.territory, args.to)
    if not pp:
        print(f"\n✗ 在 {args.territory} 找不到价格 {args.to} 的价格点")
        return 1
    print(f"\n目标价格点（{args.territory}）: {pp['customerPrice']} {pp.get('currency','')}")
    print(f"  id={pp['id']}")

    local_price_id = "${price1}"
    payload = {
        "data": {
            "type": "appPriceSchedules",
            "relationships": {
                "app": {"data": {"type": "apps", "id": args.app}},
                "baseTerritory": {"data": {"type": "territories", "id": args.territory}},
                "manualPrices": {"data": [{"type": "appPrices", "id": local_price_id}]},
            },
        },
        "included": [
            {
                "type": "appPrices",
                "id": local_price_id,
                "attributes": {"startDate": None},
                "relationships": {
                    "appPricePoint": {
                        "data": {"type": "appPricePoints", "id": pp["id"]}
                    }
                },
            }
        ],
    }

    if not args.apply:
        print("\n[dry-run] 将 POST /v1/appPriceSchedules payload:")
        print(json.dumps(payload, ensure_ascii=False, indent=2)[:1200])
        print("\n加 --apply 真正执行")
        return 0

    st, body = req("POST", "/v1/appPriceSchedules", payload)
    if st not in (200, 201):
        print(f"\n✗ 提交失败 HTTP {st}")
        print("  " + err_text(body))
        return 1

    print(f"\n✓ 已提交 HTTP {st}")
    print("  回读校验…")
    import time
    for _ in range(6):
        time.sleep(5)
        now = current_prices(args.app)
        vals = [f"{p.get('currency')} {p.get('customerPrice')}" for p in now if "_err" not in p]
        print("   现在:", vals)
        if len(now) == 1 and now[0].get("customerPrice") is not None and abs(float(now[0]["customerPrice"]) - args.to) < 1e-6:
            print("✓ 价格已生效")
            print("  提示：App Store 页面与 iTunes lookup 有缓存延迟（几分钟到数小时）")
            return 0
    print("⚠ 回读未完全匹配，去 ASC 网页确认")
    return 2


if __name__ == "__main__":
    sys.exit(main())
