/// 临时 SMB 连接验证（跑完即删）
/// flutter test integration_test/smb_test.dart -d macos
library;

import 'package:checks/checks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wavelink_mobile/data/services/rust_service.dart' as rs;
import 'package:wavelink_mobile/data/services/smb_service.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await rs.initRust();
    check(rs.rustAvailable).isTrue();
  });

  test('SMB connect + listShares', () async {
    final ok = await SmbService.connect(
      host: '192.168.110.27',
      username: '',
      password: '',
    );
    print('connect ok: $ok');
    check(ok).isTrue();

    final shares = await SmbService.listShares();
    print('shares: $shares');
    check(shares).isNotEmpty();
    check(shares).contains('misic');

    final mounted = await SmbService.connectShare('misic');
    print('connectShare misic: $mounted');
    check(mounted).isTrue();

    final files = await SmbService.listFiles('');
    print('misic root entries: ${files.map((e) => '${e.name}${e.isDir ? "/" : ""}').toList()}');

    await SmbService.disconnect();
  });
}
