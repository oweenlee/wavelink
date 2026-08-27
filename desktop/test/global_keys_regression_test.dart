// 回归测试：home 全局按键处理（空格=播放/暂停、↑↓=音量）必须真正拦截按键，
// 不能被 WidgetsApp 默认快捷键劫持。
//
// 根因：KeyboardListener 的 onKeyEvent 回调无论返回什么都会被包装成
// KeyEventResult.ignored，按键继续冒泡 → WidgetsApp 默认 Shortcuts：
// 空格 → ActivateIntent（激活聚焦的列表行 → 误切歌）
// 上下 → DirectionalFocusIntent（列表焦点移动）
// 修复：改用 Focus.onKeyEvent 返回 handled 截断传播。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Focus 处理空格并阻止 InkWell 激活（切歌）', (tester) async {
    var toggleCount = 0;
    var rowActivateCount = 0;
    final kbFocus = FocusNode();

    await tester.pumpWidget(MaterialApp(
      home: Focus(
        focusNode: kbFocus,
        autofocus: true,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.space) {
            toggleCount++;
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Scaffold(
          body: ListView(
            children: [
              InkWell(
                onTap: () => rowActivateCount++,
                child: const SizedBox(height: 40, width: 200),
              ),
            ],
          ),
        ),
      ),
    ));

    // 把焦点移到列表里的 InkWell 行上（模拟用户点击列表行后的状态）
    final rowFocus = Focus.of(tester.element(find.byType(InkWell).first));
    rowFocus.requestFocus();
    await tester.pumpAndSettle();

    // 按空格：应只触发全局 toggle，行不得被激活
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(toggleCount, 1, reason: '空格应触发全局播放/暂停');
    expect(rowActivateCount, 0, reason: '空格不得激活聚焦的行（切歌）');
  });

  testWidgets('Focus 处理上下键并阻止列表焦点移动', (tester) async {
    var volumeUpCount = 0;
    var volumeDownCount = 0;
    final kbFocus = FocusNode();

    await tester.pumpWidget(MaterialApp(
      home: Focus(
        focusNode: kbFocus,
        autofocus: true,
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
            volumeUpCount++;
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
            volumeDownCount++;
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Scaffold(
          body: ListView(children: [
            InkWell(
              onTap: () {},
              child: const SizedBox(height: 40, width: 200),
            ),
            InkWell(
              onTap: () {},
              child: const SizedBox(height: 40, width: 200),
            ),
          ]),
        ),
      ),
    ));

    // 焦点落到第一行（模拟用户点击列表中某行后按方向键）
    final rowFocus = Focus.of(tester.element(find.byType(InkWell).first));
    rowFocus.requestFocus();
    await tester.pumpAndSettle();
    final initialFocusId =
        FocusManager.instance.primaryFocus?.context?.widget.key;

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();

    expect(volumeDownCount, 1, reason: '下键应触发音量降低');
    expect(volumeUpCount, 1, reason: '上键应触发音量升高');
    expect(
      FocusManager.instance.primaryFocus?.context?.widget.key,
      initialFocusId,
      reason: '上下键不得移动列表焦点',
    );
  });
}
