import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:community_app/api/client.dart';
import 'package:community_app/config.dart';
import 'package:community_app/design/components.dart';
import 'package:community_app/design/tokens.dart';
import 'package:community_app/pages/post/post_detail.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

Map<String, Object?> _post({
  required List<String> images,
  bool video = false,
}) => {
  'id': 'p_tone',
  'type': video ? 'video' : (images.isEmpty ? 'text' : 'image'),
  'video': video ? 'v.mp4' : '',
  'cover': video ? 'cover.png' : '',
  'content': '夜里整理一版帖子详情，让封面、署名和正文各自有呼吸。',
  'images': images,
  'topic': ['夜晚写作'],
  'likeCount': 12,
  'commentCount': 0,
  'shareCount': 1,
  'liked': false,
  'faved': false,
  'later': false,
  'created': 1795046400,
  'author': {
    'id': 'u1',
    'name': '林晚萤',
    'avatar': '',
    'level': 3,
    'adminLevel': 0,
    'frameId': '',
  },
  'music': null,
  'poll': null,
};

MockClient _client({required List<String> images, bool video = false}) =>
    MockClient((req) async {
      final path = req.url.path;
      if (path.endsWith('/post/p_tone')) {
        return _json({'ok': true, 'post': _post(images: images, video: video)});
      }
      if (path.endsWith('/post/p_tone/comments')) {
        return _json({'ok': true, 'hasMore': false, 'list': <Object>[]});
      }
      if (path.endsWith('/topics')) {
        return _json({'ok': true, 'list': <Object>[]});
      }
      return _json({'ok': true, 'list': <Object>[]});
    });

Color _backdropTop(WidgetTester tester) {
  final box = tester.widget<AnimatedContainer>(
    find.byKey(const ValueKey('post-hero-backdrop')),
  );
  final decoration = box.decoration! as BoxDecoration;
  final gradient = decoration.gradient! as LinearGradient;
  return gradient.colors.first;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ApiClient.baseOverride = 'http://test.local/api';
    ApiClient.token = 'tok';
    ApiClient.userId = '';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => Directory.systemTemp.path,
        );
  });

  testWidgets('图文详情背景取首图主色，而不是固定品牌绿', (tester) async {
    final bytes = (await tester.runAsync(
      () => File('test/fixtures/tone_red.png').readAsBytes(),
    ))!;
    final image = (await tester.runAsync(() => _decode(bytes)))!;
    ApiClient.httpClient = _client(images: ['tone_red.png']);

    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildImmersiveTheme(),
          home: PostDetailPage(
            postId: 'p_tone',
            debugHeroImageProvider: _OneFrameProvider(image),
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

    final top = _backdropTop(tester);
    expect(top.r, greaterThan(top.g));
    expect(top.r, greaterThan(top.b));
    expect(
      top.toARGB32(),
      Color.lerp(
        const Color(0xFFC0392B),
        const Color(AppTheme.bg),
        0.76,
      )!.toARGB32(),
    );
  });

  testWidgets('视频详情背景取封面主色', (tester) async {
    final bytes = (await tester.runAsync(
      () => File('test/fixtures/tone_red.png').readAsBytes(),
    ))!;
    final image = (await tester.runAsync(() => _decode(bytes)))!;
    ApiClient.httpClient = _client(images: const [], video: true);

    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildImmersiveTheme(),
          home: PostDetailPage(
            postId: 'p_tone',
            debugHeroImageProvider: _OneFrameProvider(image),
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

    final top = _backdropTop(tester);
    expect(top.r, greaterThan(top.g));
    expect(top.r, greaterThan(top.b));
    expect(
      top.toARGB32(),
      Color.lerp(
        const Color(0xFFC0392B),
        const Color(AppTheme.bg),
        0.76,
      )!.toARGB32(),
    );
  });

  testWidgets('纯文字详情仍回退品牌绿', (tester) async {
    ApiClient.httpClient = _client(images: const []);

    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildImmersiveTheme(),
          home: const PostDetailPage(postId: 'p_tone'),
        ),
      );
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tester.pump();
    });
    await tester.pump();

    final top = _backdropTop(tester);
    expect(top.g, greaterThan(top.r));
    expect(
      top.toARGB32(),
      Color.lerp(
        const Color(AppTheme.accent),
        const Color(AppTheme.bg),
        0.93,
      )!.toARGB32(),
    );
  });
}
