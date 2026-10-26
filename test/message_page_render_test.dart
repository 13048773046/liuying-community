/// 消息页渲染回归：任何状态（加载/未登录 401/空数据/加载失败）都必须渲染出
/// 可见内容，不允许白屏或渲染异常。新版为二级架构（一级列表 = 互动/官方/私信）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:community_app/models/feed_item.dart';
import 'package:community_app/pages/message/message_page.dart';

void main() {
  testWidgets('消息页任意终态都必须渲染出可见内容（绝不白屏）', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: MessagePage()));
    // 初始加载态：标题必须可见
    expect(find.text('消息'), findsOneWidget);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    // 无渲染异常
    expect(tester.takeException(), isNull);
    // 最终必须出现可读内容之一：登录引导 / 加载失败重试
    final visibleTexts = <String>[];
    for (final t in [
      '登录后查看消息',
      '加载失败',
    ]) {
      if (find.text(t).evaluate().isNotEmpty) visibleTexts.add(t);
    }
    expect(visibleTexts, isNotEmpty, reason: '消息页不能白屏：必须渲染任一可读状态');
  });

  testWidgets('消息页二级入口列表渲染：标题 + 提示文案可见', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: MessagePage()));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
    expect(find.text('消息'), findsOneWidget);
    // 未登录或加载失败时，任一可读终态仍可见
    final visible = <String>[];
    for (final t in ['登录后查看消息', '加载失败']) {
      if (find.text(t).evaluate().isNotEmpty) visible.add(t);
    }
    expect(visible, isNotEmpty, reason: '消息页不能白屏');
  });

  test('消息页 tile 依赖的容错函数对脏数据不崩', () {
    // boolOf：后端 isRead 可能为 0/1/null/'1'，全部安全
    expect(boolOf(0), false);
    expect(boolOf(1), true);
    expect(boolOf(null), false);
    expect(boolOf('1'), true);
    expect(boolOf('0'), false);
    // timeAgo：created 为 double 时间戳（后端 REAL）或 0/负数，全部安全
    expect(timeAgo(1730000000), isNotEmpty);
    expect(timeAgo(0), isNotEmpty); // 走日期分支
    expect(timeAgo(-1), isNotEmpty);
    expect(timeAgo(DateTime.now().millisecondsSinceEpoch ~/ 1000), '刚刚');
    // countText 边界
    expect(countText(0), '0');
    expect(countText(12345), '1.2w');
  });
}
