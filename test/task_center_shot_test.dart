/// 任务中心 390 视觉验收：真实活动、签到、任务进度与领取按钮同时在场。
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
import 'package:community_app/pages/mine/task_center_page.dart';

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

ThemeData _theme() => buildImmersiveTheme().copyWith(
  textTheme: buildImmersiveTheme().textTheme.apply(
    fontFamily: 'LAT',
    fontFamilyFallback: const ['CJK'],
  ),
  primaryTextTheme: buildImmersiveTheme().primaryTextTheme.apply(
    fontFamily: 'LAT',
    fontFamilyFallback: const ['CJK'],
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(_loadFonts);
  testWidgets('任务中心 390 视觉', (tester) async {
    ApiClient.token = 'shot-token';
    ApiClient.userId = 'me';
    ApiClient.httpClient = MockClient((req) async {
      final path = req.url.path;
      if (path.endsWith('/tasks')) {
        return _ok({
          'list': [
            {
              'id': 't_first_post',
              'name': '发布第一篇帖子',
              'type': 'newbie',
              'target': 1,
              'rewardExp': 20,
              'progress': 1,
              'done': true,
              'claimed': false,
              'status': 'done',
            },
            {
              'id': 't_first_video',
              'name': '发布第一条短视频',
              'type': 'newbie',
              'target': 1,
              'rewardExp': 30,
              'progress': 0,
              'done': false,
              'claimed': false,
              'status': 'pending',
            },
            {
              'id': 't_signin3',
              'name': '累计签到 3 天',
              'type': 'daily',
              'target': 3,
              'rewardExp': 15,
              'progress': 1,
              'done': false,
              'claimed': false,
              'status': 'pending',
            },
            {
              'id': 't_first_like',
              'name': '第一次点赞',
              'type': 'newbie',
              'target': 1,
              'rewardExp': 5,
              'progress': 1,
              'done': true,
              'claimed': true,
              'status': 'claimed',
            },
          ],
        });
      }
      if (path.endsWith('/signins')) {
        return _ok({'list': <dynamic>[]});
      }
      if (path.endsWith('/activities')) {
        return _ok({
          'list': [
            {
              'id': 'a1',
              'topicId': '秋日歌单',
              'title': '秋日歌单分享',
              'desc': '带话题发帖，活动结束统一发经验',
              'rewardExp': 50,
              'startAt': 1,
              'endAt': 0,
              'status': 1,
            },
          ],
        });
      }
      return _ok({});
    });
    addTearDown(() {
      ApiClient.httpClient = http.Client();
      ApiClient.token = null;
      ApiClient.userId = null;
    });
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: _theme(),
          home: const TaskCenterPage(),
        ),
      ),
    );
    await tester.pump();
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }
    await expectLater(
      find.byKey(key),
      matchesGoldenFile('goldens/task_center_390.png'),
    );
  });
}
