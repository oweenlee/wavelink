import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../data/services/rust_service.dart' as rs;
import '../theme/app_theme.dart';

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

  @override
  void initState() {
    super.initState();
    _refresh();
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
      debugPrint('[Diagnostic] 刷新失败: $e');
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
              color: _underrunDelta > 0 ? Colors.red : Colors.green,
            ),
            const SizedBox(height: 20),
            Text(
              l10n.diagnosticHint,
              style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
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
          Text(label, style: const TextStyle(color: AppTheme.textSecondary, fontSize: 15)),
          Text(value, style: TextStyle(
            color: color ?? AppTheme.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          )),
        ],
      ),
    );
  }
}
