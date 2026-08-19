# WaveLink Desktop UI/UX 设计方案

> 基于 `ui-ux-pro-max` skill 数据库 + `flutter-best-practices` skill + 项目现状审计
> 生成时间：2026-08-20

---

## 一、Skill 推荐摘要 vs. 项目现状

### 1.1 设计系统推荐（`--design-system`）

| 维度 | Skill 推荐 | 项目现状 | 采纳决策 |
|------|-----------|---------|---------|
| **Pattern** | Minimal Single Column — 大留白、少导航干扰 | 三栏布局（侧栏+曲库+Now Playing） | ✅ 采纳精神：桌面三栏保留，但每栏内部遵循「大留白+少干扰」 |
| **Style** | Vibrant & Block-based（彩色、几何、高对比） | OLED Dark Mode（纯黑白灰阶） | ⚠️ **拒绝彩色方向**，采纳 OLED Dark Mode（Result #1），WCAG AAA |
| **Color** | #0F0F23 bg / #22C55E CTA / #1E1B4B primary | S0-S4 灰阶 + 动态封面色 accent | ✅ **保持现有**：黑白 UI + 封面内容带色（已确立的设计哲学） |
| **Typography** | Righteous + Poppins（音乐/娱乐/活力） | SpaceGrotesk + Inter + JetBrainsMono | ✅ **保持现有**：SpaceGrotesk 比 Righteous 更克制，适合 hi-res 严肃工具定位 |
| **Effects** | 大间距 48px+ / 色彩偏移 hover / 200-300ms | 部分 hover 已实现 | ⚠️ 部分采纳：间距桌面化、hover 统一 200ms |
| **Anti-patterns** | 扁平无深度、文字过多 | 已有 S0-S4 分层 | ✅ 已规避 |

### 1.2 Style 匹配分析

Skill 的 5 个 style 结果中，**Dark Mode (OLED)** 是最匹配的：

```
✅ Deep Black #000000, Dark Grey #121212 — 项目 S0=#08090A, S1=#0E1011 已对齐
✅ Text contrast 7:1+ — textPrimary #F0F1F3 on S1 = 15.8:1（超 AAA）
✅ Minimal glow — 项目已用 highlight 6% 白替代发光
✅ High readability — 三级文字层级已建立
✅ WCAG AAA — 已达标
```

**Exaggerated Minimalism** 也部分适用（黑白主色 + 单一强调色），但项目用的是动态封面色而非固定单一色——这是更优的方案。

### 1.3 UX Guidelines 审计

从 99 条 UX guidelines 中提取与本项目相关的：

| # | 类别 | 规则 | 现状 | 优先级 |
|---|------|------|------|--------|
| 78 | Feedback | Loading Indicators — >300ms 操作需反馈 | ⚠️ 曲库扫描/导入无骨架屏 | **P0** |
| 79 | Feedback | Empty States — 有引导消息+操作 | ⚠️ 曲库空态仅文字，无操作引导 | **P0** |
| 8 | Animation | Duration 150-300ms 微交互 | ✅ 已实现（歌词滚动 350ms 略长，可调） | — |
| 9 | Animation | Reduced Motion — 尊重 prefers-reduced-motion | ❌ 未实现 | **P1** |
| 14 | Animation | Easing — ease-out 进入 / ease-in 退出 | ⚠️ 部分用 easeOutCubic，未系统化 | P2 |
| 29 | Interaction | Hover States — 视觉反馈 | ✅ 已实现（hoverColor: highlight） | — |
| 30 | Interaction | Active States — 按压反馈 | ⚠️ 播放按钮有，其他控件无 | P2 |
| 31 | Interaction | Disabled States — 降低透明度+cursor | ⚠️ 部分 disabled 仅变灰 | P2 |
| 32 | Interaction | Loading Buttons — 防重复提交 | ✅ 网络对话框已实现 | — |
| 33 | Interaction | Error Feedback — 清晰错误消息 | ✅ errorStream → SnackBar 已实现 | — |
| 35 | Interaction | Confirmation Dialogs — 破坏性操作确认 | ✅ 清空数据已有确认 | — |
| 36 | Accessibility | Color Contrast 4.5:1+ | ✅ 已达标（AAA） | — |
| 37 | Accessibility | Color Only — 不仅靠颜色传达信息 | ⚠️ 连接状态仅靠颜色区分 | **P1** |
| 40 | Accessibility | ARIA Labels — 图标按钮需无障碍标签 | ❌ 未实现 | P2 |
| 72 | Typography | Line Height 1.5-1.75 正文 | ⚠️ bodyLarge 1.4 偏紧 | P2 |
| 76 | Typography | Contrast Readability | ✅ 已达标 | — |
| 82 | Feedback | Toast — 3-5s 自动消失 | ✅ SnackBar 已实现 | — |
| 84 | Content | Truncation — 省略号+展开 | ✅ TextOverflow.ellipsis 已用 | — |

### 1.4 Flutter Stack 最佳实践审计

| # | 规则 | 现状 | 优先级 |
|---|------|------|--------|
| 3 | const constructors | ✅ 已广泛使用 | — |
| 8 | Riverpod | ✅ 已使用 | — |
| 9 | Dispose resources | ✅ 已实现 | — |
| 13 | LayoutBuilder 响应式 | ❌ **未实现**，桌面无窗口尺寸适配 | **P0** |
| 15 | ListView.builder 懒加载 | ✅ 已使用 | — |
| 16 | itemExtent 固定高度 | ⚠️ 歌词已用 SizedBox 固定高度，曲库列表未用 | P2 |
| 27 | ThemeData 集中管理 | ✅ 已实现 | — |
| 30 | Support dark mode | ✅ 已实现（纯暗色） | — |
| 40 | 避免全树重建 | ⚠️ Consumer 范围基本正确，少数可优化 | P2 |
| 41 | RepaintBoundary 隔离动画 | ❌ 歌词滚动/进度条未加 | **P1** |
| 43 | Semantics 无障碍 | ❌ 未实现 | P2 |

---

## 二、设计改进方案

### P0 — 立即需要（体验硬伤）

#### 2.1 窗口响应式布局（LayoutBuilder 断点）

**问题**：当前三栏宽度固定（侧栏 240 + 曲库 Expanded + Now Playing 340），窗口缩小时曲库区域被压缩到不可用，窗口放大时大量空白浪费。

**方案**：LayoutBuilder 三级断点

| 窗口宽度 | 布局 | 侧栏 | Now Playing |
|----------|------|------|-------------|
| < 900px | 紧凑：侧栏收为图标条 | 56px | 隐藏（点击展开覆盖层） |
| 900-1400px | 标准：三栏 | 240px | 320px |
| > 1400px | 宽松：三栏+加大间距 | 260px | 360px |

```dart
LayoutBuilder(builder: (context, constraints) {
  final w = constraints.maxWidth;
  if (w < 900) return _CompactLayout(...);
  if (w < 1400) return _StandardLayout(...);
  return _WideLayout(...);
});
```

#### 2.2 空状态设计（Empty States）

**问题**：曲库为空时仅显示「暂无曲目」文字，无引导操作。

**方案**：空状态卡片——大图标 + 说明文字 + 主操作按钮

```
┌─────────────────────────────────┐
│                                 │
│         [/library icon]         │
│                                 │
│        曲库还是空的              │
│   添加本地文件夹或连接网络源     │
│                                 │
│   [选择文件夹]  [添加网络源]     │
│                                 │
└─────────────────────────────────┘
```

- 图标用 Lucide `libraryBig`，textTertiary 色
- 说明文字 textSecondary
- 两个按钮：FilledButton（本地导入）+ OutlinedButton（网络源）

#### 2.3 加载状态骨架屏（Skeleton Loading）

**问题**：曲库扫描/导入时 UI 冻结，无任何反馈。

**方案**：扫描中显示骨架行

```
┌────────────────────────────────────────┐
│ ░░░░  ░░░░░░░░░░░░░░░  ░░░░  ░░░░░░  │
│ ░░░░  ░░░░░░░░░░░░░░░  ░░░░  ░░░░░░  │
│ ░░░░  ░░░░░░░░░░░░░░░  ░░░░  ░░░░░░  │
│       正在扫描曲库... 12/48          │
└────────────────────────────────────────┘
```

- 骨架行用 `AnimatedContainer` + `highlight` 色做 pulse 动画（800ms 循环）
- 底部进度文字用 JetBrainsMono 等宽字体
- Skill UX #78: >300ms 操作必须有反馈

---

### P1 — 重要改进（一致性与可访问性）

#### 2.4 Reduced Motion 支持

**问题**：歌词自动滚动、hover 动画不尊重系统「减少动态效果」偏好。

**方案**：

```dart
bool _reduceMotion(BuildContext c) =>
    MediaQuery.of(c).disableAnimations; // Flutter 等价 prefers-reduced-motion

// 歌词滚动
if (_reduceMotion(context)) {
  _ctrl.jumpTo(target);  // 瞬移
} else {
  _ctrl.animateTo(target, duration: Duration(milliseconds: 350), curve: Curves.easeOutCubic);
}
```

- Skill UX #9: Reduced Motion, Severity: High

#### 2.5 RepaintBoundary 隔离动画区域

**问题**：歌词滚动和进度条更新触发整个 Now Playing 面板重绘。

**方案**：

```dart
// 进度条 — 每秒更新，需隔离
RepaintBoundary(child: _Progress(player: player))

// 歌词 — 滚动动画，需隔离
RepaintBoundary(child: Expanded(child: _Lyrics(player: player)))

// 分析标签 — 后台分析完成后更新
RepaintBoundary(child: _AnalysisTags(...))
```

- Skill Flutter #41: RepaintBoundary for animations, Severity: Medium

#### 2.6 连接状态不只靠颜色

**问题**：网络源连接状态（ok/fail）仅靠绿色/红色区分，色盲用户无法区分。

**方案**：颜色 + 图标 + 文字三重编码

```
✅ [check-circle]  连接正常     ← 绿 + 图标 + 文字
❌ [alert-circle]  连接失败     ← 红 + 图标 + 文字
⏳ [loader]        正在连接...   ← 灰 + 旋转图标 + 文字
```

- Skill UX #37: Color Only, Severity: High

---

### P2 — 精修打磨（视觉精致度）

#### 2.7 统一动画时长与曲线体系

建立项目动画常量，替代散落的魔法数字：

```dart
class WlMotion {
  static const Duration fast = Duration(milliseconds: 150);
  static const Duration normal = Duration(milliseconds: 200);
  static const Duration slow = Duration(milliseconds: 300);
  static const Curve enter = Curves.easeOut;     // 进入：快进慢出
  static const Curve exit = Curves.easeIn;       // 退出：慢进快出
  static const Curve standard = Curves.easeOutCubic;
}
```

应用范围：
- hover 色彩过渡：fast (150ms)
- 侧栏选中态切换：normal (200ms)
- 歌词滚动：slow (300ms，从 350ms 下调)
- 对话框进出：normal (200ms)

#### 2.8 曲目行 itemExtent 优化

**问题**：曲库 ListView.builder 无 itemExtent，每行需测量高度。

**方案**：曲目行高度固定（如 52px），加 `itemExtent: 52`：

```dart
ListView.builder(
  itemExtent: 52,  // 固定高度，跳过测量
  itemCount: tracks.length,
  itemBuilder: (c, i) => _SongTile(track: tracks[i], ...),
)
```

- Skill Flutter #16: Provide itemExtent when known, Severity: Medium

#### 2.9 正文行高微调

**问题**：bodyLarge height=1.4 偏紧，长文本阅读疲劳。

**方案**：

```dart
bodyLarge: TextStyle(height: 1.5),   // 1.4 → 1.5
bodyMedium: TextStyle(height: 1.45), // 1.3 → 1.45
```

- Skill UX #72: Line Height 1.5-1.75, Severity: Medium

#### 2.10 按压态（Active State）统一

**问题**：播放按钮有按压反馈，其他可点击元素（侧栏项、曲目行、设置项）无按压态。

**方案**：利用已有的 `hoverColor` + 增加 `splashColor: AppTheme.highlightStrong`（极淡），或用 `GestureDetector` + `StatefulWidget` 控制 `isPressed` 状态微调背景色。

但注意：项目已显式移除 Material ripple（`splashFactory: NoSplash.splashFactory`），这是正确的桌面设计选择。按压态改为：

```dart
// 侧栏项/曲目行/设置项按压时
color: isPressed ? AppTheme.highlightStrong : (isHovered ? AppTheme.highlight : Colors.transparent)
```

---

### P3 — 锦上添花

#### 2.11 Semantics 无障碍标签

为所有图标按钮添加语义标签：

```dart
IconButton(
  icon: const Icon(LucideIcons.play),
  onPressed: player.togglePlay,
  tooltip: '播放/暂停',  // 已有 tooltip 的保留
)
// 或用 Semantics 包裹
Semantics(
  label: '播放',
  button: true,
  child: GestureDetector(...),
)
```

#### 2.12 键盘焦点环

桌面应用键盘导航时需要可见的焦点环：

```dart
// 在 ThemeData 中
inputDecorationTheme: InputDecorationTheme(
  focusedBorder: OutlineInputBorder(
    borderSide: BorderSide(color: AppTheme.textTertiary, width: 1.5),
  ),
),
// 自定义可聚焦控件
Focus(
  child: Builder(builder: (context) {
    final hasFocus = Focus.of(context).hasFocus;
    return Container(
      decoration: BoxDecoration(
        border: hasFocus ? Border.all(color: AppTheme.textTertiary, width: 1.5) : null,
        borderRadius: BorderRadius.circular(8),
      ),
      child: ...,
    );
  }),
)
```

---

## 三、设计令牌审计

### 3.1 现有令牌 vs. Skill 规范对照

| 令牌 | 当前值 | Skill 推荐 | 状态 |
|------|--------|-----------|------|
| S0 (最深底) | #08090A | #000000 | ✅ 近似，保留（纯黑在 macOS 上过刺眼） |
| S1 (主背景) | #0E1011 | #121212 | ✅ 近似 |
| S2 (卡片) | #16191B | — | ✅ 合理 |
| S3 (高亮表面) | #1F2427 | — | ✅ 合理 |
| S4 (边框) | #2A3033 | — | ✅ 合理 |
| textPrimary | #F0F1F3 (94%) | #FFFFFF | ✅ 略低于纯白，减少眩光，合理 |
| textSecondary | #9A9FA6 (60%) | #E0E0E0 | ⚠️ Skill 推荐 87%，但 60% 是副文字层级，合理 |
| textTertiary | #5C6166 (36%) | — | ✅ 三级层级清晰 |
| 对比度 (primary on S1) | 15.8:1 | 7:1+ | ✅ 超 AAA |
| 对比度 (secondary on S1) | 6.2:1 | 4.5:1+ | ✅ 达 AA |
| 对比度 (tertiary on S1) | 2.8:1 | — | ⚠️ 仅用于非关键信息（图标/提示），可接受 |

### 3.2 字体体系审计

| 用途 | 字体 | Skill 推荐 | 状态 |
|------|------|-----------|------|
| 标题/Display | SpaceGrotesk | Righteous | ✅ 更克制，适合 hi-res 工具定位 |
| 正文/Body | Inter | Poppins | ✅ 更中性，通用性更强 |
| 技术读数/Mono | JetBrainsMono | — | ✅ 项目特色，Skill 未涉及但合理 |
| 字重范围 | 400-700 | 300-700 | ⚠️ 可考虑加 Light(300) 用于大号标题 |

### 3.3 间距体系建议

当前间距散落在各 Widget 中（SizedBox 魔法数字）。建议建立间距令牌：

```dart
class WlSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
  static const double xxxl = 48;  // Skill 推荐：大间距 48px+
}
```

---

## 四、实施优先级

| 阶段 | 内容 | 涉及文件 |
|------|------|---------|
| **P0-a** | 空状态设计 | `home.dart` |
| **P0-b** | 骨架屏加载 | `home.dart` |
| **P0-c** | LayoutBuilder 响应式 | `home.dart` |
| **P1-a** | Reduced Motion | `home.dart`, `settings.dart` |
| **P1-b** | RepaintBoundary | `home.dart` |
| **P1-c** | 连接状态三重编码 | `network_dialogs.dart`, `home.dart` |
| **P2-a** | 动画常量体系 | `theme.dart` + 全局 |
| **P2-b** | itemExtent 优化 | `home.dart` |
| **P2-c** | 行高微调 | `theme.dart` |
| **P2-d** | 按压态统一 | `home.dart`, `settings.dart` |
| **P3-a** | Semantics 标签 | 全局 |
| **P3-b** | 键盘焦点环 | `theme.dart` + 全局 |

---

## 五、Skill Pre-Delivery Checklist 对照

| 检查项 | 状态 |
|--------|------|
| 无 emoji 图标（用 Lucide SVG） | ✅ 已达标 |
| 所有可点击元素有 hover 反馈 | ✅ 已达标 |
| hover 过渡 150-300ms | ⚠️ 需统一（P2-a） |
| 暗色模式文字对比 4.5:1+ | ✅ 已达标 |
| 键盘焦点可见 | ❌ 待实现（P3-b） |
| prefers-reduced-motion | ❌ 待实现（P1-a） |
| 响应式（多断点） | ❌ 待实现（P0-c） |

---

## 六、设计哲学总结

本方案的核心原则，与 Skill 推荐对齐但坚持项目已确立的方向：

1. **黑白 UI + 内容带色** — UI 结构纯灰阶，专辑封面是唯一的色彩来源。这是 Tidal/Apple Music 范式，不是 Skill 推荐的「彩色 UI」，但更适合 hi-res 音乐播放器的严肃工具定位。
2. **OLED Dark Mode** — Skill 的 Dark Mode (OLED) style 是最匹配的，WCAG AAA 对比度已达标。
3. **SpaceGrotesk > Righteous** — Skill 推荐 Righteous（活泼/娱乐），但项目定位是 hi-res 严肃工具，SpaceGrotesk 的几何感+克制感更合适。
4. **大留白 + 少干扰** — 采纳 Skill 的 Minimal pattern 精神，但在桌面三栏框架内实现。
5. **200-300ms 微交互** — 采纳 Skill 的动画时长规范，建立统一常量。
6. **无障碍不只是颜色** — 采纳 Skill 的 UX guideline：连接状态用图标+文字+颜色三重编码。
