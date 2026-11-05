/// 排行榜页：热帖 / 话题榜 / 达人榜 三个分段（[FeedTabs]）
///
/// 版式：前三名「大号数字 + 头像/标识行」，其余用 [ListRow] 紧凑列表。
library;

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../config.dart';
import '../../design/components.dart';
import '../../models/feed_item.dart';
import '../post/post_detail.dart';
import '../user/user_profile.dart';
import 'topic_detail_page.dart';

class RankingPage extends StatefulWidget {
  const RankingPage({super.key});

  @override
  State<RankingPage> createState() => _RankingPageState();
}

class _RankingPageState extends State<RankingPage> {
  int _tab = 0; // 0 热帖 | 1 话题榜 | 2 达人榜

  // 热帖
  List<FeedItem> _posts = [];
  bool _loading = true;
  // 话题
  List<Map<String, dynamic>> _topics = [];
  // 达人
  List<Map<String, dynamic>> _users = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final futures = <Future>[
        ApiClient.rankings('post', limit: 20),
        ApiClient.rankings('topic', limit: 20),
        ApiClient.rankings('user', limit: 20),
      ];
      final results = await Future.wait(futures);
      if (!mounted) return;
      setState(() {
        _posts = ((results[0]['list'] ?? []) as List)
            .whereType<Map<String, dynamic>>()
            .map(FeedItem.fromJson)
            .toList();
        _topics = ((results[1]['list'] ?? []) as List)
            .whereType<Map<String, dynamic>>()
            .toList();
        _users = ((results[2]['list'] ?? []) as List)
            .whereType<Map<String, dynamic>>()
            .toList();
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ImmersivePage(
      child: Column(
        children: [
          const GlassTopBar(title: '排行榜', solid: true),
          FeedTabs(
            labels: const ['热帖榜', '话题榜', '达人榜'],
            index: _tab,
            onChanged: (i) => setState(() => _tab = i),
          ),
          Expanded(child: _loading ? const _RankingSkeleton() : _body()),
        ],
      ),
    );
  }

  Widget _body() {
    return switch (_tab) {
      0 => _postList(),
      1 => _topicList(),
      _ => _userList(),
    };
  }

  // ---------------------------------------------------------------- 跳转
  void _openPost(FeedItem p) {
    Navigator.push(context,
        MaterialPageRoute(builder: (_) => PostDetailPage(postId: p.id)));
  }

  void _openTopic(Map<String, dynamic> t) {
    final name = (t['name'] ?? '') as String;
    final count = ((t['count'] ?? 0) as num).toInt();
    Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => TopicDetailPage(topic: name, count: count)),
    );
  }

  void _openUser(String uid) {
    Navigator.push(context,
        MaterialPageRoute(builder: (_) => UserProfilePage(uid: uid)));
  }

  // -------------------------------------------------------------- 热帖榜
  Widget _postList() {
    if (_posts.isEmpty) return _empty();
    final top = _posts.take(3).toList();
    return ListView(
      padding: _listPadding(context),
      children: [
        for (var i = 0; i < top.length; i++)
          _podiumRow(
            rank: i,
            leading: AppAvatar(
              url: avatarUrlOf(top[i].author.id),
              size: 44,
              name: top[i].author.name,
              ring: top[i].author.isAdmin,
            ),
            title: top[i].content.isEmpty ? '（无文字内容）' : top[i].content,
            subtitle:
                '${_authorName(top[i].author.name)} · ${formatCount(top[i].likeCount)} 赞',
            onTap: () => _openPost(top[i]),
          ),
        if (_posts.length > 3) ...[
          const Hairline(),
          for (var i = 3; i < _posts.length; i++)
            ListRow(
              leading: _rankNumber(i),
              title: _posts[i].content.isEmpty ? '（无文字内容）' : _posts[i].content,
              subtitle:
                  '${_authorName(_posts[i].author.name)} · ${formatCount(_posts[i].likeCount)} 赞',
              showChevron: false,
              padding: const EdgeInsets.symmetric(vertical: AppSpace.x3),
              onTap: () => _openPost(_posts[i]),
            ),
        ],
      ],
    );
  }

  // -------------------------------------------------------------- 话题榜
  Widget _topicList() {
    if (_topics.isEmpty) return _empty();
    final top = _topics.take(3).toList();
    return ListView(
      padding: _listPadding(context),
      children: [
        for (var i = 0; i < top.length; i++)
          _podiumRow(
            rank: i,
            leading: _hashTile(),
            title: '#${top[i]['name'] ?? ''}',
            subtitle:
                '${formatCount(((top[i]['count'] ?? 0) as num).toInt())} 帖参与',
            onTap: () => _openTopic(top[i]),
          ),
        if (_topics.length > 3) ...[
          const Hairline(),
          for (var i = 3; i < _topics.length; i++)
            ListRow(
              leading: _rankNumber(i),
              title: '#${_topics[i]['name'] ?? ''}',
              subtitle:
                  '${formatCount(((_topics[i]['count'] ?? 0) as num).toInt())} 帖参与',
              showChevron: false,
              padding: const EdgeInsets.symmetric(vertical: AppSpace.x3),
              onTap: () => _openTopic(_topics[i]),
            ),
        ],
      ],
    );
  }

  // -------------------------------------------------------------- 达人榜
  Widget _userList() {
    if (_users.isEmpty) return _empty();
    final top = _users.take(3).toList();
    return ListView(
      padding: _listPadding(context),
      children: [
        for (var i = 0; i < top.length; i++)
          _podiumRow(
            rank: i,
            leading: AppAvatar(
              url: avatarUrlOf(_uidOf(top[i])),
              size: 44,
              name: _nameOf(top[i]),
            ),
            title: _nameOf(top[i]),
            subtitle:
                'LV.${_levelOf(top[i])} · ${formatCount(_expOf(top[i]))} 经验',
            onTap: () => _openUser(_uidOf(top[i])),
          ),
        if (_users.length > 3) ...[
          const Hairline(),
          for (var i = 3; i < _users.length; i++)
            ListRow(
              leading: AppAvatar(
                url: avatarUrlOf(_uidOf(_users[i])),
                size: 40,
                name: _nameOf(_users[i]),
              ),
              title: _nameOf(_users[i]),
              subtitle:
                  'LV.${_levelOf(_users[i])} · ${formatCount(_expOf(_users[i]))} 经验',
              showChevron: false,
              padding: const EdgeInsets.symmetric(vertical: AppSpace.x3),
              onTap: () => _openUser(_uidOf(_users[i])),
            ),
        ],
      ],
    );
  }

  // ---------------------------------------------------------------- 原子件
  EdgeInsets _listPadding(BuildContext context) => EdgeInsets.fromLTRB(
        AppSpace.gutter,
        AppSpace.x4,
        AppSpace.gutter,
        MediaQuery.paddingOf(context).bottom + 28,
      );

  String _authorName(String name) => name.isEmpty ? '匿名用户' : name;

  String _uidOf(Map<String, dynamic> e) =>
      (((e['user'] ?? {}) as Map<String, dynamic>)['id'] ?? '') as String;

  String _nameOf(Map<String, dynamic> e) =>
      (((e['user'] ?? {}) as Map<String, dynamic>)['name'] ?? '') as String;

  int _levelOf(Map<String, dynamic> e) =>
      ((e['level'] ?? 0) as num).toInt();

  int _expOf(Map<String, dynamic> e) => ((e['exp'] ?? 0) as num).toInt();

  /// 前三名：大号数字 + 头像/标识行 + 标题/副标题
  Widget _podiumRow({
    required int rank,
    required Widget leading,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return PressableScale(
      onTap: onTap,
      scale: 0.98,
      child: Padding(
        padding: const EdgeInsets.only(bottom: AppSpace.x4),
        child: Row(
          children: [
            SizedBox(
              width: 42,
              child: Text(
                '${rank + 1}',
                style: AppType.h1.copyWith(
                  fontSize: 30,
                  height: 1,
                  color: rank == 0
                      ? const Color(AppColors.accent)
                      : const Color(AppColors.textPrimary),
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            const SizedBox(width: AppSpace.x1),
            leading,
            const SizedBox(width: AppSpace.x3),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.body,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.micro,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _rankNumber(int i) {
    return SizedBox(
      width: 26,
      child: Text(
        '${i + 1}',
        style: AppType.label.copyWith(
          color: const Color(AppColors.textTertiary),
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }

  Widget _hashTile() {
    return Container(
      width: 44,
      height: 44,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: const Color(AppColors.accent).withValues(alpha: 0.12),
        borderRadius: AppRadius.rSm,
      ),
      child: Text('#',
          style: AppType.h2.copyWith(color: const Color(AppColors.accent))),
    );
  }

  Widget _empty() => const Center(
        child: EmptyState(
          icon: Icons.leaderboard_outlined,
          title: '暂无数据',
          message: '榜单还在统计中，稍后再来看看',
        ),
      );
}

/// 首屏骨架：名次 + 文字的列表占位。
class _RankingSkeleton extends StatelessWidget {
  const _RankingSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
          AppSpace.gutter, AppSpace.x4, AppSpace.gutter, 0),
      physics: const NeverScrollableScrollPhysics(),
      children: [
        for (var i = 0; i < 6; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.x4),
            child: Row(
              children: const [
                SkeletonBox(width: 26, height: 26, radius: AppRadius.xs),
                SizedBox(width: AppSpace.x2),
                SkeletonBox(width: 44, height: 44, radius: 22),
                SizedBox(width: AppSpace.x3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SkeletonBox(height: 12),
                      SizedBox(height: AppSpace.x2),
                      SkeletonBox(width: 120, height: 10),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
