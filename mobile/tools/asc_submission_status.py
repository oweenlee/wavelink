#!/usr/bin/env python3
"""查看 App 的 reviewSubmission 现状 + 内购状态（只读）。

用法:
    ASC_KEY_ID=<你的 Key ID> ASC_ISSUER_ID=<你的 Issuer ID> python3 tools/asc_submission_status.py
"""
import os
import sys

sys.path.insert(0, "/Users/qin/.workbuddy/skills/asc-readonly-query")
import asc  # noqa: E402

APP = "6802973339"


def main() -> int:
    asc.TOKEN = asc.make_token(
        asc.find_key(os.environ["ASC_KEY_ID"]),
        os.environ["ASC_KEY_ID"],
        os.environ["ASC_ISSUER_ID"],
    )

    print("=== reviewSubmissions ===")
    r = asc.get(f"/v1/reviewSubmissions?filter[app]={APP}&limit=10")
    if "_err" in r:
        print("  ERR", r)
    for sub in r.get("data", []):
        attrs = sub["attributes"]
        print(
            f"  提交 {sub['id']}  state={attrs.get('state')}  "
            f"platform={attrs.get('platform')}  submittedDate={attrs.get('submittedDate')}"
        )
        items = asc.get(
            f"/v1/reviewSubmissionItems?filter[reviewSubmission]={sub['id']}&limit=20"
        )
        for it in items.get("data", []):
            rid = it["relationships"].get("appStoreVersion", {}).get("data") or {}
            iap = it["relationships"].get("inAppPurchaseVersion", {}).get("data") or {}
            kind = "App版本" if rid.get("id") else ("内购" if iap.get("id") else "?")
            print(f"     - {kind}  item={it['id']}  state={it['attributes'].get('state')}")

    print("\n=== 内购 (v2) ===")
    iaps = asc.get(f"/v1/apps/{APP}/inAppPurchasesV2?limit=20")
    if "_err" in iaps:
        print("  ERR", iaps)
    for p in iaps.get("data", []):
        a = p["attributes"]
        print(f"  {a.get('productId')}  state={a.get('state')}  type={a.get('inAppPurchaseType')}")
        shot = asc.get(f"/v1/inAppPurchases/{p['id']}/appStoreReviewScreenshot")
        if shot.get("data"):
            sa = shot["data"]["attributes"]
            state = (sa.get("assetDeliveryState") or {}).get("state")
            print(f"     审核截图: {sa.get('fileName')}  {state}")
        else:
            print("     审核截图: 无")
    return 0


if __name__ == "__main__":
    sys.exit(main())
