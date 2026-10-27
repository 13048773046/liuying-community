/// 排行榜页：热帖 / 话题榜 / 达人榜 三个 Tab
library;

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../config.dart';
import '../../models/feed_item.dart';
import '../../widgets/user_avatar.dart';
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
    return Scaffold(
      backgroundColor: const Color(AppTheme.bg),
      appBar: AppBar(
        backgroundColor: const Color(AppTheme.bg),
        elevation: 0,
        centerTitle: true,
        title: const Text('排行榜',
            style: TextStyle(
                color: Color(AppTheme.textPrimary),
                fontSize: 16,
                fontWeight: FontWeight.w600)),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded,
              color: Colors.white, size: 18),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: Column(
        children: [
          // Tab
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
            child: Row(
              children: [
                for (final (label, v) in [
                  ('热帖榜', 0),
                  ('话题榜', 1),
                  ('达人榜', 2),
                ])
                  Expanded(
                    child: GestureDetector(
                      onTap: () => setState(() => _tab = v),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: _tab == v
                              ? const Color(AppTheme.accent)
                                  .withValues(alpha: 0.14)
                              : Colors.transparent,
                          borderRadius:
                              BorderRadius.circular(AppTheme.radiusPill),
                        ),
                        child: Text(label,
                            style: TextStyle(
                              color: _tab == v
                                  ? const Color(AppTheme.accent)
                                  : const Color(AppTheme.textSecondary),
                              fontSize: 13.5,
                              fontWeight: _tab == v
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                            )),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const Divider(
              height: 1, color: Color(AppTheme.border), thickness: 0.5),
          Expanded(
            child: _loading
                ? const Center(
                    child: CircularProgressIndicator(
                        color: Color(AppTheme.accent), strokeWidth: 2.5))
                : switch (_tab) {
                    0 => _postList(),
                    1 => _topicList(),
                    _ => _userList(),
                  },
          ),
        ],
      ),
    );
  }

  // ---------- 热帖榜 ----------
  Widget _postList() {
    if (_posts.isEmpty) {
      return const Center(
          child: Text('暂无数据',
              style: TextStyle(color: Color(AppTheme.textSecondary))));
    }
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: _posts.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (_, i) {
        final p = _posts[i];
        return GestureDetector(
          onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => PostDetailPage(postId: p.id))),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(AppTheme.card),
              borderRadius: BorderRadius.circular(AppTheme.radiusCard),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 名次
                SizedBox(
                  width: 30,
                  child: Text(
                    '${i + 1}',
                    style: TextStyle(
                      color: i < 3
                          ? const Color(0xFFFFB84D)
                          : const Color(AppTheme.textTertiary),
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        p.content.isEmpty ? '（无文字内容）' : p.content,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Color(AppTheme.textPrimary),
                            fontSize: 14,
                            height: 1.3),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          UserAvatar(
                              url: p.author.avatar,
                              name: p.author.name,
                              size: 16),
                          const SizedBox(width: 5),
                          Expanded(
                            child: Text(p.author.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    color: Color(AppTheme.textTertiary),
                                    fontSize: 11)),
                          ),
                          Text(
                            '${_fmt(p.likeCount)} 赞',
                            style: const TextStyle(
                                color: Color(AppTheme.textTertiary),
                                fontSize: 11),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ---------- 话题榜 ----------
  Widget _topicList() {
    if (_topics.isEmpty) {
      return const Center(
          child: Text('暂无数据',
              style: TextStyle(color: Color(AppTheme.textSecondary))));
    }
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: _topics.length,
      separatorBuilder: (_, __) => const Divider(
          height: 1, color: Color(AppTheme.border), thickness: 0.5),
      itemBuilder: (_, i) {
        final t = _topics[i];
        final name = (t['name'] ?? '') as String;
        final count = ((t['count'] ?? 0) as num).toInt();
        return GestureDetector(
          onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) =>
                      TopicDetailPage(topic: name, count: count))),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(
              children: [
                SizedBox(
                  width: 30,
                  child: Text(
                    '${i + 1}',
                    style: TextStyle(
                      color: i < 3
                          ? const Color(0xFFFFB84D)
                          : const Color(AppTheme.textTertiary),
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                Expanded(
                  child: Text('#$name',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Color(AppTheme.textPrimary),
                          fontSize: 14,
                          fontWeight: FontWeight.w600)),
                ),
                Text('$_fmt(count) 帖',
                    style: const TextStyle(
                        color: Color(AppTheme.textTertiary), fontSize: 12)),
              ],
            ),
          ),
        );
      },
    );
  }

  // ---------- 达人榜 ----------
  Widget _userList() {
    if (_users.isEmpty) {
      return const Center(
          child: Text('暂无数据',
              style: TextStyle(color: Color(AppTheme.textSecondary))));
    }
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: _users.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (_, i) {
        final u = (_users[i]['user'] ?? {}) as Map<String, dynamic>;
        final uid = (u['id'] ?? '') as String;
        final name = (u['name'] ?? '') as String;
        final avatar = (u['avatar'] ?? '') as String;
        final exp = ((_users[i]['exp'] ?? 0) as num).toInt();
        final lv = ((_users[i]['level'] ?? 0) as num).toInt();
        return GestureDetector(
          onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => UserProfilePage(uid: uid))),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(AppTheme.card),
              borderRadius: BorderRadius.circular(AppTheme.radiusCard),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 30,
                  child: Text(
                    '${i + 1}',
                    style: TextStyle(
                      color: i < 3
                          ? const Color(0xFFFFB84D)
                          : const Color(AppTheme.textTertiary),
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                UserAvatar(url: avatar, name: name, size: 42),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14.5,
                              fontWeight: FontWeight.w600)),
                      const SizedBox(height: 2),
                      Text('LV.$lv · ${_fmt(exp)} 经验',
                          style: const TextStyle(
                              color: Color(AppTheme.textTertiary),
                              fontSize: 11)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _fmt(int n) {
    if (n >= 10000) {
      final w = n / 10000;
      return w >= 100
          ? '${w.toStringAsFixed(0)}万'
          : '${w.toStringAsFixed(1)}万';
    }
    return '$n';
  }
}
