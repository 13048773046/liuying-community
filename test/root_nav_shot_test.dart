import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:community_app/api/client.dart';
import 'package:community_app/pages/home/home_page.dart';
import 'package:community_app/pages/message/message_page.dart';
import 'package:community_app/pages/root_page.dart';
import 'package:community_app/services/notify_bus.dart';

http.Response _ok(Map<String, dynamic> body) => http.Response(
  jsonEncode({'ok': true, ...body}),
  200,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

Future<void> _loadFont(String name, String path) async {
  final f = File(path);
  if (!f.existsSync()) return;
  final bytes = await f.readAsBytes();
  final loader = FontLoader(name)
    ..addFont(Future.value(ByteData.view(bytes.buffer)));
  await loader.load();
}

Future<void> _loadFonts() async {
  await _loadFont('LAT', '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf');
  await _loadFont(
    'CJK',
    '/usr/share/fonts/truetype/droid/DroidSansFallbackFull.ttf',
  );
  await _loadFont(
    'MaterialIcons',
    '/home/user/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(_loadFonts);
  setUp(() {
    SharedPreferences.setMockInitialValues({'community_token': 't'});
    NotifyBus.enabled = false;
    NotifyBus.shared.clearUnread();
    NotifyBus.shared.clearDmUnread();
    NotifyBus.shared.clearOfficialUnread();
    ApiClient.token = 't';
    ApiClient.userId = 'me';
    ApiClient.httpClient = MockClient((request) async {
      final p = request.url.path;
      if (p.endsWith('/notifications/unread')) {
        return _ok({
          'unread': 4,
          'officialUnread': 2,
          'byType': {'like': 2, 'comment': 1, 'follow': 1, 'audit': 0},
        });
      }
      if (p.endsWith('/dm/unread')) return _ok({'unread': 3});
      if (p.endsWith('/dm/conversations'))
        return _ok({'list': [], 'hasMore': false});
      if (p.endsWith('/notifications') || p.endsWith('/official-messages')) {
        return _ok({'list': [], 'hasMore': false});
      }
      return _ok({'list': [], 'hasMore': false});
    });
  });
  tearDown(() {
    ApiClient.httpClient = http.Client();
    NotifyBus.shared.clearUnread();
    NotifyBus.shared.clearDmUnread();
    NotifyBus.shared.clearOfficialUnread();
  });
  testWidgets('底部导航总红点 390', (tester) async {
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            useMaterial3: true,
            brightness: Brightness.dark,
            fontFamily: 'LAT',
            fontFamilyFallback: const ['CJK'],
          ),
          home: const RootPage(),
        ),
      ),
    );
    await tester.pump();
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await expectLater(
      find.byKey(key),
      matchesGoldenFile('goldens/message_nav_390.png'),
    );
  });
  testWidgets('切 tab 是交叉淡入，不是 Offstage 硬切', (tester) async {
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          fontFamily: 'LAT',
          fontFamilyFallback: const ['CJK'],
        ),
        home: const RootPage(),
      ),
    );
    await tester.pump();
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    await tester.tap(find.text('消息'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));

    // 导航图标本身也在交叉淡入：描边与实心两枚图标短暂同时在树上。
    expect(find.byKey(const ValueKey('nav_icon_消息_false')), findsOneWidget);
    expect(find.byKey(const ValueKey('nav_icon_消息_true')), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 40));
    // 动画中：新页正在淡入、旧首页同时在淡出（offstage=false），
    // 两层都带 0–1 之间的透明度，说明不是 Offstage 硬切。
    expect(find.byType(MessagePage), findsOneWidget);
    expect(find.byType(HomePage), findsOneWidget);
    final newFade = tester
        .widget<Opacity>(find.byKey(const ValueKey('tab_fade_3')))
        .opacity;
    final oldFade = tester
        .widget<Opacity>(find.byKey(const ValueKey('tab_fade_0')))
        .opacity;
    expect(newFade, inExclusiveRange(0, 1));
    expect(oldFade, inExclusiveRange(0, 1));
    expect(tester.takeException(), isNull);

    await tester.pump(const Duration(milliseconds: 200));
    // 动画结束：旧页转 Offstage，避免两层长期合成。
    expect(find.byType(HomePage), findsNothing);
    expect(find.byType(MessagePage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
