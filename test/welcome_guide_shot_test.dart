// 首次欢迎引导：三页滑动、胶囊指示器、末页按钮的 390 视觉验收。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:community_app/design/components.dart';
import 'package:community_app/pages/onboarding/welcome_guide_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final cjk = FontLoader('NotoSansSC')
      ..addFont(rootBundle.load('assets/fonts/NotoSansSC-Regular.otf'));
    await cjk.load();
    final icons = FontLoader('MaterialIcons');
    final iconBytes = await File(
      '/home/user/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    ).readAsBytes();
    icons.addFont(Future.value(ByteData.view(iconBytes.buffer)));
    await icons.load();
  });

  testWidgets('欢迎引导三页与开始按钮', (tester) async {
    tester.view.physicalSize = const Size(390 * 2, 844 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    var done = false;
    final base = buildImmersiveTheme();
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: base.copyWith(
          textTheme: base.textTheme.apply(fontFamily: 'NotoSansSC'),
        ),
        builder: (context, child) => DefaultTextStyle(
          style: const TextStyle(fontFamily: 'NotoSansSC', color: Colors.white),
          child: child!,
        ),
        home: WelcomeGuidePage(onDone: () => done = true),
      ),
    );
    await tester.pump(const Duration(milliseconds: 120));
    // 图片解码是真实异步；测试里先预热，避免黄金图截在还没画出来的那一帧。
    await tester.runAsync(() async {
      final ctx = tester.element(find.byType(WelcomeGuidePage));
      for (final asset in [
        'assets/characters_v2/c01_mint.png',
        'assets/ai/xiaoying.png',
        'assets/deco/sakura.png',
        'assets/deco/stars.png',
        'assets/deco/notes.png',
        'assets/deco/moon.png',
      ]) {
        await precacheImage(AssetImage(asset), ctx);
      }
    });
    await tester.pump(const Duration(milliseconds: 800));

    expect(find.text('跳过'), findsOneWidget);
    expect(find.text('把喜欢的事\n留在流萤'), findsOneWidget);
    await expectLater(
      find.byType(WelcomeGuidePage),
      matchesGoldenFile('goldens/welcome_guide_01_390.png'),
    );

    await tester.fling(find.byType(PageView), const Offset(-330, 0), 1200);
    await tester.pumpAndSettle();
    expect(find.text('在同一条时间线\n遇见同频的人'), findsOneWidget);
    await expectLater(
      find.byType(WelcomeGuidePage),
      matchesGoldenFile('goldens/welcome_guide_02_390.png'),
    );

    await tester.fling(find.byType(PageView), const Offset(-330, 0), 1200);
    await tester.pumpAndSettle();
    expect(find.text('开始使用'), findsOneWidget);
    expect(find.text('开始使用'), findsOneWidget);
    await expectLater(
      find.byType(WelcomeGuidePage),
      matchesGoldenFile('goldens/welcome_guide_03_390.png'),
    );

    await tester.tap(find.text('开始使用'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(done, isTrue);
  });
}
