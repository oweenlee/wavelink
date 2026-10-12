# ASC 执行清单：付费下载 → 免费下载 + $3.99 买断

> 生成：2026-10-08（用 ASC API 只读核实过当前状态）
> **这份是唯一要照着做的清单。** 背景与设计依据见 `FREEMIUM_MIGRATION.md` 与 `IAP_SETUP.md`。
>
> **已拍板**：不做老用户豁免（确认 0 付费用户）· **放开网络音源与 AutoEQ** →
> Pro 只剩 **房间校正 + Bit Perfect** · 因此**必须重新构建上传 build 6**。

---

## 🔴 当前状态（2026-10-12 更新 —— 第二次被拒）

**两次被拒的经过**

| 轮次 | 被审版本 | 提交 ID | 审核日 | Apple 给的条款 |
|---|---|---|---|---|
| 第 1 次 | 1.0.3 **(6)** | `ada1ef04-ecb3-4d06-b254-800684fb314f` | 10-09 | **5.2.1**（截图第三方封面）+ **2.1(b)**（引用 Monthly 但内购没送审） |
| 第 2 次 | 1.0.3 **(7)** | `d04ee7bd-22ac-43b1-85dd-1d2164bd4098` | 10-12 | **只剩 5.2.1**（截图第三方封面） |

### ✅ 2.1(b) 已彻底解决

第 2 次审核**不再提 Monthly** → build 7 里「付费墙只查买断」的修复生效。版本页现挂 **build 7（VALID）**。

### 🔴 5.2.1 仍在，根因 100% 定位：**这 20 张截图根本没换过**

把 ASC 上当前 20 张截图下载下来，与 10-09 那批作**内容哈希（MD5）**对比：**逐张完全相同**。

```
00 现=d490924a4c62  10-09原图=d490924a4c62   ★ 完全相同
01 现=b9eb3c7282db  10-09原图=b9eb3c7282db   ★ 完全相同
…（10 张全部一致）
```

→ 上一次只换了 build，**截图原样重提**，Apple 看到的还是同一批含真实专辑封面/歌词的图 → 必然同样被拒。

> 💡 截图属于**元数据**，与二进制无关：**这次不需要重新构建，只要换掉那 20 张图**。
> 素材已备好：`~/Desktop/WaveLink-Demo-Pack`（8 张原创封面 + 8 首合成演示曲目，全部代码生成、
> 封面已内嵌、**不含歌词**）→ 做法见**第 10 步**。

### 🟢 提交条目仍然齐全（依旧不用重新拼）

当前提交 `d04ee7bd…` 实测仍含 2 个条目：

```
item state=READY_FOR_REVIEW | 内购/其它(UUID)  f44adf38-…
item state=REJECTED         | App 版本 (891989353)
```

→ 换完截图后，**在同一个提交上点「提交以供审核」**即可。⛔ 不要新建提交，也不要再动版本/内购的归属。

### 历史（第 1 次的完整归因，留档）

| 条款 | Apple 原文要点 | 归因 |
|---|---|---|
| **5.2.1** | `The app includes protected album cover artworks in app icons, screenshots or previews without the necessary authorization.` | **App Store 截图**（第 10 步） |
| **2.1(b)** | `the app includes references to Monthly but the associated In-App Purchase products have not been submitted for review.` | build 6 付费墙仍查 `wavelink_pro_monthly` → ✅ 已由 build 7 修掉 |

被拒理由**不是**「隐私政策 404」——那是我当时的推测，它仍是隐患，但已在 build 7 里顺手修掉：

| 问题 | 根因 | 状态 |
|---|---|---|
| 付费墙「隐私政策」链接 **HTTP 404** | 指向 `…/wavelink/privacy-policy/`，该路径从未部署到 gh-pages | ✅ 改为 `https://oweenlee.github.io/wavelink/`（实测 200，与 ASC 元数据 privacyPolicyUrl 同页） |
| 权益剥夺会误删免费功能 | 退款时 `proRevocationHandler` 会清 AutoEQ，但 AutoEQ 已免费 | ✅ 剥夺清单收窄为 Bit Perfect + 房间校正 |
| 自检脚本假绿灯 | 版本被 Apple 拒时仍报「可以去提交审核了」 | ✅ 现区分 `REJECTED` / `DEVELOPER_REJECTED`，并把 `UNRESOLVED_ISSUES` 纳入校验 |

---

## 🔴 本轮动作清单（按顺序，别跳步）

1. **把 8 首演示曲目装到 iPhone 上**（`~/Desktop/WaveLink-Demo-Pack/music`）——
   AirDrop 文件夹 →「文件」App → App 内「文件导入」全选导入；并把原来的真实音乐移除/隐藏
2. **重拍并替换 App Store 截图**（20 张 = 6.1" 10 张 + 6.5" 10 张）—— 见第 10 步
3. **换掉内购审核截图**（现在那张是旧付费墙 3 张卡 + 红字错误）—— 见第 1 步
4. **重新提审**：在同一提交 `d04ee7bd-22ac-43b1-85dd-1d2164bd4098` 上点「提交以供审核」—— 见第 6 步
5. **在解决中心回一句**（英文，见第 11 步）—— 说明已移除第三方素材
6. ~~重建上传 build 7~~ ✅ **已完成**（版本页已挂 build 7，本次**无需**再构建）

---

## 随时可跑的自检

```bash
python tools/asc_preflight.py
```

提审前跑一次，一眼看到还差什么（只读，安全）。共 6 组：

版本状态 · 构建包（含与 pubspec 是否一致）· 元数据（whatsNew + **审核备注**）·
内购商品（状态 / 截图 / 本地化 / **价格**）· 订阅遗留 · **提审草稿条目数**

> 💡 最后一组是判断「**内购有没有挂进提交**」的可靠办法：
> 草稿里 **App 版本 + 内购 = 2 个条目**；**只有 1 个 = 内购没挂**。
> （`reviewSubmissionItems` 不允许单条查询，只能这样间接验证。）

---

## 前置：当前实况（2026-10-08 实测）

| 对象 | 状态（2026-10-08 20:10 实测） |
|---|---|
| 线上 1.0.2 | `READY_FOR_SALE`，仍付费 $3.99 |
| 待发 1.0.3 | 🔴 **`REJECTED`**（10-12 第二次被拒，仅 5.2.1）· 挂着 **build 7**（VALID）· 发布方式 = 手动（`MANUAL`）· 三语言「新增内容」+ 描述已填 |
| build 7 上传 | ✅ 已完成（10-10）—— 签名权限问题已由账户持有人登录 Xcode 解决 |
| 1.0.3 元数据 | ✅ 三语言 whatsNew 已填（en 354 / zh 166 / ja 225 字符），描述已改成「免费 + 买断」口径 |
| 旧 `WaveLink_Pro` / `wavelink_pro_monthly` / 订阅组 | ✅ ASC 已删（订阅组为空、不可售）。⚠️ 旧版 v1 接口仍列出 `wavelink_pro_monthly` / `WaveLink_Pro` 的**历史记录**，但代码已不再查询它们 |
| 新商品 `wavelink_pro` | ✅ **已建且已就绪**：`READY_TO_SUBMIT` · 5 语言本地化 · 审核截图 · 审核备注 · **价格 $3.99（基准地区 USA）** |
| **App 审核信息备注** | ✅ **已填**（659 字符，预检第 3 组显示「有备注」） |
| **进行中的提交** | 🔴 提交 `d04ee7bd-22a…` = **`UNRESOLVED_ISSUES`**（10-12 被 Apple 拒绝）· 内含 2 项（App 版本 + 内购）→ 换完截图在同一提交重提，见第 6 步 |
| **App Store 截图** | 🔴 **仍是 10-09 那批含真实专辑封面/歌词的图**（MD5 逐张相同）→ **本轮唯一待办**，见第 10 步 |

### 功能边界（2026-10-08 调整后）

| | 功能 |
|---|---|
| **免费** | 本地播放全套（曲库 / 播放列表 / 歌词 / 基础 EQ）· **NAS/SMB** · **WebDAV** · **Subsonic / Navidrome / Jellyfin** · **AutoEQ** |
| **Pro**（买断 $3.99） | **房间校正** · **Bit Perfect 输出** |

> 🔴 别忘了根因：代码用 `wavelink_pro`（全小写），ASC 里原来那个是 `WaveLink_Pro`
> （大写）—— 这是两个不同商品，导致**线上付费墙从来没拉到过商品**。新建的商品 ID
> 必须**全小写**。

---

## 第 0 步 · 构建并上传 build 6

门控逻辑是编译进二进制的，改了功能边界就必须出新包（build 5 里还是旧边界）。

### 0-1 归档 ✅ 已完成（2026-10-08 命令行）

已生成 `build/ios/archive/Runner.xcarchive`（**1.0.3 / build 6 / com.wavelink.player**）。
**不需要再点 Xcode 的 Archive。** 用的是 `flutter build ipa --release`，
归档那一步成功（175s），只有导出 IPA 失败。

### 0-2 导出并上传 ✅ 已解决（2026-10-08）

> 留档：曾卡在 `Cloud signing permission error`。根因是团队无本地分发证书、
> 走 Apple **云托管分发证书**，而本机 ASC key 是 App Manager 级别（Apple 硬限制只有
> **Admin 级别的 key** 能签）。**最终由账户持有人 `ds_ios@163.com` 登录 Xcode 解决。**

> ℹ️ 不用管 fastlane（它当前是坏的），也别尝试用它。
> ⚠️ 改 `ios/Runner.xcodeproj/project.pbxproj` 前必须先 ⌘Q 退出 Xcode。

---

## 第 1 步 · 拍内购审核截图

IAP 商品**必须**上传审核截图。付费墙刚改过样式，重拍一张。

> 🔴 **2026-10-09 补充：现在 ASC 上那张是旧付费墙**（3 张功能卡 + 一行红色
> 「暂时无法获取购买信息，请检查网络后重试」），与 build 7 的界面不一致 → **本轮要换掉**。
> 拍的时候按下面第 4 条的最终形态核对（**只有 2 张卡** + 免费说明行 + 单张买断卡显示价格）。

1. Xcode 打开 `ios/Runner.xcworkspace`，选任意 iOS 模拟器
2. `Product → Run`（scheme 已绑 `WaveLinkPro.storekit`，走本地 StoreKit，不扣款）
3. 进 App「设置」页 → 点 **房间校正** 或 **Bit Perfect** → 进付费墙
4. 确认画面是：
   - 标题 **WaveLink Pro**
   - 副标题：**Room correction and bit-perfect output. One-time purchase, no subscription.**
   - 小字：**Already free: local playback, network libraries (NAS/WebDAV/Subsonic) and AutoEQ.**
   - **只有两张功能卡**：Room correction / Bit-perfect output
   - 按钮：**Buy once · $3.99**
5. `⌘S` 截图存桌面
6. 尺寸若 ASC 报错，缩放到 1170×2532：
   ```bash
   sips -z 2532 1170 桌面截图.png --out iap_review_1170x2532.png
   ```

> ⚠️ 必须从 **Xcode 里 Run**。`flutter run` 不会注入 scheme 的 StoreKit 本地配置，
> 跑出来只会是错误空态（就是旧那张截图里的红字）。
>
> 🔧 **若在 Xcode 里 Run 仍是红字错误**：说明 scheme 的 StoreKit 配置没生效。
> 不要去手改 `.xcscheme` 的路径（格式敏感、容易写错），直接走 UI 让 Xcode 自己写：
> `Product → Scheme → Edit Scheme… → Run → Options → StoreKit Configuration`
> → 下拉选 **WaveLinkPro.storekit** → Close。之后再 Run 就能看到 $3.99 的买断卡。

---

## 第 2 步 · 删掉旧的 `WaveLink_Pro` ✅ 已完成（2026-10-08）

留档，无需重做。路径与做法：

```
App Store Connect → 「App」板块 → WaveLink HiFi
  → 左侧边栏 「变现」（英文 Monetization；旧版界面叫「功能」）
  → 「App 内购买项目」→ 鼠标悬停到 WaveLink_Pro 那一行 → 「删除」→ 确认
```

- 商品处于**「正在审核」**时删不掉；已可售的需先下架。`READY_TO_SUBMIT`（从未送审）可直接删
- ⚠️ Product ID **一经删除，同一 App 内永久不可复用** —— 只能「删了重建」，不能「改名」
- 权限需「账户持有人 / 管理 / App 管理」；**「开发者」职能是只读的**

---

## 第 3 步 · 新建买断商品 `wavelink_pro` @ $3.99

> 🟡 **进度（10-08 18:47 API 实测）**：商品壳**已建好** ——
> ID `wavelink_pro` ✅ / 类型「非消耗型」✅ / 审核截图已传 ✅ / 价格计划已建 ✅。
> **还差「本地化」0 条** → 这就是状态卡在 `MISSING_METADATA` 的唯一原因。
> 把下面表格里的 5 语言**显示名称 + 描述**填完，状态才会变 `READY_TO_SUBMIT`。
> 另：`reviewNote`（审核备注）为空，建议一并填上下面的英文备注。
>
> ⛔ **API 代写这条路已试过，走不通（10-08 18:52）**：用 `tools/asc_write_metadata.py`
> 探测写入第一条本地化即被拒 —— `403 FORBIDDEN_ERROR / The API key in use does not
> allow this request`。→ 说明本机这张 key **只有只读权限**（能读不能写）。
> **所以这一节（含第 5 步）的文案只能手工填。** 想以后能代写 → 需在 ASC 建
> **Admin 角色**的 Team Key（见第 0 步解锁法 B）。
> 该脚本已留在仓库里，换成 Admin key 即可直接跑。

**「变现」→「App 内购买项目」→ 右上「+」→ 类型选「非消耗型」**

| 字段 | 填什么 |
|---|---|
| 产品 ID | **`wavelink_pro`** ← 全小写，必须和代码逐字一致 |
| 参考名称 | `WaveLink Pro Lifetime`（仅内部可见，用户看不到） |
| 价格 | **$3.99** |
| App Store 审核截图 | 第 1 步拍的那张 |

### 各语言「显示名称 / 描述」（逐字照抄）

Apple 硬限：**显示名称 2–30 字符，描述 ≤45 字符**（超了网页存不进去）。
⚠️ English / Deutsch 两条已按 45 字符上限**精简过**（原稿 47 字符，会被拒）—— 用下表的版本。

| 语言 | Display Name | Description | 字符数 |
|---|---|---|---|
| English (U.S.) | `WaveLink Pro` | `Buy once. Room correction & bit-perfect.` | 40 |
| 简体中文 | `WaveLink Pro` | `一次性买断，永久解锁房间校正与 Bit Perfect 输出` | 30 |
| Deutsch | `WaveLink Pro` | `Einmalkauf: Raumkorrektur & bit-perfect.` | 40 |
| 日本語 | `WaveLink Pro` | `ルーム補正と Bit Perfect 出力。買い切りで永久アンロック` | 34 |
| 한국어 | `WaveLink Pro` | `룸 보정 & Bit Perfect 출력. 일시불 구매.` | 30 |

### 审核备注（同一商品的「审核信息」里，英文）

```
WaveLink HiFi is free to download. Local playback, network music sources
(NAS/SMB, WebDAV, Subsonic/Navidrome/Jellyfin) and AutoEQ headphone correction
are all free — no purchase required.

WaveLink Pro is a one-time, non-consumable in-app purchase that permanently
unlocks room correction and bit-perfect output. No subscriptions, no account
required. Sandbox test account provided below.
```

完成后确认状态到 **`READY_TO_SUBMIT`**（别停在 `MISSING_METADATA`）。

---

## 第 4 步 · 清掉订阅遗留

**「变现」→「订阅」** → 选中订阅组 `WaveLink Pro` → 删除

- 组内订阅已经清空，删组不影响任何东西
- ⚠️ 严格说这**不是提审前置条件**（空订阅组无害），赶时间可以放到最后

---

## 第 5 步 · 补 1.0.3 的元数据 ⚠️ 漏了会卡住提审

1.0.3 只有 en-US / zh-Hans / ja 三个语言，**三个语言的「此版本的新增内容」全是空的**。
更新版本必填这一项，不填会在提交时被拦。

### 「此版本的新增内容」（逐字粘贴）

**en-US**
```
WaveLink HiFi is now free to download.

New in this version: network music sources (NAS/SMB, WebDAV, Subsonic/Navidrome/Jellyfin) and AutoEQ headphone correction are now completely free — alongside local playback, playlists, lyrics and basic EQ.

Pro adds room correction and bit-perfect output, unlocked with a single one-time purchase. No subscription.
```

**zh-Hans**
```
WaveLink HiFi 改为免费下载。

本次更新：网络音源（NAS/SMB、WebDAV、Subsonic/Navidrome/Jellyfin）与 AutoEQ 耳机校正已全部免费开放，与本地播放、播放列表、歌词、基础 EQ 一样永久可用。

Pro 提供房间校正与 Bit Perfect 输出，一次性买断解锁，无需订阅。
```

**ja**
```
WaveLink HiFi は無料ダウンロードになりました。

今回の更新：ネットワーク音源（NAS/SMB、WebDAV、Subsonic/Navidrome/Jellyfin）と AutoEQ ヘッドホン補正がすべて無料になりました。ローカル再生、プレイリスト、歌詞、基本EQ と同様にずっと無料です。

Pro ではルーム補正と Bit Perfect 出力を提供。買い切りの一度のお支払いでアンロックされます。サブスクリプションはありません。
```

### 同时改「描述」

要点：**NAS / WebDAV 已免费，不能再标 (Pro)**；Pro 只列房间校正与 Bit Perfect。

**en-US**
```
HiFi sound, zero compromise. WaveLink HiFi is an ad-free, account-free music player built for lossless listening.

• Lossless playback — FLAC, WAV, ALAC, APE and more
• Your own library — stream from your NAS, WebDAV or Subsonic server
• AutoEQ headphone correction — thousands of profiles, one tap
• Pure sound — high-performance native audio engine with stable, low-latency output
• No ads, no tracking, no login required

Free download. Room correction and bit-perfect output unlock with a single one-time purchase. No subscription.
```

**zh-Hans**
```
HiFi 音质，毫不妥协。WaveLink HiFi 是一款无广告、无需账号的高解析音乐播放器，为无损聆听而生。

• 无损本地播放 — 支持 FLAC、WAV、ALAC、APE 等主流格式
• 连接你的音乐库 — 直接串流 NAS、WebDAV 或 Subsonic 服务器
• AutoEQ 耳机校正 — 数千条曲线，一键匹配
• 原生高性能音频引擎 — 输出稳定、低延迟、纯净还原
• 无广告、无追踪、无需登录

你的音乐，你的服务器，你的隐私。

免费下载。房间校正与 Bit Perfect 输出通过一次性买断解锁，无需订阅。
```

**ja**
```
ハイレゾサウンドを、妥協なく。WaveLink HiFi は、広告もアカウント登録も不要のロスレス音楽プレーヤーです。

• ロスレス再生 — FLAC、WAV、ALAC、APE など主要フォーマットに対応
• 自分のライブラリを接続 — NAS、WebDAV、Subsonic サーバーを直接ストリーミング
• AutoEQ ヘッドホン補正 — 数千のプロファイルをワンタップで適用
• ネイティブ高性能オーディオエンジン — 安定した低遅延でクリアな音質を再現
• 広告なし、トラッキングなし、ログイン不要

あなたの音楽、あなたのサーバー、あなたのプライバシー。

無料ダウンロード。ルーム補正と Bit Perfect 出力は買い切りの一度のお支払いでアンロックされます。サブスクリプションはありません。
```

---

## 第 6 步 · 提审 1.0.3（App 版本与内购必须同一个提交）✅ **已完成（2026-10-08 20:29:58）**

> ### 🔴 被拒后：**不需要重新拼提交**（第二轮实测同样成立）
> 被拒提交 `d04ee7bd-22ac-43b1-85dd-1d2164bd4098`（10-12 被拒）里 **2 个条目都还在**：
> ```
> item state=READY_FOR_REVIEW | 内购/其它 (UUID)  f44adf38-…
> item state=REJECTED         | App 版本 (891989353)
> ```
> → 只需「换截图 → 在**同一个提交**上点**提交以供审核**」。
> ⛔ **不要新建提交**、不要再走一遍合并两个草稿的流程（那个坑踩过了，见下）。
> ⚠️ 唯一要小心的是：**别让「版本」先单独提交出去**（那会把提交拆成两个，得整个撤回重来）。

> ### ✅ 结果：提审成功
> 预检 12/12 全绿，关键两行：
> ```
> 6) 提交内容完整性
>       提交 ada1ef04-ecb… state=WAITING_FOR_REVIEW submitted=2026-10-08T12:29:58
>         条目构成：App 版本 1 个 · 内购/其它 1 个（共 2）
>   [✓] 内购已随提交送审（内购状态 WAITING_FOR_REVIEW）
> ```
> 1.0.3 = `WAITING_FOR_REVIEW`、`wavelink_pro` = `WAITING_FOR_REVIEW`（**随行成功**，
> 这是内购真被送审的标志）。**接下来等 Apple，不要再动 ASC 里这个版本/商品的任何内容** ——
> 改动可能导致审核被推迟或重新排队。审核期间可随时重跑预检看状态。
> 通过后立刻做**第 7 步（先手动发布）**，再走第 8 步（改价免费）—— 顺序不能反。

先跑 `python tools/asc_preflight.py` 确认全绿。

1. ~~「构建版本」→ 选 **build 6**~~ ✅ **已完成**（版本页现挂 build 6）
2. **让「App 版本 1.0.3」+「wavelink_pro」出现在同一个提交里** —— 缺一半都不行

### 官方流程（依据 Apple 帮助《提交 App 内购买项目》）

**入口在「变现 → App 内购买项目」，不在版本页。** 官方原文关键句：

> If your In-App Purchase requires a new app version, **select a platform and the
> app version to include in your submission**.

即：点「添加以供审核」后会**弹窗**，弹窗里要**勾选 App 版本 1.0.3** ——
**这一步漏掉就是上次失败的原因**（只把内购加进了提交，App 版本没跟着）。

```
变现 → App 内购买项目 → 点进 wavelink_pro
  → 点右上角蓝色「添加以供审核」(Add for Review)   ← 必须在「详情页」之外点，见下方 ⚠️
  → 弹窗：① 平台选 iOS  ② 【选 App 版本 1.0.3】  ③ 有草稿才出现「加入现有提交内容」
  → 进入提交内容页，确认列出 2 项 → 「提交以供审核」
```

> ⚠️ **「选 App 版本」不出现在内购详情页上。** 详情页（状态 / 产品 ID / 价格 /
> 本地化 / 审核截图那一页）**只有一个蓝色「添加以供审核」按钮**；
> 平台 + App 版本的选择器**在点了这个按钮之后才弹出的对话框里**。
> 官方帮助原文：
> 「点按"添加以供审核"。你可以将项目添加至现有提交内容（如有），或点按"创建新提交内容"。
> **如果 App 内购买项目或订阅需要新的 App 版本，请选择要添加到提交内容中的平台和 App 版本。**」
> —— 找不到勾选框时，先确认「真的点了那个蓝按钮、并且弹窗真的弹出来了」。

### 2026-10-08 晚 实况（取消审核 + 预检复核后）

| 对象 | 状态 |
|---|---|
| 1.0.3 版本 | `DEVELOPER_REJECTED`（已移出审核队列，可重新添加） |
| 内购 `wavelink_pro` | `READY_TO_SUBMIT`（**未随行**） |
| 提交（草稿/待审/审核中） | **一个都没有** —— 取消审核时那个「只含内购 1 项」的草稿已被一并撤掉 |

> 📌 因此现在点「添加以供审核」**不会**出现「加入现有提交内容」选项（没有旧草稿），
> 只会让你「选平台 + 选 App 版本」或「创建新提交内容」。这是正常的，不是出错。

**两条路，任选其一（都能把 2 项凑进同一个提交）**：

- **A（推荐，先版本后内购）** 分发 → App 版本 → **1.0.3** → 点「添加以供审核」
  → 生成含 App 版本的草稿 → 回到 变现 → App 内购买项目 → `wavelink_pro`
  → 「添加以供审核」→ 弹窗里选**已有的那个提交**（此时版本已在里面）
- **B（先内购）** 变现 → App 内购买项目 → `wavelink_pro` → 「添加以供审核」
  → 弹窗里**选平台 iOS + 选 App 版本 1.0.3**（若此处列表里**没有 1.0.3**，
  说明该版本还没回到可加入状态 → 改写走 A）

### 🔴 2026-10-08 20:22 实况（版本已单独送审 → 必须先撤回再合并）

预检实测：

| 提交 ID | 状态 | 条目构成 |
|---|---|---|
| `40ebb6c1-1b9…` | **`WAITING_FOR_REVIEW`**（`submitted = 2026-10-08T12:19:50`） | App 版本 **1** 个 · 内购 **0** 个 |
| `ada1ef04-ecb…` | `READY_FOR_REVIEW`（草稿，20:20 创建） | App 版本 **0** 个 · 内购 **1** 个 |

1.0.3 版本状态已变成 `WAITING_FOR_REVIEW`。
→ 用户在内购之前，先从**版本页**把 1.0.3 单独提交了；随后去内购页点「添加以供审核」，
因为**已经没有草稿**（版本那个提交已经发出去了，不是草稿），于是又新建了一个只含内购的草稿。
这正是截图里 ⚠️「无法提交以供审核 · 首个非消耗型 App 内购买项目必须随新 App 版本提交」的成因 ——
不是缺版本可勾，而是**版本被另一个已提交的提交占住了**。

> ⏱️ **时间成本警告**：一旦 1.0.3 被审核**通过**，这第一个非消耗型内购就**必须再配一个更新的版本
> （1.0.4）**才能送审（官方硬规则）。所以发现后要**尽快撤回**，不要等审核跑完。

**修正顺序（先撤回，再合并，最后提交）**：

1. **撤回**：分发 → App 版本 → 点「1.0.3」→ 页面顶部「**将此版本从审核中移除**」；
   或左侧「App 审核」→ 选中 20:19 那个提交 → 底部「取消提交」。
   等 1.0.3 不再是 `WAITING_FOR_REVIEW`。
2. **合并**（二选一）：
   - **2a** 回那个「草稿提交」面板（变现 → App 内购买项目 → `wavelink_pro` → 「添加以供审核」，
     或侧栏「App 审核」→ 草稿 → 打开它）：看项目列表里是否出现可选的 **1.0.3** → 勾上。
   - **2b** 若面板里没有 1.0.3 可选：去 **1.0.3 版本页 → 右上角「添加以供审核」**，
     若出现下拉，选「**加入现有提交内容**」（**别点「创建新提交内容」**，否则又变两个提交）。
3. **提交**：面板里应列出 **2 项**（1.0.3 + WaveLink Pro Lifetime），⚠️ 消失，按钮变可点 → 「提交以供审核」。
4. **验证**：跑预检，期望看到下面这段（同时内购 state 应从 `READY_TO_SUBMIT` 变 `WAITING_FOR_REVIEW`）。

### 验证

跑 `python tools/asc_preflight.py`，期望第 6 节变成

```
提交 … state=READY_FOR_REVIEW
  条目构成：App 版本 1 个 · 内购/其它 1 个（共 2）
[✓] 草稿含 App 版本 + 内购（共 2 项），可提交
```

> ℹ️ 第 6 节现在会**解码每个条目的类型**，直接告诉你缺的是哪一半。
3. 「App 审核信息」→ **备注（Notes）** 粘下面这段 —— 当前是**空的**，这是提审前最后一项
   - ℹ️ **不需要填沙盒测试账号**：本 App 无需登录，`demoAccountRequired = false` 就是对的
     （旧稿写的「必须填测试账号」只适用于需要登录的 App，不适用这里）
   - 但**备注建议填**：含内购的提交，写清付费点入口能明显降低被拒率

   ```
   WaveLink HiFi is free to download — no account or login required. Local
   playback, playlists, lyrics, basic EQ, network music sources (NAS/SMB,
   WebDAV, Subsonic/Navidrome/Jellyfin) and AutoEQ headphone correction are
   all free.

   The only paid feature is a one-time, non-consumable in-app purchase
   ("WaveLink Pro", $3.99) that permanently unlocks two settings:
     1) Room correction    — Settings → Room correction
     2) Bit-perfect output — Settings → Bit Perfect output

   To test: open the app → Settings → tap "Room correction" (or toggle
   "Bit Perfect output") → the paywall appears with a single lifetime
   purchase option. No subscriptions, no account required.
   ```
4. **「版本发布方式」选「手动发布此版本」** ← 否则审核一过就自动上线，来不及改价
5. 提交审核（**此时 App 价格仍是 $3.99**）

---

## 第 7 步 · 【审核通过后立刻做】先手动发布 1.0.3 👈 **下一个要做的动作**

1.0.3 的发布方式是**手动发布（MANUAL）**，所以审核通过后它不会自动上线，
状态会变成 `PENDING_DEVELOPER_RELEASE`。App 页面会出现「**发布此版本**」→ 点它。
**这一步要先做**，然后才去第 8 步改价。

## 第 8 步 · 紧接着改价免费（无 API，必须网页操作）

ASC → **「价格与销售范围」→ 价格 → 选「免费」** → 存储

- 改价不需要审核，通常数小时生效
- 老用户不会被重新计费；本项目 0 付费用户，无历史包袱

> 🚨 **顺序：先发布 1.0.3 → 确认它「真的上线了」→ 再改价免费。**（2026-10-08 二次修正）
>
> **原理**：App 的**价格是 App 级属性**，改价立刻作用于**当前线上的那个版本**，
> 跟你想发的新版本无关。所以「什么时候改价」= 「想让哪个版本吃到免费流量」。

> ### ⚠️ 重要更正：我曾写过「1.0.2 一个门控都没有」——**这是错的**
>
> 错因：本机 Bash 里管道中的 `grep` 会**静默失败**（无输出、退出码却是 0），
> 我据此得出了「1.0.2 无门控」的假结论。改用 `git grep` 实测
> 线上 1.0.2 对应提交 `9b574ec`（`version: 1.0.2+7`，发布日 2026-08-28，`git merge-base` 确认是 HEAD 祖先）：
>
> | | 线上 **1.0.2** (`9b574ec`) | 新的 **1.0.3** |
> |---|---|---|
> | 房间校正 | 🔒 锁 | 🔒 锁 |
> | Bit Perfect | 🔒 锁 | 🔒 锁 |
> | AutoEQ | 🔒 **锁** | ✅ **免费** |
> | NAS/SMB · WebDAV · Subsonic | ✅ 免费 | ✅ 免费 |
>
> **两者真正的差异只有 AutoEQ 一项**，不是「零门控白送全套」。
> 旁证：`memory/2026-09-09.md` 当时记的就是「门控点 3 个：AutoEQ、房间校正、Bit Perfect」。

> #### 那么先改价的实际代价是什么
>
> 窗口期内新用户免费拿到的是 **1.0.2**：
> - 房间校正 / Bit Perfect **仍然锁着** → **Pro 的卖点并没有流失**（这一点我原先夸大了）
> - **但 AutoEQ 在 1.0.2 里是锁的**，点它会跳付费墙 → 用户会以为 AutoEQ 要花 $3.99 买，
>   而我们的本意是免费给。**可能造成「为本来免费的功能付费」的误导性购买，以及退款/差评。**
> - 1.0.2 查的商品 ID 正是 `wavelink_pro`（小写），所以它的付费墙**真的能成交** —— 这一点让误导更实。
>
> 先发布 1.0.3 就没有这个问题。代价只是「1.0.3 已上线但仍标 $3.99」的一小段窗口 ——
> 而这本来就是现状（App 一直 $3.99），不算新增风险。

> #### 两个操作细节
>
> ⚠️ **别在「点完发布按钮」的那一刻就改价**：发布到真正上架有延迟（Apple 称最长约 24 小时）。
> 必须等 **App Store 上确实显示 1.0.3** 再改，否则又回到「价格已免费、线上还是 1.0.2」的窗口。
> 验证（只读）：
> ```bash
> curl -s "https://itunes.apple.com/lookup?id=6802973339&country=us" \
>   | python3 -c "import sys,json;d=json.load(sys.stdin)['results'][0];print(d['version'], d['formattedPrice'])"
> ```
> 看到 `1.0.3 3.99` → 可以改价了；（改完再查一次应显示 `1.0.3 0.0` / 免费）
>
> ⚠️ **1.0.3 的发布方式必须是「手动发布」**（见第 6 步）。若留在「审核通过后自动发布」，
> 审核一过就自动上线，你可能还在睡觉 —— 这里倒不是怕价格问题，而是失去
> 「确认已上线再改价」这个可控节奏。

---

## 第 9 步 · 上线后自测（沙盒账号）

- [ ] 免费下载 App → 本地播放、曲库、播放列表、歌词、基础 EQ **全部可用**
- [ ] **NAS / WebDAV / Subsonic / AutoEQ 也能直接用，不弹付费墙、不显示 PRO 徽标**
- [ ] 点 **房间校正** / **Bit Perfect** → 跳付费墙（其余入口不应再跳）
- [ ] 付费墙显示：两张功能卡 + `Buy once · $3.99`（**不是**错误空态）
- [ ] 购买 → 房间校正与 Bit Perfect 解锁
- [ ] 卸载重装 → 「恢复购买」→ 权益回来
- [ ] 断网进付费墙 → 显示「重试」按钮，不是白屏

---

## 第 10 步 · 🔴 替换 App Store 截图（5.2.1 被拒的直接原因）

> ### ⚠️ 先看：上次为什么又挂了一次
> 10-12 那次审核，**这 20 张截图与 10-09 的逐张 MD5 完全相同** —— 只换了 build，图没换。
> 截图是**元数据**，与二进制无关：本次**不用重新构建**，只换图就能解决。

### 实测：侵权内容在**截图**里，其余位置都干净

| 位置 | 结论 |
|---|---|
| App 图标 | ✅ 干净（橙色波形 logo，无第三方内容） |
| App 预览视频 | ✅ **无**（ASC 上预览组 = 0） |
| App 内打包资源 | ✅ 干净（`assets/` 只有 `fonts/` 与 `splash/`，无任何封面图） |
| **App Store 截图** | ❌ **就是这里**：en-US 下 2 组 × 10 张 = **20 张**，逐张打开确认**全部含第三方内容** |

截图里出现的第三方内容（实测清单）：

- **真实专辑封面**：崔健《新长征路上的摇滚》、王力宏《爱错》《火力全开》、张学友《吻别》、
  张国荣《为你钟情》、优客李林《认错》、李宗盛、蔡健雅、五月天、张震岳、Beyond、
  周华健、赵鑫、黑鸭子、萧煌奇、The Offspring、John Lennon、Hayley Westenra 等
- **真实歌词**：现在播放页直接显示歌词行，例如
  「我從哪裡起飛（愛錯 愛錯）從哪裡降落」「多少不能原諒的錯（Woo 請妳原諒我的愛錯）」
  以及「词：崔健」这类署名

> ⚠️ **歌词同样是第三方版权内容。** Apple 这次只点名封面，但同一批图再送一次，
> 很可能是下一个理由 —— 这次一并清掉。
> 💡 补充：ASC 的 zh-Hans / ja **没有单独截图**（沿用主语言），所以**只需改 en-US 这两组**。

### 两条合规路径（选第 2 条）

Apple 原文给了两条：

1. ~~`please attach documentary evidence in the App Review Information section`~~
   —— 即提供唱片公司授权书，实际不可行
2. ✅ **`remove all protected third-party album cover artwork from the app icons, screenshots and previews`**

### 素材：已做好，直接用

我这边已经程序化生成了一整套**零版权**演示素材（脚本：`tools/gen_asc_demo_assets.py`，可随时重跑）：

```
~/Desktop/WaveLink-Demo-Pack/
├── covers/   8 张原创专辑封面（几何 / 渐变 / 噪点；无文字、无人物、无 logo；1024×1024）
├── music/    8 首合成演示曲目（FLAC，封面已内嵌；元数据全为虚构名称；
│             其中 2 首 96 kHz / 24-bit，便于在截图里体现 hi-res 播放）
├── README.txt
└── manifest.json
```

- **全部由代码生成** → 不含任何第三方素材，不会有 5.2.1 风险
- **不含任何歌词**（无 lyrics 标签、无 `.lrc` 文件）→ 连歌词这个雷一起排掉
- 曲名/艺人名都是虚构的（Lumen Bay、青禾、九伏…）→ 不会指向任何真实作品

### 重拍做法

**目标：截图里不出现任何真实专辑封面、不出现真实歌词。**

1. 把 `music/` 里的 8 首用 **AirDrop** 传到 iPhone（AirDrop 文件夹会自动打包）
2. 「文件」App 里找到它们 → 打开 WaveLink → **文件导入** → 全选导入
3. ⚠️ **把 iPhone 上原来的真实音乐移除 / 隐藏**，否则它们仍会出现在截图里
4. 确认曲库显示的是本包的几何封面；**若有歌词开关，截图前关掉**
5. 按原来的取景与排版重拍 10 张（曲库 / 音源 / 设置 / 播放 / 均衡器 / AutoEQ 各一张）
6. 拍 **6.1" 组（1179×2556）** 10 张；**6.5" 组（1284×2778）** 用同一批图等比缩放：
   ```bash
   sips -z 2778 1284 原图.png --out 目标_1284x2778.png
   ```
7. **替换 ASC 上的 20 张**：ASC → 版本页 → **App 预览与屏幕快照** →
   左侧分别选 **iPhone 6.1 英寸** / **iPhone 6.5 英寸** → 删除旧图 → 拖入新图 → 等处理完成

> 💡 备用方案（更省事但观感差些）：用**完全不内嵌封面**的音频，App 会显示自绘黑胶占位图
> （`CoverPlaceholder`）——同样零版权风险，只是整屏灰阶。
> ⚠️ 6.5" 组历来由 6.1" 图缩放而来，Apple 没提尺寸问题，**保持原样即可**。

### 完成后自检

```bash
python tools/asc_preflight.py    # 第 6 节会看到 1.0.3 仍是 REJECTED，属正常
```

---

## 第 11 步 · 在解决中心回一句（可选但推荐）

位置：ASC 左侧「**App 审核**」→ **解决中心（Resolution Center）** → 该提交 → 回复。

**本轮回复全文（10-12 那次被拒后；只改截图，没有新二进制）：**

```
Thank you for the follow-up.

Guideline 5.2.1 — All third-party album cover artwork and lyrics have now been
removed from the App Store screenshots. The screenshots have been replaced with
new captures that contain only the app's own interface and original, self-generated
artwork (procedurally created, with no third-party material of any kind). The app
icon and previews contain no third-party content either.

The app's own functionality is unchanged; only the store screenshots were updated.
No new binary was required for this change.

Please let us know if anything else is required. Thank you.
```

> 💡 上一轮（10-09 那次）用过的双条款版本，留档备查：
>
> ```
> Thank you for the detailed feedback. Both issues have been addressed:
>
> 1. Guideline 5.2.1 — We have removed ALL third-party album cover artwork and
>    lyrics from the App Store screenshots.
>
> 2. Guideline 2.1(b) — The reference to a "Monthly" purchase has been removed.
>    The product set has been reduced to a single non-consumable in-app purchase
>    (wavelink_pro), and the in-app purchase is included in the same submission.
>
> Please let us know if anything else is required. Thank you.
> ```

> 💡 不写也能过，写了能减少来回。**关键是新二进制 + 干净截图必须已经在提交里。**

---

## 附：不要做的事

- ❌ 不要用 fastlane 发版 —— `flutter build ipa` 那步会失败。**先排查是否只是残留 flutter 进程
  占着 lockfile**（`pkill -f flutter_tools.snapshot`，清掉后 build 通常就正常）；仍不行再走 Xcode Organizer
- ❌ 不要给订阅组补本地化 —— 订阅整个已弃用（组已删）
- ❌ **不要先改价再发布 1.0.3** —— 顺序反了会让免费用户拿到 AutoEQ 仍被锁的 1.0.2，
  点 AutoEQ 跳付费墙 → **误导性付费**（详见第 7/8 步）
- ❌ **不要「点完发布按钮」就立刻改价** —— 发布到真正上架最长约 24h，
  必须先用 `itunes lookup` 确认线上已是 1.0.3
- ❌ 不要把发布方式留在「审核通过后自动发布」
- ❌ 不要用「创建新提交内容」——App 版本与内购必须在**同一个**提交里（见第 6 步）
- ❌ 不要在审核期间改动 ASC 里该版本/商品的任何内容
- ❌ **不要把含真实专辑封面 / 真实歌词的截图提交审核** —— 2026-10-09 与 **10-12** 已因此吃了
  两次 5.2.1（详见第 10 步）；重拍时也别再用带真实封面的曲目
- ❌ 不要在被拒后**新建提交** —— 被拒的提交里 2 个条目都还在，直接改完重提即可（见第 6 步）
- ❌ 不要把「只改了截图」当成需要重新构建 —— 截图是元数据，与二进制无关，
  改完直接重提同一个 build 即可（10-12 那次就是本不必要的重构建）
- ~~❌ 不要忘记把版本页的构建从 5 改成 6~~ ✅ 已完成；**build 6 已被 build 7 取代，版本页现挂 build 7**

---

## 附：全项目排查结果（2026-10-09，`dart analyze` 无问题 / `flutter test` 139 项全过）

### 已修正
| 项 | 说明 |
|---|---|
| 付费墙「按月」卡片 | `proProductIds` 只留买断（见第 1 步） |
| 隐私政策死链 404 | 改为 `https://oweenlee.github.io/wavelink/`（与 ASC 元数据同页） |
| 权益剥夺误清 AutoEQ | AutoEQ 已免费，退款用户的免费设置不该被清 → 剥夺清单收窄为 Bit Perfect + 房间校正 |
| 注释与实现不符 | 月/年历史 ID 的注释原写「用于解析历史交易」，实际既不查询也不参与权益判定 |
| `.gitignore` | 根目录忽略 `/wavelink-ghpages/`（独立 clone，一直污染 `git status`）；去掉重复行 |

### 已核对无问题
版本号链路（pubspec → iOS/Android）、5 个 `.arb` 键集合一致（各 285 键）、
门控仅 2 处、本地 `.storekit` 与 ASC 一致、外链可达、**无密钥入库**、
无 TODO/`print(`、`Info.plist` 权限说明齐备（房间校正不录音，无需麦克风权限）、
ASC 描述与 whatsNew 口径一致、无 CI、Android 签名无硬编码。

### 遗留小项（**均不影响本次提审**，可按需处理）
1. `mobile/ios/File.txt`（内容只有 `https://helloo.cc.cd/`）—— pbxproj 里只剩一个
   PBXFileReference + 根组一行，**不在任何 build phase**，不会打进包。只在 Xcode 显红字。
   清理需删文件 + 删 pbxproj 那 2 行（⚠️ 先 ⌘Q 退出 Xcode）。
2. **Xcode scheme 的 StoreKit 配置路径疑似失效**：`identifier = "../../Runner/WaveLinkPro.storekit"`，
   按惯例（相对 `xcshareddata/xcschemes/`）应为 `../../../Runner/…`。
   只影响 **Xcode Run 的本地测试环境**，不影响上架构建；跑一次 Xcode 即可确认（字段无红字就没事）。
3. `FREEMIUM_MIGRATION.md` / `IAP_SETUP.md` 仍是旧的「月/年 + 买断三档」规划（历史文档）。
4. l10n 中订阅相关文案（`paywallPlanMonthly/Yearly`、`paywallSubscribeButton`、
   `paywallManage`、`paywallTermsSubscription`、`proActiveMonthly/Yearly`）已成**死键**，不会渲染。
