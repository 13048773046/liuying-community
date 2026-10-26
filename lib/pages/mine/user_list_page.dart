/// 关注 / 粉丝列表页（对齐概念稿：统计行可点击进入）
library;

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../config.dart';
import '../../widgets/user_avatar.dart';
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
    return Scaffold(
      backgroundColor: const Color(AppTheme.bg),
      appBar: AppBar(
        backgroundColor: const Color(AppTheme.bg),
        foregroundColor: const Color(AppTheme.textPrimary),
        elevation: 0,
        title: Text(widget.title,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
      ),
      body: !_loaded
          ? const Center(
              child: CircularProgressIndicator(
                  color: Color(AppTheme.accent), strokeWidth: 2.5))
          : _items.isEmpty
              ? ListView(
                    padding: EdgeInsets.only(bottom: 24+ MediaQuery.paddingOf(context).bottom),
                  children: [
                    const SizedBox(height: 120),
                    Icon(widget.kind == 'followings'
                        ? Icons.person_add_alt_outlined
                        : Icons.person_outline,
                        size: 52, color: const Color(AppTheme.textTertiary)),
                    const SizedBox(height: 10),
                    Center(
                      child: Text(
                        widget.kind == 'followings' ? '还没有关注任何人' : '还没有粉丝',
                        style: const TextStyle(
                            color: Color(AppTheme.textSecondary),
                            fontSize: 13.5),
                      ),
                    ),
                  ],
                )
              : RefreshIndicator(
                  color: const Color(AppTheme.accent),
                  backgroundColor: const Color(AppTheme.card),
                  onRefresh: () => _load(refresh: true),
                  child: NotificationListener<ScrollNotification>(
                    onNotification: (n) {
                      if (n.metrics.extentAfter < 300) _load();
                      return false;
                    },
                    child: ListView.separated(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                      itemCount: _items.length + (_hasMore ? 1 : 0),
                      separatorBuilder: (_, _) => const SizedBox(height: 12),
                      itemBuilder: (_, i) {
                        if (i >= _items.length) {
                          return const Padding(
                            padding: EdgeInsets.symmetric(vertical: 14),
                            child: Center(
                              child: SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Color(AppTheme.accent)),
                              ),
                            ),
                          );
                        }
                        final u = _items[i];
                        final uid = (u['id'] ?? '') as String;
                        final name = (u['name'] ?? '用户') as String;
                        final avatar = (u['avatar'] ?? '') as String;
                        final signature = (u['signature'] ?? '') as String;
                        final following = _following.contains(uid);
                        final isSelf = uid == ApiClient.userId;
                        return GestureDetector(
                          onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) =>
                                      UserProfilePage(uid: uid))),
                          child: Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: const Color(AppTheme.card),
                              borderRadius:
                                  BorderRadius.circular(AppTheme.radiusCard),
                            ),
                            child: Row(
                              children: [
                                ClipOval(
                                  child: UserAvatar(url: avatar, size: 44),
                                ),
                                const SizedBox(width: 11),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(name,
                                          style: const TextStyle(
                                              color: Color(AppTheme.textPrimary),
                                              fontSize: 14.5,
                                              fontWeight: FontWeight.w500)),
                                      if (signature.isNotEmpty)
                                        Padding(
                                          padding:
                                              const EdgeInsets.only(top: 2),
                                          child: Text(signature,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                  color:
                                                      Color(AppTheme.textTertiary),
                                                  fontSize: 11.5)),
                                        ),
                                    ],
                                  ),
                                ),
                                if (!isSelf)
                                  GestureDetector(
                                    onTap: () => _toggle(uid),
                                    child: Container(
                                      width: 66,
                                      height: 30,
                                      alignment: Alignment.center,
                                      decoration: BoxDecoration(
                                        color: following
                                            ? Colors.transparent
                                            : const Color(AppTheme.accent),
                                        borderRadius: BorderRadius.circular(
                                            AppTheme.radiusPill),
                                        border: following
                                            ? Border.all(
                                                color: const Color(
                                                    AppTheme.border))
                                            : null,
                                      ),
                                      child: Text(
                                        following ? '已关注' : '+ 关注',
                                        style: TextStyle(
                                            color: following
                                                ? const Color(
                                                    AppTheme.textSecondary)
                                                : Colors.black,
                                            fontSize: 12.5,
                                            fontWeight: FontWeight.w600),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
    );
  }
}
