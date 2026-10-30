import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:community_app/models/feed_item.dart';
import 'package:community_app/pages/shorts/video_card.dart';

// 外层垂直 PageView（短视频整屏切换）+ 内层图片帖水平 PageView（真机结构）
Widget nestedShorts() => Scaffold(
      body: PageView.builder(
        scrollDirection: Axis.vertical,
        itemCount: 3,
        itemBuilder: (_, i) => VideoCard(
          item: i == 0 ? imgPost() : imgPost2(),
          isActive: i == 0,
        ),
      ),
    );

FeedItem imgPost2() => FeedItem.fromJson({
      'id': 't2',
      'type': 'text',
      'content': '单图',
      'images': ['d.jpg'],
      'video': '',
      'cover': '',
      'author': {'id': 'u2', 'name': '甲', 'avatar': ''},
    });

FeedItem imgPost() => FeedItem.fromJson({
      'id': 't1',
      'type': 'text',
      'content': '三图测试帖',
      'images': ['a.jpg', 'b.jpg', 'c.jpg'],
      'video': '',
      'cover': '',
      'topic': [],
      'mentions': [],
      'author': {'id': 'u1', 'name': '测试', 'avatar': ''},
      'music':
          '{"url": "https://x.example/m.m4a", "name": "配乐A", "cover": ""}',
    });

void main() {
  testWidgets('垂直短视频流内嵌图集帖：水平滑动仍生效（真机结构）', (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: nestedShorts(),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('1/3'), findsOneWidget);

    await tester.drag(find.byType(PageView).last, const Offset(-400, 0),
        warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('2/3'), findsOneWidget, reason: '垂直流内嵌时左滑应生效');
  });
}
