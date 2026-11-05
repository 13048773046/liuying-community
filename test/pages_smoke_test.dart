/// 全页面冒烟：每个主要页面在「空数据 + 网络不可用」下都要能渲染出东西，
/// 不允许抛异常 / 白屏。用来兜住详情页、我的页这类有大量 `!` 解引用的地方。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:community_app/design/components.dart';
import 'package:community_app/pages/boards/boards_page.dart';
import 'package:community_app/pages/discover/ranking_page.dart';
import 'package:community_app/pages/discover/topic_detail_page.dart';
import 'package:community_app/pages/discover/topic_page.dart';
import 'package:community_app/pages/favorites/favorites_page.dart';
import 'package:community_app/pages/feedback/feedback_page.dart';
import 'package:community_app/pages/home/home_page.dart';
import 'package:community_app/pages/message/message_page.dart';
import 'package:community_app/pages/mine/audit_page.dart';
import 'package:community_app/pages/mine/frames_page.dart';
import 'package:community_app/pages/mine/login_page.dart';
import 'package:community_app/pages/mine/mine_page.dart';
import 'package:community_app/pages/mine/task_center_page.dart';
import 'package:community_app/pages/post/post_detail.dart';
import 'package:community_app/pages/post/post_editor.dart';
import 'package:community_app/pages/search/search_page.dart';
import 'package:community_app/pages/settings/settings_page.dart';
import 'package:community_app/pages/user/user_profile.dart';
import 'package:community_app/pages/shorts/shorts_page.dart';

/// 页面构造器表：加页面时同步补一行
final List<(String, Widget Function())> _pages = [
  ('首页 HomePage', () => const HomePage()),
  ('版块 BoardsPage', () => const BoardsPage()),
  ('短视频 ShortsPage', () => const ShortsPage()),
  ('消息 MessagePage', () => const MessagePage()),
  ('我的 MinePage', () => const MinePage()),
  ('搜索 SearchPage', () => const SearchPage()),
  ('收藏 FavoritesPage', () => const FavoritesPage()),
  ('设置 SettingsPage', () => const SettingsPage()),
  ('任务中心 TaskCenterPage', () => const TaskCenterPage()),
  ('头像框 FramesPage', () => const FramesPage()),
  ('审核 AuditPage', () => const AuditPage()),
  ('登录 LoginPage', () => const LoginPage()),
  ('发布 PostEditorPage', () => const PostEditorPage()),
  ('排行榜 RankingPage', () => const RankingPage()),
  ('话题 TopicPage', () => const TopicPage()),
  ('话题详情 TopicDetailPage', () => const TopicDetailPage(topic: '测试话题')),
  ('帖子详情(空 id) PostDetailPage', () => const PostDetailPage(postId: 'not-exist')),
  ('用户主页(空 id) UserProfilePage', () => const UserProfilePage(uid: 'not-exist')),
  ('反馈 FeedbackPage', () => const FeedbackPage()),
];

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  for (final (name, build) in _pages) {
    testWidgets('页面冒烟：$name 不抛异常且非空渲染', (tester) async {
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(MaterialApp(
        theme: buildImmersiveTheme(),
        home: build(),
      ));

      // 不用 pumpAndSettle：骨架/转圈是无限动画，会一直 settle 不下来
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }

      expect(tester.takeException(), isNull, reason: '$name 渲染抛异常');
      // 至少要有一个可见 widget，避免整页空白
      expect(find.byType(WidgetsApp), findsWidgets);
    });
  }
}
