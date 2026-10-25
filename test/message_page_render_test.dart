/// 消息页渲染回归：任何状态（加载/未登录 401/空数据/加载失败）都必须渲染出
/// 可见内容，不允许白屏或渲染异常。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:community_app/pages/message/message_page.dart';

void main() {
  testWidgets('消息页任意终态都必须渲染出可见内容（绝不白屏）', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: MessagePage()));
    // 初始加载态：标题 + Tab 必须可见
    expect(find.text('消息'), findsOneWidget);
    expect(find.text('互动通知'), findsOneWidget);
    expect(find.text('社区官方'), findsOneWidget);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    // 无渲染异常
    expect(tester.takeException(), isNull);
    // 最终必须出现可读内容之一：登录引导 / 空态 / 加载失败重试
    final visibleTexts = <String>[];
    for (final t in [
      '登录后查看消息',
      '暂无互动通知',
      '暂无社区官方通知',
      '加载失败',
    ]) {
      if (find.text(t).evaluate().isNotEmpty) visibleTexts.add(t);
    }
    expect(visibleTexts, isNotEmpty, reason: '消息页不能白屏：必须渲染任一可读状态');
  });

  testWidgets('消息页切到官方通知 tab 仍有内容', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: MessagePage()));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    await tester.tap(find.text('社区官方'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
    final visible = <String>[];
    for (final t in [
      '暂无社区官方通知',
      '登录后查看消息',
      '加载失败',
    ]) {
      if (find.text(t).evaluate().isNotEmpty) visible.add(t);
    }
    expect(visible, isNotEmpty, reason: '官方通知 tab 也不能白屏');
  });
}
