/// 私信动效渲染验收：语音态、按住提示、AI 输入态、长按菜单。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:community_app/api/client.dart';
import 'package:community_app/design/components.dart';
import 'package:community_app/pages/message/dm_chat_page.dart';
import 'package:community_app/services/notify_bus.dart';

http.Response _ok(Map<String, dynamic> body) => http.Response(
  jsonEncode({'ok': true, ...body}),
  200,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);
final _now = DateTime.now().millisecondsSinceEpoch / 1000;

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

ThemeData _theme() => ThemeData(
  useMaterial3: true,
  brightness: Brightness.dark,
  fontFamily: 'LAT',
  fontFamilyFallback: const ['CJK'],
  scaffoldBackgroundColor: const Color(0xFF000000),
);

void _mockApi({bool ai = false, List<Map<String, dynamic>> emojis = const []}) {
  ApiClient.token = 'motion-shot-token';
  ApiClient.userId = 'me';
  ApiClient.httpClient = MockClient((request) async {
    final path = request.url.path;
    if (path.endsWith('/dm/messages')) {
      return _ok({
        'list': [
          {
            'id': 'm1',
            'senderId': 'u1',
            'content': '今天过得怎么样？',
            'msgType': 'text',
            'created': _now - 70,
            'isRead': 1,
          },
          {
            'id': 'm2',
            'senderId': 'me',
            'content': '刚把歌单整理完，晚点一起听',
            'msgType': 'text',
            'created': _now - 30,
            'isRead': 1,
          },
          if (ai)
            {
              'id': 'm3',
              'senderId': 'u1',
              'content': '好啊，我先把今晚的歌单听一遍',
              'msgType': 'text',
              'created': _now - 10,
              'isRead': 1,
            },
        ],
        'peer': 'u1',
      });
    }
    if (path.endsWith('/dm/read')) return _ok({'read': true});
    if (path.endsWith('/dm/unread')) return _ok({'unread': 0});
    if (path.endsWith('/dm/send'))
      return _ok({'id': 'sent-1', 'created': _now});
    if (path.endsWith('/emojis')) return _ok({'list': emojis});
    if (path.endsWith('/emojis/favs')) return _ok({'list': []});
    return _ok({});
  });
}

GlobalKey _key = GlobalKey();

Future<void> _pump(
  WidgetTester t, {
  bool ai = false,
  EdgeInsets viewInsets = EdgeInsets.zero,
  List<Map<String, dynamic>> emojis = const [],
}) async {
  t.view.physicalSize = const Size(780, 1688);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  _mockApi(ai: ai, emojis: emojis);
  await t.pumpWidget(
    RepaintBoundary(
      key: _key,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _theme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(viewInsets: viewInsets),
          child: child!,
        ),
        home: DmChatPage(
          peerId: 'u1',
          peerName: ai ? '流小萤' : '夏梓璇',
          peerIsAi: ai,
        ),
      ),
    ),
  );
  await t.pump();
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 80));
  }
}

Future<void> _shot(WidgetTester t, String name) async {
  await expectLater(find.byKey(_key), matchesGoldenFile('goldens/$name.png'));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => Directory.systemTemp.path,
        );
    // 模拟设备语音能力：initialize/listen 返回 true，让“按住说话”进入真实提示态，
    // 避免测试环境无插件时被 Mock 成“语音不可用”，把提示层截图拍成空态。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugin.csdcorp.com/speech_to_text'),
          (call) async {
            if (call.method == 'initialize' || call.method == 'listen') {
              return true;
            }
            return null;
          },
        );
    await _loadFonts();
  });
  setUp(() {
    NotifyBus.enabled = false;
    _key = GlobalKey();
  });
  tearDown(() {
    ApiClient.httpClient = http.Client();
    ApiClient.token = null;
    ApiClient.userId = null;
  });

  testWidgets('语音态：输入框收成圆钮', (t) async {
    await _pump(t);
    await t.tap(find.byKey(const ValueKey('dm_voice_toggle')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 320));
    await _shot(t, 'dm_voice_mode_390');
  });

  testWidgets('按住说话：提示从输入栏上方展开', (t) async {
    await _pump(t);
    await t.tap(find.byKey(const ValueKey('dm_voice_toggle')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 320));
    final gesture = await t.startGesture(
      t.getCenter(find.byKey(const ValueKey('dm_voice_hold'))),
    );
    await t.pump(const Duration(milliseconds: 620));
    await t.pump(const Duration(milliseconds: 180));
    await _shot(t, 'dm_voice_hint_390');
    await gesture.up();
    // stop() 在插件内部会启动一个 2s 的 finalTimeout 定时器；测试结束前必须走完，
    // 否则会以“Timer is still pending”失败，而不是产品行为失败。
    await t.pump(const Duration(seconds: 3));
  });

  testWidgets('AI 回复等待：打字点气泡', (t) async {
    await _pump(t, ai: true);
    await t.enterText(find.byType(TextField), '在吗');
    await t.pump();
    await t.tap(find.byIcon(Icons.send_rounded));
    await t.pump();
    await t.pump(const Duration(milliseconds: 150));
    expect(find.byKey(const ValueKey('dm_typing_bubble')), findsOneWidget);
    await _shot(t, 'dm_typing_390');
  });

  testWidgets('键盘弹出：聊天列表整体被顶起', (t) async {
    await _pump(t, ai: true, viewInsets: const EdgeInsets.only(bottom: 300));
    final area = t.getRect(find.byKey(const ValueKey('dm_message_area')));
    final field = t.getRect(find.byType(TextField));
    expect(area.bottom, lessThanOrEqualTo(field.top + 1));
    expect(field.top - area.bottom, lessThan(22));
    await _shot(t, 'dm_keyboard_390');
  });

  testWidgets('表情包飞入：从键盘位置向上进入气泡', (t) async {
    await _pump(
      t,
      emojis: [
        {'id': 'f1', 'image': '/emoji/f1.png', 'category': '默认'},
      ],
    );
    await t.tap(find.byIcon(Icons.emoji_emotions_outlined));
    await t.pump(const Duration(milliseconds: 400));
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 80));
    }
    final item = find
        .descendant(
          of: find.byType(GridView),
          matching: find.byType(PressableScale),
        )
        .first;
    await t.tap(item);
    await t.pump(const Duration(milliseconds: 70));
    expect(find.byKey(const ValueKey('dm_flying_sticker')), findsOneWidget);
    final first = t.getRect(
      find.byKey(const ValueKey('dm_flying_sticker_body')),
    );
    await t.pump(const Duration(milliseconds: 160));
    final second = t.getRect(
      find.byKey(const ValueKey('dm_flying_sticker_body')),
    );
    expect(second.top, lessThan(first.top));
    await t.pump(const Duration(milliseconds: 600));
    expect(find.byKey(const ValueKey('dm_flying_sticker')), findsNothing);
  });

  testWidgets('AI 流式回复：逐段长高 + 尾光标', (t) async {
    await _pump(t, ai: true);
    await t.runAsync(() async {
      NotifyBus.shared.onDm.add({
        'id': 'ai-stream-1',
        'from': {'id': 'u1'},
        'content':
            '今晚把你整理的那张歌单从头听了一遍，第三首和第七首最合我胃口，'
            '我还在评论区留了想法，等你有空来看看。',
        'msgType': 'text',
        'created': _now,
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('dm_stream_ai-stream-1')), findsOneWidget);
    await _shot(t, 'dm_ai_stream_390');
    await t.pump(const Duration(milliseconds: 1600));
  });

  testWidgets('长按消息：半透菜单浮层', (t) async {
    await _pump(t, ai: true);
    await t.longPress(find.text('今天过得怎么样？'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 260));
    await _shot(t, 'dm_longpress_390');
  });
}
