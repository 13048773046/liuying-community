// 下载列表页视觉验收：渲染空态与三条本地记录。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:community_app/design/tokens.dart';
import 'package:community_app/pages/apps/app_downloads_page.dart';

Future<void> _loadFont() async {
  final ico = File(
    '/home/user/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  );
  if (ico.existsSync()) {
    try {
      final l = FontLoader('MaterialIcons')
        ..addFont(Future.value(ByteData.sublistView(ico.readAsBytesSync())));
      await l.load();
    } catch (_) {}
  }
  for (final path in [
    '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
    '/usr/share/fonts/truetype/droid/DroidSansFallbackFull.ttf',
  ]) {
    final f = File(path);
    if (!f.existsSync()) continue;
    try {
      final loader = FontLoader('NotoSansCJK')
        ..addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
      await loader.load();
      return;
    } catch (_) {}
  }
}

Future<void> _shot(WidgetTester tester, String name) async {
  tester.view.physicalSize = const Size(390 * 2, 844 * 2);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  final theme = buildImmersiveTheme();
  await tester.pumpWidget(
    MaterialApp(
      theme: theme.copyWith(
        textTheme: theme.textTheme.apply(fontFamily: 'NotoSansCJK'),
      ),
      home: const AppDownloadsPage(),
    ),
  );
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 300));
  // 页面读取的是真实文件系统；让真实事件循环跑完再截图。
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
  });
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 700));
  await expectLater(
    find.byType(AppDownloadsPage),
    matchesGoldenFile('goldens/app_downloads_$name.png'),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  setUpAll(() async {
    await _loadFont();
    temp = await Directory.systemTemp.createTemp('liuying_downloads_shot_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => temp.path,
        );
  });

  tearDownAll(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  testWidgets('空态', (tester) async => _shot(tester, 'empty'));

  testWidgets('本地记录', (tester) async {
    await tester.runAsync(() async {
      final root = Directory('${temp.path}/app_market');
      const specs = [
        ('app_one', '流萤音乐', '1.4.2', 3 * 1024 * 1024, true),
        ('app_two', '夜航工具箱', '0.9.0', 2 * 1024 * 1024, false),
        ('app_three', '萤火笔记', '2.1', 512 * 1024, true),
      ];
      for (var i = 0; i < specs.length; i++) {
        final spec = specs[i];
        final dir = Directory('${root.path}/${spec.$1}');
        await dir.create(recursive: true);
        final file = File('${dir.path}/package.apk');
        await file.writeAsBytes(List<int>.generate(64, (i) => i));
        await File('${dir.path}/download.meta.json').writeAsString(
          jsonEncode({
            'versionId': 'ver_${spec.$1}',
            'appName': spec.$2,
            'appVersion': spec.$3,
            'platform': 'android',
            'packageType': 'apk',
            'fileName': 'package.apk',
            'totalBytes': spec.$4,
            'finalPath': spec.$5 ? file.path : null,
            // 固定递增时间戳：列表应按更新时间倒序，不能依赖测试执行时刻。
            'updatedAt': 1700000000000 + i * 1000,
          }),
        );
      }
    });
    await _shot(tester, 'records');
  });
}
