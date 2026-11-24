/// 应用市场客户端组件测试。
///
/// 使用本地假服务验证「首页入口 → 市场列表 → 应用详情 → 评论/下载面板」的
/// 真实组件链路，不依赖线上数据。运行：
/// `flutter test --dart-define=API_BASE=http://127.0.0.1:8799/community/api test/app_market_widget_test.dart`
library;

import 'dart:convert';
import 'dart:io';

import 'package:community_app/api/client.dart';
import 'package:community_app/design/components.dart';
import 'package:community_app/pages/apps/app_detail_page.dart';
import 'package:community_app/pages/apps/app_ios_install_sheet.dart';
import 'package:community_app/pages/apps/app_market_home_entry.dart';
import 'package:community_app/pages/apps/app_market_page.dart';
import 'package:community_app/pages/apps/app_share_sheet.dart';
import 'package:community_app/pages/apps/app_submit_page.dart';
import 'package:community_app/pages/apps/app_widgets.dart';
import 'package:community_app/utils/cover_palette.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import 'visual_shot_data.dart';

const _pngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';

class _RecordingLauncher extends UrlLauncherPlatform {
  final List<String> launched = [];

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launched.add(url);
    return true;
  }
}

Map<String, dynamic> _appJson({bool detail = false}) => {
  'id': 'app_test',
  'name': '测试应用甲',
  'icon': '/community/api/media/icon.png',
  'platform': 'android',
  'packageType': 'apk',
  'packageName': 'com.liuying.test',
  'version': '1.0.0',
  'osVersion': 'Android 10+',
  'categoryId': 'appcat_tools',
  'subCategoryId': 'appcat_tools_system',
  'category': '工具',
  'subCategory': '系统工具',
  'description': '这是一个用于验证应用市场详情页的测试应用，包含完整的下载与评论链路。',
  'shareReason': '它真的很轻，日常整理文件特别顺手，所以推荐给社区。',
  'reason': '因为你常逛「工具」分类',
  'downloadCount': 128,
  'rating': 4.5,
  'ratingCount': 2,
  'favoriteCount': 3,
  'commentCount': 2,
  'featured': true,
  'publishedAt': 1763380000,
  'downloadUrl': 'https://example.com/download/test.apk',
  'author': {'id': '', 'name': '测试投稿者', 'avatar': '', 'level': 3},
  'screenshots': [
    '/community/api/media/shot1.png',
    '/community/api/media/shot2.png',
    '/community/api/media/shot3.png',
  ],
  'versionId': 'ver_test',
  'myRating': 0,
  'favorited': false,
  if (detail) 'status': 2,
};

Map<String, dynamic> _visualAppJson() => {
  ..._appJson(detail: true),
  'id': 'app_visual',
  'name': 'K-9 Mail',
  'icon': '/community/api/media/k9icon.png',
  'packageName': 'com.fsck.k9',
  'version': '25.0',
  'osVersion': 'Android 6.0+',
  'categoryId': 'appcat_social',
  'subCategoryId': 'appcat_social_mail',
  'category': '社交',
  'subCategory': '邮箱',
  'description':
      'K-9 Mail 是一款开源邮件客户端，支持多个邮箱账号、IMAP/POP3、邮件搜索、'
      '统一收件箱和 OpenPGP 加密。界面简洁，通知与文件夹管理完整，'
      '适合需要同时处理工作和个人邮箱的用户。',
  'shareReason': '多账号收信很稳，支持 PGP，开源也比较放心，日常处理邮件够用了。',
  'author': {'id': '', 'name': '夏梓璇', 'avatar': '', 'level': 1},
  'screenshots': [
    '/community/api/media/visual1.png',
    '/community/api/media/visual2.png',
    '/community/api/media/visual3.png',
  ],
};

List<Map<String, dynamic>> _extraComments = [];

Map<String, dynamic> _iosVisualAppJson() => {
  ..._visualAppJson(),
  'id': 'app_ios_visual',
  'name': '流萤社区',
  'icon': '/community/api/media/k9icon.png',
  'platform': 'ios',
  'packageType': 'ipa',
  'packageName': 'com.liuying.community',
  'version': '0.9.28',
  'osVersion': 'iOS 15.0+',
  'category': '社交',
  'subCategory': '社区',
  'description': '流萤社区 iOS 客户端，支持动态、私信、应用市场与系统级应用安装。',
  'shareReason': '把社区装进口袋，随时看看朋友们在做什么。',
};

Map<String, dynamic> _storeVisualAppJson() => {
  ..._visualAppJson(),
  'id': 'app_store_visual',
  'name': 'Chatbox AI',
  'platform': 'ios',
  'packageType': 'store',
  'packageName': 'xyz.chatboxapp.chatbox',
  'version': '1.24.4',
  'osVersion': 'iOS 16.0+',
  'category': '工具',
  'subCategory': '效率',
  'description': '支持多家模型和本地数据的 AI 客户端，聊天、写作和代码辅助都在一个界面里完成。',
  'shareReason': '一直用它整理资料和写代码片段，界面干净，多模型切换也顺手。',
  'storeUrl': 'https://apps.apple.com/cn/app/chatbox-ai-%E5%BC%BA%E5%A4%A7%E7%9A%84-ai-llm-%E5%AE%A2%E6%88%B7%E7%AB%AF/id6471368056',
  'downloadUrl': '/community/api/apps/app_store_visual/download',
};

Future<void> _handle(HttpRequest req) async {
  final path = req.uri.path;
  final res = req.response;
  res.persistentConnection = false;
  res.headers.contentType = ContentType.json;
  if (path == '/community/api/apps/app_test/favorite') {
    res.write(
      jsonEncode({
        'ok': true,
        'favorited': req.method == 'POST',
        'favoriteCount': req.method == 'POST' ? 4 : 2,
      }),
    );
  } else if (path == '/community/api/apps/app_test/rating') {
    res.write(jsonEncode({'ok': true, 'rating': 4.5, 'ratingCount': 3}));
  } else if (path == '/community/api/apps/app_test/report') {
    res.write(jsonEncode({'ok': true}));
  } else if (path == '/community/api/apps/categories') {
    res.write(
      jsonEncode({
        'ok': true,
        'list': [
          {
            'id': 'appcat_tools',
            'name': '工具',
            'slug': 'tools',
            'parentId': '',
            'sort': 0,
            'children': [
              {
                'id': 'appcat_tools_system',
                'name': '系统工具',
                'slug': 'tools-system',
                'parentId': 'appcat_tools',
                'sort': 1,
                'children': [],
              },
              {
                'id': 'appcat_tools_file',
                'name': '文件管理',
                'slug': 'tools-file',
                'parentId': 'appcat_tools',
                'sort': 2,
                'children': [],
              },
            ],
          },
          {
            'id': 'appcat_media',
            'name': '影音',
            'slug': 'media',
            'parentId': '',
            'sort': 20,
            'children': [
              {
                'id': 'appcat_media_music',
                'name': '音乐',
                'slug': 'media-music',
                'parentId': 'appcat_media',
                'sort': 1,
                'children': [],
              },
            ],
          },
        ],
      }),
    );
  } else if (path == '/community/api/apps') {
    res.write(
      jsonEncode({
        'ok': true,
        'list': [_appJson()],
        'page': 1,
        'pageSize': 20,
        'total': 1,
        'personalized': true,
      }),
    );
  } else if (path == '/community/api/apps/app_visual') {
    res.write(jsonEncode({'ok': true, 'app': _visualAppJson()}));
  } else if (path == '/community/api/apps/app_visual/comments') {
    res.write(
      jsonEncode({
        'ok': true,
        'list': [],
        'total': 0,
        'page': 1,
        'pageSize': 20,
      }),
    );
  } else if (path == '/community/api/apps/app_store_visual') {
    res.write(jsonEncode({'ok': true, 'app': _storeVisualAppJson()}));
  } else if (path == '/community/api/apps/app_store_visual/comments') {
    res.write(
      jsonEncode({
        'ok': true,
        'list': [],
        'total': 0,
        'page': 1,
        'pageSize': 20,
      }),
    );
  } else if (path == '/community/api/apps/app_ios_visual') {
    res.write(jsonEncode({'ok': true, 'app': _iosVisualAppJson()}));
  } else if (path == '/community/api/apps/app_ios_visual/comments') {
    res.write(
      jsonEncode({
        'ok': true,
        'list': [],
        'total': 0,
        'page': 1,
        'pageSize': 20,
      }),
    );
  } else if (path == '/community/api/apps/app_test') {
    res.write(jsonEncode({'ok': true, 'app': _appJson(detail: true)}));
  } else if (path == '/community/api/apps/app_test/comments') {
    if (req.method == 'POST') {
      final body = jsonDecode(await utf8.decoder.bind(req).join());
      final content = (body is Map ? body['content'] : '')?.toString() ?? '';
      _extraComments.add({
        'id': 'c_new_${_extraComments.length}',
        'content': content,
        'parentId': '',
        'created': 1763380300,
        'status': 1,
        'author': {'id': 'me', 'name': '我', 'avatar': '', 'level': 1},
      });
      res.write(jsonEncode({'ok': true}));
    } else {
      res.write(
        jsonEncode({
          'ok': true,
          'list': [
            {
              'id': 'c1',
              'content': '下载很顺，界面也干净。',
              'parentId': '',
              'created': 1763380100,
              'status': 1,
              'author': {'id': '', 'name': '路人甲', 'avatar': '', 'level': 1},
            },
            {
              'id': 'c2',
              'content': '希望后续版本能加上深色模式。',
              'parentId': '',
              'created': 1763380200,
              'status': 1,
              'author': {'id': '', 'name': '路人乙', 'avatar': '', 'level': 2},
            },
            ..._extraComments,
          ],
          'total': 2 + _extraComments.length,
          'page': 1,
          'pageSize': 20,
        }),
      );
    }
  } else if (path.startsWith('/community/api/media/')) {
    final name = path.split('/').last;
    if (name == 'k9icon.png') {
      res.headers.contentType = ContentType('image', 'png');
      res.add(base64Decode(kVisualIconBase64));
    } else {
      final shot = kVisualShotBase64[name];
      res.headers.contentType = ContentType(
        'image',
        shot == null ? 'png' : 'jpeg',
      );
      res.add(base64Decode(shot ?? _pngBase64));
    }
  } else {
    res.statusCode = 404;
    res.write(jsonEncode({'ok': false, 'error': 'not found: $path'}));
  }
  await res.close();
}

Future<void> _settle(WidgetTester tester, {int rounds = 12}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 60)),
    );
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Finder _verticalList() => find.byWidgetPredicate(
  (w) =>
      (w is ListView && w.scrollDirection == Axis.vertical) ||
      w is CustomScrollView,
);

Future<void> _reveal(WidgetTester tester, Finder target) async {
  for (var i = 0; i < 8; i++) {
    if (target.evaluate().isNotEmpty) {
      await tester.ensureVisible(target.first);
      await tester.pump(const Duration(milliseconds: 120));
      return;
    }
    final list = _verticalList();
    if (list.evaluate().isEmpty) break;
    await tester.drag(list.first, const Offset(0, -260));
    await tester.pump(const Duration(milliseconds: 150));
  }
  if (target.evaluate().isEmpty) {
    fail('滚动后仍未找到目标：$target');
  }
  await tester.ensureVisible(target.first);
  await tester.pump(const Duration(milliseconds: 120));
}

void _checkNoOverflow(WidgetTester tester, String stage) {
  final err = tester.takeException();
  if (err != null) {
    expect(err, isNull, reason: 'stage=$stage');
  }
}

void main() {
  late HttpServer server;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final cjk = FontLoader('NotoSansSC')
      ..addFont(rootBundle.load('assets/fonts/NotoSansSC-Regular.otf'));
    await cjk.load();
    final icons = FontLoader('MaterialIcons');
    final iconBytes = await File(
      '/home/user/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    ).readAsBytes();
    icons.addFont(Future.value(ByteData.view(iconBytes.buffer)));
    await icons.load();
    HttpOverrides.global = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => Directory.systemTemp.path,
        );
    ApiClient.baseOverride = 'http://127.0.0.1:8799/community/api';
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 8799);
    server.listen(_handle);
  });

  tearDownAll(() async {
    ApiClient.baseOverride = null;
    await server.close(force: true);
  });

  test('应用图标取色：K-9 输出酒红主色而非平台绿', () async {
    final color = await CoverPalette.colorFor(
      'palette_test',
      'http://127.0.0.1:8799/community/api/media/k9icon.png',
    );
    expect(color, isNotNull);
    final c = color!;
    expect(c.r, greaterThan(c.g));
    expect(c.r, greaterThan(c.b));
    final shades = CoverPalette.gradientShades(c);
    expect(shades.top, isNot(equals(c)));
    expect(shades.bottom, isNot(equals(c)));
  });

  testWidgets('首页应用入口可点击', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var tapped = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildImmersiveTheme(),
        home: Scaffold(
          backgroundColor: const Color(AppColors.bg),
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: AppMarketHomeEntry(onTap: () => tapped = true),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('社区应用市场'), findsOneWidget);
    expect(find.text('把真正好用的应用，带进社区'), findsOneWidget);
    await tester.tap(find.byType(AppMarketHomeEntry));
    expect(tapped, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('应用市场列表可以打开详情并看到下载与评论', (tester) async {
    await tester.pumpWidget(
      MaterialApp(theme: buildImmersiveTheme(), home: const AppMarketPage()),
    );
    await tester.pump();
    await _settle(tester);
    expect(find.text('应用市场'), findsWidgets);
    expect(find.text('为你推荐'), findsOneWidget);
    expect(find.byType(AppListTile), findsOneWidget);

    await tester.tap(find.byType(AppListTile).first);
    await tester.pump();
    await _settle(tester, rounds: 30);

    expect(find.text('下载安装包'), findsWidgets);
    expect(find.text('预览'), findsOneWidget);

    await _reveal(tester, find.text('关于这款应用'));
    expect(find.text('关于这款应用'), findsOneWidget);

    await _reveal(tester, find.text('为什么推荐它'));
    expect(find.text('为什么推荐它'), findsOneWidget);

    await _reveal(tester, find.text('应用信息'));
    expect(find.text('应用信息'), findsOneWidget);

    await _reveal(tester, find.text('评分'));
    expect(find.text('评分'), findsWidgets);

    await _reveal(tester, find.text('下载很顺，界面也干净。'));
    expect(find.text('评论'), findsWidgets);
    expect(find.text('下载很顺，界面也干净。'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 20));
  });

  testWidgets('390 宽手机尺寸下市场与详情无布局溢出', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(theme: buildImmersiveTheme(), home: const AppMarketPage()),
    );
    await tester.pump();
    await _settle(tester);
    expect(find.byType(AppListTile), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byType(AppListTile).first);
    await tester.pump();
    await _settle(tester, rounds: 30);
    expect(find.text('下载安装包'), findsWidgets);
    _checkNoOverflow(tester, 'detail-top');
    await _reveal(tester, find.text('关于这款应用'));
    _checkNoOverflow(tester, 'detail-about');
    await _reveal(tester, find.text('为什么推荐它'));
    _checkNoOverflow(tester, 'detail-share');
    expect(find.text('为什么推荐它'), findsOneWidget);
    await _reveal(tester, find.text('应用信息'));
    _checkNoOverflow(tester, 'detail-info');
    await _reveal(tester, find.text('评分'));
    _checkNoOverflow(tester, 'detail-rating');
    await _reveal(tester, find.text('下载很顺，界面也干净。'));
    _checkNoOverflow(tester, 'detail-comments');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 20));
  });

  testWidgets('详情可以收藏、评分并发表评论', (tester) async {
    ApiClient.token = 'test-token';
    ApiClient.userId = 'me';
    addTearDown(() {
      ApiClient.token = null;
      ApiClient.userId = null;
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: buildImmersiveTheme(),
        home: const AppDetailPage(appId: 'app_test'),
      ),
    );
    await tester.pump();
    await _settle(tester);
    expect(find.text('测试应用甲'), findsWidgets);

    await tester.tap(find.byTooltip('收藏'));
    await _settle(tester);
    expect(find.byTooltip('取消收藏'), findsOneWidget);

    await _reveal(tester, find.text('评分'));
    await tester.tap(find.bySemanticsLabel('评 4 星'));
    await _settle(tester);
    expect(find.text('你已评分 4 星'), findsOneWidget);

    await _reveal(tester, find.text('说说你的使用感受…'));
    await tester.enterText(find.byType(TextField), '这是新的测试评论');
    await tester.tap(find.widgetWithText(PillButton, '发送'));
    await _settle(tester);
    expect(find.text('这是新的测试评论'), findsOneWidget);

    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 20));
  });

  testWidgets('应用详情 390x844 视觉验收', (tester) async {
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildImmersiveTheme().copyWith(
            textTheme: buildImmersiveTheme().textTheme.apply(
              fontFamily: 'NotoSansSC',
            ),
          ),
          home: const AppDetailPage(appId: 'app_visual'),
        ),
      ),
    );
    await tester.pump();
    await _settle(tester, rounds: 30);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byKey(key),
      matchesGoldenFile('goldens/app_detail_390.png'),
    );
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -520));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byKey(key),
      matchesGoldenFile('goldens/app_detail_390_scrolled.png'),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 20));
  });

  testWidgets('应用详情 320x700 视觉验收', (tester) async {
    tester.view.physicalSize = const Size(640, 1400);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildImmersiveTheme().copyWith(
            textTheme: buildImmersiveTheme().textTheme.apply(
              fontFamily: 'NotoSansSC',
            ),
          ),
          home: const AppDetailPage(appId: 'app_visual'),
        ),
      ),
    );
    await tester.pump();
    await _settle(tester, rounds: 30);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byKey(key),
      matchesGoldenFile('goldens/app_detail_320.png'),
    );
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -520));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byKey(key),
      matchesGoldenFile('goldens/app_detail_320_scrolled.png'),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 20));
  });

  testWidgets('投稿支持 App Store 链接类型', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(theme: buildImmersiveTheme(), home: const AppSubmitPage()),
    );
    await tester.pump();
    await _settle(tester);
    await _reveal(tester, find.text('App Store'));
    await tester.tap(find.text('App Store'));
    await tester.pump();
    expect(find.text('App Store 链接'), findsOneWidget);
    await _reveal(tester, find.text('App Store 应用页'));
    expect(find.text('App Store 应用页'), findsOneWidget);
    expect(find.textContaining('只接受 App Store 具体应用页链接'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 20));
  });

  testWidgets('390 宽投稿表单可滚动且无溢出', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(theme: buildImmersiveTheme(), home: const AppSubmitPage()),
    );
    await tester.pump();
    await _settle(tester);
    expect(find.text('投稿应用'), findsOneWidget);
    await _reveal(tester, find.text('分享感言'));
    expect(find.text('分享感言'), findsOneWidget);
    await _reveal(tester, find.text('外部下载地址'));
    expect(find.text('外部下载地址'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 20));
  });

  testWidgets('App Store 应用详情 390x844：只显示前往商店', (tester) async {
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildImmersiveTheme().copyWith(
            textTheme: buildImmersiveTheme().textTheme.apply(
              fontFamily: 'NotoSansSC',
            ),
          ),
          home: const AppDetailPage(appId: 'app_store_visual'),
        ),
      ),
    );
    await tester.pump();
    await _settle(tester, rounds: 40);
    expect(find.text('App Store 应用'), findsOneWidget);
    expect(find.widgetWithText(PillButton, '前往 App Store'), findsOneWidget);
    expect(find.textContaining('由 Apple 提供下载'), findsOneWidget);
    expect(find.text('安装应用'), findsNothing);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byKey(key),
      matchesGoldenFile('goldens/app_store_detail_390.png'),
    );
  });

  testWidgets('App Store 应用详情：点击按钮真实打开商店链接', (tester) async {
    final original = UrlLauncherPlatform.instance;
    final launcher = _RecordingLauncher();
    UrlLauncherPlatform.instance = launcher;
    addTearDown(() => UrlLauncherPlatform.instance = original);

    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildImmersiveTheme().copyWith(
          textTheme: buildImmersiveTheme().textTheme.apply(
            fontFamily: 'NotoSansSC',
          ),
        ),
        home: const AppDetailPage(appId: 'app_store_visual'),
      ),
    );
    await tester.pump();
    await _settle(tester, rounds: 40);
    await tester.tap(find.text('前往 App Store'));
    await tester.pump();

    expect(launcher.launched, hasLength(1));
    expect(
      launcher.launched.single,
      'https://apps.apple.com/cn/app/chatbox-ai-%E5%BC%BA%E5%A4%A7%E7%9A%84-ai-llm-%E5%AE%A2%E6%88%B7%E7%AB%AF/id6471368056',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('iOS 应用详情 390x844：安装入口与安装面板视觉验收', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final key = GlobalKey();

    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildImmersiveTheme().copyWith(
            textTheme: buildImmersiveTheme().textTheme.apply(
              fontFamily: 'NotoSansSC',
            ),
          ),
          home: const AppDetailPage(appId: 'app_ios_visual'),
        ),
      ),
    );
    await tester.pump();
    await _settle(tester, rounds: 40);

    expect(find.text('安装到 iPhone'), findsOneWidget);
    expect(find.text('安装应用'), findsWidgets);
    expect(find.textContaining('iOS · IPA'), findsWidgets);
    _checkNoOverflow(tester, 'ios-dock');

    await tester.tap(find.widgetWithText(PillButton, '安装应用').first);
    await tester.pump();
    await _settle(tester);
    expect(find.byType(AppIosInstallSheet), findsOneWidget);
    expect(find.text('开始安装'), findsOneWidget);
    expect(find.text('下载 IPA 文件'), findsOneWidget);
    expect(
      find.textContaining('Bundle ID · com.liuying.community'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byKey(key),
      matchesGoldenFile('goldens/app_ios_install_sheet_390.png'),
    );

    debugDefaultTargetPlatformOverride = null;
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 20));
  });

  testWidgets('应用市场个性化推荐 390x844', (tester) async {
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildImmersiveTheme().copyWith(
            textTheme: buildImmersiveTheme().textTheme.apply(
              fontFamily: 'NotoSansSC',
            ),
          ),
          home: const AppMarketPage(),
        ),
      ),
    );
    await tester.pump();
    await _settle(tester, rounds: 20);
    expect(find.text('为你推荐'), findsOneWidget);
    expect(find.text('因为你常逛「工具」分类'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byKey(key),
      matchesGoldenFile('goldens/app_market_personalized_390.png'),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 20));
  });

  testWidgets('应用分享面板 390x844：链接与应用卡视觉验收', (tester) async {
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final key = GlobalKey();

    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildImmersiveTheme().copyWith(
            textTheme: buildImmersiveTheme().textTheme.apply(
              fontFamily: 'NotoSansSC',
            ),
          ),
          home: const AppDetailPage(appId: 'app_ios_visual'),
        ),
      ),
    );
    await tester.pump();
    await _settle(tester, rounds: 40);

    await tester.tap(find.byTooltip('分享').first);
    await tester.pump();
    await _settle(tester);
    expect(find.byType(AppShareSheet), findsOneWidget);
    expect(find.text('分享给互关好友'), findsOneWidget);
    expect(find.text('应用分享'), findsOneWidget);
    expect(find.text('复制链接'), findsOneWidget);
    expect(find.text('系统分享'), findsOneWidget);
    expect(
      find.textContaining('/community/app/app_ios_visual'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byKey(key),
      matchesGoldenFile('goldens/app_share_sheet_390.png'),
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 20));
  });
}
