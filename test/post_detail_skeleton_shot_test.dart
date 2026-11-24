// 帖子详情首屏骨架：加载态要与正文同形，而不是一个居中转圈。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:community_app/api/client.dart';
import 'package:community_app/design/components.dart';
import 'package:community_app/pages/post/post_detail.dart';

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
  });

  testWidgets('帖子详情加载态是同形骨架', (tester) async {
    ApiClient.token = 'tok';
    final never = Completer<http.Response>();
    ApiClient.httpClient = MockClient((_) => never.future);
    addTearDown(() => ApiClient.httpClient = http.Client());

    tester.view.physicalSize = const Size(390 * 2, 844 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    final base = buildImmersiveTheme();
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: base.copyWith(
          textTheme: base.textTheme.apply(fontFamily: 'NotoSansSC'),
        ),
        builder: (context, child) => DefaultTextStyle(
          style: const TextStyle(fontFamily: 'NotoSansSC', color: Colors.white),
          child: child!,
        ),
        home: const PostDetailPage(postId: 'skeleton'),
      ),
    );
    await tester.pump(const Duration(milliseconds: 240));

    expect(find.byType(ShimmerBox), findsWidgets);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await expectLater(
      find.byType(PostDetailPage),
      matchesGoldenFile('goldens/post_detail_skeleton_390.png'),
    );

    // 收尾：完成挂起的请求并卸载骨架，避免 15s 超时定时器泄漏到下一个测试。
    never.complete(
      http.Response(
        '{"ok":true,"post":null}',
        200,
        headers: const {'content-type': 'application/json'},
      ),
    );
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
