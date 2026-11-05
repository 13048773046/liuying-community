/// 用户主页（P0）：头像/昵称/签名/统计 + 关注关系 + 三列作品网格
///
/// 沉浸黑：顶部身份区（[AppAvatar] + [StatTile] + [PillButton]）→ 分段（帖子/短视频）
/// → 作品网格（[PostGridTile]）。请求、分页与关注逻辑保持原样。
library;

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../config.dart';
import '../../design/components.dart';
import '../../models/feed_item.dart';
import '../../widgets/post_card.dart';
import '../message/dm_chat_page.dart';
import '../post/post_detail.dart';

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
      showAppToast(context, '操作失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return ImmersivePage(
      child: Column(
        children: [
          const GlassTopBar(title: '个人主页', solid: true),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading) return const _ProfileSkeleton();
    if (_user == null) {
      return const Center(
        child: EmptyState(
          icon: Icons.person_off_outlined,
          title: '用户不存在',
          message: '该用户可能已注销或主页不可见',
        ),
      );
    }
    return RefreshIndicator(
      color: const Color(AppColors.accent),
      backgroundColor: const Color(AppColors.elevated),
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics()),
        padding: EdgeInsets.only(
            bottom: MediaQuery.paddingOf(context).bottom + 28),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpace.gutter),
            child: _header(),
          ),
          const SizedBox(height: AppSpace.x2),
          FeedTabs(
            labels: const ['帖子', '短视频'],
            index: _tab == 'text' ? 0 : 1,
            onChanged: _switchTab,
          ),
          const SizedBox(height: AppSpace.x2),
          _grid(),
        ],
      ),
    );
  }

  void _switchTab(int i) {
    final t = i == 0 ? 'text' : 'video';
    if (_tab == t) return;
    setState(() {
      _tab = t;
      _items = [];
      _hasMore = false;
    });
    _loadPosts(refresh: true);
  }

  // ------------------------------------------------------------------ 头部
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
    final gender = (u['gender'] ?? '') as String;
    final age = (u['age'] ?? 0) as num;
    final city = (u['city'] ?? '') as String;
    final signature = (u['signature'] ?? '') as String;
    final parts = <String>[];
    if (gender.isNotEmpty) parts.add(gender);
    if (age > 0) parts.add('$age岁');
    if (city.isNotEmpty) parts.add(city);
    final metaLine = parts.join(' · ');

    return Column(
      children: [
        const SizedBox(height: AppSpace.x5),
        AppAvatar(
          url: avatar.isEmpty ? null : avatarUrl(avatar),
          size: 84,
          name: name,
          ring: frameId.isNotEmpty,
        ),
        const SizedBox(height: AppSpace.x3),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppType.h2,
              ),
            ),
            if (title.isNotEmpty) ...[
              const SizedBox(width: AppSpace.x2),
              TagPill(label: title, compact: true),
            ],
          ],
        ),
        const SizedBox(height: AppSpace.x2),
        Text('Lv.$level · 流萤社区', style: AppType.caption),
        if (metaLine.isNotEmpty) ...[
          const SizedBox(height: 3),
          Text(metaLine, style: AppType.micro),
        ],
        if (signature.isNotEmpty) ...[
          const SizedBox(height: AppSpace.x2),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpace.x5),
            child: Text(
              signature,
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: AppType.bodySm,
            ),
          ),
        ],
        const SizedBox(height: AppSpace.x5),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            StatTile(value: '$followings', label: '关注'),
            const SizedBox(width: AppSpace.x8),
            StatTile(value: '$followers', label: '粉丝', highlight: true),
          ],
        ),
        const SizedBox(height: AppSpace.x5),
        Row(
          children: [
            Expanded(
              child: PillButton(
                label: following ? '已关注' : '关注',
                variant: following ? PillVariant.tonal : PillVariant.primary,
                expand: true,
                glow: !following,
                onTap: _toggleFollow,
              ),
            ),
            const SizedBox(width: AppSpace.x2),
            Expanded(
              child: PillButton(
                label: '私信',
                variant: PillVariant.ghost,
                icon: Icons.chat_bubble_outline_rounded,
                expand: true,
                onTap: _openDm,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpace.x4),
      ],
    );
  }

  // ------------------------------------------------------------------ 网格
  Widget _grid() {
    if (_items.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.gutter),
        child: EmptyState(
          icon: Icons.photo_library_outlined,
          title: _listLoading ? '加载中…' : '还没有内容',
          message: _tab == 'text' ? 'TA 还没有发布帖子' : 'TA 还没有发布短视频',
          compact: true,
        ),
      );
    }
    return Column(
      children: [
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.gutter),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            mainAxisSpacing: AppSpace.x2,
            crossAxisSpacing: AppSpace.x2,
            childAspectRatio: 0.78,
          ),
          itemCount: _items.length,
          itemBuilder: (context, i) => PostGridTile(
            item: _items[i],
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => PostDetailPage(postId: _items[i].id)),
            ),
            onAuthorTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) =>
                      UserProfilePage(uid: _items[i].author.id)),
            ),
          ),
        ),
        LoadMoreFooter(
          loading: _listLoading,
          hasMore: _hasMore,
          onTap: () => _loadPosts(),
          endLabel: '— 只有这些啦 —',
        ),
      ],
    );
  }
}

/// 首屏骨架：头像 + 文本行 + 网格占位。
class _ProfileSkeleton extends StatelessWidget {
  const _ProfileSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
          AppSpace.gutter, AppSpace.x6, AppSpace.gutter, 0),
      physics: const NeverScrollableScrollPhysics(),
      children: [
        const Center(
          child: SkeletonBox(width: 84, height: 84, radius: 42),
        ),
        const SizedBox(height: AppSpace.x3),
        const Center(child: SkeletonBox(width: 120, height: 18)),
        const SizedBox(height: AppSpace.x2),
        const Center(child: SkeletonBox(width: 80, height: 11)),
        const SizedBox(height: AppSpace.x5),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            mainAxisSpacing: AppSpace.x2,
            crossAxisSpacing: AppSpace.x2,
            childAspectRatio: 0.78,
          ),
          itemCount: 6,
          itemBuilder: (_, _) => const SkeletonBox(radius: AppRadius.sm),
        ),
      ],
    );
  }
}
