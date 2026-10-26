#!/usr/bin/env python3
"""把一组 App Store 截图上传到指定 App 版本的 en-US 本地化，替换旧图。

用法:
    # 只看现状与将要做什么（不写任何东西）
    ASC_KEY_ID=<你的 Key ID> ASC_ISSUER_ID=<你的 Issuer ID> \\
      python3 tools/asc_upload_screenshots.py --version 1.0.3

    # 真正执行
    ... tools/asc_upload_screenshots.py --version 1.0.3 --apply

目录约定（由 tools/prep_asc_screenshots.py 产出）:
    build/asc-final/iphone_61/*.jpg  → APP_IPHONE_61 (1179x2556)
    build/asc-final/iphone_65/*.jpg  → APP_IPHONE_65 (1284x2778)

安全设计:
  - 默认 dry-run，只列现状
  - 替换时**不会先把旧图全删光**：先删到只剩 N 张（N=新图数量），
    再上传新图，最后删掉剩下的旧图 → 任何时刻该组都有图，不会出现空列表
  - 每张图校验尺寸与显示类型匹配，不匹配直接中止
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, "/Users/qin/.workbuddy/skills/asc-readonly-query")
import asc  # noqa: E402

BUNDLE_ID = "com.wavelink.player"
ROOT = Path(__file__).resolve().parent.parent

# 显示类型 -> (目录, 允许的尺寸)
TARGETS = {
    "APP_IPHONE_61": ("build/asc-final/iphone_61", [(1179, 2556), (1206, 2622)]),
    "APP_IPHONE_65": ("build/asc-final/iphone_65", [(1284, 2778), (1242, 2688)]),
}

TOKEN = ""


def die(msg: str) -> None:
    print(f"✗ {msg}", file=sys.stderr)
    sys.exit(1)


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


def jpeg_size(path: Path) -> tuple[int, int]:
    """读 JPEG 的 SOF 段拿宽高（不依赖第三方库）。"""
    with open(path, "rb") as f:
        data = f.read()
    i = 2
    while i < len(data) - 9:
        if data[i] != 0xFF:
            i += 1
            continue
        marker = data[i + 1]
        if marker in (0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7,
                      0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF):
            h = int.from_bytes(data[i + 5:i + 7], "big")
            w = int.from_bytes(data[i + 7:i + 9], "big")
            return w, h
        seg_len = int.from_bytes(data[i + 2:i + 4], "big")
        i += 2 + seg_len
    raise ValueError(f"{path.name}: 读不到 JPEG 尺寸")


def upload_one(set_id: str, path: Path, index: int) -> str:
    """三步资产上传：reserve → PUT → PATCH uploaded。返回 screenshot id。"""
    size = path.stat().st_size
    status, body = req("POST", "/v1/appScreenshots", {
        "data": {
            "type": "appScreenshots",
            "attributes": {"fileSize": size, "fileName": path.name},
            "relationships": {
                "appScreenshotSet": {
                    "data": {"type": "appScreenshotSets", "id": set_id}
                }
            },
        }
    })
    if status not in (200, 201):
        die(f"reserve 失败({path.name}): {status} {err_text(body)}")

    sid = body["data"]["id"]
    ops = body["data"]["attributes"].get("uploadOperations") or []
    if not ops:
        die(f"{path.name}: 没有拿到 uploadOperations")

    blob = path.read_bytes()
    for op in ops:
        off = int(op.get("offset", 0))
        length = int(op.get("length", len(blob)))
        chunk = blob[off:off + length]
        r = urllib.request.Request(op["url"], data=chunk, method=op["method"])
        for h in op.get("requestHeaders") or []:
            r.add_header(h["name"], h["value"])
        try:
            with urllib.request.urlopen(r) as resp:
                resp.read()
        except urllib.error.HTTPError as e:
            die(f"{path.name}: 上传分片失败 {e.code} {e.read().decode()[:200]}")

    status, body = req("PATCH", f"/v1/appScreenshots/{sid}", {
        "data": {"type": "appScreenshots", "id": sid,
                 "attributes": {"uploaded": True}}
    })
    if status not in (200, 201):
        die(f"{path.name}: 确认 uploaded 失败 {status} {err_text(body)}")

    # 等处理完成
    for _ in range(30):
        st, b = req("GET", f"/v1/appScreenshots/{sid}")
        state = ((b.get("data", {}).get("attributes", {})
                  .get("assetDeliveryState") or {}).get("state"))
        if state == "COMPLETE":
            break
        if state in ("FAILED",):
            die(f"{path.name}: 处理失败 {json.dumps(b)[:300]}")
        time.sleep(1)
    print(f"    ↑ {path.name} → {sid[:8]}… ({index})")
    return sid


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", required=True, help="版本号，如 1.0.3")
    ap.add_argument("--locale", default="en-US")
    ap.add_argument("--apply", action="store_true", help="真正执行（默认只看）")
    args = ap.parse_args()

    key_id = os.environ.get("ASC_KEY_ID")
    issuer = os.environ.get("ASC_ISSUER_ID")
    if not key_id or not issuer:
        die("需要环境变量 ASC_KEY_ID 与 ASC_ISSUER_ID")
    global TOKEN
    TOKEN = asc.make_token(asc.find_key(key_id), key_id, issuer)

    # App
    st, b = req("GET", f"/v1/apps?filter[bundleId]={BUNDLE_ID}&limit=5")
    if st != 200 or not b.get("data"):
        die(f"找不到 App: {st} {err_text(b)}")
    app_id = b["data"][0]["id"]

    # 版本
    st, b = req("GET", f"/v1/apps/{app_id}/appStoreVersions"
                       f"?filter[platform]=IOS&filter[versionString]={args.version}&limit=5")
    if st != 200 or not b.get("data"):
        die(f"找不到版本 {args.version}: {st} {err_text(b)}")
    ver = b["data"][0]
    ver_id = ver["id"]
    print(f"App {app_id} · 版本 {args.version} = {ver_id} · 状态 {ver['attributes'].get('appStoreState')}")

    # 本地化
    st, b = req("GET", f"/v1/appStoreVersions/{ver_id}/appStoreVersionLocalizations?limit=50")
    if st != 200:
        die(f"取本地化失败: {err_text(b)}")
    locs = {l["attributes"]["locale"]: l["id"] for l in b["data"]}
    print(f"本地化: {', '.join(sorted(locs))}")
    if args.locale not in locs:
        die(f"没有 {args.locale}")
    loc_id = locs[args.locale]

    # 截图组
    st, b = req("GET", f"/v1/appStoreVersionLocalizations/{loc_id}/appScreenshotSets?limit=50")
    if st != 200:
        die(f"取截图组失败: {err_text(b)}")
    sets = {s["attributes"]["screenshotDisplayType"]: s["id"] for s in b["data"]}
    print(f"现有截图组: {json.dumps(sets, ensure_ascii=False)}")

    for dtype, (reldir, allowed) in TARGETS.items():
        print(f"\n=== {dtype} ===")
        files = sorted(p for p in (ROOT / reldir).glob("*.jpg"))
        if not files:
            die(f"{reldir} 里没有 jpg")
        for f in files:
            w, h = jpeg_size(f)
            if (w, h) not in allowed:
                die(f"{f.name} 尺寸 {w}x{h} 不符合 {dtype} 允许值 {allowed}")
        print(f"待上传 {len(files)} 张，尺寸校验通过")

        set_id = sets.get(dtype)
        if not set_id:
            print(f"  ! 该组不存在，需要新建")
            if args.apply:
                st, b = req("POST", "/v1/appScreenshotSets", {
                    "data": {"type": "appScreenshotSets",
                             "attributes": {"screenshotDisplayType": dtype},
                             "relationships": {"appStoreVersionLocalization": {
                                 "data": {"type": "appStoreVersionLocalizations",
                                          "id": loc_id}}}}})
                if st not in (200, 201):
                    die(f"新建截图组失败: {err_text(b)}")
                set_id = b["data"]["id"]
                print(f"  ✓ 已新建 {set_id}")
            else:
                continue

        st, b = req("GET", f"/v1/appScreenshotSets/{set_id}/appScreenshots?limit=50")
        if st != 200:
            die(f"取截图失败: {err_text(b)}")
        existing = b["data"]
        print(f"  现有 {len(existing)} 张")

        if not args.apply:
            print(f"  [dry-run] 将删除 {len(existing)} 张旧图，上传 {len(files)} 张新图")
            continue

        # 先删到只剩 len(files) 张，保证列表始终非空
        keep = len(files)
        olds = [s["id"] for s in existing]
        for sid in olds[:max(0, len(olds) - keep)]:
            st, b = req("DELETE", f"/v1/appScreenshots/{sid}")
            if st not in (200, 204):
                print(f"  ! 删除 {sid[:8]} 失败 {st} {err_text(b)}")
        print(f"  已腾位，开始上传…")
        new_ids = []
        for i, f in enumerate(files, 1):
            new_ids.append(upload_one(set_id, f, i))

        # 删掉剩下的旧图
        remaining = [sid for sid in olds if sid not in new_ids]
        st, b = req("GET", f"/v1/appScreenshotSets/{set_id}/appScreenshots?limit=50")
        still = [s["id"] for s in b.get("data", [])]
        for sid in still:
            if sid not in new_ids:
                st, bb = req("DELETE", f"/v1/appScreenshots/{sid}")
                if st not in (200, 204):
                    print(f"  ! 删除旧图 {sid[:8]} 失败 {st} {err_text(bb)}")
        print(f"  ✓ 清理旧图 {len(remaining)} 张")

    if not args.apply:
        print("\n（dry-run 结束，加 --apply 才真正写入）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
