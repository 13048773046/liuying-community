import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:community_app/pages/home/af_workbench_page.dart';

http.Response _json(Object data) => http.Response(
      jsonEncode(data),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

// ---- 假的 HttpClient：所有网络图片都返回同一张本地 PNG ----
class _FakeHeaders implements HttpHeaders {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeResponse implements HttpClientResponse {
  _FakeResponse(this.bytes);
  final Uint8List bytes;

  @override
  int get statusCode => 200;

  @override
  int get contentLength => bytes.length;

  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;

  @override
  HttpHeaders get headers => _FakeHeaders();

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      Stream<List<int>>.fromIterable(<List<int>>[bytes]).listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeRequest implements HttpClientRequest {
  _FakeRequest(this.bytes);
  final Uint8List bytes;

  @override
  HttpHeaders get headers => _FakeHeaders();

  @override
  Future<HttpClientResponse> close() async => _FakeResponse(bytes);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeClient implements HttpClient {
  _FakeClient(this.bytes);
  final Uint8List bytes;

  @override
  bool autoUncompress = true;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async => _FakeRequest(bytes);

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _FakeRequest(bytes);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  late Uint8List imgBytes;

  setUpAll(() async {
    // 中文字体
    final loader = FontLoader('NotoSansSC');
    loader.addFont(rootBundle.load('assets/fonts/NotoSansSC-Regular.otf'));
    await loader.load();
    imgBytes = File('test/fixtures/sample_img.png').readAsBytesSync();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'community_token': 'tok',
      'af_conv_id': 'cimg1',
      'af_model': 'deepseek-flash',
    });
    debugNetworkImageHttpClientProvider = () => _FakeClient(imgBytes);
  });

  tearDown(() {
    debugNetworkImageHttpClientProvider = null;
  });

  final client = MockClient((req) async {
    final p = req.url.path;
    if (p.endsWith('/af/quota')) {
      return _json({'ok': true, 'plan': 'svip', 'left': 999, 'limit_w5h': 3000000});
    }
    if (p.endsWith('/af/conversations')) {
      return _json({
        'ok': true,
        'list': [
          {'id': 'cimg1', 'title': '画图', 'pinned': 0, 'created': 1.0, 'updated': 2.0}
        ],
      });
    }
    if (p.endsWith('/af/messages')) {
      return _json({
        'ok': true,
        'list': [
          {'role': 'user', 'content': '画一张流萤社区的海报，深色霓虹风', 'created': 1.0},
          {
            'role': 'assistant',
            'content': '海报画好了：\n![流萤社区海报](https://example.com/poster.png)\n你看这张行不行，要改配色我再出一版。',
            'status': 'done',
            'id': 'm1',
            'created': 2.0,
          },
        ],
        'items': [
          {
            'created': 2.1,
            'payload': {
              'name': 'publish_file',
              'status': 'ok',
              'detail': {
                'url': 'https://example.com/poster.png',
                'file': 'poster.png',
                'size': 20480,
                'kind': 'image',
              },
            },
          }
        ],
      });
    }
    return _json({'ok': true});
  });

  testWidgets('图片消息截图：正文图 + 图片卡缩略图', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3.0;

    final key = GlobalKey();
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: false,
        fontFamily: 'NotoSansSC',
        scaffoldBackgroundColor: Colors.white,
      ),
      home: RepaintBoundary(
        key: key,
        child: AfWorkbenchPage(client: client),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 600));
    });
    await tester.pump(const Duration(milliseconds: 500));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byType(Image), findsWidgets);
    expect(find.text('poster.png'), findsWidgets);

    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final img = await boundary.toImage(pixelRatio: 2.0);
      final data = await img.toByteData(format: ui.ImageByteFormat.png);
      final out = File('test/golden/af_image_msg.png');
      out.writeAsBytesSync(data!.buffer.asUint8List());
      // ignore: avoid_print
      print('SHOT: ${out.path} ${out.lengthSync()} bytes');
    });
    debugNetworkImageHttpClientProvider = null;
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });
}
