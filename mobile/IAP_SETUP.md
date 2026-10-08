# WaveLink Pro 内购配置手册（iOS）

面向「本地播放免费 + Pro 一次性购买解锁」的商业模式，记录代码已实现的部分与需要
在 App Store Connect / Xcode 手工完成的部分。

---

## 一、商业模式与产品清单

> **定价决策（2026-09-30 定稿）：只卖一档非消耗型买断 `wavelink_pro`，价格 $3.99。不做订阅。**
> $3.99 就是原付费下载价，平移到买断档最自然；砍掉订阅是为了避免「买断 ≡ 年订阅」的同价
> 自杀（详见 `FREEMIUM_MIGRATION.md` 开头的 9/30 定价决策）。
> 付费墙按 StoreKit 实际返回的商品**动态渲染** —— 只配一个商品，它就只显示一张卡。

| 产品 ID | 类型 | 订阅组 | 价格 | 说明 |
|---|---|---|---|---|
| `wavelink_pro` | 非消耗型 | — | **$3.99 一次性** | **唯一商品**，买断后永久解锁 Pro |
| ~~`wavelink_pro_yearly`~~ | ~~自动续期订阅~~ | — | — | **不做** |
| ~~`wavelink_pro_monthly`~~ | ~~自动续期订阅~~ | — | — | **弃用** |

> 🔴 **2026-09-30 实测核对（ASC API 只读导出）**：ASC 里**根本没有** `wavelink_pro` ——
> 现存的是 **`WaveLink_Pro`**（大小写不一致 → 线上付费墙拿不到商品），价 $7.99；
> 订阅组下只有一个 `wavelink_pro_monthly`（`MISSING_METADATA`）。
> **上表是本次要达成的目标态，不是现状**；现状明细见文末附录，
> 执行步骤见 `FREEMIUM_MIGRATION.md` 开头的 9/30 节。

> 代码里仍保留月/年订阅的产品 ID 常量与分支（`data/services/subscription_service.dart`），
> 本次**不动**、只是死代码；将来若要上线订阅，在 ASC 建好商品即可，端侧近乎零改动。

**免费层（不做任何限制）**：本地文件播放、曲库管理、播放列表、歌词、基础 EQ、
**NAS/SMB、WebDAV、Subsonic/Navidrome/Jellyfin、AutoEQ**
（后四项于 **2026-10-08** 从 Pro 放开）。

**Pro 层（门控）** —— 只剩两项：

| 功能 | 门控位置 |
|---|---|
| 房间校正 | `settings_page.dart` → `/room-correction` |
| Bit Perfect | `settings_page.dart` → 开关 |

> 💡 原本门控的 6 项里，NAS/WebDAV/Subsonic/AutoEQ 已放开。放开 AutoEQ 的一个附带
> 好处：基础 EQ 是免费的，而 AutoEQ 的本质就是一条 PEQ 曲线（`autoeq.app` 免费生成），
> 用户完全可以手抄进基础 EQ 绕过——原来那个门控拦不住懂的人，只劝退了不懂的人。
>
> ⚠️ 改动门控 = 改了二进制 → **必须重新构建上传 build 6**（`pubspec.yaml` 已 bump 到
> `1.0.3+6`）。详见 `ASC_ACTION_CHECKLIST.md` 第 0 步。

---

## 二、App Store Connect 配置（必须手工完成）

1. **删除旧商品**：非消耗型 `WaveLink_Pro`（$7.99，ID 大小写与代码不符）→ 删除。
   ⚠️ Product ID **一经删除，同一 App 内不可复用**（所以只能"删了重建"，不能"改"）
2. **新建买断商品**：`App 内购买项目` → 新建 → **非消耗型**，Product ID 填 **`wavelink_pro`**
   （必须与代码逐字一致，**全小写**），价格 **$3.99**
   - 要填：显示名称、描述、**审核截图**、本地化（照抄现有 5 语言，见文末附录 §一）
   - 提交审核并处于「已批准」状态
3. **清理订阅遗留**：订阅组 `Pro` + `wavelink_pro_monthly` 不再需要 → 删除
4. **审核信息**：商品填「审核备注」，并提供沙盒测试账号（不给几乎必拒）
5. **App 信息**：确认已填 EULA 链接（当前用苹果标准 EULA）
6. **App 描述**：说明「免费下载，Pro 功能一次性购买解锁」（3.1.2(c)）
7. **下载价改免费**：`价格与销售范围` → **$3.99 → 免费**（⚠️ **审核通过后再改**）

> ⚠️ **首个非消耗型商品必须随 App 版本一起提交**（官方规则）→ 把 `wavelink_pro`
> 挂进 **1.0.3 的提交**里，与已上传的 build 5 同批送审。

### 暂无（已不做订阅，本节作废）

- ~~推介优惠 / 免费试用 / 订阅降价 / 优惠代码~~：单档买断，这些都不适用

---

## 三、Xcode 配置

✅ 实测：`ios/Podfile` 与 Runner target 的 `IPHONEOS_DEPLOYMENT_TARGET` 均为
**16.0**，高于 StoreKit 2 要求的 iOS 15 → **无需调整部署目标，原生代码零改动**
（`in_app_purchase` 插件已封装 StoreKit，Swift/ObjC 侧不用写一行）。

### 必做：添加 In-App Purchase capability

1. 打开 `ios/Runner.xcworkspace`
2. Runner target → **Signing & Capabilities** → `+ Capability` → **In-App Purchase**

📚 官方依据（[Adding capabilities to your app](https://developer.apple.com/documentation/xcode/adding_capabilities_to_your_app)）：
自动签名下 Xcode 会**自动**给 App ID 开通 IAP service 并重新生成 profile。
与 Push / iCloud 不同，**IAP 不写入 entitlements 文件**——所以工程里没有
`.entitlements` 是正常的，不用补。

⚠️ 若用**手动签名**（或 profile 创建早于 capability 添加）：需到开发者后台
Certificates, Identifiers & Profiles → 对应 App ID 勾 In-App Purchase，然后
重新生成并下载 provisioning profile。

### 本地调试（StoreKit 本地测试，不走真实扣款）

- Scheme → Run → Options → **StoreKit Configuration** → 选
  `ios/Runner/WaveLinkPro.storekit`（下拉里没有就用 *Choose…* 直接指到该文件，
  **不必加入工程、不必加进 Copy Bundle Resources**）
- 该文件已同步为**单档买断 `wavelink_pro` @ $3.99**（2026-09-30 改），
  可在无网状态下跑通购买/恢复；**审核截图就用它拍**
- ⚠️ 若 Xcode 报文件格式错误，删掉让 Xcode 重新生成即可

### 沙盒测试

- ASC → 用户和访问 → 沙盒测试员，建一个账号
- 真机登录沙盒账号后购买；沙盒下 **1 个月 = 5 分钟**，便于验证订阅到期与剥夺

---

## 四、代码结构

| 文件 | 职责 |
|---|---|
| `data/services/subscription_service.dart` | StoreKit 2 直连：商品拉取、购买、sync、权益判定 |
| `ui/features/paywall/view_models/subscription_provider.dart` | Riverpod 状态、`ProPlan` 档位、失效剥夺 |
| `ui/features/paywall/view_models/pro_gate.dart` | 门控函数 `requirePro` / `showProBadge` |
| `ui/features/paywall/views/paywall_page.dart` | 付费墙；**按 StoreKit 实际返回的商品动态渲染**（只配买断 → 只显示一张卡） |
| `test/subscription_provider_test.dart` | 档位流转、到期剥夺、购买/恢复 |

### 权益判定原理（无后端）

✅ 实测：`in_app_purchase` 3.3.0 在 iOS/macOS 默认注册
`InAppPurchaseStoreKitPlatform`（StoreKit 2 实现，见 `lib/in_app_purchase.dart`
第 32-40 行），`restorePurchases()` 走 `AppStore.sync()`。

📚 官方依据：StoreKit 2 的 `Transaction.currentEntitlements` 只返回**当前仍有效**
的权益，过期订阅与退款不会出现在其中
（https://developer.apple.com/documentation/storekit/transaction/currententitlements）。

因此启动时 `sync()` 一次 + 读取 purchaseStream 即可判定订阅是否有效，**不需要
后端收据校验**。代价：退款、账单失败宽限期（grace period）感知有延迟，需下次
启动或用户主动恢复时才同步。

### 合规要点

📚 Review Guidelines（https://developer.apple.com/app-store/review/guidelines/#in-app-purchase）：

- **3.1.1** 解锁功能必须走 IAP，且要有恢复机制 → 付费墙有「恢复购买」按钮
- **3.1.2(a)** 订阅期至少 7 天、跨设备生效；改订阅制不得剥夺老用户已付费功能
  → 本项目上线时无存量付费用户，不适用
- **3.1.2(c)** 订阅前必须说清「花这个钱得到什么」→ 付费墙按选中档位动态显示
  价格、周期、自动续订与取消方式（`paywallTermsSubscription`）

付费墙固定展示：使用条款（苹果标准 EULA）+ 隐私政策 + App Store 订阅管理入口。

---

## 五、❓ 待验证 / 上线前检查清单

- [ ] ASC 买断商品 `wavelink_pro` 已创建、状态「已批准」（旧的 `WaveLink_Pro` 已删）
- [ ] ASC 订阅组与月订阅已清理
- [ ] Xcode 已添加 In-App Purchase capability
- [ ] 本地 StoreKit 配置下付费墙正常显示**单档 $3.99**，并据此**重拍审核截图**
- [ ] 沙盒账号走通：买断 → 卸载重装 → **恢复购买**
- [ ] 付费墙在「无网络」下的降级展示（应显示重试按钮而非空白）
- [ ] App Store 描述中已声明含一次性内购
- [ ] 下载价已由 $3.99 改为免费（**审核通过后**操作）

---

## 附：ASC 现有商品文案底稿（2026-09-30 实测导出，新建商品时直接抄）

> 来源：App Store Connect API 只读导出（app id `6802973339`）。
> ⚠️ 与本页 §一 表格里的定价有一处**实测冲突**，见本节第四点。

### 一、买断商品现有 5 条本地化 —— 新建 `wavelink_pro` 时原样复用

现有商品的 productId 是 `WaveLink_Pro`（⚠️ 大小写与代码不符，详见
`FREEMIUM_MIGRATION.md` 开头 9/30 节），但**文案是可以直接照抄的**：

| locale | Display Name | Description |
|---|---|---|
| `en-US` | `WaveLink Pro` | `AutoEQ, room correction & bit-perfect. Buy once.` |
| `zh-Hans` | `WaveLink Pro` | `一次性买断，永久解锁全部 Pro 功能：AutoEQ、房间校正、Bit Perfect` |
| `de-DE` | `WaveLink Pro` | `AutoEQ, Raumkorrektur & bit-perfect. Einmaliger Kauf.` |
| `ja` | `WaveLink Pro` | `AutoEQ、ルーム補正、Bit Perfect 出力。買い切りで永久にアンロック` |
| `ko` | `WaveLink Pro` | `AutoEQ, 룸 보정 & Bit Perfect. 일시불 구매.` |

📚 字符上限（[In-App Purchase information](https://developer.apple.com/help/app-store-connect/reference/in-app-purchase-information)）：
Display Name ≥2 且 ≤30 字符；Description ≤45 字符。
⚠️ 实测 en-US 那条 Description 是 **48 字符**却保存成功了 → 说明不是硬卡，
但**别再往上加字**，照抄最稳。

### 二、订阅本地化 —— **本次不需要**（已决定不做订阅）

（留档）现有 `wavelink_pro_monthly` 只有这 2 条：
`zh-Hans` = `解锁高级音频校正功能`、`en-US` = `Unlock advanced audio calibration`。
单档买断后，这部分连同订阅组一起删除即可。

### 三、订阅组本地化 —— **本次不需要**（订阅组将删除）

（留档）实测订阅组本地化为 **0 条** —— 这正是 `wavelink_pro_monthly` 一直卡在
`MISSING_METADATA` 的元凶。组名建议值如下（仅日后恢复订阅才用得上）：

| locale | Display Name |
|---|---|
| `zh-Hans` | `WaveLink Pro` |
| `en-US` | `WaveLink Pro` |

### 四、价格 —— **已定稿：买断 $3.99**

| 项 | 旧设计值 | ASC 实测现值 | **本次定稿** |
|---|---|---|---|
| 买断 | $5.99 | `WaveLink_Pro` = **$7.99**（中国区 ¥48） | ✅ **`wavelink_pro` = $3.99** |
| 月订阅 | （已砍） | `$3.99 / 月` | ❌ 弃用 |

→ 新建 `wavelink_pro` 时**把价格设为 $3.99**（≈ 原付费下载价，用户心智延续）。

### 五、🔴 现有审核截图**不能复用**，必须重拍

已从 ASC 导出到 `ios/Runner/iap_review_screenshot_1170x2532.png`（1170×2532 PNG，507 KB）。
**但它的内容是坏的** —— 拍的是付费墙的**报错空态**：

> 「暂时无法获取购买信息，请检查网络后重试」+「恢复购买」/「重试」

看不到任何档位和价格。这正是「商品 ID 大小写不匹配 → `fetchProducts` 返回空」的
**可视化证据**（也说明付费墙的降级 UI 本身是正常的，没有白屏）。

⚠️ 拿这张去送审有风险：Apple 要求审核截图**清楚展示所售项目**，且 3.1.2(c)
要求付费前讲清价格与所得。**修好商品后，用本地 StoreKit 配置跑通付费墙，
重拍一张正常展示 **$3.99 单档价格与购买按钮**的截图再上传。**
