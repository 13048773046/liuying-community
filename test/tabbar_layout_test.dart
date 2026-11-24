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
    // 首帧即 RootPage；固定循环 pump 等待布局就绪
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (find.text('首页').evaluate().isNotEmpty) break;
    }

    // 当前底栏为 4 项（首页/版块/消息/我的），发布入口改成了浮动菜单
    final homeTab = find.text('首页');
    final mineTab = find.text('我的');

    expect(homeTab, findsOneWidget);
    expect(mineTab, findsOneWidget);

    final homeRect = tester.getRect(homeTab);
    final mineRect = tester.getRect(mineTab);

    // 逻辑像素尺寸 = 物理 / dpr = 390 x 844
    const screenH = 844.0;
    debugPrint('home y=${homeRect.center.dy} mine y=${mineRect.center.dy} '
        'screenH=$screenH');

    // 导航栏中线应位于屏幕底部区域（> 屏幕高度的 82%）
    expect(homeRect.center.dy, greaterThan(screenH * 0.82),
        reason: '导航栏必须在屏幕底部（home center=${homeRect.center.dy}）');
    expect(mineRect.center.dy, greaterThan(screenH * 0.82));

    // 且不超出屏幕（含底部安全区留白）
    expect(mineRect.bottom, lessThan(screenH));
  });
}
