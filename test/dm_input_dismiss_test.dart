/// 私信输入区交互回归：点输入框外出应收起键盘与面板。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:community_app/pages/message/dm_chat_page.dart';
import 'package:community_app/widgets/emoji_panel.dart';

// ---------------------------------------------------------------- HTTP mock

class _MockHeaders implements HttpHeaders {
  @override
  void forEach(void Function(String name, List<String> values) f) {}
  @override
  dynamic noSuchMethod(Invocation i) => null;
}

class _MockRequest implements HttpClientRequest {
  _MockRequest(this.uri);
  @override
  final Uri uri;
  @override
  final HttpHeaders headers = _MockHeaders();
  @override
  Future<HttpClientResponse> close() async => _MockResponse(uri);
  @override
  dynamic noSuchMethod(Invocation i) {
    switch (i.memberName) {
      case #addStream:
      case #add:
      case #flush:
        return Future<void>.value();
    }
    return null;
  }
}

class _MockResponse implements HttpClientResponse {
  _MockResponse(this.uri);
  final Uri uri;

  String get _body {
    if (uri.path.endsWith('/emojis')) {
      return '{"ok":true,"list":[{"id":"e1","image":"e1.png","category":"日常"}]}';
    }
    if (uri.path.contains('/emojis/favs')) return '{"ok":true,"list":[]}';
    if (uri.path.endsWith('/dm/messages')) {
      return '{"ok":true,"list":[],"hasMore":false}';
    }
    if (uri.path.endsWith('/dm/unread')) return '{"ok":true,"count":0}';
    return '{"ok":true}';
  }

  @override
  int get statusCode => 200;
  @override
  String get reasonPhrase => 'OK';
  @override
  int get contentLength => utf8.encode(_body).length;
  @override
  HttpHeaders get headers => _MockHeaders();
  @override
  bool get isRedirect => false;
  @override
  bool get persistentConnection => false;
  @override
  List<RedirectInfo> get redirects => const [];
  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;

  @override
  StreamSubscription<List<int>> listen(void Function(List<int>)? onData,
      {Function? onError, void Function()? onDone, bool? cancelOnError}) {
    return Stream<List<int>>.fromIterable([utf8.encode(_body)]).listen(onData,
        onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  }

  @override
  dynamic noSuchMethod(Invocation i) => null;
}

class _MockClient implements HttpClient {
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _MockRequest(url);
  @override
  dynamic noSuchMethod(Invocation i) => null;
}

class _MockOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) => _MockClient();
}

// ---------------------------------------------------------------------------

Widget app() => MaterialApp(
      debugShowCheckedModeBanner: false,
      home: const DmChatPage(peerId: 'u1', peerName: '夏梓璇'),
    );

Future<void> settle(WidgetTester t) async {
  await t.pump();
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 80));
  }
}

bool _focused(WidgetTester t) =>
    t.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus;

void main() {
  setUpAll(() => HttpOverrides.global = _MockOverrides());
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('点输入框 → 点消息区：收起键盘', (t) async {
    t.view.physicalSize = const Size(1179, 2556);
    t.view.devicePixelRatio = 3.0;
    addTearDown(t.view.reset);
    await t.pumpWidget(app());
    await settle(t);
    await t.tap(find.byType(TextField));
    await settle(t);
    expect(_focused(t), isTrue);
    // 点聊天区空白
    await t.tap(find.byKey(const ValueKey('dm_message_area')));
    await settle(t);
    expect(_focused(t), isFalse);
  });

  testWidgets('表情面板打开 → 点消息区：面板关闭且不弹键盘', (t) async {
    t.view.physicalSize = const Size(1179, 2556);
    t.view.devicePixelRatio = 3.0;
    addTearDown(t.view.reset);
    await t.pumpWidget(app());
    await settle(t);
    await t.tap(find.byIcon(Icons.emoji_emotions_outlined));
    await settle(t);
    expect(find.byType(EmojiPanel), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('dm_message_area')));
    await settle(t);
    expect(find.byType(EmojiPanel), findsNothing);
    expect(_focused(t), isFalse);
  });
}
