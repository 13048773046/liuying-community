/// 消息页 tile 渲染回归：用线上真实数据结构（含脏数据变体）驱动 tile 构建，
/// 任何输入都不得抛渲染异常、不得空白。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:community_app/pages/message/notif_list_page.dart' show buildNotifTile;
import 'package:community_app/pages/message/official_messages_page.dart';

/// 线上 _handle_notifications 真实结构（社区端 + 音乐端共享表数据）
final List<Map<String, dynamic>> kLiveNotifications = [
  {
    'id': '802e286cbbc64b609f3692479ba8e208',
    'type': 'community_comment',
    'title': '收到新评论',
    'content': '夏梓璇 评论了你的视频：🤔',
    'fromUserId': '5b75a84c62e540068d9f72cb5faaf4e8',
    'fromUserName': '夏梓璇',
    'isRead': 0,
    'created': 1792968585.51789,
  },
  {
    'id': 'ba8011d7a69847ae801553559ec70d04',
    'type': 'comment',
    'title': '收到 AI 乐评',
    'content': '流小萤 评论了你的歌曲《重新出发吗》',
    'fromUserId': 'a334105a8a2f4401a19001ee4ce66929',
    'fromUserName': '流小萤',
    'isRead': 1,
    'created': 1792965151.89844,
  },
  {
    'id': '9a8ecced2d894caea2a4ad5c2a6199b2',
    'type': 'community_mention',
    'title': '@了 你',
    'content': '我@了你 快来看看',
    'fromUserId': 'u1',
    'fromUserName': '小明',
    'isRead': 0,
    'created': 1792964176.11483,
  },
  {
    'id': '695bdff17f7342ee9386ff701b8bacfa',
    'type': 'community_audit',
    'title': '审核通过',
    'content': '你的内容已通过审核',
    'fromUserId': '',
    'fromUserName': '',
    'isRead': 1,
    'created': 1792965151.89844,
  },
];

/// 脏数据变体：类型异常/null/字符串时间戳（此前 `as num`/`as String` 会崩）
final List<Map<String, dynamic>> kDirtyVariants = [
  {
    'type': null,
    'title': 123,
    'content': null,
    'fromUserName': true,
    'created': 1792968585.5,
    'isRead': 0,
  },
  {
    'type': 'community_follow',
    'title': '',
    'content': '',
    'fromUserName': '',
    'created': '1792964176',
    'isRead': '1',
  },
  {
    'type': 'community_interact',
    'title': '嵌套结构',
    'content': {'a': [1, 2, 3]},
    'fromUserName': null,
    'created': null,
    'isRead': null,
  },
];

void main() {
  Widget host(List<Widget> children) => MaterialApp(
        home: Scaffold(
          backgroundColor: const Color(0xFF121214),
          body: ListView(children: children),
        ),
      );

  testWidgets('线上真实通知数据渲染：全部渲染成功无异常', (tester) async {
    await tester.pumpWidget(host(kLiveNotifications.map(buildNotifTile).toList()));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: '真实数据渲染不得抛异常');
    expect(find.text('收到新评论'), findsOneWidget);
    expect(find.text('收到 AI 乐评'), findsOneWidget);
    expect(find.text('@了 你'), findsOneWidget);
    expect(find.text('审核通过'), findsOneWidget);
  });

  testWidgets('脏数据变体渲染：类型异常/null/字符串时间戳全部安全', (tester) async {
    await tester.pumpWidget(host(kDirtyVariants.map(buildNotifTile).toList()));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: '脏数据不得抛渲染异常');
    // 至少渲染出内容（标题行不会空白）
    final textCount = tester.widgetList(find.byType(Text)).length;
    expect(textCount, greaterThan(0), reason: 'tile 不得空白');
  });

  testWidgets('官方通知聊天页：标题可见且不白屏（含加载失败态）', (tester) async {
    // 官方通知已改为聊天框页（只读气泡）；测试环境无网络 → 必走失败态，
    // 断言标题与失败重试入口可见、无渲染异常即可
    await tester.pumpWidget(const MaterialApp(
      home: OfficialMessagesPage(),
    ));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    expect(find.text('官方通知'), findsOneWidget);
    // 任一可读内容可见（提示语 / 失败重试 / 加载中）
    final visible = <String>[];
    for (final t in ['仅流萤社区官方可发送，无法回复', '加载失败，下拉重试', '暂无官方通知']) {
      if (find.text(t).evaluate().isNotEmpty) visible.add(t);
    }
    expect(visible, isNotEmpty, reason: '官方通知页不能白屏');
  });
}
