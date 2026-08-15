import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// 运行时包信息（版本号等）：从 PackageInfo 读取而非文案硬编码——
/// 发版时 pubspec version 提升即可，无需同步改语言文件。
/// 插件不可用（测试/受限环境）时降级为空对象，UI 侧自行兜底。
final packageInfoProvider = FutureProvider<PackageInfo>((ref) async {
  try {
    return await PackageInfo.fromPlatform();
  } catch (_) {
    return PackageInfo(
      appName: '',
      packageName: '',
      version: '',
      buildNumber: '',
      buildSignature: '',
    );
  }
});