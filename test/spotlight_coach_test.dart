import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:community_app/design/components.dart';
import 'package:community_app/design/spotlight_coach.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('聚光灯引导三步切换并跳过', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final k1 = GlobalKey();
    final k2 = GlobalKey();
    final k3 = GlobalKey();
    var done = false;

    await tester.pumpWidget(
      MaterialApp(
        theme: buildImmersiveTheme(),
        home: Scaffold(
          body: Stack(
            children: [
              Container(color: const Color(AppColors.bg)),
              Positioned(
                left: 16,
                top: 610,
                width: 220,
                height: 44,
                child: Container(key: k1, color: const Color(AppColors.card)),
              ),
              Positioned(
                left: 260,
                top: 720,
                width: 44,
                height: 44,
                child: Container(key: k2, color: const Color(AppColors.card)),
              ),
              Positioned(
                left: 320,
                top: 720,
                width: 44,
                height: 44,
                child: Container(key: k3, color: const Color(AppColors.card)),
              ),
              Positioned.fill(
                child: SpotlightCoach(
                  steps: [
                    SpotlightStep(
                      targetKey: k1,
                      title: '第一步',
                      body: '一句话说明第一步。',
                    ),
                    SpotlightStep(
                      targetKey: k2,
                      title: '第二步',
                      body: '一句话说明第二步。',
                    ),
                    SpotlightStep(
                      targetKey: k3,
                      title: '第三步',
                      body: '一句话说明第三步。',
                    ),
                  ],
                  onDone: () => done = true,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.text('1/3'), findsOneWidget);
    expect(find.text('下一步'), findsOneWidget);

    await tester.tap(find.text('下一步'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450));
    expect(find.text('2/3'), findsOneWidget);
    expect(find.text('第二步'), findsOneWidget);

    await tester.tap(find.text('下一步'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450));
    expect(find.text('3/3'), findsOneWidget);
    expect(find.text('知道了'), findsOneWidget);

    await tester.tap(find.text('知道了'));

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(done, isTrue);
  });

  testWidgets('聚光灯跳过立即结束', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final k = GlobalKey();
    var done = false;

    await tester.pumpWidget(
      MaterialApp(
        theme: buildImmersiveTheme(),
        home: Scaffold(
          body: Stack(
            children: [
              Positioned(
                left: 16,
                top: 600,
                width: 200,
                height: 44,
                child: Container(key: k, color: const Color(AppColors.card)),
              ),
              Positioned.fill(
                child: SpotlightCoach(
                  steps: [
                    SpotlightStep(targetKey: k, title: '唯一一步', body: '说明。'),
                  ],
                  onDone: () => done = true,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    await tester.tap(find.text('跳过'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(done, isTrue);
  });

  testWidgets('聚光灯在父级偏移时仍挖在目标上', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final target = GlobalKey();
    final boundaryKey = GlobalKey();

    await tester.pumpWidget(
      MaterialApp(
        theme: buildImmersiveTheme(),
        home: RepaintBoundary(
          key: boundaryKey,
          child: SizedBox(
            width: 390,
            height: 844,
            child: Padding(
              // 模拟详情页目标的父级偏移：overlay 不在屏幕 (0,0)。
              padding: const EdgeInsets.only(left: 44, top: 36, right: 20),
              child: Stack(
                children: [
                  Container(color: const Color(AppColors.bg)),
                  Positioned(
                    left: 16,
                    top: 600,
                    width: 220,
                    height: 44,
                    child: Container(key: target, color: Colors.red),
                  ),
                  Positioned.fill(
                    child: SpotlightCoach(
                      steps: [
                        SpotlightStep(
                          targetKey: target,
                          title: '偏移一步',
                          body: '洞口必须落在红色目标上。',
                        ),
                      ],
                      onDone: () {},
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    final boundary =
        boundaryKey.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
    late final ui.Image image;
    late final ByteData data;
    await tester.runAsync(() async {
      image = await boundary.toImage();
      data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    });
    addTearDown(image.dispose);

    // 屏幕坐标：padding(44,36) + target(16,600)，取目标左边缘向内 4px。
    final width = image.width;
    final px = 64;
    final py = 658;
    final offset = (py * width + px) * 4;
    final r = data.getUint8(offset);
    final g = data.getUint8(offset + 1);
    final b = data.getUint8(offset + 2);
    expect(r, greaterThan(180), reason: '洞口应露出红色目标，实际 RGB=($r,$g,$b)');
    expect(g, lessThan(140));
    expect(b, lessThan(140));
  });
}
