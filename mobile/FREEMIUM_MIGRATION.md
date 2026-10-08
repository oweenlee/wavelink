# WaveLink iOS：付费下载 → 免费下载 + Pro 内购 迁移方案

> 范围：**仅 iOS**（用户明确不考虑 Android）。
> 更新：2026-09-30 第 5 版 · 已用 **App Store Connect API 只读核实线上真实状态**
> 💰 **定价已定稿：只保留买断 `wavelink_pro` @ $3.99，不做订阅**（见 9/30 节内的定价决策）
> ⚠️ **先读下面 9/30 一节**，它推翻了本文多处旧结论。

> 🔴 **2026-10-08 变更（最新）**：**放开网络音源（NAS/SMB、WebDAV、Subsonic）与 AutoEQ**
> → Pro 只剩 **房间校正 + Bit Perfect**。因此：
> ① 本文所有「6 项门控」的表述**已过时**；
> ② **必须重新构建上传 build 6**，不再是「build 5 直接提审」；
> ③ 付费墙文案与商品文案已同步改过。
> **执行请以 `ASC_ACTION_CHECKLIST.md` 为准**（含重写后的商品文案、whatsNew 全文、build 6 步骤）。
> 成本变化：多一次 `Xcode → Archive → Distribute App` 上传。

---

## 🔴 2026-09-30 实测核实（ASC API 只读拉取，本节为当前唯一权威）

**核实方式**：用本机 `~/.fastlane/AuthKey_P4Q97KKSQQ.p8` 走 App Store Connect API
做只读查询。目标 App：`WaveLink HiFi`，`bundleId = com.wavelink.player`，
**app id = `6802973339`**。

| 对象 | 实测状态 | 判定 |
|---|---|---|
| 线上版本 **1.0.2** | `READY_FOR_SALE` | 线上仍是 **付费 $3.99**（未改价） |
| 待发版本 **1.0.3** | `PREPARE_FOR_SUBMISSION` | **从未提交审核**；已挂 build **5**（09-27 上传，`VALID`） |
| 买断商品 | productId = **`WaveLink_Pro`**（⚠️ 见问题 1），state `READY_TO_SUBMIT` | 元数据已齐（含 en-US / de-DE / zh-Hans 等本地化），但**从未提交过审核** |
| 年订阅 `wavelink_pro_yearly` | **不存在** | 必须新建 |
| 月订阅 `wavelink_pro_monthly` | `MISSING_METADATA` | 已挂在订阅组内，但元数据不全 |
| 订阅组 `WaveLink Pro`（id 22334129） | **本地化 0 条** | ← 见问题 3 |
| 审核提交记录 | 最近一次 = **2026-08-28**（那次是 1.0.2） | **1.0.3 没有任何提交记录** |

### 三个必须修的硬问题

**问题 1 · 代码与 ASC 的商品 ID 大小写不匹配 —— 线上买断功能从未真正可购买**

- 代码里是 `proLifetimeId = 'wavelink_pro'`（**HEAD 与线上 1.0.2 都是这个小写写法**，
  已 `git grep 3621d14` 核实）
- ASC 里实际存在的是 **`WaveLink_Pro`**（大写 W / L / P）
- 📚 官方依据（[In-App Purchase information](https://developer.apple.com/help/app-store-connect/reference/in-app-purchase-information)）：
  Product ID **大小写敏感**；且「**一经保存不可修改；即便删除该商品，同一 App 内该 ID 也不可复用**」
- **后果**：`fetchProducts` 永远拿不到商品 → **付费墙是空的**。也就是说线上 1.0.2
  「付 $3.99 下载后还要再买 `wavelink_pro`」这条链路**从来没成交过**（与"0 付费用户"吻合）
- 两条解法（**已决策 → 走方案乙**）：
  - **✅ 方案乙 · 改 ASC → 新建 `wavelink_pro`**（**2026-09-30 用户选定**）：
    删掉 `WaveLink_Pro`、按代码的 ID 重建；**代码零改动 → 已上传的 build 5
    可直接提审，无需重新构建**。代价：要重填 5 种语言的商品本地化文案。
  - ~~方案甲 · 改代码 → `WaveLink_Pro`~~（未采用）：可复用已配好的商品本地化，
    但必须重新构建上传 build 6，而 fastlane 当前是坏的，多一个失败变量。

**问题 2 · `wavelink_pro_yearly` 不存在，且它是本 App 的首个自动续期订阅**

📚 官方依据（[提交 App 内购买项目](https://developer.apple.com/cn/help/app-store-connect/manage-submissions-to-app-review/submit-an-in-app-purchase/)）：
> 「**首个**消耗型、非消耗型、**自动续期订阅**和非续期订阅的 App 内购买项目**都必须随新的 App 版本提交**。」
> 「提交新的订阅时，**必须随其订阅群组一同提交**。」

→ 年订阅必须**与 1.0.3 版本挂在同一个提交里**一起送审；买断商品同理（也是首个非消耗型）。

**问题 3 · 订阅组没有本地化显示名**

订阅组 `22334129` 的 `subscriptionGroupLocalizations` 返回**空数组**。
组本身缺本地化显示名时，组内订阅会卡在非 Ready 状态 —— **`wavelink_pro_monthly`
的 `MISSING_METADATA` 大概率就是它导致的**。新建年订阅前必须先补上。

### 📌 本机发版能力（**推翻本文早前"本机无法发版"的结论**）

- ✅ **本机可以归档、可以上传**。证据：`build/ios/ipa/DistributionSummary.plist` 显示
  09-25 成功导出 ipa，用的是 **`Cloud Managed Apple Distribution`** 证书
  （team `7B9U6K89CN`，到期 **2027-08-19**）；ASC 侧 build **5** 于 09-27 上传成功。
- ⚠️ 该证书由 **Xcode 云托管**，**不会出现在 `security find-identity -p codesigning`
  列表里**（那里只有 3 个 `Apple Development`）→ 所以"本机没有 Distribution 身份"
  是**假象**，不要据此判断发不了版。
- ⚠️ **`fastlane upload_testflight` 目前会失败**：`fastlane/report.xml` 记录
  09-28 10:20 那次在 `flutter build ipa --build-number 5` 处 exit 1。
- ✅ **可行路径**：`Xcode → Product → Archive → Organizer → Distribute App`——
  09-27 的 build 5 就是这么传上去的。（Xcode 归档时 SigningIdentity 显示
  `Apple Development` 属正常，Organizer 分发时会用云托管 Distribution 证书重签。）
- ℹ️ 本机 Xcode = **27.0 (27A266a)**；`ios/Runner.xcodeproj/project.pbxproj` 有未提交改动
  （`objectVersion 54→60` + 一个误加入的 `ios/File.txt` 文件引用）——**签名配置未被改动**，
  `CODE_SIGN_STYLE = Automatic`、`DEVELOPMENT_TEAM = 7B9U6K89CN` 均正常。

### 💰 定价最终决策（2026-09-30 用户选定）：**只保留买断 $3.99，不做订阅**

**本节取代 §六 与 9/28 的「两档（年 $3.99 + 买断 $5.99）」口径。**

| 商品 | 类型 | 价格 | 处置 |
|---|---|---|---|
| `wavelink_pro` | 非消耗型（买断） | **$3.99** | **在 ASC 新建**（删掉现存的 `WaveLink_Pro`） |
| ~~`wavelink_pro_yearly`~~ | ~~自动续期订阅~~ | — | **不再创建** |
| ~~`wavelink_pro_monthly`~~ | ~~自动续期订阅~~ | — | **弃用**（连同订阅组一起删） |

**为什么"统一 $3.99"只落在买断上**：$3.99 正是原来的付费下载价，把它平移到买断档最自然。
但若订阅也定 $3.99，则**买断（一次付清）≡ 年订阅（每年付）**，理性用户 100% 选买断、
订阅一分钱收不到。既然订阅本就难卖，**直接砍掉只留买断**——决策成本最低、付费墙最干净。

**已确认的代价**：放弃经常性收入（苹果"订阅首年后佣金降至 15%"的激励用不上）。

**代码影响：零**。付费墙（`paywall_page.dart:220`）是 `for (final product in _products)`
遍历 StoreKit **实际返回**的商品；ASC 只配一个买断商品 → 付费墙只渲染**一张卡**，
标题/按钮/条款自动走"买断"分支（`paywallPlanLifetime` / `paywallBuyButton` /
`paywallTermsLifetime`）。所以 **build 5 依然可直接提审，无需重新构建**。

### 修订后的执行顺序

```
⓪ ✅ 已决策：只保留买断 `wavelink_pro` @ $3.99，不做订阅
       ↓
① ASC 删除旧的 `WaveLink_Pro`（非消耗型 / $7.99 / ID 大小写与代码不符）
   · 从未提交过审核 → 删除安全。⚠️ 但 ID 一经删除，同一 App 内**不可复用**
       ↓
② ASC 新建非消耗型 `wavelink_pro`，价格 **$3.99**
   · 显示名 / 描述 / **审核截图** / 5 种语言本地化
     （文案直接照抄现有 `WaveLink_Pro`，见 IAP_SETUP.md 文末附录）
   · 状态须到 `READY_TO_SUBMIT`
       ↓
③ ASC 处理订阅遗留：订阅组 `WaveLink Pro` + `wavelink_pro_monthly` 不再需要 → 删除
       ↓
④ 本地 `ios/Runner/WaveLinkPro.storekit` 同步为单档 $3.99（仅本地测试用，不影响二进制）
   · 用它跑通付费墙 → **重拍审核截图**（现有那张是报错空态，不能用，见 IAP_SETUP.md）
       ↓
⑤ 把 1.0.3 版本（**已挂 build 5**）+ `wavelink_pro` 挂在**同一个提交**里送审
   · 首个非消耗型必须随 App 版本提交；此时 App 仍是付费 $3.99
       ↓
⑥ 审核通过 → ASC 改价 $3.99 → 免费（改价不需审核，通常数小时生效）
       ↓
⑦ 立刻手动发布 1.0.3（别停在「已免费但新版未上」的窗口）
```

> ⚠️ **改价时机**：务必在审核通过后才改价，且当天完成"改价 → 发布"。
> 若先改价，新用户会下到旧版 1.0.2，而它的付费墙是**空的**（见问题 1），必招差评。
>
> ℹ️ 代码里 `subscription_service.dart` 仍保留月/年订阅的产品 ID 常量与分支（本次**不动**，
> 避免重建风险）。它们只是死代码：StoreKit 查不到的 ID 会被静默忽略，不影响单档买断。
> 日后再想做订阅，端侧几乎是零改动。

---

## ⚠️ 2026-09-28 现状更新（本节的「商品档位 / 定价」两行已被 9/30 定价决策取代）

本文写于 9/14。之后的实际进展与决策如下，**下文凡与本节冲突之处，以开头 9/30 节为准**：

| 项 | 本文原状态 | 最新状态 |
|---|---|---|
| 代码 | 曾从分支回滚 | **已恢复**（cherry-pick `5000e89`），6 项门控 + 付费墙均在 |
| 商品档位 | 月 / 年 / 买断 三档 | ~~两档：年订阅 + 买断~~ → **⚠️ 已再改为「只保留买断一档」** |
| 定价 | ¥12 / ¥88 / ¥98（设计值） | ~~年订阅 $3.99 / 买断 $5.99~~ → **买断 $3.99 单档** |
| 版本号 | `1.0.2+42` 待 bump | 已是 **`1.0.3+3`**（+2 已上传 TestFlight，故抬到 +3） |
| 门控测试 | 无 | `pro_gate_test.dart` 8 例 + 订阅状态机 22 例，全量 139 例绿 |
| 本地 StoreKit 配置 | 三档 | 已同步为两档（`WaveLinkPro.storekit`） |
| Flutter / Dart | 3.44.9 / 3.12.2 | **3.47.5 / 3.13.4** |

> 📌 定价说明：§六 方案 B 原建议「年 $9.99 + 买断 $19.99」，实际决策为
> **「年 $3.99 + 买断 $5.99」**——走低价快速验证路线。代价是买断价仅为年费的
> **1.5 倍**（订阅满 18 个月即与买断等值），理性用户多半直接买断，订阅转化预计偏低。

**因此 §二「代码侧就绪度」的版本号一行、§三 的 ASC 商品清单、§六 的定价复盘均已过时**；
§四 发布顺序与 §五 老用户豁免分析仍然有效。

---

## 〇、结论

三件事确定后，结论收敛得很干净：

1. **线上是 1.0.2，售价 $3.99**（用户提供）
2. **没有任何付费用户**（用户提供）→ 老用户豁免**不用做**
3. **代码已经写好**（git 核实：HEAD 即为目标形态）→ 商业模式代码**不用改**

所以剩下的工作是：**补 ASC 商品 → 涨一次版本号 → 提审 → 改价 → 发布**。

| 原以为必须做 | 实际 | 原因 |
|---|---|---|
| 老用户豁免（读 `AppTransaction`） | ❌ 不用做 | 3.1.2(a) 保护对象是"已付费用户"，0 用户则无适用对象 |
| 原生 Swift MethodChannel / Keychain | ❌ 不用做 | 同上 |
| 判定阈值 `kFreeSinceBuild` / 日期 | ❌ 不用填 | 同上 |
| 改写商业模式代码 | ❌ 不用做 | 见 §二 |
| **提升版本号（build number）** | ✅ **必做** | ⚠️ 见下，这是唯一被忽略的必做项 |

> ✅ **版本号已提升（2026-09-28 完成）**：`pubspec.yaml` 现为 `version: 1.0.3+5`，
> 对应构建包已上传且 `VALID`。**App Store 不接受重复 build number**，此项已了结。

---

## 一、线上版本 vs 开发版本（✅ 实测，git 核实）

### 线上：`1.0.2`

- 售价 **$3.99**，付费下载
- 付费 SDK 已是 **StoreKit 2 直连**（RevenueCat 在 `9b574ec` 已移除，
  该提交的版本即 `1.0.2+7`）
- 商品定义：**只有一档** —— `subscription_service.dart` 里
  `proProductId = 'wavelink_pro'`（非消耗型买断）
- 门控：**只有设置页 3 个功能**
  （`_requirePro` 是 `settings_page.dart` 的私有函数，3 个调用点：
  AutoEQ、房间校正、Bit Perfect）
- **`app.dart` 里 0 处门控** → 网络音源（NAS / WebDAV / Subsonic）**不门控**

> ⚠️ **既有隐患（仍未引爆）**：线上付费下载的用户，付完 $3.99 进去，
> **AutoEQ / 房间校正 / Bit Perfect 仍带 PRO 徽标、点击跳付费墙**——
> 即"付了下载费还要再付费"的双重收费结构。
> 你说没有付费用户，所以没有实际受害者。但**请务必再去 ASC 核实一次**：
> - 销售趋势报告有 **1–2 天延迟**
> - **Family Sharing（家庭共享）** 与**兑换码**下载**不体现在常规销量里**
> - 若 App 上架时间很短，数据可能还没跑出来
>
> 若核实后确认确实为 0，按本方案走；若发现有人付过款，
> 他们需要按 §五 的备用方案补偿。

### 开发版：`HEAD`（`version: 1.0.2+42`，**未发布**）

相对线上 1.0.2 的差异（`git diff 3621d14 HEAD`，13 个文件 / +685 −217）：

- `subscription_service.dart` 重构 → **三档**：
  `wavelink_pro_monthly` / `wavelink_pro_yearly` / `wavelink_pro`
- 新增 `pro_gate.dart`（把门控从 settings 私有函数抽成公共模块）
- `app.dart` +49 行 → **门控扩到网络音源**，共 **6 个功能**
- `paywall_page.dart` +288 行 → 三档选择 UI
- 5 个语言的 l10n 同步更新

**结论：HEAD 就是为「免费 + 内购」准备的版本，代码侧已经就绪，无需改动。**

---

## 二、代码侧就绪度盘点（✅ 实测）

| 项 | 位置 | 状态 |
|---|---|---|
| 商品定义（代码保留月/年/买断三档常量） | `data/services/subscription_service.dart` | ✅ 代码零改动；ASC 只配买断一档 → 付费墙自动只显示一张卡 |
| StoreKit 2 权益判定（纯端侧无后端） | 同上 `queryPro` / `restore` | ✅ |
| 6 个功能门控 | `paywall/view_models/pro_gate.dart` → `requirePro` | ✅ 已全部接入 |
| 状态管理与失效剥夺 | `paywall/view_models/subscription_provider.dart` | ✅ |
| 付费墙页面（含条款/隐私外链） | `paywall/views/paywall_page.dart` | ✅ |
| 本地 StoreKit 测试配置 | `ios/Runner/WaveLinkPro.storekit` | ✅ |
| 部署目标 | `IPHONEOS_DEPLOYMENT_TARGET = 16.0` | ✅ 满足 StoreKit 2 |
| 发版工具 | `fastlane`，`bump_version` lane 自动递增 | ✅ |
| **版本号** | `1.0.3+5` | ✅ **已 bump**（build 5 已上传且 `VALID`） |

---

## 三、ASC 操作清单（核心工作，全部在网页后台完成）

> ⚠️ **本节已被开头「9/30 实测核实」节取代**（它假设了两个订阅都不存在、买断 ID 是
> `wavelink_pro`，与 ASC 实况不符）。保留作背景参考，执行请以 9/30 节为准。

### 3.1 补齐 IAP 商品

**`wavelink_pro`（买断）很可能已经存在** —— 线上 1.0.2 的代码就在拉这个 ID。
需要**新建的是两个订阅商品**。

| 产品 ID | 类型 | 订阅组 | 状态 |
|---|---|---|---|
| `wavelink_pro` | 非消耗型 | —（不进订阅组） | ⚠️ 可能已有，去确认 |
| `wavelink_pro_monthly` | 自动续期订阅 | 新建 `Pro` | ❌ 需新建 |
| `wavelink_pro_yearly` | 自动续期订阅 | `Pro` | ❌ 需新建 |

每个商品都要填：显示名称、描述、**审核截图**（订阅必传）、价格、
本地化（zh-Hans + en-US）、**沙盒测试账号**（不给几乎必拒）。
商品需单独提交审核并处于**「已批准」**状态。

**没有这一切，改价后付费墙是空的** —— 用户点"解锁"什么也买不到，收入为 0。

### 3.2 改价

`App Store Connect → App → 价格与销售范围` → 当前价格 **$3.99 → 免费** → 保存。

- 💡 改价是普通价格变更，**不需要新版本审核**，通常数小时内生效
- 💡 有开发者反馈改价会让**排行榜重置**

### 3.3 涨版本号

```
cd mobile && fastlane bump_version     # 1.0.2+42 → 1.0.3+43
```

### 3.4 元数据更新

- **App 描述**：去掉"付费下载"表述 → 「免费下载，Pro 功能一次性购买解锁」
  （3.1.2(c) 要求付费前说清花这个钱得到什么）
- **审核备注**（已按 9/30 决策改为「单档买断」）：
  > This update transitions the app from a paid up-front download to a free
  > download with a single in-app purchase. There are no existing paid
  > customers. Premium features (NAS/WebDAV/Subsonic, AutoEQ, room
  > correction, bit-perfect) are unlocked by a one-time non-consumable
  > purchase, `wavelink_pro`. There are no subscriptions. Sandbox test
  > account provided below.

---

## 四、发布顺序

```
① 确认 ASC 三个商品「已批准」（尤其两个新订阅）
       ↓
② fastlane bump_version → 1.0.3+43
       ↓
③ 提交 1.0.3 审核（此时 App 仍是【付费 $3.99】）
       ↓
④ 审核通过
       ↓
⑤ 去 ASC 把价格改为【免费】
       ↓
⑥ 手动发布 1.0.3
```

**容错说明**：因为付费用户为 0，这次顺序容错很高。即使做反，最坏也只是
"改价后有人免费下载到旧版 1.0.2"，而那些是免费获得，不构成"已付费"权益。

> ⚠️ 唯一要避免的：**别长期停在「价格已免费、但 1.0.3 还没上」的状态**。
> 这个窗口里新用户下到旧版 1.0.2，会撞见"点了没反应"的付费墙
> （因为订阅商品那时可能还没批准），容易招差评。审批通过当天完成 ⑤⑥。

---

## 五、备用方案：若核实时发现有付费用户

- **合规依据**：审核指南 **3.1.2(a)** —— 改订阅制
  "should not take away the primary functionality existing users have already paid for"
  https://developer.apple.com/app-store/review/guidelines/
- **官方路径**：`AppTransaction.shared` 的 `originalAppVersion`
  https://developer.apple.com/documentation/storekit/supporting-business-model-changes-by-using-the-app-transaction
  - ⚠️ **iOS 比较 `CFBundleVersion`（build number）**，macOS 才是 short version
  - 本项目 build 号来自 pubspec `+N`，且线上是 1.0.2 → 阈值应取 **1.0.3 的 build（43）**
- **必须补原生 Swift**：`in_app_purchase` **不暴露** `AppTransaction`，
  需在 `AppDelegate+Channels.swift` 加第 5 个 channel
- **三个坑**：
  1. `originalAppVersion` 是**字符串**，`"9" > "43"` 成立 → 必须数值比较
  2. **TestFlight 和沙盒都返回 `"1.0"`** → 会把人全误判成老用户，
     必须限定 `environment == "Production"`
  3. **卸载重装会重置** → 豁免标记要落 **Keychain**
- **权益**：老用户 → 永久 Pro 全集（`ProPlan` 加 `legacy` 档）；
  ⚠️ 绝不能进 `subscription_provider.dart` 的 `proRevocationHandler` 剥夺分支

---

## 六、定价复盘（⚠️ 已被 2026-09-30 的「只保留买断 $3.99」决策取代，仅作背景）

### 现状

| | 价格 |
|---|---|
| 原**付费下载** | **$3.99** |
| 月订阅（设计值，¥） | ¥12 |
| 年订阅（设计值，¥） | ¥88 |
| 买断（设计值，¥） | ¥98 |

按 App Store 价格档换算，¥12 ≈ $1.99、¥88 ≈ $11.99、¥98 ≈ $13.99。

### 问题：年订阅与买断只差约 $2

**后果**：任何理性用户都会直接选买断（不到一年就回本、还永久有效），
**订阅必然卖不出去**。而订阅才是能带来持续收入、也最受苹果推荐
（首年后佣金降至 15%）的模式。

### 建议

考虑到原价只有 $3.99（用户价格敏感度偏高），不宜把买断定得过高：

**方案 A（保留三档，拉开买断）**
- 月 **$1.99** / 年 **$7.99** / 买断 **$19.99**
- 逻辑：年订阅约省 66%（对比月付），买断 ≈ 2.5 年订阅价，三档各有位置

**方案 B（工具类常见做法，砍掉月订阅）**
- 年 **$9.99** + 买断 **$19.99**
- 逻辑：Hi-res 播放器是垂直工具，用户偏好买断（参考 USB Audio Player PRO
  $9.99、Neutron $7.99 的买断模式）；月订阅对工具类转化帮助有限，
  反而增加决策成本

**方案 C（最保守，只调买断）**
- 保持 月 $1.99 / 年 $12.99 不变，**买断提到 $29.99**
- 逻辑：改动最小，但买断相对 $3.99 的旧价跨度较大

> 说明：以上为💡判断，非官方依据。定价取决于你的目标客群与转化目标。
> 无论选哪个方案，**记得同步修改 `WaveLinkPro.storekit`**（仅本地测试用，
> 不影响线上），线上一律以 ASC 配置为准。

---

## 七、上线前检查清单

> ⚠️ **本节已被开头「9/30 实测核实」节取代**（商品档位口径已从月/年/买断三档
> 收敛为「年订阅 + 买断」两档，且版本号已在 9/28 手动 bump 过）。

**ASC**
- [ ] `wavelink_pro` 现存状态已确认（买断，非消耗型）
- [ ] 新建订阅组 `Pro` + `wavelink_pro_monthly` / `wavelink_pro_yearly`
- [ ] 三个商品 ID 与代码逐字一致
- [ ] 三个商品状态均为「已批准」
- [ ] 沙盒测试账号已填
- [ ] 价格已按 §六 决策定稿
- [ ] 价格已由 $3.99 改为**免费**
- [ ] App 描述已去掉"付费下载"表述

**代码**
- [ ] `fastlane bump_version` → `1.0.3+43`（否则 App Store 拒绝重复 build）
- [ ] 真机（StoreKit 本地配置）走通三档购买
- [ ] 沙盒走通：月订阅 → 到期（沙盒 1 月 = 5 分钟）→ Pro 设置被剥夺
- [ ] 沙盒走通：买断 → 卸载重装 → 恢复购买
- [ ] **无网络时付费墙的降级**（应显示重试而非白屏）← 容易漏，重点测
- [ ] 6 个功能门控逐一验证：未购买时全部跳付费墙

**流程**
- [ ] 已核实 ASC 销量确无付费用户（含家庭共享 / 兑换码）
- [ ] 审核备注已写
- [ ] 审批通过后当天完成「改价 → 发布」

---

## 附：官方依据索引

| 主题 | 链接 |
|---|---|
| 审核指南（3.1.1 / 3.1.2） | https://developer.apple.com/app-store/review/guidelines/ |
| 业务模型变更与 AppTransaction（备用方案用） | https://developer.apple.com/documentation/storekit/supporting-business-model-changes-by-using-the-app-transaction |
| StoreKit 2 `Transaction.currentEntitlements` | https://developer.apple.com/documentation/storekit/transaction/currententitlements |
