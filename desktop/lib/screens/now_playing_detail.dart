import 'dart:io';

// hide RepeatMode：Flutter 的 repeating_animation_builder 也导出同名符号，
// 与 player_notifier 的播放循环模式冲突（与 transport_bar 处理方式一致）。
import 'package:flutter/material.dart' hide RepeatMode;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:path/path.dart' as p;

import '../core/format.dart';
import '../core/theme.dart';
import '../l10n/app_localizations.dart';
import '../models/track.dart';
import '../services/audio_settings_provider.dart';
import '../services/player_notifier.dart';
import '../services/player_providers.dart';
import '../widgets/cover_art.dart';

// 单色板别名（与 now_playing.dart 同源，仅为缩短引用）。
const _onSurface = kOnSurface;
const _onSurfaceVariant = kOnSurfaceVariant;

/// 详情展示用的容器格式标签：CUE 分轨 / 本地或远端文件扩展名 / 音源短名。
///
/// 与 [Track] 的播放分支对齐：CUE 虚拟分轨没有自己的音频容器，实际播放的
/// 是 `cuePath` 指向的整轨文件，因此格式统一标注为 CUE。
String trackFormatLabel(Track t) {
  if (t.isCueTrack) return 'CUE';
  final path = t.filePath ?? t.remotePath;
  if (path != null) {
    final ext = p.extension(path).replaceFirst('.', '').toUpperCase();
    if (ext.isNotEmpty) return ext;
  }
  return t.source.short;
}

/// 详情展示用的文件/资源地址：本地路径 → 远端路径 → 流地址。
///
/// 流地址（Subsonic）带凭据 query，展示前一律脱敏，只保留到 path。
String? trackLocationLabel(Track t) {
  final local = t.filePath ?? t.remotePath;
  if (local != null && local.isNotEmpty) return local;
  final url = t.streamUrl;
  if (url == null || url.isEmpty) return null;
  final i = url.indexOf('?');
  return i < 0 ? url : url.substring(0, i);
}

/// 曲目详情视图（播放面板「详情」页）。
///
/// 定位：hi-res 播放器真正该露出的技术参数——来源文件、时长、输出链路、
/// BPM/调性分析。与「正在播放」页的观赏性信息（封面/歌词/频谱）互补，
/// 因此独立成页而不是塞进正在播放页挤占歌词区。
///
/// 数据源：曲目元数据取 [PlayerState.currentTrack]，输出链路取
/// [audioSettingsProvider]，分析结果为播放后异步落地，经 [analysisProvider]
/// 广播刷新。除文件大小需 [File.stat] 异步探测外，全部为同步读取。
class TrackDetailView extends ConsumerStatefulWidget {
  final PlayerNotifier player;

  const TrackDetailView({super.key, required this.player});

  @override
  ConsumerState<TrackDetailView> createState() => _TrackDetailViewState();
}

class _TrackDetailViewState extends ConsumerState<TrackDetailView> {
  /// 文件体积探测结果按 track.id 缓存，避免切歌瞬间的旧值串台。
  String? _sizeTrackId;
  Future<int?>? _sizeFuture;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final track = ref.watch(playerProvider.select((s) => s.currentTrack));
    if (track == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                LucideIcons.info,
                size: 36,
                color: AppTheme.textTertiary,
              ),
              const SizedBox(height: 12),
              Text(
                l10n.nowPlayingEmpty,
                style: const TextStyle(color: _onSurface, fontSize: 14),
              ),
              const SizedBox(height: 4),
              Text(
                l10n.detailEmptyHint,
                textAlign: TextAlign.center,
                style: const TextStyle(color: _onSurfaceVariant, fontSize: 12),
              ),
            ],
          ),
        ),
      );
    }

    _ensureSizeFuture(track);
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
      children: [
        _Header(track: track),
        const SizedBox(height: 20),
        _Section(
          title: l10n.detailGroupFile,
          rows: [
            _Row(label: l10n.detailSource, value: track.sourceLabel),
            _Row(label: l10n.detailFormat, value: trackFormatLabel(track)),
            _SizeRow(track: track, future: _sizeFuture!),
            // 路径/远端路径/流地址：三项互斥，取第一个有值的展示
            if (trackLocationLabel(track) case final loc?)
              _Row(
                label: l10n.detailPath,
                value: loc,
                copyValue: loc,
                maxLines: 4,
              ),
            if (track.isStrm)
              _Row(
                label: l10n.detailStrmTarget,
                value: _strmLabel(track),
                copyValue: track.targetUri,
                maxLines: 3,
              ),
            if (track.isCueTrack)
              _Row(
                label: l10n.detailCueTrack,
                value: _cueLabel(track),
                copyValue: track.cuePath,
                maxLines: 2,
              ),
            if (track.trackNumber case final no?)
              _Row(label: l10n.detailTrackNo, value: '$no'),
          ],
        ),
        const SizedBox(height: 18),
        _Section(
          title: l10n.detailGroupPlayback,
          rows: [
            _DurationRow(track: track),
            const _PositionRow(),
            const _PlayModeRow(),
          ],
        ),
        const SizedBox(height: 18),
        const _OutputSection(),
        const SizedBox(height: 18),
        _AnalysisSection(player: widget.player, track: track),
      ],
    );
  }

  /// 文件大小：网络曲目扫描期已知（[Track.fileSize]），本地曲目需 stat。
  /// 仅在曲目变化时重新探测（build 多次进入不重复 IO）。
  void _ensureSizeFuture(Track track) {
    if (_sizeTrackId == track.id && _sizeFuture != null) return;
    _sizeTrackId = track.id;
    _sizeFuture = _probeSize(track);
  }

  Future<int?> _probeSize(Track t) async {
    if (t.fileSize != null) return t.fileSize;
    final path = t.filePath;
    if (path == null || t.isNetwork) return null;
    try {
      return (await File(path).stat()).size;
    } catch (_) {
      // 文件被移动/无权限：显示「未知」，不打断详情渲染
      return null;
    }
  }

  String _strmLabel(Track t) {
    final kind = t.targetKind;
    final uri = trackLocationLabelOf(t.targetUri);
    if (kind != null && uri != null) return '$kind · $uri';
    return uri ?? kind ?? '—';
  }

  String _cueLabel(Track t) {
    final i = t.cueTrackIndex;
    final total = t.cueTrackCount;
    if (i == null) return t.cuePath ?? '—';
    final idx = '${i + 1}';
    return total == null ? idx : '$idx / $total';
  }
}

/// 详情头部：小封面 + 标题/艺术家（与正在播放页共用同一曲目时的视觉锚点）。
class _Header extends StatelessWidget {
  final Track track;
  const _Header({required this.track});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        CoverArt(
          key: ValueKey('detail-${track.coverUrl ?? track.id}'),
          seed: track.id,
          coverUrl: track.coverUrl,
          size: 46,
          rounded: true,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                track.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: WlText.display(fontSize: 15),
              ),
              const SizedBox(height: 3),
              Text(
                track.artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: _onSurfaceVariant, fontSize: 12),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 分组容器：组标题 + 行列表（行间等距）。
class _Section extends StatelessWidget {
  final String title;
  final List<Widget> rows;

  const _Section({required this.title, required this.rows});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: AppTheme.textTertiary,
            letterSpacing: 0.6,
          ),
        ),
        const SizedBox(height: 8),
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) const SizedBox(height: 7),
          rows[i],
        ],
      ],
    );
  }
}

/// 键值行：标签左、读数右（等宽）。传入 [copyValue] 时整行可点击复制
/// —— 桌面端最实用的动作是复制路径去排查文件/转码问题。
class _Row extends StatelessWidget {
  final String label;
  final String value;
  final String? copyValue;
  final int maxLines;

  const _Row({
    required this.label,
    required this.value,
    this.copyValue,
    this.maxLines = 2,
  });

  @override
  Widget build(BuildContext context) {
    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 76,
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 11.5,
              color: AppTheme.textTertiary,
              height: 1.5,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.right,
            maxLines: maxLines,
            overflow: TextOverflow.ellipsis,
            style: WlText.mono(
              fontSize: 11.5,
              color: _onSurface,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );

    final copy = copyValue;
    if (copy == null) return row;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _copyToClipboard(context, copy),
        child: row,
      ),
    );
  }
}

/// 文件体积：本地曲目 stat 异步探测，探测中/失败显示「未知」。
class _SizeRow extends StatelessWidget {
  final Track track;
  final Future<int?> future;

  const _SizeRow({required this.track, required this.future});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return FutureBuilder<int?>(
      future: future,
      builder: (context, snap) =>
          _Row(label: l10n.detailSize, value: fmtBytes(snap.data)),
    );
  }
}

/// 时长：优先引擎实测时长，回落扫描期 [Track.durationHint]；
/// 估算值（按文件大小推算）显式标注，避免把估值当实测读数。
class _DurationRow extends ConsumerWidget {
  final Track track;
  const _DurationRow({required this.track});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final dur = ref.watch(playerProvider.select((s) => s.duration));
    final shown = dur > Duration.zero
        ? dur
        : (track.durationHint ?? Duration.zero);
    final estimated = track.durationEstimated
        ? ' · ${l10n.detailEstimated}'
        : '';
    return _Row(
      label: l10n.detailDuration,
      value: shown > Duration.zero
          ? '${fmtDuration(shown)}$estimated'
          : l10n.detailUnknown,
    );
  }
}

/// 播放进度：位置 + 百分比。独立订阅 position，避免高频刷新整张详情页。
class _PositionRow extends ConsumerWidget {
  const _PositionRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final pos = ref.watch(playerProvider.select((s) => s.position));
    final dur = ref.watch(playerProvider.select((s) => s.duration));
    final pct = dur > Duration.zero
        ? '${(pos.inMilliseconds / dur.inMilliseconds * 100).clamp(0, 100).round()}%'
        : '—';
    return _Row(
      label: l10n.detailPosition,
      value: '${fmtDuration(pos)} · $pct',
    );
  }
}

/// 播放模式：随机优先（与传输条的模式按钮语义一致），否则按循环模式。
class _PlayModeRow extends ConsumerWidget {
  const _PlayModeRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final shuffle = ref.watch(playerProvider.select((s) => s.shuffle));
    final repeat = ref.watch(playerProvider.select((s) => s.repeatMode));
    final value = shuffle
        ? l10n.modeShuffle
        : switch (repeat) {
            RepeatMode.off => l10n.modeSequential,
            RepeatMode.all => l10n.modeRepeatAll,
            RepeatMode.one => l10n.modeRepeatOne,
          };
    return _Row(label: l10n.detailMode, value: value);
  }
}

/// 音频输出链路：hi-res 定位的核心读数（实际输出采样率 / 设备 / 独占 /
/// bit-perfect / 自动采样率）。
class _OutputSection extends ConsumerWidget {
  const _OutputSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final s = ref.watch(audioSettingsProvider);
    final on = l10n.detailOn;
    final off = l10n.detailOff;
    return _Section(
      title: l10n.detailGroupOutput,
      rows: [
        _Row(
          label: l10n.detailOutputRate,
          value: s.actualSampleRate != null
              ? '${s.actualSampleRate} Hz'
              : l10n.detailUnknown,
        ),
        _Row(
          label: l10n.detailDevice,
          value: s.selectedDevice ?? l10n.settingsSystemDefault,
          copyValue: s.selectedDevice,
          maxLines: 2,
        ),
        _Row(label: l10n.detailExclusive, value: s.exclusive ? on : off),
        _Row(label: 'Bit-perfect', value: s.bitPerfect ? on : off),
        _Row(label: l10n.detailAutoRate, value: s.autoSampleRate ? on : off),
      ],
    );
  }
}

/// 分析结果：播放后由 Rust 侧异步分析，完成经 [analysisProvider] 广播刷新；
/// 未出结果时给出「尚未分析」，不显示占位 0 值误导。
class _AnalysisSection extends ConsumerWidget {
  final PlayerNotifier player;
  final Track track;

  const _AnalysisSection({required this.player, required this.track});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    ref.watch(analysisProvider);
    final a = player.getAnalysis(track.id);
    final rows = <Widget>[
      _Row(
        label: 'BPM',
        value: a?.bpm != null
            ? _withConfidence('${a!.bpm!.round()}', a.bpmConfidence)
            : '—',
      ),
      _Row(
        label: l10n.detailTrackKey,
        value: (a?.key?.isNotEmpty ?? false)
            ? _withConfidence(a!.key!, a.keyConfidence)
            : '—',
      ),
      _Row(
        label: l10n.detailEnergy,
        value: a?.energy != null ? a!.energy!.toStringAsFixed(2) : '—',
      ),
    ];
    if (a == null) {
      rows.add(
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            l10n.detailNotAnalyzed,
            style: const TextStyle(color: AppTheme.textTertiary, fontSize: 11),
          ),
        ),
      );
    }
    return _Section(title: l10n.detailGroupAnalysis, rows: rows);
  }

  /// 读数 + 置信度后缀（分析结果为概率估计，不给置信度等于给了假精度）。
  String _withConfidence(String value, double? confidence) {
    if (confidence == null) return value;
    return '$value · ${(confidence * 100).clamp(0, 100).round()}%';
  }
}

/// 复制反馈：桌面端惯例走底部 SnackBar（与传输条/侧栏一致）。
Future<void> _copyToClipboard(BuildContext context, String text) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (!context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      content: Text(AppLocalizations.of(context).detailCopied),
      duration: const Duration(seconds: 2),
      behavior: SnackBarBehavior.floating,
    ),
  );
}

/// 流地址脱敏：去掉 `?` 之后的 query（Subsonic 的流地址带凭据）。
String? trackLocationLabelOf(String? url) {
  if (url == null || url.isEmpty) return null;
  final i = url.indexOf('?');
  return i < 0 ? url : url.substring(0, i);
}
