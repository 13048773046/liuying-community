/// 任务中心真实数据回归：状态、进度、领取、签到、活动全部走后端。
library;

import 'dart:convert';

import 'package:flutter/material.dart';
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

void main() {
  testWidgets('任务状态可领取、签到后刷新、活动来自后端', (tester) async {
    final now = DateTime.now();
    final today =
        '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
    var claimed = false;
    var signed = false;
    var signinCalls = 0;
    var claimCalls = 0;

    ApiClient.token = 'task-token';
    ApiClient.userId = 'me';
    ApiClient.httpClient = MockClient((req) async {
      final path = req.url.path;
      if (path.contains('/tasks/t_first_post/claim')) {
        claimCalls++;
        claimed = true;
        return _ok({'claimed': true, 'msg': '已领取 +20 经验'});
      }
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
              'claimed': claimed,
              'status': claimed ? 'claimed' : 'done',
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
          ],
        });
      }
      if (path.endsWith('/signins')) {
        // 后端 /signins 返回的是服务器当天日期；测试必须按同一“今天”构造，
        // 否则 UTC 时区的 CI runner 会把 2026-11-21 当成今天，误判为已签到。
        return _ok({
          'list': signed ? [today] : <dynamic>[],
        });
      }
      if (path.endsWith('/signin')) {
        signinCalls++;
        signed = true;
        return _ok({'day': today, 'streak': 1, 'exp': 5, 'msg': '签到成功 +5 经验'});
      }
      if (path.endsWith('/activities')) {
        return _ok({
          'list': [
            {
              'id': 'a1',
              'topicId': '秋日歌单',
              'title': '秋日歌单分享',
              'desc': '带话题发帖参与',
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

    tester.view.physicalSize = const Size(390 * 2, 844 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(theme: buildImmersiveTheme(), home: const TaskCenterPage()),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('成长任务'), findsOneWidget);
    expect(find.text('已完成 1 / 2'), findsOneWidget);
    expect(find.text('1/3'), findsOneWidget);
    expect(find.text('秋日歌单分享'), findsOneWidget);
    expect(find.text('去发帖'), findsOneWidget);
    expect(find.text('领取'), findsOneWidget);

    await tester.tap(find.text('领取'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(claimCalls, 1);
    expect(find.text('已领取'), findsOneWidget);

    expect(find.text('每日签到'), findsOneWidget);
    await tester.tap(find.text('签到'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(signinCalls, 1);
    expect(find.text('今日已签到'), findsOneWidget);

    // 320 窄屏同样不能溢出。
    tester.view.physicalSize = const Size(320 * 2, 700 * 2);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
  });
}
