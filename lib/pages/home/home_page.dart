/// 社区首页：沉浸黑单列信息流（关注 / 推荐）
///
/// 版式：关注·推荐分段 →（二楼分开口）→ 搜索 → Banner → 内容卡。
/// 手势：列表在顶部时下拉，未过阈值交给刷新；超过阈值从分开口撑开二楼。
/// 分开口在「关注/推荐」与「热门话题」之间，手往下拉时顶部块均匀渐隐，
/// 松手只看已拉开比例，不做甩动速度豁免（参考 flutter_pulltorefresh 的
/// TwoLevelHeader：headerTriggerDistance 刷新 / twiceTriggerDistance 进二楼）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/physics.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../api/app_market_api.dart';
import '../../api/client.dart';
import '../../config.dart';
import '../../design/components.dart';
import '../../design/shared_element.dart';
import '../../features/emoji/text_emoji.dart';
import 'af_workbench_page.dart';
import '../../models/app_market.dart';
import '../../models/feed_item.dart';
import '../apps/app_detail_page.dart';
import '../apps/app_market_page.dart';
import '../../services/app_market_bus.dart';
import '../apps/app_widgets.dart';
import '../../widgets/banner_carousel.dart';
import '../../widgets/hot_announcement_card.dart';
import '../../widgets/post_card.dart';
import '../../widgets/user_avatar.dart';
import '../game/petalwake_page.dart';
import '../favorites/favorites_page.dart';
import '../feedback/feedback_page.dart';
import '../discover/ranking_page.dart';
import '../discover/topic_detail_page.dart';
import '../discover/topic_page.dart';
import 'home_discovery_widgets.dart';
import '../mine/login_page.dart';
import '../mine/task_center_page.dart';
import '../post/post_detail.dart';
import '../post/post_editor.dart';
import '../search/search_page.dart';
import '../user/user_profile.dart';
import '../../services/hot_update.dart';
import '../../services/notify_bus.dart';
import '../../services/publish_bus.dart';
import '../message/notif_list_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, this.onFloorOpenChanged});

  /// 二楼展开/收起时通知外层（用于隐藏底部导航，避免中心发布键抢点击）
  final ValueChanged<bool>? onFloorOpenChanged;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with SingleTickerProviderStateMixin {
  int _tab = 1; // 0=关注 1=推荐（默认推荐）
  final List<FeedItem> _items = [];
  bool _loading = false;
  bool _loaded = false;
  bool _tabLoading = false;
  bool _refreshing = false;

  /// 下拉刷新缝隙是否正在展示加载。只覆盖“松手后停在刷新线”的场景，
  /// 不跟「换一批」等程序化刷新共用，避免所有刷新都弹开缝隙。
  bool _gapRefresh = false;
  double _refreshTurns = 0;
  int _feedRequest = 0;
  int _page = 0;
  bool _hasMore = true;
  String? _error;
  final ScrollController _scroll = ScrollController();
  final ValueNotifier<double> _scrollProgress = ValueNotifier<double>(0);
  final ScrollController _panelScroll = ScrollController();

  // ---------------------------------------------------------- 首页应用发现
  List<MarketApp> _apps = const [];
  List<HomeTopic> _topics = const [];
  bool _appsLoading = true;
  String? _appsError;
  int _discoveryRequest = 0;

  /// 二楼上滑收起：原始指针跟踪，避免和面板自己的 ListView 抢手势
  bool _panelDragReady = false;
  bool _panelPulling = false;
  double _panelStartY = 0;

  /// 下拉进度 0..1：0=一楼，1=二楼。拖拽与松手后的弹簧动画共用这一个值，
  /// 所有位移/透明度都由它推导，保证「跟手 → 松手」不会有跳变。
  late final AnimationController _pullCtl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
  );

  /// 列表到顶后先走这么多「准备」行程，避免 iOS 回弹或误触直接撩开二楼
  static const double kStartIntercept = 36;

  /// 阻尼：真正拉开缝隙的距离略小于手指行程（SecondFloorBehavior 的 dampingRatio）
  static const double kDragScale = 0.92;

  /// 第一段阈值：松手进入刷新（不再依赖 RefreshIndicator 自带的 25% 视口触发线，
  /// 否则刷新线会高于二楼线，二者互相打架）。
  static const double kRefreshProgress = 0.07;

  /// 刷新缝隙的固定停留高度：松手后先停在这里显示加载，刷新完成再合上。
  static const double kRefreshHoldPx = 72;

  /// 第二段阈值：松手直接进二楼，否则回弹一楼。
  /// 不按甩动速度放行：没过这条线就是刷新，避免轻甩一下误进二楼。
  static const double kCommitProgress = 0.18;

  /// 二楼上滑收起：手指行程超过满开行程的多少比例就判定关闭
  static const double kCloseProgress = 0.66;

  bool _floorOpen = false;

  /// 底栏是否已因二楼手势退场。下拉一开始就退，避免黑条压在二楼底部。
  bool _chromeHidden = false;

  void _setChromeHidden(bool v) {
    if (_chromeHidden == v) return;
    _chromeHidden = v;
    widget.onFloorOpenChanged?.call(v);
  }

  bool _pulling = false;
  double _dragStartY = 0;
  double _lastMoveY = 0;
  int _lastMoveTs = 0;
  double _flingVel = 0; // px/s，松手时作为弹簧初速度

  /// 分开口的纵坐标 = 顶部块（标题 + 关注/推荐）的真实高度，首帧后实测回填
  final GlobalKey _topKey = GlobalKey();
  double _seamY = 58;

  /// 二楼面板顶部色（背景渐变起点），状态栏区也用它，保证连成一片
  static const Color kFloorTop = Color(0xFF0B0D10);

  /// 二楼满开所需的手指行程 = 分开口到屏幕底部的距离。
  /// 位移按像素 1:1 映射到手指，拖多少画面就走多少，手感才跟得住。
  double _maxOpen = 700;

  @override
  void initState() {
    super.initState();
    _load(refresh: true);
    _loadDiscovery();
    _loadRecentTool();
    PublishBus.completed.addListener(_onPublishCompleted);
  }

  void _onPublishCompleted() {
    if (mounted) _load(refresh: true);
  }

  // ---------------------------------------------------------- 最近使用的工具
  String? _recentTool;
  DateTime? _recentAt;

  Future<void> _loadRecentTool() async {
    final sp = await SharedPreferences.getInstance();
    final k = sp.getString('floor_recent_tool');
    final t = sp.getInt('floor_recent_at');
    if (!mounted) return;
    setState(() {
      _recentTool = k;
      _recentAt = t == null ? null : DateTime.fromMillisecondsSinceEpoch(t);
    });
  }

  Future<void> _markRecentTool(String label) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString('floor_recent_tool', label);
    await sp.setInt('floor_recent_at', DateTime.now().millisecondsSinceEpoch);
    if (!mounted) return;
    setState(() {
      _recentTool = label;
      _recentAt = DateTime.now();
    });
  }

  String _agoLabel(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return '刚刚';
    if (d.inMinutes < 60) return '${d.inMinutes} 分钟前';
    if (d.inHours < 24) return '${d.inHours} 小时前';
    if (d.inDays == 1) return '昨天';
    return '${d.inDays} 天前';
  }

  void _measureSeam() {
    // 顶栏会随滚动收缩；只在回到顶部时记录展开态高度，避免把收起高度写进 seam。
    if (_scrollProgress.value > 0.001) return;
    final h = _topKey.currentContext?.size?.height;
    if (h == null || h <= 0) return;
    if ((h - _seamY).abs() > 0.5 && mounted) {
      setState(() => _seamY = h);
    }
  }

  @override
  void dispose() {
    PublishBus.completed.removeListener(_onPublishCompleted);
    _pullCtl.dispose();
    _scroll.dispose();
    _scrollProgress.dispose();
    _panelScroll.dispose();
    super.dispose();
  }

  Future<void> _load({bool refresh = false}) async {
    if (_loading && !refresh) return;
    if (!_hasMore && !refresh) return;
    final req = ++_feedRequest;
    final tab = _tab;
    setState(() {
      _loading = true;
      if (refresh) _error = null;
    });
    try {
      final seen = tab == 1 ? _items.take(100).map((e) => e.id).join(',') : '';
      final p = await ApiClient.feed(
        tab: tab == 0 ? 'follow' : 'recommend',
        // 推荐流用 exclude 做游标：每次都从剩余候选取第一页，避免 offset 与排除叠加后跳空。
        page: tab == 1 ? 1 : (refresh ? 1 : _page + 1),
        size: 10,
        exclude: seen,
        fresh: refresh && tab == 1,
      );
      // 切 Tab / 连续刷新时，旧请求可能后返回：只认最后一次请求。
      if (!mounted || req != _feedRequest) return;
      setState(() {
        if (refresh) {
          _items.clear();
          _page = 0;
        }
        _page = p.page;
        _hasMore = p.hasMore;
        _items.addAll(p.list);
        _loaded = true;
        _loading = false;
        _tabLoading = false;
      });
    } catch (e) {
      if (!mounted || req != _feedRequest) return;
      setState(() {
        _loaded = true;
        _loading = false;
        _tabLoading = false;
        _error = '$e';
      });
    }
  }

  void _switchTab(int i) {
    if (_tab == i) return;
    setState(() {
      _tab = i;
      _page = 0;
      _hasMore = true;
      _error = null;
      // 保留旧列表直到新数据回来，避免切 Tab 先闪一屏空白转圈。
      _tabLoading = true;
    });
    _load(refresh: true);
  }

  // ------------------------------------------------------ 应用 / 话题发现
  Future<List<MarketApp>?> _fetchApps() async {
    try {
      final page = await AppMarketApi.list(pageSize: 20, sort: 'recommend');
      return page.list;
    } catch (_) {
      return null;
    }
  }

  Future<List<HomeTopic>?> _fetchTopics() async {
    try {
      final list = await ApiClient.topicsHot();
      return list
          .map(HomeTopic.fromJson)
          .where((t) => t.name.trim().isNotEmpty)
          .toList();
    } catch (_) {
      return null;
    }
  }

  Future<void> _loadDiscovery() async {
    final id = ++_discoveryRequest;
    final firstLoad = _apps.isEmpty && _topics.isEmpty;
    if (mounted && firstLoad) {
      setState(() {
        _appsLoading = true;
        _appsError = null;
      });
    }

    // 两个接口互不依赖，并行拉取，缩短首屏等待。
    final result = await Future.wait<Object?>([_fetchApps(), _fetchTopics()]);
    final apps = result[0] as List<MarketApp>?;
    final topics = result[1] as List<HomeTopic>?;
    if (!mounted || id != _discoveryRequest) return;

    setState(() {
      // 刷新失败时保留已有内容，不用空数组把已显示的橱窗/话题抹掉。
      if (apps != null) _apps = apps;
      if (topics != null) _topics = topics;
      _appsLoading = false;
      _appsError = apps == null && _apps.isEmpty ? '应用橱窗暂时没连上' : null;
    });
  }

  Future<void> _openAppMarket() async {
    final revision = AppMarketBus.value;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const AppMarketPage()),
    );
    // 只是浏览/返回时保留已加载的橱窗，不再整页拉取；只有投稿等操作
    // 真正改变了应用数据，才补一次，避免首页图片和骨架屏重新闪。
    if (mounted && AppMarketBus.value != revision) {
      await _loadDiscovery();
    }
  }

  void _openAppDetail(MarketApp app) {
    Navigator.push(
      context,
      AppPageRoute(builder: (_) => AppDetailPage(appId: app.id)),
    );
  }

  void _openTopic(HomeTopic topic) {
    Navigator.push(
      context,
      AppPageRoute(
        builder: (_) => TopicDetailPage(topic: topic.name, count: topic.count),
      ),
    );
  }

  void _openTopics() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const TopicPage()),
    );
  }

  Future<void> _openEditor() async {
    final ok = await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const PostEditorPage()),
    );
    if (ok == true && mounted) _load(refresh: true);
  }

  void _openDetail(FeedItem it) {
    Navigator.push(
      context,
      AppPageRoute(builder: (_) => PostDetailPage(postId: it.id)),
    );
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _measureSeam());
    // 一楼列表和二楼面板只在数据/尺寸变化时重建一次；下拉过程中的每一帧
    // 只重建外侧的裁剪/位移层，不再 setState 重建整棵首页树。
    final homeList = _homeList();
    final floorPanel = _floorPanel();
    return ImmersivePage(
      // 二楼展开时，状态栏区域也要铺二楼顶色，不能露出一楼纯黑
      child: AnimatedBuilder(
        animation: _pullCtl,
        builder: (context, _) {
          final p = _pullCtl.value.clamp(0.0, 1.0);
          return Stack(
            fit: StackFit.expand,
            children: [
              SafeArea(
                bottom: false,
                child: LayoutBuilder(
                  builder: (context, box) {
                    final h = box.maxHeight;
                    final seam = _seamY.clamp(0.0, h);
                    // 满开时一楼必须整屏退出：只推到 seam 会留下底部一截黑块盖住二楼。
                    _maxOpen = (h + 24).clamp(1.0, h + 24);
                    final px = p * _maxOpen;
                    final floorTop = seam * (1 - p); // 展开中分界线从 seam 上移到 0
                    final push = px;
                    final lift = px * 0.10;
                    final gapH = push + lift;
                    final body = Stack(
                      children: [
                        // 二楼：用裁剪矩形从分开口向上下撑开，而不是整页平移
                        if (p > 0.0001)
                          Positioned.fill(
                            child: ClipRect(
                              clipper: _SeamClipper(
                                top: floorTop,
                                px: px,
                                height: h,
                              ),
                              child: IgnorePointer(
                                key: _floorOpen
                                    ? const ValueKey('home-floor-open')
                                    : null,
                                ignoring: !_floorOpen,
                                child: Transform.translate(
                                  offset: Offset(0, floorTop),
                                  child: RepaintBoundary(child: floorPanel),
                                ),
                              ),
                            ),
                          ),
                        // 下拉刷新缝隙：只在刷新/下拉阶段出现，盖在二楼顶上。
                        // 过了二楼主线后逐渐退场，把空间让给正在展开的二楼。
                        if (gapH > 30 &&
                            (_gapRefresh ||
                                (!_floorOpen && p < kCommitProgress)))
                          _pullGapLayer(
                            top: seam - lift,
                            height: gapH,
                            p: p,
                          ),
                        // 一楼下半部分：热门话题 / Banner / 信息流，整体被向下推
                        Positioned.fill(
                          child: Transform.translate(
                            offset: Offset(0, push),
                            child: Opacity(
                              // 二楼满开时一楼必须彻底退场，否则列表顶部会压在二楼底部。
                              opacity: (1 - p).clamp(0.0, 1.0),
                              child: IgnorePointer(
                                ignoring: p > 0.02,
                                child: RepaintBoundary(child: homeList),
                              ),
                            ),
                          ),
                        ),
                        // 一楼顶部块：标题 + 关注/推荐，随下拉均匀变透明
                        Positioned(
                          top: -lift,
                          left: 0,
                          right: 0,
                          child: Opacity(
                            opacity: (1 - p * 1.6).clamp(0.0, 1.0),
                            child: IgnorePointer(
                              ignoring: p > 0.02,
                              // 内容会从顶栏下方滑过，顶栏始终铺实底。
                              child: ColoredBox(
                                color: const Color(AppColors.bg),
                                child: Column(
                                  key: _topKey,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    AnimatedBuilder(
                                      animation: _scrollProgress,
                                      builder: (_, _) => _header(_collapseT),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                        // 分开口的小把手：只有图形，没有文字
                        if (p > 0.02 && p < 0.995)
                          Positioned(
                            top: seam - lift - 7,
                            left: 0,
                            right: 0,
                            child: IgnorePointer(
                              child: Center(
                                child: Container(
                                  width: 30 + 26 * p,
                                  height: 4,
                                  decoration: BoxDecoration(
                                    color: const Color(
                                      AppColors.textPrimary,
                                    ).withValues(alpha: 0.18 + 0.22 * (1 - p)),
                                    borderRadius: BorderRadius.circular(99),
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    );
                    return Listener(
                      onPointerDown: _onPullDown,
                      onPointerMove: _onPullMove,
                      onPointerUp: _onPullUp,
                      onPointerCancel: _onPullUp,
                      child: body,
                    );
                  },
                ),
              ),
              // 状态栏区底色：跟二楼顶部同色，随展开进度淡入
              if (p > 0.001)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: MediaQuery.paddingOf(context).top,
                  child: IgnorePointer(
                    child: Opacity(
                      opacity: p,
                      child: const ColoredBox(color: kFloorTop),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  double get _collapseT => Curves.easeOutCubic.transform(_scrollProgress.value);

  Widget _homeList() {
    return Padding(
      padding: EdgeInsets.only(top: _seamY),
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          // 轮播是横向 PageView，别把它的滚动当成首页纵向进度。
          if (n.metrics.axis != Axis.vertical) return false;
          if (n.metrics.extentAfter < n.metrics.viewportDimension) _load();
          _scrollProgress.value = ((n.metrics.pixels - 18) / 78).clamp(
            0.0,
            1.0,
          );
          return false;
        },
        child: RefreshIndicator.noSpinner(
          key: const ValueKey('home-refresh'),
          onRefresh: _refreshHome,
          // 手势由首页自己按双阈值处理；这里只保留 show() 程序化入口，
          // 避免原生 RefreshIndicator 的 25% 视口阈值和二楼主线冲突。
          notificationPredicate: (_) => false,
          child: CustomScrollView(
            controller: _scroll,
            scrollCacheExtent: const ScrollCacheExtent.pixels(300),
            physics: const AlwaysScrollableScrollPhysics(
              parent: ClampingScrollPhysics(),
            ),
            slivers: [
              // 0. 搜索卡跟着内容一起滚走，滚到一定位置只在顶栏留圆形按钮。
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
                  child: _searchBar(),
                ),
              ),
              // 1. 运营轮播：保持首页原有版式，只把运营位接回第一屏。
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 10),
                  child: BannerCarousel(),
                ),
              ),
              // 2. 远程公告：后台开启时插在轮播和今日焦点之间，可关闭。
              const SliverToBoxAdapter(child: HotAnnouncementCard()),
              // 3. 今日焦点：一条帖子撑起首页第一屏，不再先铺满应用卡。
              SliverToBoxAdapter(child: _leadStory()),
              // 4. 应用橱窗：一排图标，可被热更新 feature_flags.apps 关闭。
              SliverToBoxAdapter(
                child: ValueListenableBuilder<HotConfig>(
                  valueListenable: HotUpdateService.instance.config,
                  builder: (context, cfg, _) => cfg.featureEnabled('apps')
                      ? _appShelf()
                      : const SizedBox.shrink(),
                ),
              ),
              // 5. 今晚聊什么：话题横滑。
              SliverToBoxAdapter(child: _topicRail()),
              // 6. 正在流动：双列杂志式内容流。
              SliverToBoxAdapter(child: _feedHeader()),
              _feedSliver(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pullGapLayer({
    required double top,
    required double height,
    required double p,
  }) {
    final armed = p >= kRefreshProgress;
    final label = _gapRefresh
        ? '正在刷新'
        : armed
        ? '松开刷新'
        : '下拉刷新';
    final emerge = ((height - 26) / 24).clamp(0.0, 1.0);
    final color = armed
        ? const Color(AppColors.accent)
        : const Color(AppColors.textSecondary);
    return Positioned(
      top: top,
      left: 0,
      right: 0,
      height: height,
      child: IgnorePointer(
        child: Opacity(
          opacity: emerge,
          child: Container(
            key: const ValueKey('home-pull-gap'),
            clipBehavior: Clip.hardEdge,
            decoration: BoxDecoration(
              color: kFloorTop,
              border: Border(
                bottom: BorderSide(
                  color: Colors.white.withValues(alpha: 0.035),
                ),
              ),
            ),
            child: Center(
              child: Transform.translate(
                offset: Offset(0, (1 - emerge) * 8),
                child: Semantics(
                  liveRegion: true,
                  label: label,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_gapRefresh)
                        SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                            key: const ValueKey('home-pull-gap-spinner'),
                            strokeWidth: 2.2,
                            color: const Color(AppColors.accent),
                            backgroundColor: Colors.white.withValues(alpha: 0.08),
                          ),
                        )
                      else
                        Container(
                          width: 24,
                          height: 24,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: const Color(
                              AppColors.accent,
                            ).withValues(alpha: 0.09),
                            border: Border.all(
                              color: const Color(AppColors.accent).withValues(
                                alpha: armed ? 0.38 : 0.16,
                              ),
                            ),
                          ),
                          child: AnimatedRotation(
                            turns: armed ? 0.5 : 0.0,
                            duration: const Duration(milliseconds: 160),
                            curve: Curves.easeOutCubic,
                            child: Icon(
                              Icons.keyboard_arrow_down_rounded,
                              size: 15,
                              color: color,
                            ),
                          ),
                        ),
                      const SizedBox(width: 8),
                      Text(
                        label,
                        key: const ValueKey('home-pull-gap-text'),
                        style: TextStyle(
                          fontSize: 11.5,
                          height: 1.2,
                          letterSpacing: 0.25,
                          fontWeight: FontWeight.w600,
                          color: color,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _refreshHome() async {
    // 下拉超过阈值会进入二楼，此时 RefreshIndicator 也会收到触发；
    // 不能让它再叠加一次刷新，否则二楼展开的同时列表在底下偷偷重载。
    if (_floorOpen || _pullCtl.value >= kCommitProgress) return;
    if (_refreshing) return;
    if (mounted) setState(() => _refreshing = true);
    try {
      await Future.wait([_load(refresh: true), _loadDiscovery()]);
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  // ---------------------------------------------------------------- 下拉手势
  void _onPullDown(PointerDownEvent e) {
    _pulling = false;
    // 刷新缝隙正在加载时不再接管下拉，避免把停留中的缝隙又拖走。
    if (_gapRefresh || _refreshing) return;
    _dragStartY = e.position.dy;
    _lastMoveY = e.position.dy;
    _lastMoveTs = e.timeStamp.inMilliseconds;
    _flingVel = 0;

    // 二楼已经展开时，下拉交给二楼面板自己的“上滑收起”，不再重复开楼。
    if (_floorOpen) return;
    // 只有列表在顶部才接管：信息流中间往下拖仍然是正常滚动/刷新。
    final pos = _scroll.hasClients ? _scroll.position : null;
    if (pos == null || pos.pixels > 0.5) return;
    // 横向轮播/详情手势不在这里拦；纵向位移在 move 里判定。
    _pulling = true;
  }

  void _onPullMove(PointerMoveEvent e) {
    if (!_pulling) return;
    if (_gapRefresh || _refreshing) return;
    final dy = e.position.dy - _dragStartY;
    // 先吃掉一段准备行程，之后按阻尼系数 1:1 跟手
    final px = (dy - kStartIntercept) * kDragScale;
    if (px <= 0) {
      if (_pullCtl.value != 0) _pullCtl.value = 0;
      _setChromeHidden(false);
      return;
    }
    final p = (px / _maxOpen).clamp(0.0, 1.0);
    _pullCtl.value = p;
    _setChromeHidden(p >= kCommitProgress);

    final ts = e.timeStamp.inMilliseconds;
    final dt = ts - _lastMoveTs;
    if (dt > 0) {
      final v = (e.position.dy - _lastMoveY) / dt * 1000;
      _flingVel = _flingVel * 0.55 + v * 0.45;
      _lastMoveY = e.position.dy;
      _lastMoveTs = ts;
    }
  }

  void _onPullUp(PointerEvent e) {
    if (!_pulling) return;
    _pulling = false;
    final p = _pullCtl.value;
    if (p <= 0) {
      _setChromeHidden(false);
      return;
    }
    // 双阈值：过二楼线直接进二楼（不刷新）；只过刷新线则把缝隙停在
    // 加载高度，刷新完成后自动合上；都没过只回弹。
    if (p >= kCommitProgress) {
      _springTo(1.0, velocity: _flingVel / _maxOpen);
      return;
    }
    if (p >= kRefreshProgress) {
      _beginGapRefresh(velocity: _flingVel / _maxOpen);
      return;
    }
    _springTo(0.0, velocity: _flingVel / _maxOpen);
  }

  /// 松手后的刷新：缝隙先停在固定高度，加载完成后弹簧归零。
  void _beginGapRefresh({required double velocity}) {
    if (_gapRefresh || _refreshing) return;
    setState(() => _gapRefresh = true);
    _springTo(
      (kRefreshHoldPx / _maxOpen).clamp(0.03, 0.12),
      velocity: velocity.clamp(-2.5, 2.5),
    );
    unawaited(_runGapRefresh());
  }

  Future<void> _runGapRefresh() async {
    final started = DateTime.now();
    try {
      await _refreshHome();
    } catch (_) {
      // _refreshHome 内部已把加载状态落到 UI；这里只负责让缝隙一定合上。
    }
    // 网络很快时也给加载图标一个可读的最短停留，不要闪一下就没。
    final minShow = const Duration(milliseconds: 420);
    final elapsed = DateTime.now().difference(started);
    if (elapsed < minShow) {
      await Future<void>.delayed(minShow - elapsed);
    }
    if (!mounted) return;
    setState(() => _gapRefresh = false);
    if (!_pulling && !_floorOpen) _springTo(0.0);
  }

  /// 弹簧归位：临界阻尼，没有生硬的 ease 停顿，也不会来回弹
  void _springTo(double target, {double velocity = 0}) {
    if (target == 1.0) {
      HapticFeedback.mediumImpact();
      _setChromeHidden(true);
      if (!_floorOpen) {
        setState(() => _floorOpen = true);
      }
    }
    final f = _pullCtl.animateWith(
      SpringSimulation(
        const SpringDescription(mass: 1, stiffness: 210, damping: 26),
        _pullCtl.value,
        target,
        velocity.clamp(-8.0, 8.0),
      ),
    );
    // animateWith 结束后状态是 completed 而不是 dismissed，
    // 必须在这里复位，否则收起一次后 _floorOpen 永远为 true，再拉就拉不动了
    if (target == 0) {
      f.whenCompleteOrCancel(() {
        if (!mounted) return;
        if (_pullCtl.value <= 0.02) {
          _pullCtl.value = 0;
          _setChromeHidden(false);
          if (_floorOpen) {
            setState(() => _floorOpen = false);
          }
        }
      });
    }
  }

  void _closeFloor() {
    if (!_floorOpen) return;
    HapticFeedback.lightImpact();
    // 弹簧回到一楼后，由 spring 完成回调复位 _floorOpen
    _springTo(0);
  }

  // ---------------------------------------------------- 二楼内上滑收起（跟手）
  void _onPanelDown(PointerDownEvent e) {
    _panelPulling = false;
    _panelStartY = e.position.dy;
    // 只有面板列表已经滚到顶，才接管上滑收起
    _panelDragReady =
        _floorOpen &&
        _panelScroll.hasClients &&
        _panelScroll.position.pixels <= 0.5;
  }

  void _onPanelMove(PointerMoveEvent e) {
    if (!_panelDragReady) return;
    final dy = e.position.dy - _panelStartY;
    if (dy >= -8) return; // 往下拉或还没过死区：交给列表
    if (_panelScroll.hasClients && _panelScroll.position.pixels > 0.5) {
      _panelDragReady = false; // 列表先被滚动了，本次不再接管
      return;
    }
    _panelPulling = true;
    _pullCtl.stop();
    final closePx = (-dy - 8) * kDragScale;
    _pullCtl.value = (1 - closePx / _maxOpen).clamp(0.0, 1.0);
  }

  void _onPanelUp(PointerEvent e) {
    if (!_panelDragReady) return;
    _panelDragReady = false;
    if (!_panelPulling) return;
    _panelPulling = false;
    // 收过一定比例就关到底，否则弹回二楼
    _springTo(_pullCtl.value < kCloseProgress ? 0.0 : 1.0);
  }

  // ---------------------------------------------------------------- 二楼
  Widget _floorPanel() {
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Listener(
      key: const ValueKey('home-floor-panel'),
      onPointerDown: _onPanelDown,
      onPointerMove: _onPanelMove,
      onPointerUp: _onPanelUp,
      onPointerCancel: _onPanelUp,
      child: GestureDetector(
        // 点空白处收起：只留 onTap，避免和列表滚动抢手势
        onTap: _closeFloor,
        child: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [kFloorTop, Color(AppColors.bg)],
            ),
          ),
          child: _FloorReveal(
            animation: _pullCtl,
            child: SafeArea(
              bottom: false,
              child: CustomScrollView(
                controller: _panelScroll,
              physics: const ClampingScrollPhysics(),
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpace.gutter,
                    AppSpace.x2,
                    AppSpace.gutter,
                    0,
                  ),
                  sliver: SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Center(
                          child: Container(
                            width: 36,
                            height: 4,
                            decoration: BoxDecoration(
                              color: const Color(0x2AFFFFFF),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                        const SizedBox(height: AppSpace.x4),
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: const Color(0x4245E0AE),
                                ),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                '二楼',
                                style: AppType.micro.copyWith(
                                  color: const Color(AppColors.accent),
                                  letterSpacing: 1.6,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            const Spacer(),
                            GestureDetector(
                              onTap: _closeFloor,
                              child: Row(
                                children: [
                                  Text(
                                    '上滑收起',
                                    style: AppType.micro.copyWith(
                                      color: const Color(
                                        AppColors.textTertiary,
                                      ),
                                    ),
                                  ),
                                  const Icon(
                                    Icons.keyboard_arrow_up_rounded,
                                    size: 15,
                                    color: Color(AppColors.textTertiary),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: AppSpace.x5),
                        const Text(
                          '这一层，\n是你的工具台',
                          style: TextStyle(
                            fontSize: 26,
                            height: 1.26,
                            letterSpacing: -0.8,
                            fontWeight: FontWeight.w800,
                            color: Color(AppColors.textPrimary),
                          ),
                        ),
                        const SizedBox(height: 10),
                        const Text(
                          '常用入口都收在这里。要用时往下拉，用完上滑就回一楼。',
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.7,
                            color: Color(AppColors.textSecondary),
                          ),
                        ),
                        const SizedBox(height: AppSpace.x6),
                        _floorGrid(),
                        if (_recentTool != null) ...[
                          const SizedBox(height: AppSpace.x6),
                          Row(
                            children: [
                              Text(
                                '最近用过',
                                style: AppType.micro.copyWith(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w600,
                                  color: const Color(AppColors.textSecondary),
                                ),
                              ),
                              const Spacer(),
                              Text(
                                _recentAt == null ? '' : _agoLabel(_recentAt!),
                                style: AppType.micro,
                              ),
                            ],
                          ),
                          const SizedBox(height: AppSpace.x1),
                          Container(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            decoration: const BoxDecoration(
                              border: Border(
                                bottom: BorderSide(
                                  color: Color(AppColors.hairline),
                                ),
                              ),
                            ),
                            child: Row(
                              children: [
                                Container(
                                  width: 34,
                                  height: 34,
                                  decoration: BoxDecoration(
                                    color: const Color(0x0FFFFFFF),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: const Icon(
                                    Icons.history_rounded,
                                    size: 17,
                                    color: Color(AppColors.textSecondary),
                                  ),
                                ),
                                const SizedBox(width: AppSpace.x3),
                                Text(
                                  _recentTool!,
                                  style: AppType.body.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const Spacer(),
                                Text(
                                  _recentAt == null
                                      ? ''
                                      : _agoLabel(_recentAt!),
                                  style: AppType.micro,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                // 内容不足一屏时，底部由这条收起入口撑住，不再留一块纯黑挡板。
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      AppSpace.gutter,
                      AppSpace.x4,
                      AppSpace.gutter,
                      16 + bottom,
                    ),
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: PressableScale(
                        onTap: _closeFloor,
                        scale: 0.97,
                        child: Container(
                          height: 40,
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.035),
                            borderRadius: BorderRadius.circular(99),
                            border: Border.all(
                              color: const Color(AppColors.hairline),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.keyboard_arrow_up_rounded,
                                size: 16,
                                color: Color(AppColors.textTertiary),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                '上滑收起二楼',
                                style: AppType.micro.copyWith(fontSize: 11),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
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

  /// 四个工具：2×2，共用一条发丝线切开，不叠卡片
  Widget _floorGrid() {
    final cells = <Widget>[
      _floorCell(
        label: 'AI Agent',
        sub: '会规划，也能动手',
        icon: Icons.auto_awesome_rounded,
        accent: true,
        onTap: () {
          _markRecentTool('AI Agent');
          _closeFloor();
          Navigator.push(
            context,
            PageRouteBuilder(
              transitionDuration: const Duration(milliseconds: 260),
              reverseTransitionDuration: const Duration(milliseconds: 200),
              pageBuilder: (_, _, _) => const AfWorkbenchPage(),
              transitionsBuilder: (_, a, _, child) => FadeTransition(
                opacity: a,
                child: SlideTransition(
                  position:
                      Tween(
                        begin: const Offset(0, 0.02),
                        end: Offset.zero,
                      ).animate(
                        CurvedAnimation(parent: a, curve: Curves.easeOutCubic),
                      ),
                  child: child,
                ),
              ),
            ),
          );
        },
      ),
      _floorCell(
        label: '流萤航线',
        sub: '沉浸式航线创作',
        icon: Icons.flight_takeoff_rounded,
        accent: true,
        onTap: () {
          _markRecentTool('流萤航线');
          _closeFloor();
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const PetalwakePage()),
          );
        },
      ),
      _floorCell(
        label: '发一帖',
        sub: '写点什么，直接发',
        icon: Icons.add_rounded,
        onTap: () {
          _markRecentTool('发一帖');
          _closeFloor();
          _openEditor();
        },
      ),
      _floorCell(
        label: '任务中心',
        sub: '签到、任务与经验',
        icon: Icons.emoji_events_outlined,
        amber: true,
        onTap: () {
          _markRecentTool('任务中心');
          _closeFloor();
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const TaskCenterPage()),
          );
        },
      ),
      _floorCell(
        label: '排行榜',
        sub: '本周活跃榜',
        icon: Icons.leaderboard_outlined,
        onTap: () {
          _markRecentTool('排行榜');
          _closeFloor();
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const RankingPage()),
          );
        },
      ),
      _floorCell(
        label: '我的收藏',
        sub: '收起来的内容',
        icon: Icons.bookmark_border_rounded,
        onTap: () {
          _markRecentTool('我的收藏');
          _closeFloor();
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const FavoritesPage()),
          );
        },
      ),
      _floorCell(
        label: '应用市场',
        sub: '精选应用与下载',
        icon: Icons.apps_rounded,
        sky: true,
        onTap: () {
          _markRecentTool('应用市场');
          _closeFloor();
          _openAppMarket();
        },
      ),
      _floorCell(
        label: '反馈',
        sub: '报错与建议',
        icon: Icons.chat_bubble_outline_rounded,
        onTap: () {
          _markRecentTool('反馈');
          _closeFloor();
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const FeedbackPage()),
          );
        },
      ),
    ];
    return DecoratedBox(
      decoration: const BoxDecoration(
        border: Border(
          top: BorderSide(color: Color(AppColors.hairline)),
          left: BorderSide(color: Color(AppColors.hairline)),
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(child: cells[0]),
              Expanded(child: cells[1]),
            ],
          ),
          Row(
            children: [
              Expanded(child: cells[2]),
              Expanded(child: cells[3]),
            ],
          ),
          Row(
            children: [
              Expanded(child: cells[4]),
              Expanded(child: cells[5]),
            ],
          ),
        ],
      ),
    );
  }

  Widget _floorCell({
    required String label,
    required String sub,
    required IconData icon,
    required VoidCallback onTap,
    bool accent = false,
    bool amber = false,
    bool sky = false,
  }) {
    final bg = amber
        ? const Color(0x22FFB020)
        : sky
        ? const Color(0x1F6FB7FF)
        : const Color(0x0FFFFFFF);
    final fg = accent
        ? const Color(AppColors.onAccent)
        : amber
        ? const Color(AppColors.warning)
        : sky
        ? const Color(AppColors.sky)
        : const Color(AppColors.textPrimary);
    return PressableScale(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(15, 16, 15, 17),
        decoration: const BoxDecoration(
          border: Border(
            right: BorderSide(color: Color(AppColors.hairline)),
            bottom: BorderSide(color: Color(AppColors.hairline)),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: accent ? null : bg,
                gradient: accent
                    ? const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Color(0xFF1B6B52), Color(0xFF3DDC97)],
                      )
                    : null,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, size: 20, color: fg),
            ),
            const SizedBox(height: 12),
            Text(
              label,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.2,
                color: Color(AppColors.textPrimary),
              ),
            ),
            const SizedBox(height: 5),
            Text(
              sub,
              style: const TextStyle(
                fontSize: 11.5,
                color: Color(AppColors.textTertiary),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ 顶部
  Widget _header(double t) {
    final miniRaw = ((t - 0.42) / 0.58).clamp(0.0, 1.0);
    final mini = Curves.easeOutCubic.transform(miniRaw);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
      child: SizedBox(
        height: 42,
        child: Row(
          children: [
            SegmentedTabs(
              labels: const ['关注', '推荐'],
              index: _tab,
              large: true,
              onChanged: _switchTab,
              padding: const EdgeInsets.symmetric(horizontal: 4),
            ),
            const Spacer(),
            if (mini > 0.001) ...[_miniSearch(mini), SizedBox(width: 6 * mini)],
            _notifyButton(),
          ],
        ),
      ),
    );
  }

  Widget _searchBar() {
    return PressableScale(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const SearchPage()),
      ),
      scale: 0.99,
      child: Container(
        height: 42,
        padding: const EdgeInsets.fromLTRB(14, 0, 5, 0),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xE6151A18), Color(0xB80E1212)],
          ),
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
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                '搜帖子、应用、用户',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13.5,
                  height: 1.2,
                  color: Color(AppColors.textTertiary),
                ),
              ),
            ),
            Container(
              height: 32,
              padding: const EdgeInsets.symmetric(horizontal: 11),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: const Color(AppColors.accent).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Text(
                '搜索',
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.2,
                  fontWeight: FontWeight.w700,
                  color: Color(AppColors.accent),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _miniSearch(double k) {
    return PressableScale(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const SearchPage()),
      ),
      scale: 0.96,
      child: Container(
        key: const ValueKey('home-mini-search'),
        width: 38 * k,
        height: 38,
        alignment: Alignment.center,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: const Color(AppColors.card).withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(19),
          border: Border.all(color: const Color(AppColors.hairline)),
        ),
        child: Opacity(
          opacity: k,
          child: const Icon(
            Icons.search_rounded,
            size: 19,
            color: Color(AppColors.textPrimary),
          ),
        ),
      ),
    );
  }

  Widget _notifyButton() {
    return PressableScale(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const NotifListPage()),
      ),
      scale: 0.96,
      child: Container(
        key: const ValueKey('home-notify-button'),
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: const Color(AppColors.card).withValues(alpha: 0.6),
          shape: BoxShape.circle,
          border: Border.all(color: const Color(AppColors.hairline)),
        ),
        child: ValueListenableBuilder<int>(
          valueListenable: NotifyBus.shared.unread,
          builder: (_, n, _) => Stack(
            children: [
              const Center(
                child: Icon(
                  Icons.notifications_none_rounded,
                  size: 20,
                  color: Color(AppColors.textPrimary),
                ),
              ),
              if (n > 0)
                Positioned(
                  right: 8,
                  top: 7,
                  child: Container(
                    key: const ValueKey('home-bell-dot'),
                    width: 6,
                    height: 6,
                    decoration: const BoxDecoration(
                      color: Color(AppColors.heart),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------ 内容模块

  /// 今日焦点：轮播已经是首屏主视觉，这里只保留一条紧凑焦点，不再叠第二张大卡。
  Widget _leadStory() {
    if (_items.isEmpty) {
      if (_loading || !_loaded) {
        return const Padding(
          padding: EdgeInsets.fromLTRB(16, 2, 16, 12),
          child: SkeletonBox(height: 78, radius: 14),
        );
      }
      return const SizedBox(height: 8);
    }
    final item = _items.first;
    final title = item.content.trim().isEmpty
        ? (item.topic.isEmpty ? '一条新动态' : '#${item.topic.first}')
        : item.content.trim();
    final topic = item.topic.isEmpty ? '' : item.topic.first;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 12),
      child: PressableScale(
        onTap: () => _openDetail(item),
        scale: 0.985,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 46,
              height: 56,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.035),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(AppColors.hairline)),
              ),
              child: const Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    'TODAY',
                    style: TextStyle(
                      fontSize: 6.5,
                      height: 1,
                      letterSpacing: 1.15,
                      fontWeight: FontWeight.w700,
                      color: Color(AppColors.textTertiary),
                    ),
                  ),
                  SizedBox(height: 4),
                  Text(
                    '01',
                    style: TextStyle(
                      fontSize: 20,
                      height: 0.9,
                      letterSpacing: -0.8,
                      fontWeight: FontWeight.w900,
                      color: Color(AppColors.accent),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text(
                        '今日焦点',
                        style: TextStyle(
                          fontSize: 8.5,
                          height: 1.1,
                          letterSpacing: 1.1,
                          fontWeight: FontWeight.w700,
                          color: Color(AppColors.accent),
                        ),
                      ),
                      if (topic.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 92),
                          child: Text(
                            '#$topic',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 9.5,
                              height: 1.1,
                              color: Color(AppColors.textTertiary),
                            ),
                          ),
                        ),
                      ],
                      const Spacer(),
                      if (item.isVideo)
                        const VideoBadge(compact: true)
                      else
                        const Text(
                          'STORY',
                          style: TextStyle(
                            fontSize: 7.5,
                            height: 1.1,
                            letterSpacing: 1.2,
                            fontWeight: FontWeight.w600,
                            color: Color(AppColors.textTertiary),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  TextEmojiText(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 15.5,
                      height: 1.28,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.3,
                      color: Color(AppColors.textPrimary),
                    ),
                  ),
                  if (item.reason.trim().isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        const Icon(
                          Icons.auto_awesome_rounded,
                          size: 9,
                          color: Color(AppColors.accent),
                        ),
                        const SizedBox(width: 3),
                        Expanded(
                          child: Text(
                            item.reason,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 9,
                              height: 1.1,
                              color: Color(AppColors.accent),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 5),
                  Row(
                    children: [
                      UserAvatar(
                        url: item.author.avatar,
                        uid: item.author.id,
                        name: item.author.name,
                        size: 16,
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
                            fontSize: 10,
                            height: 1.2,
                            color: Color(AppColors.textSecondary),
                          ),
                        ),
                      ),
                      const Icon(
                        Icons.favorite_rounded,
                        size: 10,
                        color: Color(AppColors.textTertiary),
                      ),
                      const SizedBox(width: 3),
                      Text(
                        formatCount(item.likeCount),
                        style: const TextStyle(
                          fontSize: 10,
                          height: 1.2,
                          color: Color(AppColors.textTertiary),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            const Icon(
              Icons.chevron_right_rounded,
              size: 16,
              color: Color(AppColors.textTertiary),
            ),
          ],
        ),
      ),
    );
  }

  /// 应用橱窗：一排 App 图标，替代原来的精选大卡 + 横滑 + 竖向清单。
  Widget _appShelf() {
    if (_appsLoading) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SkeletonBox(width: 132, height: 18),
            SizedBox(height: 12),
            SizedBox(height: 64, child: SkeletonBox(radius: AppRadius.md)),
          ],
        ),
      );
    }
    if (_apps.isEmpty) {
      if (_appsError == null) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: Container(
          height: 52,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: const Color(AppColors.card).withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(AppColors.hairline)),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.apps_rounded,
                size: 18,
                color: Color(AppColors.textTertiary),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _appsError!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: Color(AppColors.textSecondary),
                  ),
                ),
              ),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _loadDiscovery,
                child: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 10, horizontal: 4),
                  child: Text(
                    '重试',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: Color(AppColors.accent),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                const Text(
                  '应用橱窗',
                  style: TextStyle(
                    fontSize: 18,
                    height: 1.1,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.4,
                    color: Color(AppColors.textPrimary),
                  ),
                ),
                const SizedBox(width: 8),
                const Text(
                  'APP SHELF',
                  style: TextStyle(
                    fontSize: 8.5,
                    height: 1.1,
                    letterSpacing: 1.1,
                    fontWeight: FontWeight.w600,
                    color: Color(AppColors.textTertiary),
                  ),
                ),
                const Spacer(),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _openAppMarket,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8, horizontal: 2),
                    child: Text(
                      '全部',
                      style: TextStyle(
                        fontSize: 11,
                        color: Color(AppColors.accent),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 66,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: _apps.length,
              separatorBuilder: (_, _) => const SizedBox(width: 13),
              itemBuilder: (_, i) {
                final app = _apps[i];
                return PressableScale(
                  onTap: () => _openAppDetail(app),
                  scale: 0.96,
                  child: SizedBox(
                    width: 54,
                    child: Column(
                      children: [
                        AppIconTile(
                          app: app,
                          size: 44,
                          radius: 12,
                          heroTag: SharedElementTags.appIcon(app.id),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          app.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 10.5,
                            height: 1.1,
                            fontWeight: FontWeight.w600,
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

  /// 今晚聊什么：单行话题条，让首屏还能看到下面的内容流。
  Widget _topicRail() {
    if (_topics.isEmpty) return const SizedBox.shrink();
    final topics = _topics.take(8).toList();
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Text(
                  ApiClient.userId == null ? '今晚聊什么' : '为你挑的话题',
                  style: const TextStyle(
                    fontSize: 16,
                    height: 1.1,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.3,
                    color: Color(AppColors.textPrimary),
                  ),
                ),
                const SizedBox(width: 7),
                const Text(
                  'TOPICS',
                  style: TextStyle(
                    fontSize: 8.5,
                    height: 1.1,
                    letterSpacing: 1.1,
                    fontWeight: FontWeight.w600,
                    color: Color(AppColors.textTertiary),
                  ),
                ),
                const Spacer(),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _openTopics,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8, horizontal: 2),
                    child: Text(
                      '更多',
                      style: TextStyle(
                        fontSize: 11,
                        color: Color(AppColors.accent),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 7),
          SizedBox(
            height: 42,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: topics.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (_, i) => _topicChip(topics[i], i),
            ),
          ),
        ],
      ),
    );
  }

  Widget _topicChip(HomeTopic topic, int index) {
    return AppHero(
      tag: SharedElementTags.topicChip(topic.name),
      child: PressableScale(
        onTap: () => _openTopic(topic),
        scale: 0.97,
        child: Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: const Color(AppColors.card).withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(AppColors.hairline)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '#',
                style: TextStyle(
                  fontSize: 11,
                  height: 1.1,
                  fontWeight: FontWeight.w800,
                  color: index < 3
                      ? const Color(AppColors.accent)
                      : const Color(AppColors.textTertiary),
                ),
              ),
              const SizedBox(width: 3),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 150),
                child: Text(
                  topic.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    height: 1.1,
                    fontWeight: FontWeight.w600,
                    color: Color(AppColors.textPrimary),
                  ),
                ),
              ),
              if (topic.reason.startsWith('因为你')) ...[
                const SizedBox(width: 5),
                const Icon(
                  Icons.auto_awesome_rounded,
                  size: 9,
                  color: Color(AppColors.accent),
                ),
              ],
              const SizedBox(width: 6),
              Text(
                formatCount(topic.count),
                style: const TextStyle(
                  fontSize: 9.5,
                  height: 1.1,
                  color: Color(AppColors.textTertiary),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _feedHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'LIVE / 社区动态',
                      style: TextStyle(
                        fontSize: 8.5,
                        height: 1.2,
                        letterSpacing: 1.1,
                        fontWeight: FontWeight.w700,
                        color: Color(AppColors.accent),
                      ),
                    ),
                    SizedBox(height: 3),
                    Text(
                      '正在流动',
                      style: TextStyle(
                        fontSize: 18,
                        height: 1.1,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.4,
                        color: Color(AppColors.textPrimary),
                      ),
                    ),
                  ],
                ),
              ),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  setState(() => _refreshTurns += 0.25);
                  _load(refresh: true);
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 8,
                    horizontal: 4,
                  ),
                  child: AnimatedRotation(
                    turns: _refreshTurns,
                    duration: const Duration(milliseconds: 520),
                    curve: Curves.easeOutCubic,
                    child: const Icon(
                      Icons.refresh_rounded,
                      size: 18,
                      color: Color(AppColors.textTertiary),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          // 切 Tab 时旧列表继续显示，顶部细进度条给“正在换流”一个确定反馈。
          // 不使用常驻的 AnimatedOpacity：隐藏中的 indeterminate 进度条
          // 仍会持续调度帧，测试/低端机都会白耗性能。
          if (_tabLoading || _refreshing)
            const ClipRRect(
              borderRadius: BorderRadius.all(Radius.circular(2)),
              child: LinearProgressIndicator(
                minHeight: 2,
                backgroundColor: Colors.transparent,
                color: Color(AppColors.accent),
              ),
            )
          else
            const SizedBox(height: 2),
        ],
      ),
    );
  }

  Widget _feedSliver() {
    if (!_loaded) return const SliverToBoxAdapter(child: FeedSkeleton());
    if (_error != null && _items.isEmpty) {
      return SliverToBoxAdapter(
        child: ErrorState(
          message: _error!,
          onRetry: () => _load(refresh: true),
        ),
      );
    }
    if (_items.isEmpty) return SliverToBoxAdapter(child: _empty());
    final rest = _items.length - 1;
    if (rest <= 0) {
      return SliverPadding(
        padding: EdgeInsets.fromLTRB(
          AppSpace.gutter,
          0,
          AppSpace.gutter,
          28 + tabBarBottomInset(context),
        ),
        sliver: SliverToBoxAdapter(
          child: LoadMoreFooter(
            loading: _loading,
            hasMore: _hasMore,
            onTap: () => _load(),
            endLabel: '— 已经到底啦 —',
          ),
        ),
      );
    }
    final heights = <double>[236, 286, 252, 212, 268, 224];
    return SliverMainAxisGroup(
      slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(AppSpace.gutter, 0, AppSpace.gutter, 0),
          sliver: SliverMasonryGrid.count(
            crossAxisCount: 2,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childCount: rest,
            itemBuilder: (_, i) {
              final it = _items[i + 1];
              return StaggerReveal(
                key: ValueKey('home-feed-${it.id}'),
                index: i,
                child: SizedBox(
                  height: heights[i % heights.length],
                  child: PostGridTile(
                    item: it,
                    heroEnabled: true,
                    onTap: () => _openDetail(it),
                    onAuthorTap: () => Navigator.push(
                      context,
                      AppPageRoute(
                        builder: (_) => UserProfilePage(
                          uid: it.author.id,
                          heroTag: SharedElementTags.postAvatar(
                            it.author.id,
                            it.id,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              AppSpace.gutter,
              0,
              AppSpace.gutter,
              28 + tabBarBottomInset(context),
            ),
            child: LoadMoreFooter(
              loading: _loading,
              hasMore: _hasMore,
              onTap: () => _load(),
              endLabel: '— 已经到底啦 —',
            ),
          ),
        ),
      ],
    );
  }

  Widget _empty() {
    final needLogin = _tab == 0 && ApiClient.token == null;
    return EmptyState(
      icon: needLogin
          ? Icons.lock_outline_rounded
          : Icons.auto_awesome_outlined,
      title: needLogin ? '登录后查看关注动态' : '这里还很安静',
      message: needLogin
          ? '登录即可同步你关注的人和互动消息'
          : (_tab == 0 ? '去关注感兴趣的作者，动态会出现在这里' : '还没有内容，来发第一帖吧'),
      actionLabel: needLogin ? '去登录' : '去发布',
      onAction: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) =>
              needLogin ? const LoginPage() : const PostEditorPage(),
        ),
      ),
    );
  }
}

/// 二楼的露出区域：以分开口为中心，随进度同时向上、向下撑开。
/// 这样视觉上是「缝隙被拉开」，而不是一页从旁边滑过来。
class _FloorReveal extends StatelessWidget {
  const _FloorReveal({required this.animation, required this.child});

  final Animation<double> animation;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, child) {
        final p = animation.value;
        final raw = ((p - (_HomePageState.kCommitProgress - 0.04)) / 0.34)
            .clamp(0.0, 1.0);
        return Opacity(
          opacity: Curves.easeOutCubic.transform(raw),
          child: child,
        );
      },
    );
  }
}

class _SeamClipper extends CustomClipper<Rect> {
  _SeamClipper({required this.top, required this.px, required this.height});

  /// 当前分界线（展开过程中从 header 高度上移到 0）
  final double top;
  final double px;
  final double height;

  @override
  Rect getClip(Size size) {
    final t = top.clamp(0.0, size.height);
    final b = (top + px).clamp(0.0, size.height);
    return Rect.fromLTRB(0, t, size.width, b);
  }

  @override
  bool shouldReclip(_SeamClipper old) =>
      old.top != top || old.px != px || old.height != height;
}
