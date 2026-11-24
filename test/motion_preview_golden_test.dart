// 四条动效提示词的 390×844 视觉验收稿。
// 生成：flutter test --no-pub test/motion_preview_golden_test.dart --update-goldens
library;

import 'package:flutter/material.dart';

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:community_app/design/components.dart';
import 'package:community_app/models/app_market.dart';
import 'package:community_app/pages/home/af_palette.dart';
import 'package:community_app/pages/apps/app_widgets.dart';
import 'package:community_app/widgets/image_box.dart';

const _apps = [
  MarketApp(
    id: 'a1',
    name: '萤火音乐',
    category: '影音',
    description: '把喜欢的歌放进夜里，社区音乐播放器',
    version: '1.2.0',
    downloadCount: 12800,
    rating: 4.8,
    ratingCount: 126,
  ),
  MarketApp(
    id: 'a2',
    name: '花甸天气',
    category: '工具',
    description: '看云、看风，也看今天适合出门吗',
    version: '2.0.1',
    downloadCount: 8600,
    rating: 4.6,
    ratingCount: 88,
  ),
  MarketApp(
    id: 'a3',
    name: '夜航日志',
    category: '效率',
    description: '记录每一个不想睡去的夜晚',
    version: '0.9.0',
    downloadCount: 4300,
    rating: 4.4,
    ratingCount: 36,
  ),
];

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

  Future<void> pumpFrame(
    WidgetTester tester,
    Widget child, {
    Size size = const Size(390, 844),
  }) async {
    tester.view.physicalSize = Size(size.width * 2, size.height * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final base = buildImmersiveTheme();
    final theme = base.copyWith(
      textTheme: base.textTheme.apply(fontFamily: 'NotoSansSC'),
      primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'NotoSansSC'),
    );
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme,
        home: Scaffold(backgroundColor: const Color(AppColors.bg), body: child),
      ),
    );
  }

  testWidgets('信息流骨架：同形 + 共享斜向扫光', (tester) async {
    await pumpFrame(
      tester,
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 32, 16, 0),
        child: ShimmerScope(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  SkeletonBox(width: 40, height: 40, radius: 20),
                  SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SkeletonBox(width: 110, height: 12),
                        SizedBox(height: 8),
                        SkeletonBox(width: 64, height: 10),
                      ],
                    ),
                  ),
                  SkeletonBox(width: 54, height: 28, radius: 14),
                ],
              ),
              SizedBox(height: 14),
              SkeletonBox(height: 12),
              SizedBox(height: 9),
              SkeletonBox(width: 220, height: 12),
              SizedBox(height: 14),
              SkeletonBox(height: 180, radius: AppRadius.md),
            ],
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 760));
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/motion_feed_skeleton_390.png'),
    );
  });

  testWidgets('照片墙：模糊占位 → 清晰 + 1.04→1.0', (tester) async {
    final bytes = (await rootBundle.load('assets/ai/xiaoying.png')).buffer
        .asUint8List();
    final provider = MemoryImage(bytes);
    await pumpFrame(
      tester,
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 32, 16, 0),
        child: GridView.count(
          crossAxisCount: 3,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          childAspectRatio: 0.78,
          physics: const NeverScrollableScrollPhysics(),
          children: List.generate(
            6,
            (_) => BlurUpImage(
              url: '',
              imageProvider: provider,
              fit: BoxFit.cover,
              borderRadius: 12,
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 80));

    // 让 PNG 解码完成；真实网络图片走 IO，不需要在测试里手动等。
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
    // 刚解码完、清晰图透明度还是 0：此时应看到同色调的模糊小图。
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/motion_photo_wall_blur_390.png'),
    );

    await tester.pump(const Duration(milliseconds: 620));
    await tester.pump(const Duration(milliseconds: 120));
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/motion_photo_wall_clear_390.png'),
    );
  });

  testWidgets('商品列表：错峰滑入 + 三点加载 + 没有更多了', (tester) async {
    await pumpFrame(
      tester,
      ListView(
        padding: const EdgeInsets.fromLTRB(16, 28, 16, 24),
        children: [
          const Text(
            '全部应用',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: Color(AppColors.textPrimary),
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            '共 3 款 · 每一款都由社区人工审核',
            style: TextStyle(
              fontSize: 11,
              color: Color(AppColors.textTertiary),
            ),
          ),
          const SizedBox(height: 16),
          for (var i = 0; i < _apps.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: StaggerReveal(
                index: i,
                delay: const Duration(milliseconds: 50),
                duration: const Duration(milliseconds: 450),
                offsetY: 24,
                child: AppListTile(
                  app: _apps[i],
                  trailing: const Icon(
                    Icons.chevron_right_rounded,
                    size: 20,
                    color: Color(AppColors.textTertiary),
                  ),
                ),
              ),
            ),
          const SizedBox(height: 6),
          const Center(child: LoadMoreDots()),
          const SizedBox(height: 15),
          const Center(
            child: Text(
              '— 没有更多了 —',
              style: TextStyle(
                fontSize: 11,
                color: Color(AppColors.textTertiary),
              ),
            ),
          ),
        ],
      ),
    );
    await tester.pump(const Duration(milliseconds: 1100));
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/motion_product_list_390.png'),
    );
  });

  testWidgets('AI 回复：思考三点 → 逐段显现 + 光标', (tester) async {
    await pumpFrame(
      tester,
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 28, 16, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'AI 工坊',
              style: TextStyle(
                fontSize: 10,
                letterSpacing: .7,
                color: Color(AfPalette.text3),
              ),
            ),
            const SizedBox(height: 8),
            _bubble(
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 4),
                child: ThinkingDots(),
              ),
            ),
            const SizedBox(height: 14),
            _bubble(
              const PhraseRevealText(
                text: '夜航的风从窗边经过，我把今天的声音都收进了这条回复里。',
                animate: true,
                tick: Duration(milliseconds: 60),
                style: TextStyle(
                  fontSize: 13.5,
                  height: 1.75,
                  color: Color(AfPalette.text),
                ),
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              '气泡高度随文字增长，页面在底部平滑跟随',
              style: TextStyle(fontSize: 10, color: Color(AfPalette.text3)),
            ),
          ],
        ),
      ),
    );
    // 以真实帧节奏推进，让逐段显现的 timer 和每段 240ms 入场都动起来。
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/motion_ai_stream_390.png'),
    );
  });
}

Widget _bubble(Widget child) {
  return Container(
    padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
    decoration: BoxDecoration(
      color: const Color(AfPalette.card),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: const Color(AfPalette.line)),
    ),
    child: child,
  );
}
