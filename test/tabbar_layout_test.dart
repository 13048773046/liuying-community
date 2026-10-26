import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:community_app/main.dart';

void main() {
  testWidgets('底部导航栏必须贴底（模拟 iPhone 尺寸）', (tester) async {
    SharedPreferences.setMockInitialValues({});
    // iPhone 13 Pro Max：1170 x 2532 @3x
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const CommunityApp());
    // 等 _Bootstrap 恢复登录态（SharedPreferences 异步）
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (find.text('首页').evaluate().isNotEmpty) break;
    }

    // 找到底部导航的 5 个元素（中间是短视频圆钮，用 Icon 找）
    final homeTab = find.text('首页');
    final mineTab = find.text('我的');
    final shortsBtn = find.byKey(const ValueKey('shortsCenterBtn'));

    expect(homeTab, findsOneWidget);
    expect(mineTab, findsOneWidget);
    expect(shortsBtn, findsOneWidget);

    final homeRect = tester.getRect(homeTab);
    final mineRect = tester.getRect(mineTab);
    final btnRect = tester.getRect(shortsBtn);

    // 逻辑像素尺寸 = 物理 / dpr = 390 x 844
    const screenH = 844.0;
    debugPrint('home y=${homeRect.center.dy} mine y=${mineRect.center.dy} '
        'btn y=${btnRect.center.dy} screenH=$screenH');

    // 导航栏中线应位于屏幕底部区域（> 屏幕高度的 82%）
    expect(homeRect.center.dy, greaterThan(screenH * 0.82),
        reason: '导航栏必须在屏幕底部（home center=${homeRect.center.dy}）');
    expect(mineRect.center.dy, greaterThan(screenH * 0.82));
    expect(btnRect.center.dy, greaterThan(screenH * 0.82));

    // 且不超出屏幕（含底部安全区留白）
    expect(mineRect.bottom, lessThan(screenH));
  });
}
