import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:community_app/api/client.dart';
import 'package:community_app/design/components.dart';
import 'package:community_app/pages/post/post_detail.dart';

class _OneFrameProvider extends ImageProvider<_OneFrameProvider> {
  _OneFrameProvider(this.image);
  final ui.Image image;

  @override
  Future<_OneFrameProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<_OneFrameProvider>(this);

  @override
  ImageStreamCompleter loadImage(
    _OneFrameProvider key,
    ImageDecoderCallback decode,
  ) => OneFrameImageStreamCompleter(SynchronousFuture(ImageInfo(image: image)));
}

Future<ui.Image> _decode(Uint8List bytes) {
  final c = Completer<ui.Image>();
  ui.decodeImageFromList(bytes, c.complete);
  return c.future;
}

http.Response _json(Object o) => http.Response.bytes(
  utf8.encode(jsonEncode(o)),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

MockClient _client() => MockClient((req) async {
  final p = req.url.path;
  if (p.endsWith('/post/p_video_aspect')) {
    return _json({
      'ok': true,
      'post': {
        'id': 'p_video_aspect',
        'type': 'video',
        'content': '封面比例测试',
        'images': <String>[],
        'video': 'v.mp4',
        'cover': 'c.jpg',
        'duration': 12,
        'topic': <String>[],
        'likeCount': 0,
        'commentCount': 0,
        'shareCount': 0,
        'liked': false,
        'faved': false,
        'later': false,
        'created': 1795046400,
        'author': {'id': '', 'name': '测试', 'avatar': ''},
        'music': null,
        'poll': null,
      },
    });
  }
  if (p.endsWith('/comments')) {
    return _json({'ok': true, 'hasMore': false, 'list': <Object>[]});
  }
  return _json({'ok': true, 'list': <Object>[]});
});

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ApiClient.baseOverride = 'http://test.local/api';
    ApiClient.token = 'tok';
    ApiClient.httpClient = _client();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => Directory.systemTemp.path,
        );
  });

  testWidgets('详情视频容器按封面 9:16 动态撑开，不写死 16:9', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final bytes = (await tester.runAsync(
      () => File('test/fixtures/cover_90x160.png').readAsBytes(),
    ))!;
    final image = (await tester.runAsync(() => _decode(bytes)))!;
    final cover = _OneFrameProvider(image);
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildImmersiveTheme(),
          home: PostDetailPage(
            postId: 'p_video_aspect',
            debugHeroImageProvider: cover,
          ),
        ),
      );
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();
    });
    await tester.pump();

    final frame = tester.widget<AspectRatio>(
      find.byKey(const ValueKey('postVideoHeroFrame')),
    );
    expect(
      frame.aspectRatio,
      closeTo(90 / 160, 0.01),
      reason: '外层容器比例必须来自封面，而不是固定 16:9',
    );
    expect(tester.takeException(), isNull);
  });
}
