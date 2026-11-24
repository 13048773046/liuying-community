/// 应用市场首页：精选、搜索、大类/子类、平台筛选、排序与分页列表。
///
/// 设计上不复制应用商店的模板：以“社区人工审核的精选货架”为语义，
/// 首屏先给精选与用途，再给分类与列表；所有列表行保持同一信息层级。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../api/app_market_api.dart';
import '../../api/client.dart';
import '../../design/components.dart';
import '../../models/app_market.dart';
import '../mine/login_page.dart';
import 'app_detail_page.dart';
import 'app_list_page.dart';
import 'app_mine_page.dart';
import 'app_submit_page.dart';
import 'app_widgets.dart';

class AppMarketPage extends StatefulWidget {
  const AppMarketPage({super.key});

  @override
  State<AppMarketPage> createState() => _AppMarketPageState();
}

class _AppMarketPageState extends State<AppMarketPage> {
  final TextEditingController _search = TextEditingController();
  Timer? _debounceTimer;

  List<AppCategory> _categories = const [];
  String _categoryId = '';
  String _subCategoryId = '';
  String _platform = '';
  String _sort = 'recommend';
  bool _fresh = false;

  final List<MarketApp> _apps = [];
  bool _loading = true;
  bool _loaded = false;
  bool _hasMore = false;
  int _page = 0;
  int _total = 0;
  String? _error;
  int _requestId = 0;

  @override
  void initState() {
    super.initState();
    _loadCategories();
    _load(reset: true);
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _loadCategories() async {
    try {
      final list = await AppMarketApi.categories();
      if (!mounted) return;
      setState(() => _categories = list);
    } catch (_) {
      // 分类失败不阻塞应用列表；列表仍可搜索和按平台筛选。
    }
  }

  Future<void> _load({bool reset = false}) async {
    if (!reset && (_loading || !_hasMore)) return;
    final id = ++_requestId;
    if (reset) {
      setState(() {
        _loading = true;
        _loaded = false;
        _error = null;
      });
    } else {
      setState(() => _loading = true);
    }
    final recommend = _sort == 'recommend';
    final exclude = recommend ? _apps.take(100).map((e) => e.id).join(',') : '';
    final wantFresh = recommend && _fresh;
    try {
      final data = await AppMarketApi.list(
        page: recommend ? 1 : (reset ? 1 : _page + 1),
        pageSize: 20,
        category: _categoryId,
        subCategory: _subCategoryId,
        platform: _platform,
        q: _search.text.trim(),
        sort: _sort,
        exclude: exclude,
        fresh: wantFresh,
      );
      if (!mounted || id != _requestId) return;
      setState(() {
        if (reset) {
          _apps.clear();
          _page = 0;
        }
        _page = data.page;
        _total = data.total;
        _apps.addAll(data.list);
        _hasMore = data.hasMore;
        _loading = false;
        _loaded = true;
        _error = null;
        if (wantFresh) _fresh = false;
      });
    } catch (e) {
      if (!mounted || id != _requestId) return;
      setState(() {
        _loading = false;
        _loaded = true;
        _hasMore = false;
        if (_apps.isEmpty) _error = e.toString();
      });
    }
  }

  Future<void> _refresh() async {
    _requestId++;
    _fresh = _sort == 'recommend';
    await _load(reset: true);
  }

  void _onSearchChanged(String _) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 360), () {
      if (mounted) _load(reset: true);
    });
    setState(() {});
  }

  void _clearSearch() {
    _search.clear();
    _debounceTimer?.cancel();
    _load(reset: true);
  }

  void _selectCategory(String id) {
    if (_categoryId == id) return;
    setState(() {
      _categoryId = id;
      _subCategoryId = '';
    });
    _load(reset: true);
  }

  void _selectSub(String id) {
    if (_subCategoryId == id) return;
    setState(() => _subCategoryId = id);
    _load(reset: true);
  }

  void _selectPlatform(String p) {
    if (_platform == p) return;
    setState(() => _platform = p);
    _load(reset: true);
  }

  void _toggleSort() {
    setState(() {
      _sort = switch (_sort) {
        'recommend' => 'hot',
        'hot' => 'latest',
        _ => 'recommend',
      };
      _fresh = false;
    });
    _load(reset: true);
  }

  Future<bool> _ensureLogin() async {
    if (ApiClient.token != null && ApiClient.token!.isNotEmpty) return true;
    final ok = await Navigator.of(context)
        .push<bool>(MaterialPageRoute(builder: (_) => const LoginPage()));
    return ok == true && ApiClient.token != null;
  }

  Future<void> _openSubmit() async {
    if (!await _ensureLogin() || !mounted) return;
    if (!mounted) return;
    final result = await Navigator.of(context)
        .push<bool>(MaterialPageRoute(builder: (_) => const AppSubmitPage()));
    if (result == true && mounted) _refresh();
  }

  Future<void> _openMine() async {
    if (!await _ensureLogin() || !mounted) return;
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const AppMinePage()));
    if (mounted) _refresh();
  }

  Future<void> _openFavorites() async {
    if (!await _ensureLogin() || !mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            const AppListPage(mode: AppListMode.favorites, title: '收藏的应用'),
      ),
    );
  }

  void _openDetail(MarketApp app) {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => AppDetailPage(appId: app.id)));
  }

  MarketApp? get _featured {
    for (final app in _apps) {
      if (app.featured) return app;
    }
    return null;
  }

  List<AppCategory> get _subCategories {
    for (final c in _categories) {
      if (c.id == _categoryId) return c.children;
    }
    return const [];
  }

  @override
  Widget build(BuildContext context) {
    return ImmersivePage(
      child: Column(
        children: [
          GlassTopBar(
            title: '应用市场',
            subtitle: '社区精选 · 人工审核后才上架',
            solid: true,
            actions: [
              IconCircleButton(
                icon: Icons.bookmark_border_rounded,
                size: 36,
                iconSize: 17,
                tooltip: '我的收藏',
                onTap: _openFavorites,
              ),
              const SizedBox(width: 2),
              IconCircleButton(
                icon: Icons.add_rounded,
                size: 36,
                iconSize: 18,
                background: const Color(AppColors.accent)
                    .withValues(alpha: 0.12),
                color: const Color(AppColors.accent),
                tooltip: '投稿应用',
                onTap: _openSubmit,
              ),
              const SizedBox(width: 4),
            ],
          ),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _body() {
    return RefreshIndicator(
      color: const Color(AppColors.accent),
      backgroundColor: const Color(AppColors.card),
      onRefresh: _refresh,
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n.metrics.axis == Axis.vertical &&
              n.metrics.extentAfter < n.metrics.viewportDimension) {
            _load();
          }
          return false;
        },
        child: CustomScrollView(
          scrollCacheExtent: const ScrollCacheExtent.pixels(300),
          physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics(),
          ),
          slivers: [
            SliverToBoxAdapter(child: _filters()),
            if (!_loaded)
              SliverToBoxAdapter(child: ShimmerScope(child: _MarketSkeleton()))
            else if (_error != null && _apps.isEmpty)
              SliverToBoxAdapter(child: _errorState())
            else if (_apps.isEmpty)
              SliverToBoxAdapter(child: _emptyState())
            else ...[
              if (_featured != null) ...[
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpace.gutter,
                      AppSpace.x4,
                      AppSpace.gutter,
                      0,
                    ),
                    child: FeaturedAppCard(
                      app: _featured!,
                      onTap: () => _openDetail(_featured!),
                    ),
                  ),
                ),
              ],
              SliverToBoxAdapter(
                child: AppSectionTitle(
                  title: _search.text.trim().isNotEmpty
                      ? '搜索结果'
                      : (_sort == 'recommend' ? '为你推荐' : '全部应用'),
                  subtitle: _apps.isEmpty
                      ? null
                      : (_sort == 'recommend'
                            ? '根据你的浏览、下载、收藏和评分动态排序'
                            : '共 $_total 款 · 每一款都由社区人工审核'),
                  action: '我的投稿',
                  onAction: _openMine,
                  padding: const EdgeInsets.fromLTRB(
                    AppSpace.gutter,
                    AppSpace.x6,
                    AppSpace.gutter,
                    AppSpace.x3,
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpace.gutter,
                  0,
                  AppSpace.gutter,
                  0,
                ),
                sliver: SliverList.separated(
                  itemCount: _apps.length,
                  separatorBuilder: (_, _) =>
                      const SizedBox(height: AppSpace.x2),
                  itemBuilder: (context, i) {
                    final app = _apps[i];
                    return StaggerReveal(
                      key: ValueKey('market-app-${app.id}'),
                      index: i,
                      delay: const Duration(milliseconds: 50),
                      duration: const Duration(milliseconds: 450),
                      offsetY: 24,
                      child: AppListTile(
                        app: app,
                        onTap: () => _openDetail(app),
                        trailing: const Icon(
                          Icons.chevron_right_rounded,
                          size: 20,
                          color: Color(AppColors.textTertiary),
                        ),
                      ),
                    );
                  },
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.only(
                    bottom: MediaQuery.paddingOf(context).bottom + 30,
                  ),
                  child: LoadMoreFooter(
                    loading: _loading,
                    hasMore: _hasMore,
                    onTap: _hasMore ? () => _load() : null,
                    endLabel: '— 没有更多了 —',
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _filters() {
    final hasSearch = _search.text.trim().isNotEmpty;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpace.gutter,
        AppSpace.x3,
        AppSpace.gutter,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 44,
            decoration: BoxDecoration(
              color: const Color(AppColors.card).withValues(alpha: 0.72),
              borderRadius: AppRadius.rPill,
              border: Border.all(color: const Color(AppColors.border)),
            ),
            child: Row(
              children: [
                const Padding(
                  padding: EdgeInsets.only(left: 14, right: 8),
                  child: Icon(
                    Icons.search_rounded,
                    size: 19,
                    color: Color(AppColors.textTertiary),
                  ),
                ),
                Expanded(
                  child: TextField(
                    controller: _search,
                    onChanged: _onSearchChanged,
                    onSubmitted: (_) => _load(reset: true),
                    textInputAction: TextInputAction.search,
                    cursorColor: const Color(AppColors.accent),
                    style: AppType.body.copyWith(fontSize: 14),
                    decoration: InputDecoration(
                      hintText: '搜索应用、包名或用途',
                      hintStyle: AppType.bodySm.copyWith(
                        color: const Color(AppColors.textTertiary),
                      ),
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 11),
                    ),
                  ),
                ),
                if (hasSearch)
                  GestureDetector(
                    onTap: _clearSearch,
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 12),
                      child: Icon(
                        Icons.close_rounded,
                        size: 17,
                        color: Color(AppColors.textTertiary),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: AppSpace.x3),
          Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      TagPill(
                        label: '我的投稿',
                        compact: true,
                        icon: Icons.upload_file_rounded,
                        onTap: _openMine,
                      ),
                      const SizedBox(width: 6),
                      TagPill(
                        label: '我的收藏',
                        compact: true,
                        icon: Icons.bookmark_border_rounded,
                        onTap: _openFavorites,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              PressableScale(
                onTap: _openSubmit,
                child: Container(
                  height: 28,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    color: const Color(AppColors.accent)
                        .withValues(alpha: 0.10),
                    borderRadius: AppRadius.rPill,
                    border: Border.all(
                      color: const Color(AppColors.accent)
                          .withValues(alpha: 0.22),
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.add_rounded,
                        size: 14,
                        color: Color(AppColors.accent),
                      ),
                      const SizedBox(width: 3),
                      Text(
                        '投稿',
                        style: AppType.caption.copyWith(
                          color: const Color(AppColors.accent),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.x4),
          if (_categories.isNotEmpty) ...[
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  TagPill(
                    label: '全部分类',
                    active: _categoryId.isEmpty,
                    onTap: () => _selectCategory(''),
                  ),
                  for (final c in _categories) ...[
                    const SizedBox(width: 8),
                    TagPill(
                      label: c.name,
                      active: _categoryId == c.id,
                      onTap: () => _selectCategory(c.id),
                    ),
                  ],
                ],
              ),
            ),
            if (_subCategories.isNotEmpty) ...[
              const SizedBox(height: 8),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    TagPill(
                      label: '全部子类',
                      compact: true,
                      active: _subCategoryId.isEmpty,
                      onTap: () => _selectSub(''),
                    ),
                    for (final s in _subCategories) ...[
                      const SizedBox(width: 6),
                      TagPill(
                        label: s.name,
                        compact: true,
                        active: _subCategoryId == s.id,
                        onTap: () => _selectSub(s.id),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ],
          const SizedBox(height: AppSpace.x4),
          Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final (value, label) in const [
                        ('', '全部平台'),
                        ('android', 'Android'),
                        ('ios', 'iOS'),
                        ('harmony', '鸿蒙'),
                        ('windows', 'Windows'),
                      ]) ...[
                        TagPill(
                          label: label,
                          compact: true,
                          active: _platform == value,
                          onTap: () => _selectPlatform(value),
                        ),
                        if (value != 'windows') const SizedBox(width: 6),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              PressableScale(
                onTap: _toggleSort,
                scale: 0.94,
                child: Container(
                  height: 28,
                  padding: const EdgeInsets.symmetric(horizontal: 9),
                  decoration: BoxDecoration(
                    color: const Color(AppColors.card),
                    borderRadius: AppRadius.rPill,
                    border: Border.all(color: const Color(AppColors.border)),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        switch (_sort) {
                          'recommend' => Icons.auto_awesome_rounded,
                          'hot' => Icons.local_fire_department_rounded,
                          _ => Icons.schedule_rounded,
                        },
                        size: 13,
                        color: const Color(AppColors.textSecondary),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        switch (_sort) {
                          'recommend' => '推荐',
                          'hot' => '最热',
                          _ => '最新',
                        },
                        style: AppType.caption.copyWith(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Icon(
                        Icons.keyboard_arrow_down_rounded,
                        size: 14,
                        color: Color(AppColors.textTertiary),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _emptyState() {
    final hasFilter =
        _search.text.trim().isNotEmpty ||
        _categoryId.isNotEmpty ||
        _platform.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(top: 36),
      child: EmptyState(
        icon: Icons.apps_rounded,
        title: hasFilter ? '没有找到相关应用' : '应用市场正在上架中',
        message: hasFilter
            ? '换个关键词或筛选条件试试'
            : '社区应用由用户投稿、人工审核后上架。\n你可以先把好用的应用分享给大家。',
        actionLabel: hasFilter ? '清除筛选' : '投稿第一个应用',
        onAction: () {
          if (hasFilter) {
            _search.clear();
            setState(() {
              _categoryId = '';
              _subCategoryId = '';
              _platform = '';
            });
            _load(reset: true);
          } else {
            _openSubmit();
          }
        },
      ),
    );
  }

  Widget _errorState() {
    return Padding(
      padding: const EdgeInsets.only(top: 36),
      child: EmptyState(
        icon: Icons.cloud_off_rounded,
        title: '应用列表加载失败',
        message: _error ?? '请检查网络后重试',
        actionLabel: '重新加载',
        onAction: () => _load(reset: true),
      ),
    );
  }
}

/// 首屏骨架：搜索和筛选已真实展示，列表部分用与真实行同高的占位。
class _MarketSkeleton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.gutter,
        AppSpace.x4,
        AppSpace.gutter,
        60,
      ),
      child: Column(
        children: List.generate(
          4,
          (_) => Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.x2),
            child: Container(
              height: 116,
              padding: const EdgeInsets.all(AppSpace.x3),
              decoration: BoxDecoration(
                color: const Color(AppColors.card).withValues(alpha: 0.42),
                borderRadius: BorderRadius.circular(AppRadius.lg),
                border: Border.all(color: const Color(AppColors.hairline)),
              ),
              child: const Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SkeletonBox(width: 62, height: 62, radius: AppRadius.md),
                  SizedBox(width: AppSpace.x3),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SkeletonBox(width: 140, height: 15),
                        SizedBox(height: 9),
                        SkeletonBox(width: 90, height: 10),
                        SizedBox(height: 10),
                        SkeletonBox(height: 10),
                        SizedBox(height: 6),
                        SkeletonBox(width: 200, height: 10),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
