#!/usr/bin/env python3
"""WaveLink 提审前自检（App Store Connect 只读）。

在 ASC 上点「提交审核」之前跑一次，一眼看到还差什么。

用法:
    python tools/asc_preflight.py
    python tools/asc_preflight.py com.wavelink.player   # 指定 bundleId

鉴权: 复用 asc-readonly-query 技能的 asc.py（本机 ~/.fastlane/AuthKey_*.p8）。
      issuer id 可用环境变量 ASC_ISSUER_ID 覆盖。
"""
import base64
import os
import sys

SKILL_DIR = os.path.expanduser("~/.workbuddy/skills/asc-readonly-query")
if not os.path.isdir(SKILL_DIR):
    sys.exit(f"找不到 asc.py 所在目录: {SKILL_DIR}")
sys.path.insert(0, SKILL_DIR)

try:
    import asc  # noqa: E402
except ImportError:
    sys.exit("导入 asc.py 失败")

BUNDLE = sys.argv[1] if len(sys.argv) > 1 else "com.wavelink.player"
ISSUER = os.environ.get("ASC_ISSUER_ID", "f5009def-bf90-45d1-9a4a-1de2ecb3a82e")
KEY_ID = os.environ.get("ASC_KEY_ID", "P4Q97KKSQQ")

TARGET_VERSION = "1.0.3"
TARGET_PRODUCT_ID = "wavelink_pro"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _pubspec_build():
    """读 pubspec.yaml 的 version: X.Y.Z+N，返回 build 号字符串 N。"""
    try:
        with open(os.path.join(ROOT, "pubspec.yaml"), encoding="utf-8") as f:
            for line in f:
                if line.startswith("version:"):
                    return line.split("+")[-1].strip()
    except OSError:
        pass
    return None

ok_n = fail_n = 0
SUBMITTED = [False]   # 是否有「已发出」的提交（供结尾结论区分「可提交」/「等审核」）


def check(ok: bool, msg: str, hint: str = ""):
    global ok_n, fail_n
    if ok:
        ok_n += 1
        print(f"  [✓] {msg}")
    else:
        fail_n += 1
        print(f"  [✗] {msg}")
        if hint:
            print(f"      → {hint}")


def note(msg: str, hint: str = ""):
    """中性信息：既不算通过也不算失败（例如「已提交，等审核」）。"""
    print(f"  [•] {msg}")
    if hint:
        print(f"      → {hint}")


def decode_item_kind(item_id: str) -> str:
    """判断 reviewSubmissionItem 装的是什么资源。

    item id 是 base64("<submissionId>|<序号>|<resourceId>")。
    实测：resourceId 为**纯数字** → App Store 版本（App 版本的内部数字 id，
    与历史提交一致：8/28 那次 = 890317484 → 1.0.2）；**UUID** → 内购等其它资源。
    """
    try:
        pad = "=" * (-len(item_id) % 4)
        raw = base64.urlsafe_b64decode(item_id + pad).decode("utf-8", "replace")
        rid = raw.split("|")[-1]
    except Exception:  # noqa: BLE001
        return "unknown"
    if not rid:
        return "unknown"
    return "version" if rid.isdigit() else "iap"


def main():
    asc.TOKEN = asc.make_token(asc.find_key(KEY_ID), KEY_ID, ISSUER)
    aid, app_name = asc.app_id_of(BUNDLE)

    print(f"\n{app_name} ({BUNDLE})  app_id={aid}")
    print("=" * 64)

    # ---------- 1. 目标版本 ----------
    print("\n1) App 版本")
    versions = asc.get(f"/v1/apps/{aid}/appStoreVersions?limit=10").get("data", [])
    target = next((v for v in versions
                   if v["attributes"]["versionString"] == TARGET_VERSION), None)
    if not target:
        check(False, f"找不到版本 {TARGET_VERSION}")
        return finish()
    state = target["attributes"]["appStoreState"]
    if state in ("PREPARE_FOR_SUBMISSION", "READY_FOR_REVIEW"):
        check(True, f"{TARGET_VERSION} 状态 = {state}（草稿就绪，可提审）")
    elif state in ("WAITING_FOR_REVIEW", "IN_REVIEW"):
        note(f"{TARGET_VERSION} 状态 = {state} —— 已提交，Apple 尚未开始/正在审核",
             "下方第 6 节会核对「提交内容是否完整」；若漏了内购，见第 6 节的撤回办法")
    elif state in ("DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED"):
        note(f"{TARGET_VERSION} 状态 = {state} —— 已被拒/已撤回，需处理后可重新提交")
    else:
        check(False, f"{TARGET_VERSION} 状态 = {state}",
              "非预期状态 —— 先处理该状态（见 ASC 版本页）再提审")

    for v in versions:
        a = v["attributes"]
        mark = " ← 目标" if a["versionString"] == TARGET_VERSION else ""
        print(f"      {a['versionString']:8} {a['appStoreState']}{mark}")

    vid = target["id"]

    # ---------- 2. 构建包 ----------
    print("\n2) 构建包")
    build = asc.get(f"/v1/appStoreVersions/{vid}/build").get("data")
    check(bool(build), "已挂构建包",
          "去版本页「构建版本」区选一个已上传的构建")
    if build:
        ba = build["attributes"]
        print(f"      已挂: {ba.get('version')} / processing={ba.get('processingState')}")
        builds = asc.get(f"/v1/builds?filter[app]={aid}&limit=5").get("data", [])
        if builds:
            avail = ", ".join(str(b["attributes"].get("version")) for b in builds)
            print(f"      账号内近期构建: {avail}")

    # pubspec 的 build number 必须与已挂构建一致，否则提审的是旧二进制
    want = _pubspec_build()
    if want:
        attached = str(build["attributes"].get("version")) if build else None
        if attached != want:
            # 先看账号里有没有目标 build —— 决定提示「去改选」还是「先上传」
            have = any(
                str(b["attributes"].get("version")) == want
                and b["attributes"].get("processingState") == "VALID"
                for b in asc.get(f"/v1/builds?filter[app]={aid}&limit=20").get("data", [])
            )
            if have:
                hint = (f"build {want} 已在账号里且 VALID，只是没挂到版本页 —— "
                        f"去 1.0.3 版本页的「构建版本」区，把 build {attached} 改选为 build {want}"
                        f"（不用重新构建/上传）")
            else:
                hint = (f"账号里还没有 build {want} —— 需要 Xcode → Product → Archive "
                        f"→ Organizer → Distribute App 上传 build {want}，再回版本页改选")
            check(False, f"已挂构建与 pubspec 一致（+{want}）", hint)

    # ---------- 3. 多语言元数据 ----------
    print("\n3) 多语言元数据（更新版本必须填「此版本的新增内容」）")
    locs = asc.get(f"/v1/appStoreVersions/{vid}/appStoreVersionLocalizations"
                   f"?limit=50").get("data", [])
    check(bool(locs), f"本地化 {len(locs)} 条")
    for l in locs:
        a = l["attributes"]
        loc = a.get("locale")
        wn = (a.get("whatsNew") or "").strip()
        check(bool(wn), f"[{loc}] 此版本的新增内容",
              "空的 → 提审时会被拦「What's New in This Version 是必填项」")
        desc = a.get("description") or ""
        # 判据：描述里说明了「有付费项」即可，不限定必须出现商品名字样
        paid_hints = ("Pro", "pro", "买断", "一次性", "プロ", "one-time",
                      "purchase", "subscription", "unlock")
        if not any(h in desc for h in paid_hints):
            print(f"      ⚠ [{loc}] 描述里没说明哪些功能需付费 —— "
                  f"建议标注哪些需买断（2.3.1 描述须准确）")

    # App 审核信息（notes）—— 含内购的提交，写清测试路径能显著降低被拒率
    rd = asc.get(f"/v1/appStoreVersions/{vid}/appStoreReviewDetail").get("data")
    if rd is None:
        check(False, "App 审核信息（备注）",
              "版本页「App 审核信息」→ 备注里写清内购入口与测试方式")
    else:
        notes = (rd["attributes"].get("notes") or "").strip()
        check(bool(notes), "App 审核信息有备注",
              "备注为空 → 建议写明：免费范围 / 付费点在设置页 / 一次性买断无订阅")

    # ---------- 4. 内购商品 ----------
    print("\n4) 内购商品")
    iaps = asc.get(f"/v1/apps/{aid}/inAppPurchasesV2?limit=20").get("data", [])
    for p in iaps:
        pa = p["attributes"]
        print(f"      productId={pa.get('productId')!r}  "
              f"type={pa.get('inAppPurchaseType')}  state={pa.get('state')}")

    prod = next((p for p in iaps
                 if p["attributes"].get("productId") == TARGET_PRODUCT_ID), None)
    check(bool(prod), f"商品 {TARGET_PRODUCT_ID} 存在",
          "ASC → 变现 → App 内购买项目 → 新建「非消耗型」，"
          "产品 ID 必须全小写且与代码逐字一致")
    if prod:
        # 状态：提审前需 READY_TO_SUBMIT；已随版本送审后变成 WAITING_FOR_REVIEW/IN_REVIEW
        # /APPROVED 都是**正常的**（别再报 ✗，否则每次送审完都误报「待修」）。
        _iap_st = prod["attributes"].get("state")
        if _iap_st == "READY_TO_SUBMIT":
            check(True, f"{TARGET_PRODUCT_ID} 状态 = {_iap_st}",
                  "只有 READY_TO_SUBMIT 才会出现在提审页的勾选列表里")
        elif _iap_st in ("WAITING_FOR_REVIEW", "IN_REVIEW", "APPROVED"):
            check(True, f"{TARGET_PRODUCT_ID} 状态 = {_iap_st}")
            print("          ℹ 已随版本送审 → 不再是 READY_TO_SUBMIT 是正常的"
                  "（随行是否成功看第 6 节）")
        else:
            check(False, f"{TARGET_PRODUCT_ID} 状态 = {_iap_st}",
                  "需为 READY_TO_SUBMIT 才会出现在提审页的勾选列表里")

        # 审核截图
        shot = asc.get(f"/v2/inAppPurchases/{prod['id']}/appStoreReviewScreenshot")
        check(bool(shot.get("data")), "已上传 App 审核截图",
              "IAP 商品必传截图。拍法见 ASC_ACTION_CHECKLIST.md 第 0 步")

        # 商品本地化条数
        plocs = asc.get(f"/v2/inAppPurchases/{prod['id']}/inAppPurchaseLocalizations"
                        f"?limit=50").get("data", [])
        check(len(plocs) >= 2,
              f"商品本地化 {len(plocs)} 条",
              "至少 en-US + zh-Hans")

        # 价格（基准地区 + 具体档位；注意 Apple 硬限：显示名 2–30、描述 ≤45 字符）
        sched = asc.get(f"/v2/inAppPurchases/{prod['id']}/iapPriceSchedule").get("data")
        if not sched:
            check(False, "价格未设置",
                  "商品页「价格」区选 $3.99 —— 不设价格不会变 READY_TO_SUBMIT")
        else:
            base = asc.get(f"/v1/inAppPurchasePriceSchedules/{prod['id']}"
                           f"/baseTerritory").get("data") or {}
            terr = base.get("id", "?")
            mp = asc.get(f"/v1/inAppPurchasePriceSchedules/{prod['id']}/manualPrices"
                         f"?include=inAppPurchasePricePoint&limit=10")
            pts = [i["attributes"] for i in mp.get("included", [])]
            if pts:
                price = pts[0].get("customerPrice")
                check(str(price) == "3.99",
                      f"价格 = {price}（基准地区 {terr}）",
                      "预期 $3.99 —— 去商品页「价格」区改")
            else:
                print(f"      ℹ 基准地区 {terr}，具体价格档读不到 → 网页确认 $3.99")

    # 有没有大小写不符的遗留商品
    strays = [p["attributes"].get("productId") for p in iaps
              if p["attributes"].get("productId") != TARGET_PRODUCT_ID]
    if strays:
        print(f"      ⚠ 还有非目标商品（大小写不符的遗留？）: {strays} "
              f"→ 核对是否该删掉")

    # ---------- 5. 订阅遗留 ----------
    print("\n5) 订阅（本次全部弃用）")
    groups = asc.get(f"/v1/apps/{aid}/subscriptionGroups?limit=20").get("data", [])
    for g in groups:
        subs = asc.get(f"/v1/subscriptionGroups/{g['id']}/subscriptions"
                       f"?limit=20").get("data", [])
        names = [s["attributes"].get("productId") for s in subs]
        print(f"      组 {g['id']} ref={g['attributes'].get('referenceName')!r} "
              f"订阅={names}")
    if groups:
        print("      ℹ 本次不做订阅 → 建议在 ASC 里删掉这些组（不影响单档买断）")

    # ---------- 6. 提交内容完整性（App 版本 + 内购必须同在一个提交里）----------
    # 首个非消耗型内购必须与 App 版本挂在同一个 reviewSubmission，否则内购不会被审核。
    # 判据一（主）：内购 state —— 随提交送审后会从 READY_TO_SUBMIT 变成 WAITING_FOR_REVIEW。
    # 判据二（辅）：解码 item id 判断条目类型（纯数字 = App 版本；UUID = 内购等）。
    SUBMITTED[0] = False   # 是否已有「已发出」的提交（影响结尾那句结论）
    print("\n6) 提交内容完整性（App 版本 + 内购必须同在一个提交里）")
    iap_state = prod["attributes"].get("state") if prod else None
    subs = asc.get(f"/v1/reviewSubmissions?filter[app]={aid}&limit=20").get("data", [])
    active = [s for s in subs if s["attributes"].get("state")
              in ("READY_FOR_REVIEW", "WAITING_FOR_REVIEW", "IN_REVIEW")]
    if not active:
        note("当前没有进行中的提交（草稿 / 等待审核 / 审核中）",
             "去版本页点「添加以供审核」后会生成草稿，届时重跑本检查")
    for s in active:
        st = s["attributes"].get("state")
        when = str(s["attributes"].get("submittedDate") or "尚未提交")[:19]
        items = asc.get(f"/v1/reviewSubmissions/{s['id']}/items"
                        f"?limit=50").get("data", [])
        kinds = [decode_item_kind(i["id"]) for i in items]
        n_ver, n_other = kinds.count("version"), kinds.count("iap")
        print(f"      提交 {s['id'][:12]}… state={st} submitted={when}")
        print(f"        条目构成：App 版本 {n_ver} 个 · 内购/其它 {n_other} 个"
              f"（共 {len(items)}）")

        if st in ("WAITING_FOR_REVIEW", "IN_REVIEW"):
            SUBMITTED[0] = True
            # 已提交 —— 只需确认内购有没有跟着走
            if not prod:
                note("未找到内购商品，跳过「随行」检查")
            elif iap_state == "READY_TO_SUBMIT":
                check(False, "内购已随本次提交送审",
                      "提交已发出，但内购仍是「准备提交」→ 内购不会被审核。"
                      "补救：ASC →「App 审核」→ 选中该提交 → 页面底部「取消提交」；"
                      "或版本页顶部「将此版本从审核中移除」。回到可编辑状态后，"
                      "把内购加入同一提交再重新提交")
            else:
                check(True, f"内购已随提交送审（内购状态 {iap_state}）")
        elif n_ver >= 1 and n_other >= 1:
            check(True, f"草稿含 App 版本 + 内购（共 {len(items)} 项），可提交")
        elif n_ver >= 1:
            check(False, "草稿含 App 版本但缺内购",
                  f"去「变现 → App 内购买项目」点进 {TARGET_PRODUCT_ID}，"
                  f"点「添加以供审核 / 添加至提交项目」，选【加入现有提交内容】"
                  f"（别点「创建新提交内容」）")
        else:
            check(False, "草稿含内购但缺 App 版本",
                  "去 1.0.3 版本页点右上角「添加以供审核」，"
                  "选【加入现有提交内容】（别点「创建新提交内容」）")

    return finish()


def finish():
    print("\n" + "=" * 64)
    if fail_n == 0:
        if SUBMITTED[0]:
            print(f"✅ 全部 {ok_n} 项通过 —— 已提交送审，接下来等 Apple（别再动 ASC 内容）\n")
        else:
            print(f"✅ 全部 {ok_n} 项通过 —— 可以去 ASC 提交审核了\n")
    else:
        print(f"❌ {fail_n} 项待修 / {ok_n} 项通过 —— 上面带 → 的就是怎么修\n")
    print("提示：内购是否已随版本送审，看第 6 节 ——\n"
          "      已提交时以「内购状态」为准（随行后应为 WAITING_FOR_REVIEW）；\n"
          "      草稿时以「条目构成」为准（App 版本 1 + 内购 1 = 2 项）。\n")


if __name__ == "__main__":
    main()
