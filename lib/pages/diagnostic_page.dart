/// 音频诊断页面 — 实时显示 ringbuf 状态和 underrun 计数
/// 杂音排查用

import 'dart:async';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../services/rust_service.dart' as rs;
import '../src/rust/api/audio_output.dart' as audio_out;

class DiagnosticPage extends StatefulWidget {
  const DiagnosticPage({super.key});

  @override
  State<DiagnosticPage> createState() => _DiagnosticPageState();
}

class _DiagnosticPageState extends State<DiagnosticPage> {
  Timer? _timer;
  BigInt _occupied = BigInt.zero;
  BigInt _underrun = BigInt.zero;
  BigInt _prevUnderun = BigInt.zero;
  int _underrunDelta = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) => _poll());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _poll() async {
    if (!rs.rustAvailable) return;
    try {
      final occ = await audio_out.debugOccupied();
      final ur = await audio_out.getUnderrunCount();
      setState(() {
        _underrunDelta = (ur - _prevUnderun).toInt();
        _prevUnderun = ur;
        _occupied = occ;
        _underrun = ur;
      });
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        title: const Text('音频诊断'),
        backgroundColor: AppTheme.surfaceDark,
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _card('Ringbuf 占用', '${_occupied} 样本'),
            _card('总 underrun', '$_underrun'),
            _card('近期 underrun', '$_underrunDelta 次/500ms',
                color: _underrunDelta > 0 ? Colors.red : Colors.green),
            const SizedBox(height: 20),
            const Text(
              '提示：近期 underrun > 0 说明音频输出时缓冲区抽干了，\n'
              '这是杂音/断音的根源。正常播放时应该始终为 0。',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
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
