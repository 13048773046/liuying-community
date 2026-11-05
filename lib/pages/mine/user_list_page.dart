/// 关注 / 粉丝列表页（对齐概念稿：统计行可点击进入）
library;

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../config.dart';
import '../../design/components.dart';
import '../user/user_profile.dart';

class UserListPage extends StatefulWidget {
  final String uid;
  final String kind; // followings | followers
  final String title;
  const UserListPage(
      {super.key, required this.uid, required this.kind, required this.title});

  @override
  State<UserListPage> createState() => _UserListPageState();
}

class _UserListPageState extends State<UserListPage> {
  final List<Map<String, dynamic>> _items = [];
  bool _loading = false;
  bool _loaded = false;
  bool _hasMore = true;
  int _page = 0;
  final Set<String> _following = {};

  @override
  void initState() {
    super.initState();
    _load(refresh: true);
  }

  Future<void> _load({bool refresh = false}) async {
    if (_loading || (!_hasMore && !refresh)) return;
    setState(() => _loading = true);
    try {
      final j = await ApiClient.userList(widget.uid,
          kind: widget.kind, page: refresh ? 1 : _page + 1, size: 20);
      if (!mounted) return;
      setState(() {
        if (refresh) {
          _items.clear();
          _page = 0;
          _following.clear();
        }
        _page++;
        _hasMore = boolOf(j['hasMore']);
        _items.addAll(((j['list'] ?? []) as List)
            .whereType<Map<String, dynamic>>());
        for (final u in _items) {
          if (boolOf(u['following'])) _following.add((u['id'] ?? '') as String);
        }
        _loaded = true;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loaded = true;
        _loading = false;
      });
    }
  }

  bool boolOf(Object? v) =>
      v == true || v == 1 || (v is String && v.toLowerCase() == 'true');

  Future<void> _toggle(String uid) async {
    try {
      await ApiClient.toggleFollow(uid);
      if (!mounted) return;
      setState(() {
        if (_following.contains(uid)) {
          _following.remove(uid);
        } else {
          _following.add(uid);
        }
      });
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return ImmersivePage(
      child: Column(
        children: [
          GlassTopBar(title: widget.title, solid: true),
          Expanded(
            child: !_loaded
                ? const Center(
                    child: CircularProgressIndicator(strokeWidth: 2.4))
                : _items.isEmpty
                    ? _empty()
                    : _list(),
          ),
        ],
      ),
    );
  }

  Widget _empty() {
    return RefreshIndicator(
      color: const Color(AppColors.accent),
      backgroundColor: const Color(AppColors.elevated),
      onRefresh: () => _load(refresh: true),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(
          AppSpace.gutter,
          AppSpace.x8,
          AppSpace.gutter,
          AppSpace.x6 + MediaQuery.paddingOf(context).bottom,
        ),
        children: [
          EmptyState(
            icon: widget.kind == 'followings'
                ? Icons.person_add_alt_outlined
                : Icons.person_outline_rounded,
            title: widget.kind == 'followings' ? '还没有关注任何人' : '还没有粉丝',
            message: widget.kind == 'followings'
                ? '去发现页找找感兴趣的作者吧'
                : '发布优质内容，会有人循着光找到你',
          ),
        ],
      ),
    );
  }

  Widget _list() {
    return RefreshIndicator(
      color: const Color(AppColors.accent),
      backgroundColor: const Color(AppColors.elevated),
      onRefresh: () => _load(refresh: true),
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n.metrics.extentAfter < 300) _load();
          return false;
        },
        child: ListView.separated(
          physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics(),
          ),
          padding: EdgeInsets.fromLTRB(
            AppSpace.gutter,
            AppSpace.x2,
            AppSpace.gutter,
            AppSpace.x6 + MediaQuery.paddingOf(context).bottom,
          ),
          itemCount: _items.length + (_hasMore ? 1 : 0),
          separatorBuilder: (_, _) => const SizedBox(height: AppSpace.listGap),
          itemBuilder: (_, i) {
            if (i >= _items.length) {
              return const LoadMoreFooter(loading: true);
            }
            return _userCard(_items[i]);
          },
        ),
      ),
    );
  }

  Widget _userCard(Map<String, dynamic> u) {
    final uid = (u['id'] ?? '') as String;
    final name = (u['name'] ?? '用户') as String;
    final avatar = (u['avatar'] ?? '') as String;
    final signature = (u['signature'] ?? '') as String;
    final following = _following.contains(uid);
    final isSelf = uid == ApiClient.userId;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: const Color(AppColors.card),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: const Color(AppColors.border)),
      ),
      child: ListRow(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpace.x3,
          vertical: AppSpace.x3,
        ),
        showChevron: false,
        leading: AppAvatar(
          url: avatarUrl(avatar),
          name: name,
          size: 44,
        ),
        title: name,
        subtitle: signature.isEmpty ? null : signature,
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => UserProfilePage(uid: uid)),
        ),
        trailing: isSelf
            ? null
            : PillButton(
                label: following ? '已关注' : '关注',
                icon: following ? null : Icons.add_rounded,
                size: PillSize.sm,
                variant: following ? PillVariant.ghost : PillVariant.primary,
                onTap: () => _toggle(uid),
              ),
      ),
    );
  }
}
