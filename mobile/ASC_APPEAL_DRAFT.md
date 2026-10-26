# ASC 沟通/申诉稿（5.2.1）—— 先试水用

> 生成：2026-10-12 · 对应提交 `d04ee7bd-22ac-43b1-85dd-1d2164bd4098` · App ID 6802973339
> 目的：在**不动截图**的前提下，用沟通争取让审核通过（或至少拿到明确边界）。

---

## ⚠️ 先读：这条路值多少

**成功率：低。** 不是"难"，是**结构性不利**：

- Apple 拒信原文只给了两条路 —— `attach documentary evidence`（拿授权证明）/ `remove`。
  它没有给"解释一下就放行"这个选项。
- **2.3.9** 把举证责任放在**你**身上：*You are responsible for securing the rights to use
  **all materials** in your app icons, screenshots, and previews.*
  → "素材来自用户本机"**不能**免除"截图里一切素材须有权使用"。
- 实证：Apple 论坛 thread/128141，同款音乐播放器、同样申辩"我用的是免费/无版权音乐"，
  Apple **原样回了同一封拒信**。spotify 社区里用条款争辩的也一样被驳。

**所以这份稿子的真实目标只有两个，别指望更多：**

1. **小概率**：审核员接受"本地播放器不构成第三方内容分发"的论证 → 放行。
2. **大概率**：拿到一句更具体的答复（"还是要删" / "名字可以、封面不行"）→ 你按答案改，一步到位。

**它不值得的代价**：把发布往后拖好几天。所以——**发完之后设个期限，别无限等。**

---

## 🔴 发送前三条红线

1. **千万不要重提同一批截图。** 你已被同一批图拒两次；第三次用同一批图提交，
   可能踩到 2.3.1(b)（repeated behavior）。**这次只发消息，不点提交。**
2. **语气不要对抗。** 别说 disagree / unfair / your policy is wrong。
   姿态是"我们想搞清楚边界"，不是"你不讲理"。
3. **别引"合理使用/fair use"。** 那是法庭抗辩，不是平台规则；提了反而显得不懂规则。

---

## 版本 A（主推）· 解决中心回复 —— 不动截图，先把话说明白

**位置**：ASC → 左侧「App 审核」→ **解决中心（Resolution Center）** → 选中该提交 → 回复框粘贴。
**说明**：这不触发重新审核，只是开一段对话。Apple 回"仍须移除"→ 你再去换图，**没有损失**。

```
Hello,

Thank you for reviewing WaveLink HiFi. We would like to respectfully clarify the
nature of our app, because we believe the flagged artwork is not third-party
content that we supply, host, or distribute.

WaveLink HiFi is a purely local music player. The app ships with no music, no
artwork, and no catalog of any kind. It contains no streaming service, no content
store, and no download feature. The only audio it can play is audio the user
already owns and keeps on their own device. The album artwork visible in our
App Store screenshots comes from the test files on our own test device, loaded by
us the same way any user loads their own library. The screenshots are authentic
captures of the app, as Guideline 2.3.3 requires.

In other words, we do not make any use of third-party content as our product. We
do not provide, host, stream, sell, or promote it. The app is functionally a
player for content the user already owns.

We fully respect intellectual property rights and will comply with Apple's
determination. Before we replace our store screenshots, we would be grateful for
guidance on two points:

1. For a local, user-library-only music player, is it acceptable for App Store
   screenshots to show the app's own interface displaying the user's local library?

2. If artwork must nonetheless be removed, is it acceptable for the screenshots to
   show the app's interface with track and artist names as plain text (no artwork,
   no lyrics)?

If Apple's position is that all such artwork must be removed regardless, please
confirm and we will replace the screenshots immediately. We only want to
understand the exact boundary so we get it right.

Thank you for your time.
```

---

## 版本 B（升级用）· App Review Board 正式申诉 —— 只有 A 被驳回后才发

**入口**：解决中心回绝后，ASC 里会出现申诉入口（或走 App 审核页的「申诉」）；
也可从拒信邮件里的申诉链接进。**别和 A 同时发。**

```
Re: App Review Board Appeal - WaveLink HiFi, Submission d04ee7bd, App ID 6802973339

Dear App Review Board,

We are appealing the rejection of WaveLink HiFi v1.0.3 under Guideline 5.2.1,
which states that the app "includes protected album cover artworks in app icons,
screenshots or previews without the necessary authorization."

We respectfully submit that the flagged material is not third-party content that
we supply, host, or distribute, and that the screenshots faithfully depict the
app in use as Guideline 2.3.3 requires.

Facts about the app:

- WaveLink HiFi is a local music player. It ships no music, no artwork and no
  catalog. It contains no streaming, store, or download functionality of any kind.
- The only audio the app can play is audio the user already owns and keeps on
  their own device. The app functions solely as a player for the user's own files.
- The artwork visible in our screenshots was captured on our own test device from
  test files loaded locally by us. It is a genuine screen capture of the app.

Because the app neither provides nor promotes third-party content, we believe the
5.2.1 concern - the unauthorized use of protected third-party material in our
product or in our marketing - does not arise here. The screenshots show our
interface, not a third-party content offering.

We have no wish to dispute Apple's policies and will comply with whatever you
determine. We ask only that you consider whether a local, user-library-only player
may show its own interface displaying a user's local library.

If your determination is that the artwork must nonetheless be removed, please
confirm and we will replace the screenshots immediately. We would also welcome
guidance on whether plain-text track and artist names, without artwork or lyrics,
are acceptable.

Thank you for your consideration.

WaveLink
```

---

## 发完之后

| 情形 | 你做什么 |
|---|---|
| Apple 放行 | 直接在**同一提交** `d04ee7bd…` 点提交审核（截图保持原样）。若它要求替换，见下一行 |
| Apple 回"仍须移除" | **立即执行换图流程**（`ASC_ACTION_CHECKLIST.md` 第 10 步 + `tools/prep_asc_screenshots.py`），然后同一提交重提 + 按第 11 步回复 |
| 3 个工作日没回音 | 别再等 —— 直接换图。**等待不是免费动作，它在烧发布窗口** |

> 💡 不管理论上对错，**换成零版权截图是 100% 能解开这个死结的动作**；
> 沟通只有在 Apple 恰好认同你的论证时才有回报。所以这轮试水**最多花你一条消息的钱**，
> 别让它变成"卡住整条发布"的理由。
