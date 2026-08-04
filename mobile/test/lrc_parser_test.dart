import 'package:flutter_test/flutter_test.dart';
import 'package:checks/checks.dart';
import 'package:wavelink_mobile/data/services/lrc_parser.dart';

void main() {
  group('parseLrc', () {
    test('空内容返回空列表', () {
      check(parseLrc('')).isEmpty();
      check(parseLrc('   \n\n  ')).isEmpty();
    });

    test('标准 [mm:ss.xx] 标签解析为毫秒', () {
      final lines = parseLrc('[00:01.50]你好');
      check(lines).length.equals(1);
      check(lines[0].timeMs).equals(1500.0);
      check(lines[0].text).equals('你好');
    });

    test('无小数 [mm:ss] 视为整秒', () {
      final lines = parseLrc('[01:05]词');
      check(lines[0].timeMs).equals(65000.0);
    });

    test('三位小数 [mm:ss.xxx] 按毫秒计', () {
      final lines = parseLrc('[00:02.345]x');
      check(lines[0].timeMs).equals(2345.0);
    });

    test('一位小数按百分秒补零（.5 → 500ms）', () {
      final lines = parseLrc('[00:03.5]x');
      check(lines[0].timeMs).equals(3500.0);
    });

    test('一行多个时间标签拆成多条', () {
      final lines = parseLrc('[00:01.00][00:05.00]重复句');
      check(lines).length.equals(2);
      check(lines.map((l) => l.timeMs).toList()).deepEquals([1000.0, 5000.0]);
      check(lines.every((l) => l.text == '重复句')).isTrue();
    });

    test('结果按时间升序排列', () {
      final lines = parseLrc('[00:10.00]晚\n[00:02.00]早');
      check(lines.map((l) => l.text).toList()).deepEquals(['早', '晚']);
    });

    test('元数据标签被忽略', () {
      final lines = parseLrc('[ti:标题]\n[ar:歌手]\n[al:专辑]\n[00:01.00]正文');
      check(lines).length.equals(1);
      check(lines[0].text).equals('正文');
    });

    test('空文本占位行被跳过', () {
      final lines = parseLrc('[00:01.00]\n[00:02.00]有词');
      check(lines).length.equals(1);
      check(lines[0].text).equals('有词');
    });

    test('冒号分隔小数 [mm:ss:xx] 也支持', () {
      final lines = parseLrc('[00:04:25]x');
      check(lines[0].timeMs).equals(4250.0);
    });

    test('Windows 换行 \\r\\n 正常处理', () {
      final lines = parseLrc('[00:01.00]一\r\n[00:02.00]二\r\n');
      check(lines).length.equals(2);
    });
  });
}
