/// 用户主页（P0）：认证头衔/头像框/等级 + 关注关系 + 帖子与短视频列表
library;

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../config.dart';
import '../../models/feed_item.dart';
import '../post/post_detail.dart';
import '../../widgets/image_box.dart';
import '../message/dm_chat_page.dart';

class UserProfilePage extends StatefulWidget {
  final String uid;
  const UserProfilePage({super.key, required this.uid});

  @override
  State<UserProfilePage> createState() => _UserProfilePageState();
}

class _UserProfilePageState extends State<UserProfilePage> {
  Map<String, dynamic>? _user;
  bool _loading = true;
  String _tab = 'text'; // text=图文 | video=短视频
  List<FeedItem> _items = [];
  int _page = 0;
  bool _hasMore = false;
  bool _listLoading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final j = await ApiClient.userProfile(widget.uid);
      if (!mounted) return;
      setState(() {
        _user = Map<String, dynamic>.from(j['user'] as Map);
        _loading = false;
      });
      await _loadPosts(refresh: true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _loadPosts({bool refresh = false}) async {
    if (_listLoading || (!_hasMore && !refresh)) return;
    setState(() => _listLoading = true);
    try {
      final j = await ApiClient.get('/user/${widget.uid}/posts', query: {
        'type': _tab,
        'page': '${refresh ? 1 : _page + 1}',
        'size': '10',
      });
      if (!mounted) return;
      setState(() {
        final list = ((j['list'] ?? []) as List)
            .whereType<Map<String, dynamic>>()
            .map(FeedItem.fromJson)
            .toList();
        if (refresh) {
          _items = list;
          _page = 1;
        } else {
          _items.addAll(list);
          _page++;
        }
        _hasMore = boolOf(j['hasMore']);
        _listLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _listLoading = false);
    }
  }

  /// 打开与对方的私信聊天页（互关校验在服务端，未互关发送时提示）
  Future<void> _openDm() async {
    final u = _user;
    if (u == null) return;
    final peerName = (u['name'] ?? '') as String;
    final peerAvatar = (u['avatar'] ?? '') as String;
    await Navigator.of(context).push(
      MaterialPageRoute(
          builder: (_) => DmChatPage(
              peerId: widget.uid, peerName: peerName, peerAvatar: peerAvatar)),
    );
  }

  Future<void> _toggleFollow() async {
    try {
      final j = await ApiClient.toggleFollow(widget.uid);
      if (!mounted) return;
      setState(() {
        _user!['following'] = boolOf(j['following']);
        _user!['followers'] = (j['followers'] as num).toInt();
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('操作失败：$e'),
          backgroundColor: const Color(AppTheme.card)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(AppTheme.bg),
      appBar: AppBar(
        backgroundColor: const Color(AppTheme.bg),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Color(AppTheme.textPrimary)),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('个人主页',
            style: TextStyle(
                color: Color(AppTheme.textPrimary),
                fontSize: 16,
                fontWeight: FontWeight.w600)),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(
                  color: Color(AppTheme.accent), strokeWidth: 2.5))
          : _user == null
              ? const Center(
                  child: Text('用户不存在',
                      style: TextStyle(color: Color(AppTheme.textSecondary))))
              : RefreshIndicator(
                  color: const Color(AppTheme.accent),
                  backgroundColor: const Color(AppTheme.card),
                  onRefresh: () => _load(),
                  child: ListView(
                    padding: EdgeInsets.fromLTRB(16, 8, 16, 20+ MediaQuery.paddingOf(context).bottom),
                    children: [
                      _header(),
                      const SizedBox(height: 18),
                      _tabBar(),
                      const SizedBox(height: 6),
                      if (_items.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 40),
                          child: Center(
                            child: Text(_listLoading ? '加载中…' : '还没有内容',
                                style: const TextStyle(
                                    color: Color(AppTheme.textTertiary),
                                    fontSize: 13)),
                          ),
                        )
                      else
                        ..._items.map(_postTile),
                      if (_hasMore)
                        GestureDetector(
                          onTap: () => _loadPosts(),
                          child: const Padding(
                            padding: EdgeInsets.symmetric(vertical: 16),
                            child: Center(
                              child: Text('加载更多',
                                  style: TextStyle(
                                      color: Color(AppTheme.textSecondary),
                                      fontSize: 13)),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
    );
  }

  Widget _header() {
    final u = _user!;
    final name = (u['name'] ?? '用户') as String;
    final avatar = (u['avatar'] ?? '') as String;
    final title = (u['title'] ?? '') as String;
    final frameId = (u['frameId'] ?? '') as String;
    final level = ((u['level'] ?? 0) as num).toInt();
    final followers = ((u['followers'] ?? 0) as num).toInt();
    final followings = ((u['followings'] ?? 0) as num).toInt();
    final following = boolOf(u['following']);
    return Column(
      children: [
        // 头像（带头像框）
        Container(
          padding: const EdgeInsets.all(2.5),
          decoration: BoxDecoration(
            border: frameId.isNotEmpty
                ? Border.all(color: const Color(AppTheme.accent), width: 2.5)
                : null,
            shape: BoxShape.circle,
          ),
          child: CircleAvatar(
            radius: 40,
            backgroundColor: const Color(AppTheme.card),
            backgroundImage:
                avatar.isNotEmpty ? NetworkImage(avatarUrl(avatar)) : null,
            child: avatar.isEmpty
                ? const Icon(Icons.person, size: 42, color: Color(AppTheme.textSecondary))
                : null,
          ),
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(name,
                style: const TextStyle(
                    color: Color(AppTheme.textPrimary),
                    fontSize: 19,
                    fontWeight: FontWeight.w600)),
            if (title.isNotEmpty) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(AppTheme.accentSoft),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                      color: const Color(AppTheme.accent), width: 0.8),
                ),
                child: Text(title,
                    style: const TextStyle(
                        color: Color(AppTheme.accent), fontSize: 11)),
              ),
            ],
          ],
        ),
        const SizedBox(height: 6),
        Text('Lv.$level · 流萤社区',
            style: const TextStyle(
                color: Color(AppTheme.textTertiary), fontSize: 13)),
        const SizedBox(height: 14),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _stat('关注', followings),
            _stat('粉丝', followers),
          ],
        ),
        const SizedBox(height: 16),
        // 关注 / 私信 按钮行
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            GestureDetector(
              onTap: _toggleFollow,
              child: Container(
                width: 100,
                padding: const EdgeInsets.symmetric(vertical: 9),
                decoration: BoxDecoration(
                  color: following
                      ? const Color(AppTheme.card)
                      : const Color(AppTheme.accent),
                  borderRadius: BorderRadius.circular(20),
                  border: following
                      ? Border.all(color: const Color(AppTheme.border))
                      : null,
                ),
                child: Center(
                  child: Text(following ? '已关注' : '+ 关注',
                      style: TextStyle(
                        color: following
                            ? const Color(AppTheme.textSecondary)
                            : Colors.black,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      )),
                ),
              ),
            ),
            const SizedBox(width: 10),
            GestureDetector(
              onTap: _openDm,
              child: Container(
                width: 100,
                padding: const EdgeInsets.symmetric(vertical: 9),
                decoration: BoxDecoration(
                  color: const Color(AppTheme.card),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: const Color(AppTheme.border)),
                ),
                child: const Center(
                  child: Text('私信',
                      style: TextStyle(
                          color: Color(AppTheme.textPrimary),
                          fontSize: 14,
                          fontWeight: FontWeight.bold)),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _stat(String label, int n) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: Column(
        children: [
          Text('$n',
              style: const TextStyle(
                  color: Color(AppTheme.textPrimary),
                  fontSize: 16,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text(label,
              style: const TextStyle(
                  color: Color(AppTheme.textTertiary), fontSize: 12)),
        ],
      ),
    );
  }

  Widget _tabBar() {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: const Color(AppTheme.card),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          _tabItem('text', '帖子'),
          _tabItem('video', '短视频'),
        ],
      ),
    );
  }

  Widget _tabItem(String t, String label) {
    final sel = _tab == t;
    return Expanded(
      child: GestureDetector(
        onTap: () {
          if (sel) return;
          setState(() {
            _tab = t;
            _items = [];
            _hasMore = false;
          });
          _loadPosts(refresh: true);
        },
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 7),
          decoration: BoxDecoration(
            color: sel ? const Color(AppTheme.accent) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Center(
            child: Text(label,
                style: TextStyle(
                  color: sel ? Colors.black : const Color(AppTheme.textSecondary),
                  fontSize: 13,
                  fontWeight: sel ? FontWeight.bold : FontWeight.normal,
                )),
          ),
        ),
      ),
    );
  }

  Widget _postTile(FeedItem item) {
    return GestureDetector(
      onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => PostDetailPage(postId: item.id))),
      child: Container(
        margin: const EdgeInsets.only(top: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(AppTheme.card),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item.content,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Color(AppTheme.textPrimary),
                          fontSize: 14,
                          height: 1.4)),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      if (item.topic.isNotEmpty)
                        Text('#${item.topic.first}  ',
                            style: const TextStyle(
                                color: Color(AppTheme.accent), fontSize: 12)),
                      Text('${item.likeCount} 赞 · ${item.commentCount} 评 · ${timeAgo(item.created)}',
                          style: const TextStyle(
                              color: Color(AppTheme.textTertiary), fontSize: 11)),
                    ],
                  ),
                ],
              ),
            ),
            if (item.images.isNotEmpty) ...[
              const SizedBox(width: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: CachedNetworkImageCompat(
                    url: mediaUrl(item.images.first),
                    width: 72,
                    height: 72,
                    fit: BoxFit.cover),
              ),
            ] else if (item.isVideo) ...[
              const SizedBox(width: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: CachedNetworkImageCompat(
                    url: mediaUrl(item.cover == 'auto'
                        ? '${item.video}.jpg'
                        : item.cover),
                    width: 72,
                    height: 72,
                    fit: BoxFit.cover),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
