# WaveLink Pro 内购配置手册（iOS）

面向「本地播放免费 + Pro 订阅解锁」的商业模式，记录代码已实现的部分与需要
在 App Store Connect / Xcode 手工完成的部分。

---

## 一、商业模式与产品清单

> **定价决策：年订阅 $3.99 / 买断 $5.99，不提供月订阅。**
> 工具类定位，两档降低决策成本（参考 USB Audio Player PRO / Neutron 的买断模式）。
> 付费墙按 StoreKit 实际返回的商品**动态渲染**，未在 ASC 创建月订阅商品即不会展示。

| 产品 ID | 类型 | 订阅组 | 价格 | 说明 |
|---|---|---|---|---|
| `wavelink_pro_yearly` | 自动续期订阅 | `Pro` | **$3.99 / 年** | 付费墙默认选中，标「最划算」 |
| `wavelink_pro` | 非消耗型 | — | **$5.99 一次性** | 买断，**不进订阅组**（可与订阅并行销售） |

> 代码里仍保留 `wavelink_pro_monthly` 的定义（`data/services/subscription_service.dart`），
> 作为备用档位：将来若要上线月订阅，只需在 ASC 创建该商品，端侧零改动。

**免费层（不做任何限制）**：本地文件播放、曲库管理、播放列表、歌词、基础 EQ。

**Pro 层（门控）**：

| 功能 | 门控位置 |
|---|---|
| NAS / SMB | `lib/ui/core/app.dart` → `_handleNas` |
| WebDAV | `lib/ui/core/app.dart` → `_handleWebdav` |
| Subsonic / Navidrome / Jellyfin | `lib/ui/core/app.dart` → `_handleSubsonic` |
| AutoEQ | `settings_page.dart` → `/autoeq` |
| 房间校正 | `settings_page.dart` → `/room-correction` |
| Bit Perfect | `settings_page.dart` → 开关 |

> 💡 网络音源只门控「入口与扫描」，已导入到本地曲库的歌曲不清除——订阅到期后
> 用户仍能播放已下载的曲目，但无法新增或重新扫描。

---

## 二、App Store Connect 配置（必须手工完成）

1. **订阅组**：`App 内购买项目` → 管理 → 新建订阅组 `Pro`，填参考名称与本地化显示名
2. **订阅商品**（组内，仅一档）：
   - `wavelink_pro_yearly` — 订阅期 **1 年**，价格 **$3.99**
   - 要填：显示名称、描述、**审核截图**（订阅必传）、价格、本地化（zh-Hans / en-US 至少）
   - 提交审核并处于「已批准」状态
3. **买断商品**：非消耗型 `wavelink_pro`，价格 **$5.99**（若首个版本已建过则沿用，ID 不可改）
4. **审核信息**：每个商品填「审核备注」，并提供沙盒测试账号（不给几乎必拒）
5. **App 信息**：确认已填 EULA 链接（当前用苹果标准 EULA）
6. **App 描述**：按 2.3.2 要求说明 App 含订阅型内购

### 可选

- **推介优惠 / 免费试用**：在订阅商品里配 Introductory Offer，付费墙已预留展示位
- **订阅降价 / 优惠代码**：ASC 直接生成，端侧无需改动

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
- 该文件已含月/年订阅（`pro_group`）与买断三档，可在无网状态下跑通购买/恢复
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
| `ui/features/paywall/views/paywall_page.dart` | 三档选择、自动续订条款、管理订阅入口 |
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

- [ ] ASC 两个商品全部创建且状态为「已批准」（`wavelink_pro_yearly` / `wavelink_pro`）
- [ ] Xcode 已添加 In-App Purchase capability
- [ ] 沙盒账号走通：年订阅 → 到期 → 自动剥夺 Pro 设置
      （沙盒下 1 年 ≈ 1 小时；想快速验证到期剥夺，可在 Xcode 的 StoreKit
      配置里调快 Renewal Rate，本地测试不按真实时长计时）
- [ ] 沙盒账号走通：买断 → 卸载重装 → 恢复购买
- [ ] 付费墙在「无网络」下的降级展示（应显示重试按钮而非空白）
- [ ] App Store 描述中已声明含订阅内购
