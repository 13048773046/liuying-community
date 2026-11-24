import 'dart:ui' show Size;

import 'package:community_app/main.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('首次启动展示引导，跳过后写入已读标记', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const CommunityApp(showWelcome: true));
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('跳过'), findsOneWidget);
    expect(find.text('左右滑动，翻一页'), findsOneWidget);

    await tester.tap(find.text('跳过'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 420));

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('welcome_v1_seen'), isTrue);
  });
}
