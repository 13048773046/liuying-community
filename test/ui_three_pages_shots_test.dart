/// 三页 390×844 视觉验收：生成 PNG 供人工检查对齐、溢出与层级。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:community_app/api/client.dart';
import 'package:community_app/design/components.dart';
import 'package:community_app/pages/boards/boards_page.dart';
import 'package:community_app/pages/home/home_page.dart';
import 'package:community_app/pages/search/search_page.dart';

http.Response _ok(Map<String, dynamic> body) => http.Response(
  jsonEncode({'ok': true, ...body}),
  200,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

Map<String, dynamic> _post(String id, String text, String tag, int likes) => {
  'id': id,
  'type': 'text',
  'content': text,
  'tag': tag,
  'topic': [tag.replaceAll('#', '')],
  'likeCount': likes,
  'commentCount': likes ~/ 3,
  'shareCount': 2,
  'created': 1763550000,
  'author': {
    'id': 'u_$id',
    'name': ['山栀', '迟野', '小满', '鹤见', '南枝'][likes % 5],
    'avatar': '',
    'level': 6,
  },
};

final _posts = [
  {
    ..._post('p1', '夜里十一点，花甸的灯还亮着。把今天的风声、脚步和没说完的话，都收进这条动态里。', '#夜航', 128),
    'reason': '因为你常看「生活分享」',
  },
  {
    ..._post('p2', '有人一起去看明晚的月亮吗？', '#今晚聊什么', 64),
    'type': 'video',
    'duration': 18,
  },
  _post('p3', '把旧唱片翻出来听，居然还会跟着哼。', '#唱片', 92),
  _post('p4', '第一次做手冲，记录一下。', '#生活', 37),
  _post('p5', '今天的云像一只慢慢游走的鲸。', '#随手拍', 214),
  _post('p6', '给流萤写了一段新的间奏。', '#流萤音乐', 76),
  _post('p7', '凌晨的便利店，关东煮冒着热气。', '#夜行', 45),
  _post('p8', '想认识同样在苏州的朋友。', '#同城', 31),
];

final _apps = [
  {
    'id': 'a1',
    'name': '萤火音乐',
    'icon': '',
    'platform': 'android',
    'packageType': 'apk',
    'version': '1.2.0',
    'category': '影音',
    'description': '社区音乐播放器',
    'downloadCount': 1200,
    'rating': 4.8,
    'ratingCount': 12,
  },
  {
    'id': 'a2',
    'name': '花甸天气',
    'icon': '',
    'platform': 'android',
    'packageType': 'apk',
    'version': '2.0.1',
    'category': '工具',
    'description': '看云和风',
    'downloadCount': 860,
    'rating': 4.6,
    'ratingCount': 9,
  },
  {
    'id': 'a3',
    'name': '夜航日志',
    'icon': '',
    'platform': 'android',
    'packageType': 'apk',
    'version': '0.9.0',
    'category': '效率',
    'description': '记录夜晚',
    'downloadCount': 430,
    'rating': 4.4,
    'ratingCount': 5,
  },
  {
    'id': 'a4',
    'name': '流萤航线',
    'icon': '',
    'platform': 'android',
    'packageType': 'apk',
    'version': '1.0.0',
    'category': '游戏',
    'description': '花甸飞行',
    'downloadCount': 2100,
    'rating': 4.9,
    'ratingCount': 20,
  },
];

final _hot = [
  {'q': '夜航'},
  {'q': '今晚聊什么'},
  {'q': '流萤音乐'},
  {'q': '苏州同城'},
  {'q': '手冲咖啡'},
  {'q': '月亮'},
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
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => Directory.systemTemp.path,
        );
  });

  ThemeData theme() {
    final base = buildImmersiveTheme();
    return base.copyWith(
      textTheme: base.textTheme.apply(fontFamily: 'NotoSansSC'),
      iconTheme: base.iconTheme,
    );
  }

  void mockApi({bool realBoards = false}) {
    ApiClient.httpClient = MockClient((req) async {
      final path = req.url.path;
      if (path.endsWith('/banners')) {
        return _ok({
          'list': [
            {
              'id': 'bn1',
              'title': '今晚，去花甸听风',
              'linkType': 'topic',
              'linkId': '夜航',
            },
            {
              'id': 'bn2',
              'title': '把喜欢的歌放进夜里',
              'linkType': 'topic',
              'linkId': '流萤音乐',
            },
            {
              'id': 'bn3',
              'title': '社区应用新上线',
              'linkType': 'app',
              'linkId': 'a1',
            },
          ],
        });
      }
      if (path.endsWith('/feed')) {
        return _ok({'list': _posts, 'page': 1, 'hasMore': false});
      }
      if (path.endsWith('/boards')) {
        if (realBoards) {
          return _ok({
            'list': [
              {
                'id': 'b_life',
                'name': '生活分享',
                'icon': '🍀',
                'color': '#4FC3F7',
                'post_count': 4,
                'children': [],
              },
              {
                'id': 'b_food',
                'name': '美食探店',
                'icon': '🍜',
                'color': '#FF8A65',
                'post_count': 2,
                'children': [],
              },
              {
                'id': 'b_outdoor',
                'name': '户外运动',
                'icon': '🏔️',
                'color': '#81C784',
                'post_count': 1,
                'children': [],
              },
              {
                'id': 'b_digital',
                'name': '数码科技',
                'icon': '💻',
                'color': '#9575CD',
                'post_count': 3,
                'children': [],
              },
              {
                'id': 'b_city',
                'name': '同城活动',
                'icon': '📍',
                'color': '#FFD54F',
                'post_count': 1,
                'children': [],
              },
              {
                'id': 'b_pet',
                'name': '萌宠日常',
                'icon': '🐱',
                'color': '#F48FB1',
                'post_count': 2,
                'children': [],
              },
            ],
          });
        }
        return _ok({
          'list': [
            {
              'id': 'b1',
              'name': '夜色',
              'icon': '夜',
              'post_count': 128,
              'children': [
                {
                  'id': 'b1a',
                  'name': '夜航',
                  'icon': '',
                  'post_count': 32,
                  'children': [],
                },
                {
                  'id': 'b1b',
                  'name': '电台',
                  'icon': '',
                  'post_count': 19,
                  'children': [],
                },
                {
                  'id': 'b1c',
                  'name': '晚安',
                  'icon': '',
                  'post_count': 11,
                  'children': [],
                },
              ],
            },
            {
              'id': 'b2',
              'name': '声音',
              'icon': '声',
              'post_count': 96,
              'children': [],
            },
            {
              'id': 'b3',
              'name': '生活',
              'icon': '生',
              'post_count': 210,
              'children': [],
            },
            {
              'id': 'b4',
              'name': '影像',
              'icon': '影',
              'post_count': 74,
              'children': [],
            },
          ],
        });
      }
      if (path.endsWith('/topics')) {
        return _ok({
          'list': [
            {
              'name': '夜航',
              'count': 128,
              'post_count': 128,
              'reason': '因为你常看「夜航」',
            },
            {
              'name': '今晚聊什么',
              'count': 96,
              'post_count': 96,
              'reason': '因为你常看「夜航」',
            },
            {'name': '流萤音乐', 'count': 88, 'post_count': 88, 'reason': '社区热门'},
            {'name': '苏州同城', 'count': 64, 'post_count': 64, 'reason': '社区热门'},
            {'name': '手冲咖啡', 'count': 41, 'post_count': 41},
            {'name': '月亮', 'count': 37, 'post_count': 37},
          ],
        });
      }
      if (path.endsWith('/search/hot')) return _ok({'list': _hot});
      if (path.endsWith('/search/suggest')) {
        return _ok({
          'topics': ['夜航', '夜航日志'],
          'users': [
            {'name': '夜航员'},
          ],
        });
      }
      if (path.endsWith('/search')) {
        return _ok({
          'posts': _posts.take(4).toList(),
          'videos': [],
          'users': [
            {'id': 'u1', 'name': '夜航员', 'avatar': '', 'level': 4},
            {'id': 'u2', 'name': '山栀', 'avatar': '', 'level': 6},
          ],
          'topics': [
            {'name': '夜航', 'post_count': 128},
            {'name': '夜航日志', 'post_count': 32},
          ],
        });
      }
      if (path.endsWith('/apps')) {
        final q = req.url.queryParameters['q'] ?? '';
        final list = q.isEmpty
            ? _apps
            : _apps.where((e) => (e['name'] as String).contains(q)).toList();
        return _ok({
          'list': q.isEmpty
              ? list
              : (list.isEmpty ? _apps.take(1).toList() : list),
          'total': list.length,
          'page': 1,
          'pageSize': 20,
        });
      }
      return _ok({});
    });
  }

  testWidgets('首页 390x844', (tester) async {
    mockApi();
    SharedPreferences.setMockInitialValues({});
    addTearDown(() => ApiClient.httpClient = http.Client());
    final key = GlobalKey();
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme(),
          home: const HomePage(),
        ),
      ),
    );
    await tester.pump();
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byKey(key),
      matchesGoldenFile('goldens/home_390_v2.png'),
    );
  });

  testWidgets('首页 390x844 二楼入口', (tester) async {
    mockApi();
    SharedPreferences.setMockInitialValues({});
    addTearDown(() => ApiClient.httpClient = http.Client());
    final key = GlobalKey();
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme(),
          home: const HomePage(),
        ),
      ),
    );
    await tester.pump();
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }
    // 二楼只走同一条下拉手势：拉过二楼主线后松手展开。
    await tester.dragFrom(const Offset(195, 80), const Offset(0, 420));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
    expect(find.text('这一层，\n是你的工具台'), findsOneWidget);
    await expectLater(
      find.byKey(key),
      matchesGoldenFile('goldens/home_floor_390.png'),
    );
  });

  testWidgets('首页 二楼下拉临界 390x844', (tester) async {
    mockApi();
    SharedPreferences.setMockInitialValues({});
    addTearDown(() => ApiClient.httpClient = http.Client());
    final key = GlobalKey();
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme(),
          home: const HomePage(),
        ),
      ),
    );
    await tester.pump();
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }
    final gesture = await tester.startGesture(const Offset(195, 80));
    await gesture.moveBy(const Offset(0, 240));
    await tester.pump();
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byKey(key),
      matchesGoldenFile('goldens/home_second_floor_peek_390.png'),
    );
    await gesture.up();
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    await tester.pump(const Duration(seconds: 11));
    expect(tester.takeException(), isNull);
  });

  testWidgets('首页 下拉缝隙刷新 390x844', (tester) async {
    mockApi();
    SharedPreferences.setMockInitialValues({});
    addTearDown(() => ApiClient.httpClient = http.Client());
    final key = GlobalKey();
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme(),
          home: const HomePage(),
        ),
      ),
    );
    await tester.pump();
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }

    final gesture = await tester.startGesture(const Offset(195, 80));
    await gesture.moveBy(const Offset(0, 130));
    await tester.pump();
    expect(find.text('松开刷新'), findsOneWidget);
    await expectLater(
      find.byKey(key),
      matchesGoldenFile('goldens/home_pull_gap_390.png'),
    );

    await gesture.up();
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.text('正在刷新'), findsOneWidget);
    await expectLater(
      find.byKey(key),
      matchesGoldenFile('goldens/home_refreshing_390.png'),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(
      find.byKey(const ValueKey('home-pull-gap-spinner')),
      findsNothing,
    );
    // 首页图片缓存会在测试环境里排一个 10s 的清理计时器；等它过掉再结束。
    await tester.pump(const Duration(seconds: 11));
    expect(tester.takeException(), isNull);
  });

  testWidgets('首页 搜索收集中间态 390x844', (tester) async {
    mockApi();
    SharedPreferences.setMockInitialValues({});
    addTearDown(() => ApiClient.httpClient = http.Client());
    final key = GlobalKey();
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme(),
          home: const HomePage(),
        ),
      ),
    );
    await tester.pump();
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }
    await tester.drag(find.byType(HomePage), const Offset(0, -58));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byKey(key),
      matchesGoldenFile('goldens/home_search_mid_390.png'),
    );
  });

  testWidgets('首页 搜索收起 390x844', (tester) async {
    mockApi();
    SharedPreferences.setMockInitialValues({});
    addTearDown(() => ApiClient.httpClient = http.Client());
    final key = GlobalKey();
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme(),
          home: const HomePage(),
        ),
      ),
    );
    await tester.pump();
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }
    await tester.drag(find.byType(HomePage), const Offset(0, -150));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byKey(key),
      matchesGoldenFile('goldens/home_search_collapsed_390.png'),
    );
  });

  testWidgets('首页 搜索收起 320x700', (tester) async {
    mockApi();
    SharedPreferences.setMockInitialValues({});
    addTearDown(() => ApiClient.httpClient = http.Client());
    final key = GlobalKey();
    tester.view.physicalSize = const Size(640, 1400);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme(),
          home: const HomePage(),
        ),
      ),
    );
    await tester.pump();
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }
    await tester.drag(find.byType(HomePage), const Offset(0, -120));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byKey(key),
      matchesGoldenFile('goldens/home_search_collapsed_320.png'),
    );
  });

  testWidgets('板块 六频道 390x844', (tester) async {
    mockApi(realBoards: true);
    SharedPreferences.setMockInitialValues({});
    addTearDown(() => ApiClient.httpClient = http.Client());
    final key = GlobalKey();
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme(),
          home: const BoardsPage(),
        ),
      ),
    );
    await tester.pump();
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }
    expect(tester.takeException(), isNull);
    expect(find.text('生活分享'), findsWidgets);
    await expectLater(
      find.byKey(key),
      matchesGoldenFile('goldens/boards_real_390.png'),
    );
  });

  testWidgets('板块 390x844', (tester) async {
    mockApi();
    SharedPreferences.setMockInitialValues({});
    addTearDown(() => ApiClient.httpClient = http.Client());
    final key = GlobalKey();
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme(),
          home: const BoardsPage(),
        ),
      ),
    );
    await tester.pump();
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byKey(key),
      matchesGoldenFile('goldens/boards_390_v2.png'),
    );
  });

  testWidgets('搜索默认 390x844', (tester) async {
    mockApi();
    SharedPreferences.setMockInitialValues({
      'search_history': ['夜航', '流萤音乐', '苏州同城', '手冲咖啡', '月亮', '晚安电台'],
    });
    addTearDown(() => ApiClient.httpClient = http.Client());
    final key = GlobalKey();
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme(),
          home: const SearchPage(),
        ),
      ),
    );
    await tester.pump();
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }
    expect(tester.takeException(), isNull);
    // 搜索页不再做「猜你想看」式内容发现流。
    expect(find.text('猜你想看'), findsNothing);
    expect(find.text('继续逛'), findsNothing);
    expect(find.text('发现新内容'), findsNothing);
    await expectLater(
      find.byKey(key),
      matchesGoldenFile('goldens/search_default_390_v2.png'),
    );
  });

  testWidgets('搜索结果 390x844', (tester) async {
    mockApi();
    SharedPreferences.setMockInitialValues({
      'search_history': ['夜航', '流萤音乐', '苏州同城'],
    });
    addTearDown(() => ApiClient.httpClient = http.Client());
    final key = GlobalKey();
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme(),
          home: const SearchPage(),
        ),
      ),
    );
    await tester.pump();
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }
    await tester.enterText(find.byType(TextField), '夜航');
    await tester.tap(find.text('搜索').last);
    for (var i = 0; i < 14; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byKey(key),
      matchesGoldenFile('goldens/search_result_390_v2.png'),
    );
  });

  testWidgets('首页 320x700', (tester) async {
    mockApi();
    SharedPreferences.setMockInitialValues({});
    addTearDown(() => ApiClient.httpClient = http.Client());
    final key = GlobalKey();
    tester.view.physicalSize = const Size(640, 1400);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme(),
          home: const HomePage(),
        ),
      ),
    );
    await tester.pump();
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byKey(key),
      matchesGoldenFile('goldens/home_320_v2.png'),
    );
  });

  testWidgets('320 小屏三页不溢出', (tester) async {
    mockApi();
    SharedPreferences.setMockInitialValues({
      'search_history': ['夜航', '流萤音乐', '苏州同城'],
    });
    addTearDown(() => ApiClient.httpClient = http.Client());
    tester.view.physicalSize = const Size(640, 1400);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    for (final w in [
      const HomePage(),
      const BoardsPage(),
      const SearchPage(),
    ]) {
      await tester.pumpWidget(
        MaterialApp(debugShowCheckedModeBanner: false, theme: theme(), home: w),
      );
      await tester.pump();
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 80));
      }
      expect(tester.takeException(), isNull, reason: '$w 320 宽溢出');
    }
  });
}
