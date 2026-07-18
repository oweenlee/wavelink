import 'package:flutter/services.dart';

/// 原生文件选择器（替代 file_picker 插件）
class FilePickerService {
  static const _channel = MethodChannel('wavelink/file_picker');

  /// 打开系统文件选择器，返回选中文件路径列表
  static Future<List<String>> pickFiles({
    List<String> extensions = const ['mp3', 'flac', 'wav', 'aac', 'ogg', 'm4a',
      'wma', 'alac', 'aiff', 'dsf', 'dff', 'opus'],
    bool multiple = true,
  }) async {
    try {
      final result = await _channel.invokeListMethod<String>('pickFiles', {
        'extensions': extensions,
        'multiple': multiple,
      });
      return result ?? [];
    } on MissingPluginException {
      // 无原生实现时静默降级
      return [];
    }
  }
}
