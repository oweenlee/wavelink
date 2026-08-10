import 'package:flutter/material.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../../data/services/rust_service.dart' as rs;
import '../../../core/theme/app_theme.dart';
import '../../../../data/services/log.dart';

class DiagnosticPage extends StatefulWidget {
  const DiagnosticPage({super.key});

  @override
  State<DiagnosticPage> createState() => _DiagnosticPageState();
}

class _DiagnosticPageState extends State<DiagnosticPage> {
  String _position = '-';
  String _duration = '-';
  bool _isPlaying = false;
  String _currentPath = '-';
  int _underrun = 0;
  int _prevUnderun = 0;
  int _underrunDelta = 0;
  String _logSize = '-';

  @override
  void initState() {
    super.initState();
    _refresh();
    _loadLogSize();
  }

  /// 日志落盘占用（与引擎状态无关，单独加载）
  Future<void> _loadLogSize() async {
    final bytes = await Log.totalBytes();
    if (!mounted) return;
    setState(() => _logSize = _fmtBytes(bytes));
  }

  static String _fmtBytes(int n) {
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    return '${(n / 1024 / 1024).toStringAsFixed(2)} MB';
  }

  Future<void> _confirmClearLogs() async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surfaceDark,
        title: Text(l10n.clear),
        content: Text(l10n.logClearConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              l10n.clear,
              style: const TextStyle(color: AppTheme.danger),
            ),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await Log.clear();
      _loadLogSize();
    }
  }

  Future<void> _refresh() async {
    if (!rs.rustAvailable) return;
    try {
      final pos = await rs.enginePositionSecs();
      final dur = await rs.engineDurationSecs();
      final playing = await rs.engineIsPlaying();
      final path = await rs.engineCurrentPath();
      final ur = await rs.getUnderrunCount();
      setState(() {
        _position = '${pos.toStringAsFixed(1)}s';
        _duration = '${dur.toStringAsFixed(1)}s';
        _isPlaying = playing;
        _currentPath = path.isNotEmpty ? path.split('/').last : '-';
        _underrunDelta = ur - _prevUnderun;
        _prevUnderun = ur;
        _underrun = ur;
      });
    } catch (e) {
      Log.e('Diagnostic', '刷新失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        title: Text(l10n.diagnosticTitle),
        backgroundColor: AppTheme.surfaceDark,
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _card('Status', _isPlaying ? 'Playing' : 'Stopped'),
            _card('Position', _position),
            _card('Duration', _duration),
            _card('File', _currentPath),
            _card(l10n.diagnosticTotalUnderrun, '$_underrun'),
            _card(
              l10n.diagnosticRecentUnderrun,
              '$_underrunDelta (500ms)',
              color: _underrunDelta > 0 ? AppTheme.danger : AppTheme.success,
            ),
            _card(l10n.logSize, _logSize),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                style: TextButton.styleFrom(
                  backgroundColor: AppTheme.surfaceDark,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: _confirmClearLogs,
                child: Text(
                  l10n.clear,
                  style: const TextStyle(
                    color: AppTheme.danger,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              l10n.diagnosticHint,
              style: const TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _card(String label, String value, {Color? color}) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surfaceDark,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(color: AppTheme.textSecondary, fontSize: 15),
          ),
          Text(
            value,
            style: TextStyle(
              color: color ?? AppTheme.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
