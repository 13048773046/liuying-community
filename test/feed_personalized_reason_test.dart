import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:community_app/models/feed_item.dart';
import 'package:community_app/widgets/post_card.dart';
import 'package:community_app/design/tokens.dart';

void main() {
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
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => Directory.systemTemp.path,
        );
  });
  testWidgets('个性化推荐理由 390x844', (tester) async {
    final item = FeedItem.fromJson({
      'id': 'p1',
      'type': 'text',
      'content': '苏州的秋天太适合散步了。沿着河岸走一圈，风里都是桂花味。',
      'images': <dynamic>[],
      'boardId': 'b_life',
      'topic': <dynamic>['苏州秋天'],
      'likeCount': 18,
      'commentCount': 4,
      'shareCount': 2,
      'created': 1763600000,
      'reason': '因为你常看「生活分享」',
      'author': {'id': 'u1', 'name': '山栀', 'avatar': '', 'level': 6},
    });
    final key = GlobalKey();
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildImmersiveTheme().copyWith(
            textTheme: buildImmersiveTheme().textTheme.apply(
              fontFamily: 'NotoSansSC',
            ),
          ),
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: PostCard(item: item),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('因为你常看「生活分享」'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byKey(key),
      matchesGoldenFile('goldens/reason_card_390.png'),
    );
  });
}
