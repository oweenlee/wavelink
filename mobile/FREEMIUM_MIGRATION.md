# WaveLink iOS：付费下载 → 免费下载 + Pro 内购 迁移方案

> 范围：**仅 iOS**（用户明确不考虑 Android）。
> 更新：2026-09-14 第 3 版 · 已核实线上版本 = **1.0.2 / $3.99** · 未动代码

---

## ⚠️ 2026-09-28 现状更新（读下文前先看这里）

本文写于 9/14。之后的实际进展与决策如下，**下文凡与本节冲突之处，以本节为准**：

| 项 | 本文原状态 | 最新状态 |
|---|---|---|
| 代码 | 曾从分支回滚 | **已恢复**（cherry-pick `5000e89`），6 项门控 + 付费墙均在 |
| 商品档位 | 月 / 年 / 买断 三档 | **两档**：年订阅 + 买断（**已砍月订阅**，即 §六 方案 B） |
| 定价 | ¥12 / ¥88 / ¥98（设计值） | **年订阅 $3.99 / 买断 $5.99** |
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

> ⚠️ **新发现·必做项：版本号必须提升。**
> HEAD 的 `pubspec.yaml` 仍是 `version: 1.0.2+42`，而线上已经是 1.0.2。
> **App Store 不接受重复的 build number**，必须 `fastlane bump_version`
> （→ `1.0.3+43`）才能上传。

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
| 三档商品定义 | `data/services/subscription_service.dart` | ✅ |
| StoreKit 2 权益判定（纯端侧无后端） | 同上 `queryPro` / `restore` | ✅ |
| 6 个功能门控 | `paywall/view_models/pro_gate.dart` → `requirePro` | ✅ 已全部接入 |
| 状态管理与失效剥夺 | `paywall/view_models/subscription_provider.dart` | ✅ |
| 付费墙页面（含条款/隐私外链） | `paywall/views/paywall_page.dart` | ✅ |
| 本地 StoreKit 测试配置 | `ios/Runner/WaveLinkPro.storekit` | ✅ |
| 部署目标 | `IPHONEOS_DEPLOYMENT_TARGET = 16.0` | ✅ 满足 StoreKit 2 |
| 发版工具 | `fastlane`，`bump_version` lane 自动递增 | ✅ |
| **版本号** | `1.0.2+42` | ❌ **必须 bump** |

---

## 三、ASC 操作清单（核心工作，全部在网页后台完成）

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

- **App 描述**：去掉"付费下载"表述 → 「免费下载，App 内含订阅与买断」
  （3.1.2(c) 要求付费前说清花这个钱得到什么）
- **审核备注**：
  > This update transitions the app from a paid up-front download to a free
  > download with in-app purchases. There are no existing paid customers.
  > Premium features are unlocked via auto-renewable subscription
  > (monthly/yearly) or a one-time non-consumable purchase. Sandbox test
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

## 六、定价复盘（💡 本次第二个问题）

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
