/// 私信动效/布局回归：键盘顶起列表、首次进入贴底、AI 输入态、
/// 语音/文字形变、长按菜单与未读数字脉冲。
library;

import 'dart:convert';

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

void _mockApi({
  List<Map<String, dynamic>> history = const [],
  List<Map<String, dynamic>> emojis = const [],
}) {
  ApiClient.token = 'motion-token';
  ApiClient.userId = 'me';
  ApiClient.httpClient = MockClient((request) async {
    final path = request.url.path;
    if (path.endsWith('/dm/messages')) {
      return _ok({'list': history, 'peer': 'u1'});
    }
    if (path.endsWith('/dm/read')) return _ok({'read': true});
    if (path.endsWith('/dm/unread')) return _ok({'unread': 0});
    if (path.endsWith('/dm/send')) {
      return _ok({'id': 'sent-1', 'created': _now});
    }
    if (path.endsWith('/emojis')) return _ok({'list': emojis});
    if (path.endsWith('/emojis/favs')) return _ok({'list': []});
    return _ok({});
  });
}

Widget _app({bool peerIsAi = false, EdgeInsets viewInsets = EdgeInsets.zero}) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    home: Builder(
      builder: (context) {
        final mq = MediaQuery.of(context);
        return MediaQuery(
          data: mq.copyWith(
            size: const Size(390, 844),
            viewInsets: viewInsets,
            padding: const EdgeInsets.only(top: 47, bottom: 34),
          ),
          child: DmChatPage(peerId: 'u1', peerName: '夏梓璇', peerIsAi: peerIsAi),
        );
      },
    ),
  );
}

Future<void> _settle(WidgetTester t) async {
  await t.pump();
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 80));
  }
}

void _size(WidgetTester t) {
  t.view.physicalSize = const Size(1170, 2532);
  t.view.devicePixelRatio = 3.0;
  addTearDown(t.view.reset);
}

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => '/tmp',
        );
    _mockApi();
  });

  testWidgets('键盘弹出时消息列表被顶起，不被输入栏盖住', (t) async {
    _size(t);
    await t.pumpWidget(_app(viewInsets: const EdgeInsets.only(bottom: 300)));
    await _settle(t);

    final area = t.getRect(find.byKey(const ValueKey('dm_message_area')));
    final field = t.getRect(find.byType(TextField));
    expect(area.bottom, lessThanOrEqualTo(field.top + 1));
    expect(area.bottom, lessThan(844 - 300 + 20));
  });

  testWidgets('首次进入直接停在最新一条，不播放长距离滚动', (t) async {
    _size(t);
    final history = List.generate(30, (i) {
      return {
        'id': 'm$i',
        'senderId': i.isEven ? 'u1' : 'me',
        'content': '第 $i 条消息，内容足够长以撑开列表高度。',
        'msgType': 'text',
        'created': _now - 30 + i,
        'isRead': 1,
      };
    });
    _mockApi(history: history);
    await t.pumpWidget(_app());
    await _settle(t);
    final scrollable = t.state<ScrollableState>(
      find.descendant(
        of: find.byKey(const ValueKey('dm_message_area')),
        matching: find.byType(Scrollable),
      ),
    );
    expect(
      scrollable.position.pixels,
      closeTo(scrollable.position.maxScrollExtent, 1.5),
    );
  });

  testWidgets('AI 私信发送后出现打字点，语音键可形变并切回', (t) async {
    _size(t);
    await t.pumpWidget(_app(peerIsAi: true));
    await _settle(t);

    await t.enterText(find.byType(TextField), '你好');
    await t.pump();
    await t.tap(find.byIcon(Icons.send_rounded));
    await t.pump(const Duration(milliseconds: 120));
    expect(find.byKey(const ValueKey('dm_typing_bubble')), findsOneWidget);

    // 切换到语音：输入框收成圆钮，表情/发送让位。
    await t.tap(find.byKey(const ValueKey('dm_voice_toggle')));
    await t.pump(const Duration(milliseconds: 320));
    expect(find.byKey(const ValueKey('dm_voice_hold')), findsOneWidget);

    // 再切回文字：长条输入框回来。
    await t.tap(find.byKey(const ValueKey('dm_voice_toggle')));
    await t.pump(const Duration(milliseconds: 320));
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byKey(const ValueKey('dm_voice_hold')), findsNothing);
  });

  testWidgets('表情包从键盘位置飞入，落到气泡后消失', (t) async {
    _size(t);
    _mockApi(
      emojis: [
        {'id': 'e1', 'image': '/emoji/e1.png', 'category': '默认'},
      ],
    );
    await t.pumpWidget(_app());
    await _settle(t);

    await t.tap(find.byIcon(Icons.emoji_emotions_outlined));
    await t.pump(const Duration(milliseconds: 400));
    await _settle(t);
    final item = find
        .descendant(
          of: find.byType(GridView),
          matching: find.byType(PressableScale),
        )
        .first;
    expect(item, findsOneWidget);
    await t.tap(item);
    await t.pump(const Duration(milliseconds: 90));
    expect(find.byKey(const ValueKey('dm_flying_sticker')), findsOneWidget);

    await t.pump(const Duration(milliseconds: 420));
    await t.pump(const Duration(milliseconds: 60));
    expect(find.byKey(const ValueKey('dm_flying_sticker')), findsNothing);
  });

  testWidgets('AI 回复按 2-4 字逐段揭开，普通私信不流式', (t) async {
    _size(t);
    const full =
        '今晚把你整理的那张歌单从头听了一遍，第三首和第七首最合我胃口，'
        '我还在评论区留了想法，等你有空来看看。';
    await t.pumpWidget(_app(peerIsAi: true));
    await _settle(t);

    NotifyBus.shared.onDm.add({
      'id': 'ai1',
      'from': {'id': 'u1'},
      'content': full,
      'msgType': 'text',
      'created': _now,
    });
    await t.pump();
    await t.pump(const Duration(milliseconds: 1));
    await t.pump(const Duration(milliseconds: 1));
    expect(find.byKey(const ValueKey('dm_stream_ai1')), findsOneWidget);
    final rich = t.widget<RichText>(
      find
          .descendant(
            of: find.byKey(const ValueKey('dm_stream_ai1')),
            matching: find.byType(RichText),
          )
          .first,
    );
    final firstText = rich.text.toPlainText();
    expect(firstText.length, inInclusiveRange(2, 8));
    expect(firstText.length, lessThan(full.length));

    await t.pump(const Duration(milliseconds: 220));
    final midHeight = t
        .getRect(find.byKey(const ValueKey('dm_stream_ai1')))
        .height;
    await t.pump(const Duration(milliseconds: 300));
    final laterHeight = t
        .getRect(find.byKey(const ValueKey('dm_stream_ai1')))
        .height;
    expect(laterHeight, greaterThan(midHeight));

    await t.pump(const Duration(milliseconds: 1200));
    await t.pump();
    expect(find.byKey(const ValueKey('dm_stream_ai1')), findsNothing);
    expect(find.text(full), findsOneWidget);

    // 普通私信：同一段内容必须整段出现，不套 AI 节奏。
    await t.pumpWidget(_app(peerIsAi: false));
    await _settle(t);
    NotifyBus.shared.onDm.add({
      'id': 'human1',
      'from': {'id': 'u1'},
      'content': full,
      'msgType': 'text',
      'created': _now,
    });
    await t.pump();
    expect(find.byKey(const ValueKey('dm_stream_human1')), findsNothing);
    expect(find.text(full), findsOneWidget);
  });

  testWidgets('长按消息从落点浮出菜单，背景半透', (t) async {
    _size(t);
    _mockApi(
      history: [
        {
          'id': 'm1',
          'senderId': 'u1',
          'content': '你好',
          'msgType': 'text',
          'created': _now - 10,
          'isRead': 1,
        },
      ],
    );
    await t.pumpWidget(_app());
    await _settle(t);
    await t.longPress(find.text('你好'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 260));
    expect(find.text('复制'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
  });

  testWidgets('未读数变化时只脉冲，不先消失旧数字', (t) async {
    _size(t);
    await t.pumpWidget(
      const MaterialApp(home: Scaffold(body: CountBadge(count: 3))),
    );
    await t.pump();
    expect(find.text('3'), findsOneWidget);

    await t.pumpWidget(
      const MaterialApp(home: Scaffold(body: CountBadge(count: 5))),
    );
    await t.pump();
    expect(find.text('5'), findsOneWidget);
    expect(find.text('3'), findsNothing);

    final scale = t.widget<ScaleTransition>(
      find.descendant(
        of: find.byType(CountBadge),
        matching: find.byType(ScaleTransition),
      ),
    );
    await t.pump(const Duration(milliseconds: 90));
    expect(scale.scale.value, greaterThan(1.0));
  });
}
