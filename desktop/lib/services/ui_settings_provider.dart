import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ═══════════════════════════ 界面显示设置 ═══════════════════════════
//
// 对齐 audio_settings_provider 的 Notifier 模式：不可变 State + copyWith
// + setter「更新状态 → 持久化」两步走。视图只负责布局与交互反馈。

/// 列表密度档位：compact = 紧凑（行高 48），comfortable = 舒适（行高 56）。
enum RowDensity { compact, comfortable }

extension RowDensityX on RowDensity {
  String get key => name;

  static RowDensity fromKey(String? k) =>
      RowDensity.values.firstWhere((d) => d.key == k,
          orElse: () => RowDensity.compact);

  /// 曲目行高（px）。与 track_row.dart 的封面+内边距结构配套：
  /// compact = 38 封面 + 5*2 上下内边距；comfortable = 42 封面 + 7*2。
  double get rowHeight => switch (this) {
        RowDensity.compact => 48,
        RowDensity.comfortable => 56,
      };

  double get coverSize => switch (this) {
        RowDensity.compact => 38,
        RowDensity.comfortable => 42,
      };
}

/// 界面显示状态。
class UiSettingsState {
  const UiSettingsState({this.rowDensity = RowDensity.compact});

  final RowDensity rowDensity;

  UiSettingsState copyWith({RowDensity? rowDensity}) {
    return UiSettingsState(rowDensity: rowDensity ?? this.rowDensity);
  }
}

/// 界面显示设置 Notifier。
class UiSettingsNotifier extends Notifier<UiSettingsState> {
  @override
  UiSettingsState build() {
    // 异步恢复持久化值（build 同步返回默认值，与 audio_settings_provider 一致）。
    Future.microtask(_restore);
    return const UiSettingsState();
  }

  Future<void> _restore() async {
    final p = await SharedPreferences.getInstance();
    final persisted = UiSettingsState(
      rowDensity: RowDensityX.fromKey(p.getString('ui.rowDensity')),
    );
    if (ref.mounted) state = persisted;
  }

  Future<void> setRowDensity(RowDensity v) async {
    state = state.copyWith(rowDensity: v);
    (await SharedPreferences.getInstance()).setString('ui.rowDensity', v.key);
  }
}

final uiSettingsProvider =
    NotifierProvider<UiSettingsNotifier, UiSettingsState>(
        UiSettingsNotifier.new);
