import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:community_app/design/components.dart';
import 'package:community_app/models/feed_item.dart';
import 'package:community_app/pages/user/user_profile_chrome.dart';

FeedItem _item(String id, String text, String reason, {bool video = false}) =>
    FeedItem.fromJson({
      'id': id,
      'type': video ? 'video' : 'text',
      'content': text,
      'images': <dynamic>[],
      'video': '',
      'cover': '',
      'boardId': 'b_life',
      'topic': <dynamic>['生活分享'],
      'likeCount': 18,
      'commentCount': 4,
      'shareCount': 2,
      'created': 1763600000,
      'reason': reason,
      'author': {'id': 'u1', 'name': '山栀', 'avatar': '', 'level': 6},
    });

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
  });

  testWidgets('用户主页作品推荐理由 390x844', (tester) async {
    tester.view.physicalSize = const Size(780, 620);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
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
            backgroundColor: const Color(AppColors.bg),
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 220,
                      child: ProfileWorkCard(
                        item: _item(
                          'p1',
                          '苏州的秋天太适合散步了。沿着河岸走一圈，风里都是桂花味。',
                          '因为你常看「生活分享」',
                        ),
                        index: 0,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: SizedBox(
                      height: 220,
                      child: ProfileWorkCard(
                        item: _item(
                          'p2',
                          '凌晨一点四十，楼下有只猫在叫，叫得挺有节奏。',
                          '因为你常看「夜航手记」',
                          video: true,
                        ),
                        index: 1,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('因为你常看「生活分享」'), findsOneWidget);
    expect(find.text('因为你常看「夜航手记」'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byKey(key),
      matchesGoldenFile('goldens/user_profile_reason_390.png'),
    );
  });
}
