/// 新版发布页视觉验收：390×844 / 320×700 双尺寸。
///
/// 只用于生成人工检查图，不替代交互测试：
/// - 图文创作台首屏
/// - 短视频空态 / 已选视频态
/// - 抖音式选封面页
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
import 'package:community_app/design/tokens.dart';
import 'package:community_app/pages/post/post_editor.dart';
import 'package:community_app/pages/post/publish_overlay.dart';
import 'package:community_app/pages/post/video_cover_picker.dart';
import 'package:community_app/services/publish_job.dart';

http.Response _ok(Map<String, dynamic> body) => http.Response(
  jsonEncode({'ok': true, ...body}),
  200,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

final _boards = [
  {
    'id': 'b_life',
    'name': '生活分享',
    'icon': '🍀',
    'color': '#4FC3F7',
    'post_count': 4,
    'children': <dynamic>[],
  },
  {
    'id': 'b_food',
    'name': '美食探店',
    'icon': '🍜',
    'color': '#FF8A65',
    'post_count': 2,
    'children': <dynamic>[],
  },
  {
    'id': 'b_outdoor',
    'name': '户外运动',
    'icon': '🏔️',
    'color': '#81C784',
    'post_count': 1,
    'children': <dynamic>[],
  },
];

late Uint8List _previewBytes;
late List<Uint8List> _thumbBytes;
late List<Uint8List> _imageFixtures;
late File _debugVideoFile;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final dir = Directory('test/fixtures/post');
    _previewBytes = await File('${dir.path}/preview.jpg').readAsBytes();
    _imageFixtures = [
      _previewBytes,
      await File('${dir.path}/frame1.jpg').readAsBytes(),
      await File('${dir.path}/frame3.jpg').readAsBytes(),
    ];
    _thumbBytes = [
      await File('${dir.path}/frame1.jpg').readAsBytes(),
      await File('${dir.path}/frame2.jpg').readAsBytes(),
      await File('${dir.path}/frame3.jpg').readAsBytes(),
      await File('${dir.path}/frame4.jpg').readAsBytes(),
      await File('${dir.path}/frame5.jpg').readAsBytes(),
      await File('${dir.path}/frame1.jpg').readAsBytes(),
      await File('${dir.path}/frame2.jpg').readAsBytes(),
      await File('${dir.path}/frame3.jpg').readAsBytes(),
      await File('${dir.path}/frame4.jpg').readAsBytes(),
      await File('${dir.path}/frame5.jpg').readAsBytes(),
    ];
    _debugVideoFile = File('/tmp/post_debug_video.mp4');
    if (!_debugVideoFile.existsSync() ||
        _debugVideoFile.lengthSync() < 1024 * 1024) {
      final raf = await _debugVideoFile.open(mode: FileMode.write);
      await raf.truncate(6 * 1024 * 1024);
      await raf.close();
    }

    final cjk = FontLoader('NotoSansSC')
      ..addFont(rootBundle.load('assets/fonts/NotoSansSC-Regular.otf'));
    await cjk.load();
    final icons = FontLoader('MaterialIcons');
    final iconBytes = await File(
      '/home/user/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    ).readAsBytes();
    icons.addFont(Future.value(ByteData.view(iconBytes.buffer)));
    await icons.load();
  });

  ThemeData theme() {
    final base = buildImmersiveTheme();
    return base.copyWith(
      textTheme: base.textTheme.apply(fontFamily: 'NotoSansSC'),
      iconTheme: base.iconTheme,
    );
  }

  void mockApi() {
    ApiClient.httpClient = MockClient((req) async {
      final path = req.url.path;
      if (path.endsWith('/boards')) {
        return _ok({'list': _boards});
      }
      if (path.endsWith('/topics/hot')) {
        return _ok({
          'list': [
            {'name': '夜航', 'count': 128},
            {'name': '今晚聊什么', 'count': 64},
          ],
        });
      }
      return _ok({'list': <dynamic>[], 'hasMore': false});
    });
  }

  Future<GlobalKey> pumpPage(
    WidgetTester tester,
    Widget page, {
    required Size size,
  }) async {
    tester.view.physicalSize = size * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    // 先在空页面里用真实异步解码预热图片，再挂目标页面；否则 Image.file 在
    // fake async 首帧可能先缓存成错误/空图，之后 precache 也无法替换。
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme(),
        home: const ColoredBox(color: Color(0xFF000000)),
      ),
    );
    final ctx = tester.element(find.byType(MaterialApp));
    await tester.runAsync(() async {
      await precacheImage(MemoryImage(_previewBytes), ctx);
      for (final b in _thumbBytes) {
        await precacheImage(MemoryImage(b), ctx);
      }
      if (page is PostEditorPage) {
        for (final bytes in page.debugImageBytes ?? const <Uint8List>[]) {
          await precacheImage(MemoryImage(bytes), ctx);
        }
        for (final path in page.debugImagePaths ?? const <String>[]) {
          final f = File(path);
          if (f.existsSync()) {
            await precacheImage(FileImage(f), ctx);
          }
        }
      }
    });
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme(),
          home: ColoredBox(color: const Color(0xFF000000), child: page),
        ),
      ),
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }
    expect(tester.takeException(), isNull);
    return key;
  }

  Future<void> shot(WidgetTester tester, GlobalKey key, String name) async {
    await expectLater(find.byKey(key), matchesGoldenFile('goldens/$name'));
  }

  testWidgets('图文创作台 390', (tester) async {
    mockApi();
    SharedPreferences.setMockInitialValues({});
    addTearDown(() => ApiClient.httpClient = http.Client());
    final key = await pumpPage(
      tester,
      const PostEditorPage(),
      size: const Size(390, 844),
    );
    await shot(tester, key, 'post_text_390.png');
    await tester.drag(find.byType(PostEditorPage), const Offset(0, -230));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }
    await shot(tester, key, 'post_text_settings_390.png');
  });

  testWidgets('图文创作台 320', (tester) async {
    mockApi();
    SharedPreferences.setMockInitialValues({});
    addTearDown(() => ApiClient.httpClient = http.Client());
    final key = await pumpPage(
      tester,
      const PostEditorPage(),
      size: const Size(320, 700),
    );
    await shot(tester, key, 'post_text_320.png');
  });

  testWidgets('图文已选图片 390', (tester) async {
    mockApi();
    SharedPreferences.setMockInitialValues({});
    addTearDown(() => ApiClient.httpClient = http.Client());
    final key = await pumpPage(
      tester,
      PostEditorPage(
        debugImagePaths: [
          'test/fixtures/post/preview.jpg',
          'test/fixtures/post/frame1.jpg',
          'test/fixtures/post/frame3.jpg',
        ],
        debugImageBytes: _imageFixtures,
      ),
      size: const Size(390, 844),
    );
    await shot(tester, key, 'post_text_images_390.png');
  });

  testWidgets('图文已选图片 320', (tester) async {
    mockApi();
    SharedPreferences.setMockInitialValues({});
    addTearDown(() => ApiClient.httpClient = http.Client());
    final key = await pumpPage(
      tester,
      PostEditorPage(
        debugImagePaths: [
          'test/fixtures/post/preview.jpg',
          'test/fixtures/post/frame1.jpg',
        ],
        debugImageBytes: _imageFixtures.sublist(0, 2),
      ),
      size: const Size(320, 700),
    );
    await shot(tester, key, 'post_text_images_320.png');
  });

  testWidgets('发布悬浮卡 图文 390', (tester) async {
    final key = await pumpPage(
      tester,
      PublishHoverCard(
        job: PublishJob.forTest(
          preview: PublishPreview(
            kind: PublishKind.text,
            content: '把今天的光收进口袋，晚一点再拿出来看。',
            imageBytes: _thumbBytes[2],
          ),
          progress: 0.64,
          stage: '正在上传图片…',
        ),
        onFinished: () {},
      ),
      size: const Size(390, 844),
    );
    await shot(tester, key, 'post_overlay_text_390.png');
  });

  testWidgets('发布悬浮卡 纯文字 390', (tester) async {
    final key = await pumpPage(
      tester,
      PublishHoverCard(
        job: PublishJob.forTest(
          preview: const PublishPreview(
            kind: PublishKind.text,
            content: '把今天的光收进口袋，晚一点再拿出来看。',
          ),
          progress: 0.38,
          stage: '正在整理内容…',
        ),
        onFinished: () {},
      ),
      size: const Size(390, 844),
    );
    await shot(tester, key, 'post_overlay_text_only_390.png');
  });

  testWidgets('发布悬浮卡 视频 320', (tester) async {
    final key = await pumpPage(
      tester,
      PublishHoverCard(
        job: PublishJob.forTest(
          preview: PublishPreview(
            kind: PublishKind.video,
            content: '海边的风，比想象中更慢一点。',
            imageBytes: _thumbBytes[1],
          ),
          progress: 0.82,
          stage: '正在转码 5/24…',
        ),
        onFinished: () {},
      ),
      size: const Size(320, 700),
    );
    await shot(tester, key, 'post_overlay_video_320.png');
  });

  testWidgets('短视频创建台空态 390', (tester) async {
    mockApi();
    SharedPreferences.setMockInitialValues({});
    addTearDown(() => ApiClient.httpClient = http.Client());
    final key = await pumpPage(
      tester,
      const PostEditorPage(initialMode: 'video'),
      size: const Size(390, 844),
    );
    await shot(tester, key, 'post_video_empty_390.png');
  });

  testWidgets('短视频创建台空态 320', (tester) async {
    mockApi();
    SharedPreferences.setMockInitialValues({});
    addTearDown(() => ApiClient.httpClient = http.Client());
    final key = await pumpPage(
      tester,
      const PostEditorPage(initialMode: 'video'),
      size: const Size(320, 700),
    );
    await shot(tester, key, 'post_video_empty_320.png');
  });

  testWidgets('点击视频海报进入选封面页', (tester) async {
    mockApi();
    SharedPreferences.setMockInitialValues({});
    addTearDown(() => ApiClient.httpClient = http.Client());
    await pumpPage(
      tester,
      PostEditorPage(
        initialMode: 'video',
        debugVideo: _debugVideoFile,
        debugVideoThumb: _thumbBytes[1],
      ),
      size: const Size(390, 844),
    );
    await tester.tap(find.text('点击选封面帧'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('选择封面'), findsOneWidget);
    expect(find.text('使用这一帧'), findsOneWidget);
  });

  testWidgets('短视频已选视频 390', (tester) async {
    mockApi();
    SharedPreferences.setMockInitialValues({});
    addTearDown(() => ApiClient.httpClient = http.Client());
    final f = _debugVideoFile;
    final thumb = _thumbBytes[1];
    final key = await pumpPage(
      tester,
      PostEditorPage(
        initialMode: 'video',
        debugVideo: f,
        debugVideoThumb: thumb,
      ),
      size: const Size(390, 844),
    );
    await shot(tester, key, 'post_video_selected_390.png');
  });

  testWidgets('短视频已选视频 320', (tester) async {
    mockApi();
    SharedPreferences.setMockInitialValues({});
    addTearDown(() => ApiClient.httpClient = http.Client());
    final f = _debugVideoFile;
    final thumb = _thumbBytes[1];
    final key = await pumpPage(
      tester,
      PostEditorPage(
        initialMode: 'video',
        debugVideo: f,
        debugVideoThumb: thumb,
      ),
      size: const Size(320, 700),
    );
    await shot(tester, key, 'post_video_selected_320.png');
  });

  testWidgets('选封面 390', (tester) async {
    final preview = _previewBytes;
    final thumbs = _thumbBytes;
    final key = await pumpPage(
      tester,
      VideoCoverPickerPage(
        video: _debugVideoFile,
        initialTime: 2.4,
        debugPreview: preview,
        debugThumbnails: thumbs,
        debugDuration: 8.4,
      ),
      size: const Size(390, 844),
    );
    await shot(tester, key, 'post_cover_picker_390.png');
  });

  testWidgets('选封面 320', (tester) async {
    final preview = _previewBytes;
    final thumbs = _thumbBytes;
    final key = await pumpPage(
      tester,
      VideoCoverPickerPage(
        video: _debugVideoFile,
        initialTime: 2.4,
        debugPreview: preview,
        debugThumbnails: thumbs,
        debugDuration: 8.4,
      ),
      size: const Size(320, 700),
    );
    await shot(tester, key, 'post_cover_picker_320.png');
  });
}
