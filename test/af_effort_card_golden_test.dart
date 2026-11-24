import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:community_app/pages/home/af_effort_card.dart';

Future<void> _loadFont(String name, String path) async {
  final f = File(path);
  if (!f.existsSync()) return;
  final bytes = await f.readAsBytes();
  final loader = FontLoader(name)
    ..addFont(Future.value(ByteData.view(bytes.buffer)));
  await loader.load();
}

Future<void> _loadCjk() async {
  await _loadFont('LAT', '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf');
  await _loadFont('CJK', '/usr/share/fonts/truetype/droid/DroidSansFallbackFull.ttf');
}

void main() {
  setUpAll(() async {
    await _loadCjk();
  });

  testWidgets('推理档位卡片渲染', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          scaffoldBackgroundColor: Colors.black,
          fontFamily: 'LAT',
          fontFamilyFallback: const ['CJK'],
          splashFactory: NoSplash.splashFactory,
          highlightColor: Colors.transparent,
        ),
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Builder(
            builder: (ctx) => Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 40),
                child: Material(
                  color: Colors.transparent,
                  child: AfEffortSheet(
                    mode: 'chat',
                    model: 'deepseek-flash',
                    effort: 'high',
                    onMode: (_) {},
                    onModel: (_) {},
                    onEffort: (_) {},
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.pump(const Duration(milliseconds: 420));

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('golden/af_effort_card.png'),
    );

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('推理档位卡片 - ULTRA + 模型二级浮层', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          scaffoldBackgroundColor: Colors.black,
          fontFamily: 'LAT',
          fontFamilyFallback: const ['CJK'],
          splashFactory: NoSplash.splashFactory,
          highlightColor: Colors.transparent,
        ),
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Builder(
            builder: (ctx) => Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 40),
                child: Material(
                  color: Colors.transparent,
                  child: AfEffortSheet(
                    mode: 'work',
                    model: 'deepseek-v4-pro',
                    effort: 'ultra',
                    onMode: (_) {},
                    onModel: (_) {},
                    onEffort: (_) {},
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.pump(const Duration(milliseconds: 420));

    // 点「模型」行，展开二级小浮层
    expect(find.text('模型'), findsOneWidget);
    expect(find.byType(InkWell), findsNWidgets(3));
    await tester.tap(find.text('模型'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 240));
    expect(find.text('强力'), findsNWidgets(3));
    expect(find.text('响应快，适合日常'), findsOneWidget);

    // 点空白处收起浮层（H5 同款：点浮层外任意空白关闭）
    final coefRect = tester.getRect(find.text('×2.0'));
    await tester.tapAt(Offset(coefRect.left - 40, coefRect.center.dy));
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.text('响应快，适合日常'), findsNothing);

    // 再点开浮层，用系统返回键先收起浮层（卡片不关）
    await tester.tap(find.text('模型'));
    await tester.pump(const Duration(milliseconds: 220));
    expect(find.text('响应快，适合日常'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 220));
    expect(find.text('响应快，适合日常'), findsNothing);
    expect(find.text('推理等级'), findsOneWidget);

    // 重新打开浮层用于留档截图
    await tester.tap(find.text('模型'));
    await tester.pump(const Duration(milliseconds: 220));

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('golden/af_effort_card_pop.png'),
    );

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 500));
  });
}
