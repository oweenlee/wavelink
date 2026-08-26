/// 房间校正服务：封装 Rust `room` FRB 桥接，UI 层不直接依赖生成码。
///
/// REW 测量文本 → 解析校验 → 生成校正 FIR → 落盘 WAV 的完整链路，
/// 供设置页调用；类型经 [RoomCorrectionResult] 等透出。
library;

import 'dart:typed_data';

import '../src/rust/api/room.dart' as frb_room;

/// 解析 REW 文本并返回有效频点数（0 表示无可校正数据）。
Future<int> parseRewPointCount(String text) async {
  final pts = await frb_room.parseRewText(text: text);
  return pts.length;
}

/// 从 REW 测量文本生成房间校正 FIR（默认校正参数 + 指定采样率）。
Future<frb_room.RoomCorrectionResult> generateFromRew({
  required String rewTxt,
  required int sampleRate,
}) async {
  final config = await frb_room.defaultCorrectionConfig();
  return frb_room.generateRoomCorrection(
    rewTxt: rewTxt,
    config: config,
    sampleRate: sampleRate,
  );
}

/// 把 FIR 写成 32-bit float 单声道 WAV（供引擎 load_ir 加载）。
Future<void> saveIrWav({
  required Float32List ir,
  required int sampleRate,
  required String path,
}) =>
    frb_room.saveIrWav(ir: ir, sampleRate: sampleRate, path: path);
