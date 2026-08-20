import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'engine.dart';
import 'player_providers.dart';

// ═══════════════════════════ 引擎诊断 ═══════════════════════════
//
// 诊断指标轮询状态（underrun / 最后错误 / 当前曲目路径）。
// 视图持有定时器，周期性调用 [DiagnosticsNotifier.refresh]。

/// 诊断指标状态。
class DiagnosticsState {
  const DiagnosticsState({
    this.underrun = 0,
    this.lastError = '',
    this.currentPath = '',
  });

  final int underrun;
  final String lastError;
  final String currentPath;

  DiagnosticsState copyWith({
    int? underrun,
    String? lastError,
    String? currentPath,
  }) {
    return DiagnosticsState(
      underrun: underrun ?? this.underrun,
      lastError: lastError ?? this.lastError,
      currentPath: currentPath ?? this.currentPath,
    );
  }
}

/// 诊断 Notifier：refresh 拉取引擎指标。
class DiagnosticsNotifier extends Notifier<DiagnosticsState> {
  Engine? get _engine => ref.read(playerControllerProvider).engine;

  @override
  DiagnosticsState build() => const DiagnosticsState();

  Future<void> refresh() async {
    final e = _engine;
    if (e == null) return;
    try {
      final u = await e.underrunCount();
      final l = await e.lastError();
      final c = await e.currentPath();
      if (!ref.mounted) return;
      state = DiagnosticsState(underrun: u, lastError: l, currentPath: c);
    } catch (_) {
      // 引擎瞬时不可用（如重启中）不置错，保留上次读数。
    }
  }
}

final diagnosticsProvider =
    NotifierProvider<DiagnosticsNotifier, DiagnosticsState>(
        DiagnosticsNotifier.new);
