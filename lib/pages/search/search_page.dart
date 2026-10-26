/// 搜索页（概念稿对齐）：搜索框 + 历史/热门 + 实时联想 + 帖子/用户/话题结果
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../api/client.dart';
import '../../config.dart';
import '../../models/feed_item.dart';
import '../../widgets/user_avatar.dart';
import '../post/post_detail.dart';
import '../user/user_profile.dart';

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();
  Timer? _debounce;

  // 联想
  List<String> _sugTopics = [];
  List<Map<String, dynamic>> _sugUsers = [];
  bool _suggesting = false;

  // 结果
  bool _searched = false;
  bool _searching = false;
  List<FeedItem> _postResults = [];
  List<Map<String, dynamic>> _userResults = [];
  List<Map<String, dynamic>> _topicResults = [];

  // 历史 + 热门
  List<String> _history = [];
  List<String> _hot = [];

  static const _historyKey = 'search_history';

  @override
  void initState() {
    super.initState();
    _loadHistory();
    _loadHot();
    Future.microtask(() => _focus.requestFocus());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    final sp = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => _history = sp.getStringList(_historyKey) ?? []);
  }

  Future<void> _loadHot() async {
    try {
      final list = await ApiClient.searchHot();
      if (!mounted) return;
      setState(() =>
          _hot = list.map((e) => (e['q'] ?? '') as String).where((s) => s.isNotEmpty).toList());
    } catch (_) {}
  }

  void _onChanged(String q) {
    _debounce?.cancel();
    final kw = q.trim();
    if (kw.isEmpty) {
      if (mounted && _suggesting) setState(() => _suggesting = false);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 280), () async {
      try {
        final j = await ApiClient.searchSuggest(kw);
        if (!mounted || _ctrl.text.trim() != kw) return;
        setState(() {
          _suggesting = true;
          _searched = false;
          _sugTopics =
              ((j['topics'] ?? []) as List).whereType<String>().toList();
          _sugUsers = ((j['users'] ?? []) as List)
              .whereType<Map<String, dynamic>>()
              .toList();
        });
      } catch (_) {}
    });
  }

  Future<void> _submit(String q) async {
    final kw = q.trim();
    if (kw.isEmpty) return;
    _focus.unfocus();
    setState(() {
      _searched = true;
      _searching = true;
      _suggesting = false;
      _postResults = [];
      _userResults = [];
      _topicResults = [];
    });
    // 记录历史
    final sp = await SharedPreferences.getInstance();
    final hist = [kw, ..._history.where((h) => h != kw)].take(10).toList();
    await sp.setStringList(_historyKey, hist);
    if (mounted) setState(() => _history = hist);
    try {
      final j = await ApiClient.search(kw);
      if (!mounted) return;
      setState(() {
        _postResults = [
          ...(((j['posts'] ?? []) as List)
              .whereType<Map<String, dynamic>>()
              .map(FeedItem.fromJson)),
          ...(((j['videos'] ?? []) as List)
              .whereType<Map<String, dynamic>>()
              .map(FeedItem.fromJson)),
        ];
        _userResults = ((j['users'] ?? []) as List)
            .whereType<Map<String, dynamic>>()
            .toList();
        _topicResults = ((j['topics'] ?? []) as List)
            .whereType<Map<String, dynamic>>()
            .toList();
        _searching = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _searching = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('搜索失败：$e'),
        backgroundColor: const Color(AppTheme.card),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(AppTheme.bg),
      appBar: AppBar(
        backgroundColor: const Color(AppTheme.bg),
        elevation: 0,
        leadingWidth: 48,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back,
              color: Color(AppTheme.textPrimary)),
          onPressed: () => Navigator.pop(context),
        ),
        titleSpacing: 0,
        title: Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: const Color(AppTheme.card),
            borderRadius: BorderRadius.circular(AppTheme.radiusPill),
          ),
          child: Row(
            children: [
              const Icon(Icons.search,
                  color: Color(AppTheme.textSecondary), size: 19),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _ctrl,
                  focusNode: _focus,
                  style: const TextStyle(
                      color: Color(AppTheme.textPrimary), fontSize: 14.5),
                  cursorColor: const Color(AppTheme.accent),
                  textInputAction: TextInputAction.search,
                  onChanged: _onChanged,
                  onSubmitted: _submit,
                  decoration: const InputDecoration(
                    isCollapsed: true,
                    border: InputBorder.none,
                    hintText: '搜索帖子、用户、话题…',
                    hintStyle: TextStyle(
                        color: Color(AppTheme.textTertiary), fontSize: 14),
                  ),
                ),
              ),
              if (_ctrl.text.isNotEmpty)
                GestureDetector(
                  onTap: () {
                    _ctrl.clear();
                    _debounce?.cancel();
                    setState(() {
                      _suggesting = false;
                      _searched = false;
                    });
                    _focus.requestFocus();
                  },
                  child: const Icon(Icons.cancel,
                      color: Color(AppTheme.textTertiary), size: 16),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消',
                style: TextStyle(
                    color: Color(AppTheme.textSecondary), fontSize: 14)),
          ),
        ],
      ),
      body: _body(),
    );
  }

  Widget _body() {
    if (_searched) return _resultView();
    if (_suggesting) return _suggestView();
    return _defaultView();
  }

  // ---------- 默认：历史 + 热门 ----------
  Widget _defaultView() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        if (_history.isNotEmpty) ...[
          const Text('搜索历史',
              style: TextStyle(
                  color: Color(AppTheme.textPrimary),
                  fontSize: 15,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final h in _history)
                GestureDetector(
                  onTap: () {
                    _ctrl.text = h;
                    _submit(h);
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 13, vertical: 7),
                    decoration: BoxDecoration(
                      color: const Color(AppTheme.card),
                      borderRadius:
                          BorderRadius.circular(AppTheme.radiusPill),
                    ),
                    child: Text(h,
                        style: const TextStyle(
                            color: Color(AppTheme.textPrimary),
                            fontSize: 12.5)),
                  ),
                ),
              GestureDetector(
                onTap: () async {
                  final sp = await SharedPreferences.getInstance();
                  await sp.remove(_historyKey);
                  if (mounted) setState(() => _history = []);
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 13, vertical: 7),
                  decoration: BoxDecoration(
                    color: Colors.transparent,
                    borderRadius:
                        BorderRadius.circular(AppTheme.radiusPill),
                    border:
                        Border.all(color: const Color(AppTheme.border)),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.delete_outline,
                          size: 13, color: Color(AppTheme.textTertiary)),
                      SizedBox(width: 4),
                      Text('清空',
                          style: TextStyle(
                              color: Color(AppTheme.textTertiary),
                              fontSize: 12)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
        if (_hot.isNotEmpty) ...[
          const SizedBox(height: 28),
          const Text('热门搜索',
              style: TextStyle(
                  color: Color(AppTheme.textPrimary),
                  fontSize: 15,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var i = 0; i < _hot.length; i++)
                GestureDetector(
                  onTap: () {
                    _ctrl.text = _hot[i];
                    _submit(_hot[i]);
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 13, vertical: 7),
                    decoration: BoxDecoration(
                      color: const Color(AppTheme.card),
                      borderRadius:
                          BorderRadius.circular(AppTheme.radiusPill),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('${i + 1}',
                            style: TextStyle(
                                color: i < 3
                                    ? const Color(AppTheme.accent)
                                    : const Color(AppTheme.textTertiary),
                                fontSize: 12,
                                fontWeight: FontWeight.bold)),
                        const SizedBox(width: 6),
                        Text(_hot[i],
                            style: const TextStyle(
                                color: Color(AppTheme.textPrimary),
                                fontSize: 12.5)),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ],
        if (_history.isEmpty && _hot.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 120),
            child: Column(
              children: [
                const Icon(Icons.search,
                    size: 52, color: Color(AppTheme.textTertiary)),
                const SizedBox(height: 10),
                const Text('搜索感兴趣的内容',
                    style: TextStyle(
                        color: Color(AppTheme.textSecondary),
                        fontSize: 13.5)),
              ],
            ),
          ),
      ],
    );
  }

  // ---------- 联想 ----------
  Widget _suggestView() {
    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      children: [
        for (final t in _sugTopics)
          _suggestTile(Icons.tag, '#$t', () => _submit(t)),
        for (final u in _sugUsers)
          _suggestTile(
              Icons.person_outline,
              (u['name'] ?? '') as String,
              () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => UserProfilePage(
                          uid: (u['id'] ?? '') as String)))),
      ],
    );
  }

  Widget _suggestTile(IconData icon, String text, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Row(
          children: [
            Icon(icon, color: const Color(AppTheme.textTertiary), size: 18),
            const SizedBox(width: 12),
            Expanded(
              child: Text(text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Color(AppTheme.textPrimary), fontSize: 14)),
            ),
            const Icon(Icons.north_west,
                color: Color(AppTheme.textTertiary), size: 15),
          ],
        ),
      ),
    );
  }

  // ---------- 搜索结果 ----------
  Widget _resultView() {
    if (_searching) {
      return const Center(
          child: CircularProgressIndicator(
              color: Color(AppTheme.accent), strokeWidth: 2.5));
    }
    final empty = _postResults.isEmpty &&
        _userResults.isEmpty &&
        _topicResults.isEmpty;
    if (empty) {
      return ListView(
        children: [
          const SizedBox(height: 120),
          const Icon(Icons.search_off,
              size: 52, color: Color(AppTheme.textTertiary)),
          const SizedBox(height: 10),
          const Center(
            child: Text('没有找到相关内容\n换个关键词试试吧',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: Color(AppTheme.textSecondary),
                    fontSize: 13.5,
                    height: 1.6)),
          ),
        ],
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        if (_userResults.isNotEmpty) ...[
          _sectionTitle('用户'),
          for (final u in _userResults) _userTile(u),
        ],
        if (_topicResults.isNotEmpty) ...[
          _sectionTitle('话题'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final t in _topicResults)
                GestureDetector(
                  onTap: () => _submit((t['name'] ?? '') as String),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(AppTheme.accent)
                          .withValues(alpha: 0.12),
                      borderRadius:
                          BorderRadius.circular(AppTheme.radiusPill),
                    ),
                    child: Text('#${t['name'] ?? ''}',
                        style: const TextStyle(
                            color: Color(AppTheme.accent), fontSize: 12.5)),
                  ),
                ),
            ],
          ),
        ],
        if (_postResults.isNotEmpty) ...[
          _sectionTitle('帖子'),
          for (final it in _postResults) _postTile(it),
        ],
      ],
    );
  }

  Widget _sectionTitle(String t) {
    return Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 8),
      child: Text(t,
          style: const TextStyle(
              color: Color(AppTheme.textPrimary),
              fontSize: 14.5,
              fontWeight: FontWeight.w600)),
    );
  }

  Widget _userTile(Map<String, dynamic> u) {
    final name = (u['name'] ?? '用户') as String;
    final avatar = (u['avatar'] ?? '') as String;
    final bio = (u['bio'] ?? '') as String;
    final followers = ((u['followers'] ?? 0) as num).toInt();
    return GestureDetector(
      onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => UserProfilePage(uid: (u['id'] ?? '') as String))),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            ClipOval(
              child: UserAvatar(url: avatar, size: 46),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name,
                      style: const TextStyle(
                          color: Color(AppTheme.textPrimary),
                          fontSize: 14.5,
                          fontWeight: FontWeight.w500)),
                  if (bio.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(bio,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Color(AppTheme.textTertiary),
                              fontSize: 12)),
                    ),
                ],
              ),
            ),
            if (followers > 0)
              Text('${_cnt(followers)} 粉丝',
                  style: const TextStyle(
                      color: Color(AppTheme.textTertiary), fontSize: 12)),
          ],
        ),
      ),
    );
  }

  Widget _postTile(FeedItem it) {
    final thumb = (it.type == 'video' && it.cover.isNotEmpty)
        ? it.cover
        : (it.images.isNotEmpty ? it.images.first : '');
    return GestureDetector(
      onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => PostDetailPage(postId: it.id))),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(AppTheme.card),
          borderRadius: BorderRadius.circular(AppTheme.radiusCard),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (thumb.isNotEmpty)
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: SizedBox(
                  width: 82,
                  height: 82,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Image.network(
                        thumb.startsWith('http')
                            ? thumb
                            : avatarUrl(thumb),
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => Container(
                            color: const Color(AppTheme.elevated)),
                      ),
                      if (it.type == 'video')
                        const Center(
                          child: Icon(Icons.play_circle_fill,
                              color: Colors.white, size: 26),
                        ),
                    ],
                  ),
                ),
              ),
            if (thumb.isNotEmpty) const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(it.content,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Color(AppTheme.textPrimary),
                          fontSize: 13.5,
                          height: 1.4)),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      ClipOval(child: UserAvatar(url: it.author.avatar, size: 18)),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(it.author.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Color(AppTheme.textSecondary),
                                fontSize: 11.5)),
                      ),
                      const Icon(Icons.favorite,
                          size: 12, color: Color(AppTheme.heart)),
                      const SizedBox(width: 3),
                      Text(_cnt(it.likeCount),
                          style: const TextStyle(
                              color: Color(AppTheme.textTertiary),
                              fontSize: 11.5)),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _cnt(int n) {
    if (n >= 10000) {
      final w = n / 10000;
      return w >= 100 ? '${w.toStringAsFixed(0)}万' : '${w.toStringAsFixed(1)}万';
    }
    return '$n';
  }
}
