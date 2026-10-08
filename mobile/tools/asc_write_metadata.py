#!/usr/bin/env python3
"""把 WaveLink 的商店文案一次性写入 App Store Connect。

写入内容（与 ASC_ACTION_CHECKLIST.md 第 3 / 第 5 步逐字一致）：
  1. IAP `wavelink_pro` 的 5 语言本地化（显示名称 + 描述）
  2. IAP 的审核备注 reviewNote
  3. 1.0.3 版本页的 3 语言「此版本的新增内容」+「描述」

用法:
    cd ~/Desktop/wavelink/mobile
    ASC_ISSUER_ID=f5009def-... ASC_KEY_ID=P4Q97KKSQQ \\
      /Users/qin/.workbuddy/binaries/python/envs/default/bin/python tools/asc_write_metadata.py

安全设计:
  - 第一步先做权限探测（写一条 IAP 本地化）。403 则**立即停止**，不做任何后续写入。
  - 已存在的 IAP 本地化会跳过（幂等）。
  - 版本页字段是覆盖写，原值会打印出来留档。
"""
import json
import os
import sys
import urllib.error
import urllib.request

sys.path.insert(0, "/Users/qin/.workbuddy/skills/asc-readonly-query")
import asc  # noqa: E402

BUNDLE_ID = "com.wavelink.player"
IAP_PRODUCT_ID = "wavelink_pro"

# ---------------------------------------------------------------- HTTP helper
def req(method, path, payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    r = urllib.request.Request(asc.BASE + path, data=data, method=method)
    r.add_header("Authorization", "Bearer " + asc.TOKEN)
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


def err_text(body):
    if isinstance(body, dict):
        errs = body.get("errors", [])
        if errs:
            e = errs[0]
            return f"{e.get('code')} / {e.get('title')} / {e.get('detail')}"
    return str(body)[:300]


# ---------------------------------------------------------------- 要写入的内容
# (locale, display_name, 主描述, 超长时的备用描述)
IAP_LOCS = [
    ("en-US", "WaveLink Pro",
     "Room correction & bit-perfect output. Buy once.",
     "Buy once. Room correction & bit-perfect."),
    ("zh-Hans", "WaveLink Pro",
     "一次性买断，永久解锁房间校正与 Bit Perfect 输出",
     None),
    ("de", "WaveLink Pro",
     "Raumkorrektur & bit-perfect Ausgabe. Einmaliger Kauf.",
     "Einmalkauf: Raumkorrektur & bit-perfect."),
    ("ja", "WaveLink Pro",
     "ルーム補正と Bit Perfect 出力。買い切りで永久アンロック",
     None),
    ("ko", "WaveLink Pro",
     "룸 보정 & Bit Perfect 출력. 일시불 구매.",
     None),
]

IAP_REVIEW_NOTE = (
    "WaveLink HiFi is free to download. Local playback, network music sources "
    "(NAS/SMB, WebDAV, Subsonic/Navidrome/Jellyfin) and AutoEQ headphone correction "
    "are all free — no purchase required.\n\n"
    "WaveLink Pro is a one-time, non-consumable in-app purchase that permanently "
    "unlocks room correction and bit-perfect output. No subscriptions, no account "
    "required. A sandbox test account is provided in the App Review Information section."
)

VERSION_LOCS = {
    "en-US": {
        "whatsNew": (
            "WaveLink HiFi is now free to download.\n\n"
            "New in this version: network music sources (NAS/SMB, WebDAV, "
            "Subsonic/Navidrome/Jellyfin) and AutoEQ headphone correction are now "
            "completely free — alongside local playback, playlists, lyrics and basic EQ.\n\n"
            "Pro adds room correction and bit-perfect output, unlocked with a single "
            "one-time purchase. No subscription."
        ),
        "description": (
            "HiFi sound, zero compromise. WaveLink HiFi is an ad-free, account-free "
            "music player built for lossless listening.\n\n"
            "• Lossless playback — FLAC, WAV, ALAC, APE and more\n"
            "• Your own library — stream from your NAS, WebDAV or Subsonic server\n"
            "• AutoEQ headphone correction — thousands of profiles, one tap\n"
            "• Pure sound — high-performance native audio engine with stable, "
            "low-latency output\n"
            "• No ads, no tracking, no login required\n\n"
            "Free download. Room correction and bit-perfect output unlock with a "
            "single one-time purchase. No subscription."
        ),
    },
    "zh-Hans": {
        "whatsNew": (
            "WaveLink HiFi 改为免费下载。\n\n"
            "本次更新：网络音源（NAS/SMB、WebDAV、Subsonic/Navidrome/Jellyfin）与 "
            "AutoEQ 耳机校正已全部免费开放，与本地播放、播放列表、歌词、基础 EQ "
            "一样永久可用。\n\n"
            "Pro 提供房间校正与 Bit Perfect 输出，一次性买断解锁，无需订阅。"
        ),
        "description": (
            "HiFi 音质，毫不妥协。WaveLink HiFi 是一款无广告、无需账号的高解析音乐播放器，"
            "为无损聆听而生。\n\n"
            "• 无损本地播放 — 支持 FLAC、WAV、ALAC、APE 等主流格式\n"
            "• 连接你的音乐库 — 直接串流 NAS、WebDAV 或 Subsonic 服务器\n"
            "• AutoEQ 耳机校正 — 数千条曲线，一键匹配\n"
            "• 原生高性能音频引擎 — 输出稳定、低延迟、纯净还原\n"
            "• 无广告、无追踪、无需登录\n\n"
            "你的音乐，你的服务器，你的隐私。\n\n"
            "免费下载。房间校正与 Bit Perfect 输出通过一次性买断解锁，无需订阅。"
        ),
    },
    "ja": {
        "whatsNew": (
            "WaveLink HiFi は無料ダウンロードになりました。\n\n"
            "今回の更新：ネットワーク音源（NAS/SMB、WebDAV、Subsonic/Navidrome/Jellyfin）"
            "と AutoEQ ヘッドホン補正がすべて無料になりました。ローカル再生、"
            "プレイリスト、歌詞、基本EQ と同様にずっと無料です。\n\n"
            "Pro ではルーム補正と Bit Perfect 出力を提供。買い切りの一度のお支払いで"
            "アンロックされます。サブスクリプションはありません。"
        ),
        "description": (
            "ハイレゾサウンドを、妥協なく。WaveLink HiFi は、広告もアカウント登録も不要の"
            "ロスレス音楽プレーヤーです。\n\n"
            "• ロスレス再生 — FLAC、WAV、ALAC、APE など主要フォーマットに対応\n"
            "• 自分のライブラリを接続 — NAS、WebDAV、Subsonic サーバーを直接ストリーミング\n"
            "• AutoEQ ヘッドホン補正 — 数千のプロファイルをワンタップで適用\n"
            "• ネイティブ高性能オーディオエンジン — 安定した低遅延でクリアな音質を再現\n"
            "• 広告なし、トラッキングなし、ログイン不要\n\n"
            "あなたの音楽、あなたのサーバー、あなたのプライバシー。\n\n"
            "無料ダウンロード。ルーム補正と Bit Perfect 出力は買い切りの一度のお支払いで"
            "アンロックされます。サブスクリプションはありません。"
        ),
    },
}


# ---------------------------------------------------------------- 主流程
def main():
    issuer = os.environ.get("ASC_ISSUER_ID")
    key_id = os.environ.get("ASC_KEY_ID")
    if not issuer or not key_id:
        sys.exit("需要 ASC_ISSUER_ID 与 ASC_KEY_ID 环境变量")
    key_path = asc.find_key(key_id)
    asc.TOKEN = asc.make_token(key_path, key_id, issuer)

    aid, app_name = asc.app_id_of(BUNDLE_ID)
    print(f"# {app_name} ({BUNDLE_ID})  app_id={aid}\n")

    # ---- 定位 IAP ----
    iaps = asc.get(f"/v1/apps/{aid}/inAppPurchasesV2?limit=50").get("data", [])
    target = [p for p in iaps if p["attributes"].get("productId") == IAP_PRODUCT_ID]
    if not target:
        sys.exit(f"❌ 找不到商品 {IAP_PRODUCT_ID}（现有："
                 f"{[p['attributes'].get('productId') for p in iaps]}）")
    iap = target[0]
    iap_id = iap["id"]
    print(f"IAP  id={iap_id}  productId={iap['attributes'].get('productId')!r}  "
          f"state={iap['attributes'].get('state')}")

    existing = asc.get(
        f"/v2/inAppPurchases/{iap_id}/inAppPurchaseLocalizations?limit=50"
    ).get("data", [])
    have = {l["attributes"].get("locale") for l in existing}
    print(f"     现有本地化: {sorted(have) if have else '（无）'}\n")

    # ---- ① 权限探测：写第一条本地化 ----
    todo = [t for t in IAP_LOCS if t[0] not in have]
    if not todo:
        print("① IAP 本地化 —— 已全部存在，跳过\n")
    else:
        loc, name, desc, fallback = todo[0]
        print(f"① 权限探测：写 IAP 本地化 [{loc}] ...")
        payload = {"data": {
            "type": "inAppPurchaseLocalizations",
            "attributes": {"locale": loc, "name": name, "description": desc},
            "relationships": {"inAppPurchaseV2": {
                "data": {"type": "inAppPurchases", "id": iap_id}}},
        }}
        st, body = req("POST", "/v1/inAppPurchaseLocalizations", payload)

        if st >= 400 and fallback and "too long" in err_text(body).lower():
            print(f"   ↳ 描述超长，改用备用文案（{len(desc)} → {len(fallback)} 字符）")
            payload["data"]["attributes"]["description"] = fallback
            desc = fallback
            st, body = req("POST", "/v1/inAppPurchaseLocalizations", payload)

        if st >= 400:
            print(f"   ❌ 写入失败 ({st}): {err_text(body)}")
            print("\n→ 权限不足，已停止，未做任何其他改动。请按清单在网页手工填。")
            return 1
        print(f"   ✅ 成功 ({st})")

        # ---- 写剩余本地化 ----
        for loc, name, desc, fallback in todo[1:]:
            payload = {"data": {
                "type": "inAppPurchaseLocalizations",
                "attributes": {"locale": loc, "name": name, "description": desc},
                "relationships": {"inAppPurchaseV2": {
                    "data": {"type": "inAppPurchases", "id": iap_id}}},
            }}
            st, body = req("POST", "/v1/inAppPurchaseLocalizations", payload)
            if st >= 400 and fallback and "too long" in err_text(body).lower():
                payload["data"]["attributes"]["description"] = fallback
                st, body = req("POST", "/v1/inAppPurchaseLocalizations", payload)
            print(f"   {'✅' if st < 400 else '❌'} [{loc}] ({st}) "
                  f"{'' if st < 400 else err_text(body)}")
        print()

    # ---- ② 审核备注 ----
    print("② IAP 审核备注 (reviewNote) ...")
    st, body = req("PATCH", f"/v2/inAppPurchases/{iap_id}", {"data": {
        "type": "inAppPurchases", "id": iap_id,
        "attributes": {"reviewNote": IAP_REVIEW_NOTE},
    }})
    print(f"   {'✅' if st < 400 else '❌'} ({st}) "
          f"{'' if st < 400 else err_text(body)}\n")

    # ---- ③ 版本页元数据 ----
    print("③ 1.0.3 版本页「此版本的新增内容」+「描述」...")
    versions = asc.get(f"/v1/apps/{aid}/appStoreVersions?limit=20").get("data", [])
    v103 = [v for v in versions if v["attributes"].get("versionString") == "1.0.3"]
    if not v103:
        print("   ❌ 找不到 1.0.3 版本")
        return 1
    vid = v103[0]["id"]

    locs = asc.get(
        f"/v1/appStoreVersions/{vid}/appStoreVersionLocalizations?limit=50"
    ).get("data", [])
    for l in locs:
        locale = l["attributes"].get("locale")
        new = VERSION_LOCS.get(locale)
        if not new:
            print(f"   ⏭ [{locale}] 清单里没有对应文案，跳过")
            continue
        old_wn = l["attributes"].get("whatsNew")
        print(f"   [{locale}] 旧 whatsNew: {'（空）' if not old_wn else '已有内容'} "
              f"→ 覆盖写")
        st, body = req("PATCH", f"/v1/appStoreVersionLocalizations/{l['id']}", {
            "data": {"type": "appStoreVersionLocalizations", "id": l["id"],
                     "attributes": {"whatsNew": new["whatsNew"],
                                    "description": new["description"]}}})
        print(f"       {'✅' if st < 400 else '❌'} ({st}) "
              f"{'' if st < 400 else err_text(body)}")

    print("\n完成。接下来跑 python tools/asc_preflight.py 复核。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
