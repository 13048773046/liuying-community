/// 搜索页：悬浮搜索框 + 历史/热门 + 实时联想 + 帖子/用户/话题结果
///
/// 沉浸黑：黑底圆角输入框（280ms 防抖与联想逻辑原样保留）、热词用 [TagPill]、
/// 历史用紧凑胶囊、结果用 [ListRow]/[PostCard] 风格行。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../api/client.dart';
import '../../config.dart';
import '../../design/components.dart';
import '../../models/feed_item.dart';
import '../../widgets/image_box.dart';
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
      showAppToast(context, '搜索失败：$e');
    }
  }

  /// 清空输入并回到默认（历史/热门）视图
  void _clearInput() {
    _ctrl.clear();
    _debounce?.cancel();
    setState(() {
      _suggesting = false;
      _searched = false;
    });
    _focus.requestFocus();
  }

  Future<void> _clearHistory() async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_historyKey);
    if (mounted) setState(() => _history = []);
  }

  @override
  Widget build(BuildContext context) {
    return ImmersivePage(
      child: Column(
        children: [
          _searchBar(),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  // -------------------------------------------------------------- 顶部输入
  Widget _searchBar() {
    final top = MediaQuery.paddingOf(context).top;
    return Padding(
      padding: EdgeInsets.fromLTRB(
          AppSpace.x3, top + AppSpace.x2, AppSpace.x3, AppSpace.x2),
      child: Row(
        children: [
          IconCircleButton(
            icon: Icons.arrow_back_ios_new_rounded,
            size: 36,
            iconSize: 16,
            background: Colors.white.withValues(alpha: 0.06),
            onTap: () => Navigator.pop(context),
          ),
          const SizedBox(width: AppSpace.x2),
          Expanded(
            child: Container(
              height: 40,
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.x3),
              decoration: BoxDecoration(
                color: const Color(AppColors.elevated),
                borderRadius: AppRadius.rPill,
                border: Border.all(color: const Color(AppColors.border)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.search_rounded,
                      size: 18, color: Color(AppColors.textTertiary)),
                  const SizedBox(width: AppSpace.x2),
                  Expanded(
                    child: TextField(
                      controller: _ctrl,
                      focusNode: _focus,
                      style: AppType.body,
                      cursorColor: const Color(AppColors.accent),
                      textInputAction: TextInputAction.search,
                      onChanged: _onChanged,
                      onSubmitted: _submit,
                      decoration: const InputDecoration(
                        isCollapsed: true,
                        filled: false,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        hintText: '搜索帖子、用户、话题…',
                        hintStyle: TextStyle(
                          fontSize: 13.5,
                          height: 1.3,
                          color: Color(AppColors.textTertiary),
                        ),
                      ),
                    ),
                  ),
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _ctrl,
                    builder: (_, value, _) => value.text.isEmpty
                        ? const SizedBox(width: 2)
                        : IconCircleButton(
                            icon: Icons.cancel_rounded,
                            size: 20,
                            iconSize: 15,
                            background: Colors.transparent,
                            color: const Color(AppColors.textTertiary),
                            onTap: _clearInput,
                          ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: AppSpace.x2),
          PillButton(
            label: '取消',
            variant: PillVariant.ghost,
            size: PillSize.sm,
            onTap: () => Navigator.pop(context),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    if (_searched) return _resultView();
    if (_suggesting) return _suggestView();
    return _defaultView();
  }

  // ---------- 默认：历史 + 热门 ----------
  Widget _defaultView() {
    if (_history.isEmpty && _hot.isEmpty) {
      return const SingleChildScrollView(
        child: EmptyState(
          icon: Icons.search_rounded,
          title: '搜索感兴趣的内容',
          message: '帖子、视频、用户、话题都能搜',
        ),
      );
    }
    return ListView(
      padding: EdgeInsets.fromLTRB(
        AppSpace.gutter,
        AppSpace.x2,
        AppSpace.gutter,
        MediaQuery.paddingOf(context).bottom + 24,
      ),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      children: [
        if (_history.isNotEmpty) ...[
          SectionHeader(
            title: '搜索历史',
            padding: const EdgeInsets.only(bottom: AppSpace.x3),
            actionLabel: '清空',
            onAction: _clearHistory,
          ),
          Wrap(
            spacing: AppSpace.x2,
            runSpacing: AppSpace.x2,
            children: [
              for (final h in _history)
                TagPill(
                  label: h,
                  compact: true,
                  onTap: () {
                    _ctrl.text = h;
                    _submit(h);
                  },
                ),
            ],
          ),
        ],
        if (_hot.isNotEmpty) ...[
          const SizedBox(height: AppSpace.x5),
          const SectionHeader(
            title: '热门搜索',
            padding: EdgeInsets.only(bottom: AppSpace.x3),
          ),
          Wrap(
            spacing: AppSpace.x2,
            runSpacing: AppSpace.x2,
            children: [
              for (var i = 0; i < _hot.length; i++)
                TagPill(
                  label: _hot[i],
                  icon: i < 3 ? Icons.local_fire_department_rounded : null,
                  onTap: () {
                    _ctrl.text = _hot[i];
                    _submit(_hot[i]);
                  },
                ),
            ],
          ),
        ],
      ],
    );
  }

  // ---------- 联想 ----------
  Widget _suggestView() {
    return ListView(
      padding: EdgeInsets.only(
          top: AppSpace.x1, bottom: MediaQuery.paddingOf(context).bottom + 24),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      children: [
        for (final t in _sugTopics)
          ListRow(
            leading: const Icon(Icons.tag_rounded,
                size: 18, color: Color(AppColors.textTertiary)),
            title: '#$t',
            trailing: const Icon(Icons.north_west_rounded,
                size: 15, color: Color(AppColors.textTertiary)),
            showChevron: false,
            onTap: () => _submit(t),
          ),
        for (final u in _sugUsers)
          ListRow(
            leading: const Icon(Icons.person_outline_rounded,
                size: 18, color: Color(AppColors.textTertiary)),
            title: (u['name'] ?? '') as String,
            trailing: const Icon(Icons.north_west_rounded,
                size: 15, color: Color(AppColors.textTertiary)),
            showChevron: false,
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) =>
                    UserProfilePage(uid: (u['id'] ?? '') as String),
              ),
            ),
          ),
      ],
    );
  }

  // ---------- 搜索结果 ----------
  Widget _resultView() {
    if (_searching) return const _SearchSkeleton();

    final empty =
        _postResults.isEmpty && _userResults.isEmpty && _topicResults.isEmpty;
    if (empty) {
      return const SingleChildScrollView(
        child: EmptyState(
          icon: Icons.search_off_rounded,
          title: '没有找到相关内容',
          message: '换个关键词试试吧',
        ),
      );
    }

    return ListView(
      padding: EdgeInsets.fromLTRB(
        AppSpace.gutter,
        0,
        AppSpace.gutter,
        MediaQuery.paddingOf(context).bottom + 24,
      ),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      children: [
        if (_userResults.isNotEmpty) ...[
          const SectionHeader(
            title: '用户',
            padding: EdgeInsets.only(top: AppSpace.x4, bottom: AppSpace.x1),
          ),
          for (final u in _userResults) _userRow(u),
        ],
        if (_topicResults.isNotEmpty) ...[
          const SectionHeader(
            title: '话题',
            padding: EdgeInsets.only(top: AppSpace.x4, bottom: AppSpace.x3),
          ),
          Wrap(
            spacing: AppSpace.x2,
            runSpacing: AppSpace.x2,
            children: [
              for (final t in _topicResults)
                TagPill(
                  label: '#${t['name'] ?? ''}',
                  onTap: () => _submit((t['name'] ?? '') as String),
                ),
            ],
          ),
        ],
        if (_postResults.isNotEmpty) ...[
          const SectionHeader(
            title: '帖子',
            padding: EdgeInsets.only(top: AppSpace.x5, bottom: AppSpace.x3),
          ),
          for (final it in _postResults) _postRow(it),
        ],
      ],
    );
  }

  Widget _userRow(Map<String, dynamic> u) {
    final name = (u['name'] ?? '用户') as String;
    final avatar = (u['avatar'] ?? '') as String;
    final bio = (u['bio'] ?? '') as String;
    final followers = ((u['followers'] ?? 0) as num).toInt();
    return ListRow(
      leading: UserAvatar(url: avatar, name: name, size: 44),
      title: name,
      subtitle: bio.isEmpty ? null : bio,
      trailing: followers > 0
          ? Text('${formatCount(followers)} 粉丝', style: AppType.micro)
          : null,
      showChevron: false,
      padding: const EdgeInsets.symmetric(vertical: AppSpace.x2),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => UserProfilePage(uid: (u['id'] ?? '') as String)),
      ),
    );
  }

  Widget _postRow(FeedItem it) {
    final thumb = (it.type == 'video' && it.cover.isNotEmpty)
        ? it.cover
        : (it.images.isNotEmpty ? it.images.first : '');
    return PressableScale(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => PostDetailPage(postId: it.id)),
      ),
      scale: 0.98,
      child: Container(
        margin: const EdgeInsets.only(bottom: AppSpace.x3),
        padding: const EdgeInsets.all(AppSpace.x2),
        decoration: BoxDecoration(
          color: const Color(AppColors.card),
          borderRadius: AppRadius.rMd,
          border: Border.all(color: const Color(AppColors.border)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (thumb.isNotEmpty) ...[
              ClipRRect(
                borderRadius: AppRadius.rSm,
                child: SizedBox(
                  width: 80,
                  height: 80,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      CachedNetworkImageCompat(
                        url: thumb.startsWith('http') ? thumb : mediaUrl(thumb),
                        fit: BoxFit.cover,
                        borderRadius: AppRadius.sm,
                      ),
                      if (it.type == 'video')
                        const Center(
                          child: Icon(Icons.play_circle_fill_rounded,
                              color: Colors.white, size: 26),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: AppSpace.x3),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    it.content,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.bodySm.copyWith(
                        color: const Color(AppColors.textPrimary)),
                  ),
                  const SizedBox(height: AppSpace.x2),
                  Row(
                    children: [
                      UserAvatar(url: it.author.avatar, size: 18),
                      const SizedBox(width: AppSpace.x1),
                      Expanded(
                        child: Text(
                          it.author.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppType.micro,
                        ),
                      ),
                      const Icon(Icons.favorite_rounded,
                          size: 12, color: Color(AppColors.heart)),
                      const SizedBox(width: 3),
                      Text(formatCount(it.likeCount), style: AppType.micro),
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
}

/// 搜索中骨架：头像 + 文本行占位。
class _SearchSkeleton extends StatelessWidget {
  const _SearchSkeleton();

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
                SkeletonBox(width: 44, height: 44, radius: 22),
                SizedBox(width: AppSpace.x3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SkeletonBox(width: 120, height: 12),
                      SizedBox(height: AppSpace.x2),
                      SkeletonBox(height: 10),
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
