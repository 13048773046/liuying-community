/// 搜索页：社区全量搜索
///
/// 顶部胶囊搜索框 → 搜索历史 / 联想词 → 应用直达 → 大家都在搜。
/// 本页不承担「猜你想看」式的内容发现流，只有用户主动输入后才展示结果。
/// 搜索结果按「全部 / 应用 / 帖子 / 用户 / 话题」分组筛选；应用走 `/apps?q=`，
/// 帖子、视频、用户、话题继续走 `/search`，应用可直接进入详情。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../api/app_market_api.dart';
import '../../api/client.dart';
import '../../config.dart';
import '../../design/components.dart';
import '../../features/emoji/text_emoji.dart';
import '../../models/app_market.dart';
import '../../models/feed_item.dart';
import '../../widgets/image_box.dart';
import '../../widgets/post_card.dart';
import '../../widgets/user_avatar.dart';
import '../apps/app_detail_page.dart';
import '../apps/app_market_page.dart';
import '../apps/app_widgets.dart';
import '../discover/topic_detail_page.dart';
import '../post/post_detail.dart';
import '../user/user_profile.dart';

/// 命中词高亮色
const _kHitRed = Color(AppColors.accent);

/// 搜索框底色
const _kFieldBg = Color(AppColors.card);

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();
  Timer? _debounce;

  static const _historyKey = 'search_history';

  // 历史 / 联想
  List<String> _history = [];
  List<String> _hot = [];
  List<String> _suggestions = [];

  // 结果
  bool _searched = false;
  bool _searching = false;
  List<FeedItem> _postResults = [];
  List<Map<String, dynamic>> _userResults = [];
  List<Map<String, dynamic>> _topicResults = [];
  List<MarketApp> _appResults = [];
  String _resultFilter = 'all'; // all / apps / posts / users / topics
  String _lastQuery = '';
  int _searchRequest = 0;

  // 默认页应用直达
  List<MarketApp> _apps = const [];
  bool _appsLoading = true;

  @override
  void initState() {
    super.initState();
    _loadHistory();
    _loadHot();
    _loadApps();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------- 数据

  Future<void> _loadHistory() async {
    final sp = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => _history = sp.getStringList(_historyKey) ?? []);
  }

  Future<void> _loadHot() async {
    try {
      final list = await ApiClient.searchHot();
      if (!mounted) return;
      setState(
        () => _hot = list
            .map((e) => (e['q'] ?? '') as String)
            .where((s) => s.isNotEmpty)
            .toList(),
      );
    } catch (_) {}
  }

  Future<void> _loadApps() async {
    try {
      final page = await AppMarketApi.list(
        page: 1,
        pageSize: 8,
        sort: 'recommend',
      );
      if (!mounted) return;
      setState(() {
        _apps = page.list;
        _appsLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _appsLoading = false);
    }
  }

  void _onChanged(String q) {
    _debounce?.cancel();
    final kw = q.trim();
    if (kw.isEmpty) {
      if (mounted && _suggestions.isNotEmpty) {
        setState(() => _suggestions = []);
      }
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 260), () async {
      try {
        final j = await ApiClient.searchSuggest(kw);
        if (!mounted || _searched || _ctrl.text.trim() != kw) return;
        final topics = ((j['topics'] ?? []) as List)
            .whereType<String>()
            .toList();
        final users = ((j['users'] ?? []) as List)
            .whereType<Map<String, dynamic>>()
            .map((e) => (e['name'] ?? '') as String)
            .where((s) => s.isNotEmpty)
            .toList();
        List<String> appNames = const [];
        try {
          final page = await AppMarketApi.list(
            page: 1,
            pageSize: 3,
            q: kw,
            sort: 'hot',
          );
          appNames = page.list
              .map((e) => e.name.trim())
              .where((e) => e.isNotEmpty)
              .toList();
        } catch (_) {}
        if (!mounted || _searched || _ctrl.text.trim() != kw) return;
        setState(() {
          _suggestions = <String>{
            kw,
            ...appNames,
            ...topics,
            ...users,
            ..._history.where((h) => h.contains(kw)).take(4),
            ..._hot.where((h) => h.contains(kw)).take(4),
          }.take(12).toList();
        });
      } catch (_) {}
    });
  }

  Future<void> _submit(String raw) async {
    final kw = raw.trim();
    if (kw.isEmpty) return;
    _debounce?.cancel();
    _focus.unfocus();
    final request = ++_searchRequest;
    setState(() {
      _searched = true;
      _searching = true;
      _resultFilter = 'all';
      _lastQuery = kw;
      _postResults = [];
      _userResults = [];
      _topicResults = [];
      _appResults = [];
    });
    // 社区内容与应用同时请求；任一路失败都不能让另一条结果变成空白。
    final contentFuture = _searchContent(kw);
    final appsFuture = _searchApps(kw);

    try {
      final sp = await SharedPreferences.getInstance();
      final hist = [kw, ..._history.where((h) => h != kw)].take(20).toList();
      await sp.setStringList(_historyKey, hist);
      if (!mounted || request != _searchRequest) return;
      setState(() => _history = hist);
    } catch (_) {}

    final content = await contentFuture;
    final apps = await appsFuture;
    if (!mounted || request != _searchRequest) return;
    setState(() {
      _postResults = content.$1;
      _userResults = content.$2;
      _topicResults = content.$3;
      _appResults = apps;
      _searching = false;
    });
    if (content.$4 != null) showAppToast(context, '内容搜索失败：${content.$4}');
  }

  Future<
    (
      List<FeedItem>,
      List<Map<String, dynamic>>,
      List<Map<String, dynamic>>,
      String?,
    )
  >
  _searchContent(String kw) async {
    try {
      final j = await ApiClient.search(kw);
      return (
        [
          ...(((j['posts'] ?? []) as List)
              .whereType<Map<String, dynamic>>()
              .map(FeedItem.fromJson)),
          ...(((j['videos'] ?? []) as List)
              .whereType<Map<String, dynamic>>()
              .map(FeedItem.fromJson)),
        ],
        ((j['users'] ?? []) as List).whereType<Map<String, dynamic>>().toList(),
        ((j['topics'] ?? []) as List)
            .whereType<Map<String, dynamic>>()
            .toList(),
        null,
      );
    } catch (e) {
      return (
        <FeedItem>[],
        <Map<String, dynamic>>[],
        <Map<String, dynamic>>[],
        '$e',
      );
    }
  }

  Future<List<MarketApp>> _searchApps(String kw) async {
    try {
      final page = await AppMarketApi.list(
        page: 1,
        pageSize: 20,
        q: kw,
        sort: 'recommend',
      );
      return page.list;
    } catch (_) {
      return const [];
    }
  }

  void _clearInput() {
    _ctrl.clear();
    _debounce?.cancel();
    _searchRequest++;
    setState(() {
      _searched = false;
      _searching = false;
      _suggestions = [];
      _resultFilter = 'all';
      _lastQuery = '';
      _appResults = [];
      _postResults = [];
      _userResults = [];
      _topicResults = [];
    });
    _focus.requestFocus();
  }

  Future<void> _clearHistory() async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_historyKey);
    if (mounted) setState(() => _history = []);
  }

  void _openMarket() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const AppMarketPage()),
    );
  }

  void _openApp(MarketApp app) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => AppDetailPage(appId: app.id)),
    );
  }

  // -------------------------------------------------------------- 构建

  @override
  Widget build(BuildContext context) {
    return ImmersivePage(
      child: Column(
        children: [
          _topBar(),
          Expanded(child: _searched ? _resultView() : _discoverView()),
        ],
      ),
    );
  }

  /// 顶部：返回 + 44px 搜索框 + 框外搜索按钮，三者共用一条垂直中线。
  Widget _topBar() {
    final top = MediaQuery.paddingOf(context).top;
    return Padding(
      padding: EdgeInsets.fromLTRB(4, top + 6, 12, 8),
      child: Row(
        children: [
          SizedBox(
            width: 38,
            height: 44,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => Navigator.pop(context),
              child: const Icon(
                Icons.arrow_back_ios_new_rounded,
                size: 17,
                color: Colors.white,
              ),
            ),
          ),
          Expanded(
            child: Container(
              height: 44,
              padding: const EdgeInsets.fromLTRB(13, 0, 7, 0),
              decoration: BoxDecoration(
                color: _kFieldBg,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(AppColors.hairline)),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.search_rounded,
                    size: 17,
                    color: Color(AppColors.textTertiary),
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: TextField(
                      controller: _ctrl,
                      focusNode: _focus,
                      style: const TextStyle(
                        fontSize: 14,
                        color: Colors.white,
                        height: 1.25,
                      ),
                      cursorColor: _kHitRed,
                      textInputAction: TextInputAction.search,
                      onChanged: _onChanged,
                      onSubmitted: _submit,
                      decoration: const InputDecoration(
                        isCollapsed: true,
                        filled: false,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        hintText: '搜帖子、用户、话题、应用',
                        hintStyle: TextStyle(
                          fontSize: 13.5,
                          color: Color(AppColors.textTertiary),
                          height: 1.25,
                        ),
                      ),
                    ),
                  ),
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _ctrl,
                    builder: (_, value, _) => value.text.isEmpty
                        ? const SizedBox.shrink()
                        : GestureDetector(
                            onTap: _clearInput,
                            behavior: HitTestBehavior.opaque,
                            child: const SizedBox(
                              width: 28,
                              height: 36,
                              child: Icon(
                                Icons.cancel_rounded,
                                size: 16,
                                color: Color(AppColors.textTertiary),
                              ),
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 6),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _submit(_ctrl.text),
            child: const SizedBox(
              width: 42,
              height: 44,
              child: Center(
                child: Text(
                  '搜索',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: Color(AppColors.accent),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------- 默认页

  Widget _discoverView() {
    final q = _ctrl.text.trim();
    return CustomScrollView(
      scrollCacheExtent: const ScrollCacheExtent.pixels(300),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      slivers: [
        if (_history.isNotEmpty) SliverToBoxAdapter(child: _historyBlock()),
        if (q.isNotEmpty && _suggestions.isNotEmpty)
          SliverToBoxAdapter(child: _suggestBlock(q)),
        if (_appsLoading)
          const SliverToBoxAdapter(
            child: ShimmerScope(
              child: Padding(
                padding: EdgeInsets.fromLTRB(16, 14, 16, 0),
                child: SizedBox(
                  height: 66,
                  child: SkeletonBox(radius: AppRadius.md),
                ),
              ),
            ),
          )
        else if (_apps.isNotEmpty)
          SliverToBoxAdapter(child: _appShelf()),
        if (_hot.isNotEmpty) SliverToBoxAdapter(child: _hotBlock()),
        SliverToBoxAdapter(
          child: SizedBox(height: tabBarBottomInset(context) + 26),
        ),
      ],
    );
  }

  double _cardHeight(int i) {
    const hs = [214.0, 286.0, 246.0, 196.0, 268.0, 232.0];
    return hs[i % hs.length];
  }

  /// 搜索历史：单行横向滚动，不换行、不展开。
  Widget _historyBlock() {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                const Text(
                  '最近搜索',
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.2,
                    fontWeight: FontWeight.w700,
                    color: Color(AppColors.textPrimary),
                  ),
                ),
                const Spacer(),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () async {
                    final ok = await _confirmClear();
                    if (ok == true) await _clearHistory();
                  },
                  child: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 7, horizontal: 3),
                    child: Icon(
                      Icons.delete_outline_rounded,
                      size: 17,
                      color: Color(AppColors.textTertiary),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 42,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: _history.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (_, i) {
                final h = _history[i];
                return PressableScale(
                  onTap: () {
                    _ctrl.text = h;
                    _submit(h);
                  },
                  scale: 0.97,
                  child: Container(
                    height: 38,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: const Color(AppColors.card)
                          .withValues(alpha: 0.62),
                      borderRadius: BorderRadius.circular(11),
                      border: Border.all(
                        color: const Color(AppColors.hairline),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.history_rounded,
                          size: 13,
                          color: Color(AppColors.textTertiary),
                        ),
                        const SizedBox(width: 6),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 156),
                          child: Text(
                            h,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12,
                              height: 1.1,
                              color: Colors.white,
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
        ],
      ),
    );
  }

  /// 大家都在搜：纵向榜单，编号 / 关键词 / 箭头对齐在同一条线上。
  Widget _hotBlock() {
    final shown = _hot.take(6).toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(
                Icons.local_fire_department_rounded,
                size: 15,
                color: Color(AppColors.accent),
              ),
              const SizedBox(width: 5),
              const Text(
                '大家都在搜',
                style: TextStyle(
                  fontSize: 14,
                  height: 1.2,
                  fontWeight: FontWeight.w700,
                  color: Color(AppColors.textPrimary),
                ),
              ),
              const Spacer(),
              const Text(
                '社区热搜',
                style: TextStyle(
                  fontSize: 9.5,
                  height: 1.2,
                  letterSpacing: 0.6,
                  color: Color(AppColors.textTertiary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 9),
          Container(
            decoration: BoxDecoration(
              color: const Color(AppColors.card).withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(AppColors.hairline)),
            ),
            child: Column(
              children: [
                for (var i = 0; i < shown.length; i++) ...[
                  InkWell(
                    onTap: () {
                      _ctrl.text = shown[i];
                      _submit(shown[i]);
                    },
                    child: SizedBox(
                      height: 40,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 24,
                              child: Text(
                                (i + 1).toString().padLeft(2, '0'),
                                style: TextStyle(
                                  fontSize: 10,
                                  height: 1.1,
                                  fontWeight: FontWeight.w700,
                                  color: i < 3
                                      ? const Color(AppColors.accent)
                                      : const Color(AppColors.textTertiary),
                                ),
                              ),
                            ),
                            Expanded(
                              child: Text(
                                shown[i],
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 13,
                                  height: 1.2,
                                  fontWeight: FontWeight.w500,
                                  color: Color(AppColors.textPrimary),
                                ),
                              ),
                            ),
                            if (i < 3) ...[
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 5,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(AppColors.accent)
                                      .withValues(alpha: 0.10),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: const Text(
                                  '热',
                                  style: TextStyle(
                                    fontSize: 8,
                                    height: 1,
                                    fontWeight: FontWeight.w700,
                                    color: Color(AppColors.accent),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                            ],
                            const Icon(
                              Icons.chevron_right_rounded,
                              size: 15,
                              color: Color(AppColors.textTertiary),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (i != shown.length - 1)
                    const Padding(
                      padding: EdgeInsets.only(left: 36, right: 12),
                      child: Divider(height: 0.5, thickness: 0.5),
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<bool?> _confirmClear() {
    return showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(AppColors.elevated),
        title: const Text('清空搜索历史？', style: TextStyle(fontSize: 16)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
  }

  /// 联想词：两列，命中片段标红
  /// 输入联想：单列右对齐列表，命中词红色加粗。
  Widget _suggestBlock(String q) {
    final shown = _suggestions.take(6).toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(AppColors.card).withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(AppColors.hairline)),
        ),
        child: Column(
          children: [
            for (var i = 0; i < shown.length; i++) ...[
              InkWell(
                onTap: () {
                  _ctrl.text = shown[i];
                  _submit(shown[i]);
                },
                child: SizedBox(
                  height: 42,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.search_rounded,
                          size: 15,
                          color: Color(AppColors.textTertiary),
                        ),
                        const SizedBox(width: 9),
                        Expanded(
                          child: RichText(
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            text: TextSpan(
                              style: const TextStyle(
                                fontSize: 13.5,
                                height: 1.2,
                                color: Colors.white,
                              ),
                              children: _highlight(shown[i], q),
                            ),
                          ),
                        ),
                        const Icon(
                          Icons.north_west_rounded,
                          size: 13,
                          color: Color(AppColors.textTertiary),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (i != shown.length - 1)
                const Padding(
                  padding: EdgeInsets.only(left: 36, right: 12),
                  child: Divider(height: 0.5, thickness: 0.5),
                ),
            ],
          ],
        ),
      ),
    );
  }

  /// 应用直达：紧凑图标条，和应用市场共用同一套图标入口。
  Widget _appShelf() {
    final apps = _apps.take(8).toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Text(
                '应用直达',
                style: TextStyle(
                  fontSize: 14,
                  height: 1.2,
                  fontWeight: FontWeight.w700,
                  color: Color(AppColors.textPrimary),
                ),
              ),
              const Spacer(),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _openMarket,
                child: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 7, horizontal: 2),
                  child: Text(
                    '应用市场',
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.1,
                      fontWeight: FontWeight.w600,
                      color: Color(AppColors.accent),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 9),
          SizedBox(
            height: 66,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: apps.length,
              separatorBuilder: (_, _) => const SizedBox(width: 13),
              itemBuilder: (_, i) {
                final app = apps[i];
                return PressableScale(
                  onTap: () => _openApp(app),
                  scale: 0.96,
                  child: SizedBox(
                    width: 54,
                    child: Column(
                      children: [
                        AppIconTile(app: app, size: 44, radius: 12),
                        const SizedBox(height: 6),
                        Text(
                          app.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 10.5,
                            height: 1.1,
                            color: Color(AppColors.textSecondary),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// 命中片段红色加粗，其余白色
  List<TextSpan> _highlight(String word, String q) {
    if (q.isEmpty) return [TextSpan(text: word)];
    final lower = word.toLowerCase();
    final ql = q.toLowerCase();
    final spans = <TextSpan>[];
    var from = 0;
    while (true) {
      final at = lower.indexOf(ql, from);
      if (at < 0) {
        spans.add(TextSpan(text: word.substring(from)));
        break;
      }
      if (at > from) spans.add(TextSpan(text: word.substring(from, at)));
      spans.add(
        TextSpan(
          text: word.substring(at, at + q.length),
          style: const TextStyle(color: _kHitRed, fontWeight: FontWeight.w600),
        ),
      );
      from = at + q.length;
    }
    return spans;
  }

  // -------------------------------------------------------------- 结果页

  Widget _resultView() {
    if (_searching) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    final empty =
        _postResults.isEmpty &&
        _userResults.isEmpty &&
        _topicResults.isEmpty &&
        _appResults.isEmpty;
    if (empty) {
      return const Center(
        child: EmptyState(
          icon: Icons.search_off_rounded,
          title: '没有找到相关内容',
          message: '试试应用名、帖子关键词或用户昵称',
        ),
      );
    }

    final showApps = _resultFilter == 'all' || _resultFilter == 'apps';
    final showPosts = _resultFilter == 'all' || _resultFilter == 'posts';
    final showUsers = _resultFilter == 'all' || _resultFilter == 'users';
    final showTopics = _resultFilter == 'all' || _resultFilter == 'topics';
    final apps = _resultFilter == 'all'
        ? _appResults.take(3).toList()
        : _appResults;

    return CustomScrollView(
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      slivers: [
        SliverToBoxAdapter(child: _resultSummary()),
        SliverToBoxAdapter(child: _resultFilterBar()),
        if (showApps && _appResults.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: _sectionHeader(
              kicker: 'APPS / 应用',
              title: '相关应用',
              count: '${_appResults.length} 款',
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
              child: Column(
                children: [
                  for (var i = 0; i < apps.length; i++) ...[
                    if (i > 0) const SizedBox(height: 8),
                    _AppResultRow(app: apps[i], onTap: () => _openApp(apps[i])),
                  ],
                ],
              ),
            ),
          ),
          if (_resultFilter == 'all' && _appResults.length > apps.length)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => setState(() => _resultFilter = 'apps'),
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(70, 30),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(
                      '查看全部 ${_appResults.length} 款',
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: Color(AppColors.accent),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
        if (showUsers && _userResults.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: _sectionHeader(
              kicker: 'PEOPLE / 用户',
              title: '相关用户',
              count: '${_userResults.length} 位',
            ),
          ),
          SliverToBoxAdapter(
            child: SizedBox(
              height: 116,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                itemCount: _userResults.length,
                separatorBuilder: (_, _) => const SizedBox(width: 18),
                itemBuilder: (_, i) => _userCell(_userResults[i]),
              ),
            ),
          ),
        ],
        if (showTopics && _topicResults.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: _sectionHeader(
              kicker: 'TOPICS / 话题',
              title: '相关话题',
              count: '${_topicResults.length} 个',
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
              child: _topicChips(),
            ),
          ),
        ],
        if (showPosts && _postResults.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: _sectionHeader(
              kicker: 'POSTS / 内容',
              title: '相关帖子',
              count: '${_postResults.length} 条',
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
            sliver: SliverMasonryGrid.count(
              crossAxisCount: 2,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childCount: _postResults.length,
              itemBuilder: (_, i) => StaggerReveal(
                key: ValueKey('search-post-${_postResults[i].id}'),
                index: i,
                offsetY: 24,
                delay: const Duration(milliseconds: 50),
                duration: const Duration(milliseconds: 450),
                child: _FeedTile(
                  item: _postResults[i],
                  height: _cardHeight(i),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          PostDetailPage(postId: _postResults[i].id),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
        if (_resultFilter == 'apps' && _appResults.isEmpty)
          SliverToBoxAdapter(child: _filterEmpty('没有找到相关应用')),
        if (showPosts && _postResults.isEmpty && _resultFilter == 'posts')
          SliverToBoxAdapter(child: _filterEmpty('没有找到相关帖子')),
        if (showUsers && _userResults.isEmpty && _resultFilter == 'users')
          SliverToBoxAdapter(child: _filterEmpty('没有找到相关用户')),
        if (showTopics && _topicResults.isEmpty && _resultFilter == 'topics')
          SliverToBoxAdapter(child: _filterEmpty('没有找到相关话题')),
        SliverToBoxAdapter(
          child: SizedBox(height: tabBarBottomInset(context) + 30),
        ),
      ],
    );
  }

  /// 结果摘要：搜索词独占一行，数量和状态靠右，避免和长词挤成一条。
  Widget _resultSummary() {
    final all =
        _postResults.length +
        _appResults.length +
        _userResults.length +
        _topicResults.length;
    final total = switch (_resultFilter) {
      'apps' => _appResults.length,
      'posts' => _postResults.length,
      'users' => _userResults.length,
      'topics' => _topicResults.length,
      _ => all,
    };
    final query = _lastQuery.isEmpty ? _ctrl.text.trim() : _lastQuery;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                'SEARCH / RESULT',
                style: TextStyle(
                  fontSize: 8.5,
                  height: 1.2,
                  letterSpacing: 1.1,
                  fontWeight: FontWeight.w700,
                  color: Color(AppColors.accent),
                ),
              ),
              const Spacer(),
              Text(
                '$total 条结果',
                style: const TextStyle(
                  fontSize: 10,
                  height: 1.2,
                  color: Color(AppColors.textTertiary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Text.rich(
            TextSpan(
              style: const TextStyle(
                fontSize: 19,
                height: 1.2,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.4,
                color: Colors.white,
              ),
              children: [
                TextSpan(
                  text: '“$query”',
                  style: const TextStyle(color: Color(AppColors.accent)),
                ),
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _resultFilterBar() {
    final entries = <(String, String, int)>[
      (
        'all',
        '综合',
        _postResults.length +
            _appResults.length +
            _userResults.length +
            _topicResults.length,
      ),
      if (_appResults.isNotEmpty) ('apps', '应用', _appResults.length),
      if (_postResults.isNotEmpty) ('posts', '帖子', _postResults.length),
      if (_userResults.isNotEmpty) ('users', '用户', _userResults.length),
      if (_topicResults.isNotEmpty) ('topics', '话题', _topicResults.length),
    ];
    return SizedBox(
      height: 42,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        itemCount: entries.length,
        separatorBuilder: (_, _) => const SizedBox(width: 7),
        itemBuilder: (_, i) {
          final e = entries[i];
          final active = _resultFilter == e.$1;
          return PressableScale(
            onTap: () => setState(() => _resultFilter = e.$1),
            scale: 0.97,
            child: AnimatedContainer(
              duration: AppMotion.fast,
              height: 30,
              padding: const EdgeInsets.symmetric(horizontal: 11),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(9),
                color: active
                    ? const Color(AppColors.accent).withValues(alpha: 0.14)
                    : const Color(AppColors.card).withValues(alpha: 0.5),
                border: Border.all(
                  color: active
                      ? const Color(AppColors.accent).withValues(alpha: 0.35)
                      : const Color(AppColors.hairline),
                ),
              ),
              child: Text(
                '${e.$2} ${e.$3}',
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.1,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                  color: active
                      ? const Color(AppColors.accent)
                      : const Color(AppColors.textSecondary),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _sectionHeader({
    required String kicker,
    required String title,
    required String count,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  kicker,
                  style: const TextStyle(
                    fontSize: 8.5,
                    height: 1.2,
                    letterSpacing: 1.05,
                    fontWeight: FontWeight.w700,
                    color: Color(AppColors.accent),
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 17,
                    height: 1.1,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.35,
                    color: Color(AppColors.textPrimary),
                  ),
                ),
              ],
            ),
          ),
          Text(
            count,
            style: const TextStyle(
              fontSize: 10,
              height: 1.2,
              color: Color(AppColors.textTertiary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _topicChips() {
    return Wrap(
      spacing: 7,
      runSpacing: 7,
      children: [
        for (final t in _topicResults)
          _TopicChip(
            name: (t['name'] ?? '') as String,
            count: ((t['postCount'] ?? t['post_count'] ?? 0) as num).toInt(),
            reason: (t['reason'] ?? '').toString(),
            onTap: () {
              final name = (t['name'] ?? '') as String;
              if (name.isEmpty) return;
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => TopicDetailPage(topic: name)),
              );
            },
          ),
      ],
    );
  }

  Widget _filterEmpty(String message) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 26, 16, 20),
      child: Center(
        child: Text(
          message,
          style: const TextStyle(
            fontSize: 12,
            color: Color(AppColors.textTertiary),
          ),
        ),
      ),
    );
  }

  Widget _userCell(Map<String, dynamic> u) {
    final name = (u['name'] ?? '用户') as String;
    final avatar = (u['avatar'] ?? '') as String;
    final followers = intOf(u['followers']);
    final reason = (u['reason'] ?? '').toString().trim();
    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => UserProfilePage(uid: (u['id'] ?? '') as String),
        ),
      ),
      child: SizedBox(
        width: 76,
        child: Column(
          children: [
            UserAvatar(
              url: avatar,
              uid: (u['id'] ?? '') as String,
              name: name,
              size: 52,
              verified:
                  verifiedOf(u['verified']) ||
                  (u['verifiedLabel'] ?? '').toString().trim().isNotEmpty,
              verifiedLabel: (u['verifiedLabel'] ?? '').toString(),
              isAi: boolOf(u['isAi']),
            ),
            const SizedBox(height: 6),
            Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12.5, color: Colors.white),
            ),
            if (reason.isNotEmpty)
              Text(
                reason,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 9,
                  height: 1.2,
                  color: Color(AppColors.accent),
                ),
              ),
            if (followers > 0)
              Text(
                '${formatCount(followers)}粉丝',
                maxLines: 1,
                style: const TextStyle(
                  fontSize: 10.5,
                  color: Color(AppColors.textTertiary),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 搜索结果里的应用行：图标 + 名称/分类 + 一句话描述 + 评分。
class _AppResultRow extends StatelessWidget {
  const _AppResultRow({required this.app, required this.onTap});

  final MarketApp app;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final category = app.category.trim();
    final meta = [
      if (category.isNotEmpty) category,
      if (app.platformLabel.isNotEmpty) app.platformLabel,
      if (app.downloadCount > 0) '${formatCount(app.downloadCount)} 次下载',
    ].join(' · ');
    return PressableScale(
      onTap: onTap,
      scale: 0.985,
      child: Container(
        height: app.reason.trim().isNotEmpty ? 84 : 68,
        padding: const EdgeInsets.fromLTRB(10, 0, 8, 0),
        decoration: BoxDecoration(
          color: const Color(AppColors.card).withValues(alpha: 0.62),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(AppColors.hairline)),
        ),
        child: Row(
          children: [
            AppIconTile(app: app, size: 44, radius: 11),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          app.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13.5,
                            height: 1.15,
                            fontWeight: FontWeight.w700,
                            color: Color(AppColors.textPrimary),
                          ),
                        ),
                      ),
                      if (app.ratingCount > 0) ...[
                        const SizedBox(width: 6),
                        const Icon(
                          Icons.star_rounded,
                          size: 11,
                          color: Color(AppColors.warning),
                        ),
                        const SizedBox(width: 2),
                        Text(
                          app.rating.toStringAsFixed(1),
                          style: const TextStyle(
                            fontSize: 10,
                            height: 1.1,
                            fontWeight: FontWeight.w600,
                            color: Color(AppColors.warning),
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (app.reason.trim().isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        const Icon(
                          Icons.auto_awesome_rounded,
                          size: 10,
                          color: Color(AppColors.accent),
                        ),
                        const SizedBox(width: 3),
                        Expanded(
                          child: Text(
                            app.reason,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 9,
                              height: 1.15,
                              color: Color(AppColors.accent),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 5),
                  Text(
                    meta.isEmpty ? '社区应用' : meta,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 10,
                      height: 1.15,
                      color: Color(AppColors.textTertiary),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 7),
            Container(
              height: 26,
              padding: const EdgeInsets.symmetric(horizontal: 9),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: const Color(AppColors.accent).withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(7),
              ),
              child: const Text(
                '查看',
                style: TextStyle(
                  fontSize: 10.5,
                  height: 1.1,
                  fontWeight: FontWeight.w600,
                  color: Color(AppColors.accent),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TopicChip extends StatelessWidget {
  const _TopicChip({
    required this.name,
    required this.count,
    required this.onTap,
    this.reason = '',
  });

  final String name;
  final int count;
  final String reason;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return PressableScale(
      onTap: onTap,
      scale: 0.97,
      child: Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 11),
        decoration: BoxDecoration(
          color: const Color(AppColors.card).withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(AppColors.hairline)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '#',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: Color(AppColors.accent),
              ),
            ),
            const SizedBox(width: 3),
            Flexible(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11.5, color: Colors.white),
              ),
            ),
            if (reason.contains('你')) ...[
              const SizedBox(width: 4),
              const Icon(
                Icons.auto_awesome_rounded,
                size: 9,
                color: Color(AppColors.accent),
              ),
            ],
            if (count > 0) ...[
              const SizedBox(width: 5),
              Text(
                formatCount(count),
                style: const TextStyle(
                  fontSize: 9.5,
                  color: Color(AppColors.textTertiary),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 瀑布流卡片：缩略图 + 底部渐变 + 标题 + 右下播放钮 / 作者 / 点赞
class _FeedTile extends StatelessWidget {
  final FeedItem item;
  final double height;
  final VoidCallback onTap;

  const _FeedTile({
    required this.item,
    required this.height,
    required this.onTap,
  });

  String get _thumb {
    if (item.type == 'video') return item.cover;
    if (item.images.isNotEmpty) return item.images.first;
    return '';
  }

  String get _title {
    final c = item.content.trim();
    if (c.isNotEmpty) return c;
    if (item.topic.isNotEmpty) return '#${item.topic.first}';
    return '';
  }

  /// 底部渐变层（渐变对象独立定义，避免深层嵌套）
  Widget _shade(double h) {
    const g = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [Colors.transparent, Color(0xC7000000)],
    );
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      height: h,
      child: const DecoratedBox(decoration: BoxDecoration(gradient: g)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final thumb = _thumb;
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: SizedBox(
          height: height,
          width: double.infinity,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (thumb.isNotEmpty)
                BlurUpImage(
                  url: thumb.startsWith('http') ? thumb : mediaUrl(thumb),
                  fit: BoxFit.cover,
                  borderRadius: 3,
                  cacheWidth: 420,
                )
              else
                Container(
                  color: const Color(AppColors.card),
                  padding: EdgeInsets.fromLTRB(
                    10,
                    item.type == 'video' ? 36 : 12,
                    10,
                    58,
                  ),
                  child: TextEmojiText(
                    _title,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      height: 1.45,
                      color: Colors.white,
                    ),
                  ),
                ),
              _shade(thumb.isEmpty ? 54 : height * 0.55),
              if (item.type == 'video')
                const Positioned(
                  top: 8,
                  right: 8,
                  child: IgnorePointer(child: VideoBadge(compact: true)),
                ),
              Positioned(
                left: 9,
                right: 9,
                bottom: 8,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (thumb.isNotEmpty && _title.isNotEmpty)
                      TextEmojiText(
                        _title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15,
                          height: 1.34,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        UserAvatar(
                          url: item.author.avatar,
                          uid: item.author.id,
                          name: item.author.name,
                          size: 18,
                          verified: item.author.verified,
                          verifiedLabel: item.author.verifiedLabel,
                          isAi: item.author.isAi,
                          frameUrl: frameUrlOf(item.author.frameId),
                        ),
                        const SizedBox(width: 5),
                        Expanded(
                          child: Text(
                            item.author.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 11.5,
                              color: Color(0xCCFFFFFF),
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        const Icon(
                          Icons.favorite_rounded,
                          size: 12,
                          color: Color(0xCCFFFFFF),
                        ),
                        const SizedBox(width: 3),
                        Text(
                          formatCount(item.likeCount),
                          style: const TextStyle(
                            fontSize: 11.5,
                            color: Color(0xCCFFFFFF),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
