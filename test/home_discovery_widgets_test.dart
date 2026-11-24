/// 首页混合流的 390 宽布局回归：应用大卡、分类、横向滑轨、竖向清单、话题卡
/// 都必须在真实手机宽度下正常排版，且点击入口可达。
library;

import 'package:community_app/design/components.dart';
import 'package:community_app/models/app_market.dart';
import 'package:community_app/pages/home/home_discovery_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

MarketApp _app(String id, String name, {bool featured = false}) => MarketApp(
  id: id,
  name: name,
  version: '1.2.3',
  category: '工具',
  subCategory: '系统工具',
  description: '把常用的小工具收进一个干净、离线优先的清单，打开就能用。',
  downloadCount: 128,
  featured: featured,
  packageType: 'apk',
  platform: 'android',
);

void main() {
  final apps = [
    _app('a', 'K-9 Mail'),
    _app('b', 'Markor 文本编辑器'),
    _app('c', 'Aegis 身份验证器'),
    _app('d', 'NewPipe', featured: true),
  ];

  Future<void> pumpAtPhone(
    WidgetTester tester,
    Widget child, {
    double width = 390,
  }) async {
    tester.view.physicalSize = Size(width * 3, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildImmersiveTheme(),
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: child,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('390 宽精选应用大卡不溢出', (tester) async {
    await pumpAtPhone(
      tester,
      HomeFeaturedAppCard(app: apps.last, screenshotUrl: ''),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('NewPipe'), findsOneWidget);
    expect(find.text('查看'), findsOneWidget);
  });

  testWidgets('390 宽分类与横向/竖向应用模块不溢出', (tester) async {
    final categories = [
      const AppCategory(id: 'all', name: '工具'),
      const AppCategory(id: 'eff', name: '效率'),
      const AppCategory(id: 'soc', name: '社交'),
    ];
    await pumpAtPhone(
      tester,
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HomeCategoryChips(
            categories: categories,
            selectedId: '',
            onSelected: (_) {},
          ),
          const SizedBox(height: 12),
          HomeAppsRail(apps: apps, onOpen: (_) {}, onSeeAll: () {}),
          const SizedBox(height: 13),
          HomeAppListCard(apps: apps, onOpen: (_) {}, onSeeAll: () {}),
        ],
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('全部 4 款'), findsNWidgets(2));
  });

  testWidgets('320 宽小屏精选卡与竖向清单不溢出', (tester) async {
    await pumpAtPhone(
      tester,
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HomeFeaturedAppCard(app: apps.last, screenshotUrl: ''),
          const SizedBox(height: 13),
          HomeAppListCard(apps: apps, onOpen: (_) {}, onSeeAll: () {}),
        ],
      ),
      width: 320,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('分类 chip 点击回传真实分类 id', (tester) async {
    var picked = '';
    final categories = [
      const AppCategory(id: 'all', name: '全部'),
      const AppCategory(id: 'tools', name: '工具'),
      const AppCategory(id: 'eff', name: '效率'),
    ];
    await pumpAtPhone(
      tester,
      HomeCategoryChips(
        categories: categories,
        selectedId: '',
        onSelected: (id) => picked = id,
      ),
    );
    await tester.tap(find.text('工具'));
    expect(picked, 'tools');
  });

  testWidgets('390 宽话题横滑卡不溢出', (tester) async {
    var opened = '';
    await pumpAtPhone(
      tester,
      HomeTopicRail(
        topics: const [
          HomeTopic(name: '生活分享', count: 3),
          HomeTopic(name: '周末市集', count: 3),
          HomeTopic(name: '苏州秋天', count: 2),
        ],
        onOpen: (t) => opened = t.name,
      ),
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('# 周末市集'));
    expect(opened, '周末市集');
  });
}
