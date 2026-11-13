/// 社区首页：沉浸黑单列信息流（关注 / 推荐）
///
/// 版式：品牌标题 → 关注·推荐分段 → 二楼入口提示 → 运营入口 → Banner → 内容卡。
/// 手势：在信息流顶部下拉，轻拉是刷新，拉过阈值整页下沉取出「二楼」。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../api/client.dart';
import '../../config.dart';
import '../../design/components.dart';
import '../../models/feed_item.dart';
import '../../widgets/banner_carousel.dart';
import '../../widgets/post_card.dart';
import '../game/petalwake_page.dart';
import '../discover/ranking_page.dart';
import '../discover/topic_page.dart';
import '../mine/login_page.dart';
import '../mine/task_center_page.dart';
import '../post/post_detail.dart';
import '../post/post_editor.dart';
import '../search/search_page.dart';
import '../user/user_profile.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with SingleTickerProviderStateMixin {
  int _tab = 1; // 0=关注 1=推荐（默认推荐）
  final List<FeedItem> _items = [];
  bool _loading = false;
  bool _loaded = false;
  int _page = 0;
  bool _hasMore = true;
  String? _error;
  final ScrollController _scroll = ScrollController();

  /// 下拉手势进度 0..1：轻拉触发刷新，拉过阈值整页下沉取出二楼
  late final AnimationController _pullCtl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  )..addListener(() {
      if (mounted) setState(() {});
    });

  /// 进入二楼的阈值（下拉像素）
  static const double kFloorPx = 150;

  /// 触发刷新的阈值（下拉像素）
  static const double kRefreshPx = 64;

  bool _floorOpen = false;
  bool _refreshing = false;
  bool _pulling = false;
  double _dragStartY = 0;
  double _lastPullPx = 0;

  @override
  void initState() {
    super.initState();
    _load(refresh: true);
  }

  @override
  void dispose() {
    _pullCtl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load({bool refresh = false}) async {
    if (_loading || (!_hasMore && !refresh)) return;
    setState(() {
      _loading = true;
      if (refresh) _error = null;
    });
    try {
      final p = await ApiClient.feed(
        tab: _tab == 0 ? 'follow' : 'recommend',
        page: refresh ? 1 : _page + 1,
        size: 10,
      );
      if (!mounted) return;
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
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loaded = true;
        _loading = false;
        _error = '$e';
      });
    }
  }

  void _switchTab(int i) {
    if (_tab == i) return;
    setState(() {
      _tab = i;
      _items.clear();
      _page = 0;
      _hasMore = true;
      _loaded = false;
      _error = null;
    });
    _load(refresh: true);
  }

  Future<void> _openEditor() async {
    final ok = await Navigator.push(
        context, MaterialPageRoute(builder: (_) => const PostEditorPage()));
    if (ok == true && mounted) _load(refresh: true);
  }

  void _openDetail(FeedItem it) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => PostDetailPage(postId: it.id)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ImmersivePage(
      child: SafeArea(
        bottom: false,
        child: LayoutBuilder(
          builder: (context, box) {
            final v = _pullCtl.value;
            final open = _floorOpen;
            // 未打开：页面跟手下沉；打开后继续沉下去，把二楼让出来
            final offset =
                open ? box.maxHeight * (0.08 + 0.36 * v) : v * kFloorPx;
            final panelT = open
                ? Curves.easeOutCubic.transform(v)
                : ((v * kFloorPx - kRefreshPx) / (kFloorPx - kRefreshPx))
                    .clamp(0.0, 1.0);
            return Stack(
              children: [
                if (panelT > 0) Positioned.fill(child: _floorPanel(panelT)),
                Transform.translate(
                  offset: Offset(0, offset),
                  child: Opacity(
                    opacity: 1 - (open ? panelT * 0.45 : 0),
                    child: IgnorePointer(ignoring: open, child: _homeList()),
                  ),
                ),
                if (!open)
                  Positioned(top: 0, left: 0, right: 0, child: _pullHint()),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _homeList() {
    return Listener(
      onPointerDown: (e) {
        if (_floorOpen || _refreshing) return;
        if (!_scroll.hasClients || _scroll.position.pixels > 0) return;
        _pulling = true;
        _dragStartY = e.position.dy;
      },
      onPointerMove: (e) {
        if (!_pulling) return;
        final dy = e.position.dy - _dragStartY;
        if (dy <= 0) {
          if (_pullCtl.value != 0) _pullCtl.value = 0;
          _lastPullPx = 0;
          return;
        }
        final px = dy * 0.9;
        _lastPullPx = px;
        _pullCtl.value = (px / kFloorPx).clamp(0.0, 1.0);
      },
      onPointerUp: (_) => _releasePull(),
      onPointerCancel: (_) => _releasePull(),
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n.metrics.extentAfter < 500) _load();
          return false;
        },
        child: CustomScrollView(
          controller: _scroll,
          physics: const AlwaysScrollableScrollPhysics(
              parent: ClampingScrollPhysics()),
          slivers: [
            SliverToBoxAdapter(child: _header()),
            SliverToBoxAdapter(child: _tabs()),
            SliverToBoxAdapter(child: _floorEntry()),
            SliverToBoxAdapter(child: _opsRail()),
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                    AppSpace.gutter, 0, AppSpace.gutter, AppSpace.x4),
                child: BannerCarousel(),
              ),
            ),
            _feedSliver(),
          ],
        ),
      ),
    );
  }

  /// 松手：轻拉刷新，过二楼阈值整页下沉取出二楼
  Future<void> _releasePull() async {
    if (!_pulling) return;
    _pulling = false;
    final px = _lastPullPx;
    _lastPullPx = 0;

    if (px >= kFloorPx - 6) {
      HapticFeedback.mediumImpact();
      setState(() => _floorOpen = true);
      await _pullCtl.animateTo(1,
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic);
      return;
    }
    if (px >= kRefreshPx) {
      HapticFeedback.lightImpact();
      setState(() => _refreshing = true);
      _pullCtl.value = 0;
      try {
        await _load(refresh: true);
      } finally {
        if (mounted) setState(() => _refreshing = false);
      }
      return;
    }
    if (_pullCtl.value > 0) {
      await _pullCtl.animateTo(0,
          duration: const Duration(milliseconds: 240), curve: Curves.easeOut);
    }
  }

  Future<void> _closeFloor() async {
    if (!_floorOpen) return;
    await _pullCtl.animateTo(0,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic);
    if (mounted) setState(() => _floorOpen = false);
  }

  /// 顶部下拉提示：下拉刷新 → 松手刷新 → 松手进二楼
  Widget _pullHint() {
    final v = _pullCtl.value;
    final px = v * kFloorPx;
    final show = px > 6 || _refreshing;
    final pastRefresh = px >= kRefreshPx;
    final pastFloor = px >= kFloorPx - 6;
    final color = pastFloor
        ? const Color(AppColors.accent)
        : (pastRefresh
            ? const Color(0xFFCFE6D9)
            : const Color(AppColors.textTertiary));
    final label = _refreshing
        ? '正在刷新…'
        : (pastFloor ? '松手进二楼' : (pastRefresh ? '松手刷新' : '下拉刷新'));
    return IgnorePointer(
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 120),
        opacity: show ? 1 : 0,
        child: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xE60E1319),
                borderRadius: BorderRadius.circular(AppRadius.pill),
                border: Border.all(color: const Color(0x22FFFFFF)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_refreshing)
                    const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.6,
                        valueColor:
                            AlwaysStoppedAnimation<Color>(Color(0xFF3DDC97)),
                      ),
                    )
                  else
                    Transform.rotate(
                      angle: pastFloor ? 3.14159 : v * 3.14159,
                      child: Icon(Icons.arrow_downward_rounded,
                          size: 13, color: color),
                    ),
                  const SizedBox(width: 6),
                  Text(label,
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          color: color)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- 二楼
  /// 二楼入口提示：一行小字，只做引导，不占视觉重量
  Widget _floorEntry() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpace.gutter, AppSpace.x2, AppSpace.gutter, AppSpace.x1),
      child: Row(
        children: [
          const Icon(Icons.keyboard_arrow_down_rounded,
              size: 14, color: Color(AppColors.textTertiary)),
          const SizedBox(width: 3),
          Text('下拉进入二楼', style: AppType.micro.copyWith(fontSize: 10.5)),
        ],
      ),
    );
  }

  Widget _floorMiniIcon({required IconData icon, required List<Color> colors}) {
    return Container(
      width: 30,
      height: 30,
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: colors),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Icon(icon, size: 16, color: Colors.white),
    );
  }

  Widget _floorPanel(double t) {
    return GestureDetector(
      onTap: _closeFloor,
      onVerticalDragUpdate: (d) {
        if (d.delta.dy < -24) _closeFloor();
      },
      child: Opacity(
        opacity: t.clamp(0.0, 1.0),
        child: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFF0B0D10), Color(AppColors.bg)],
            ),
          ),
          child: Transform.translate(
            offset: Offset(0, (1 - t) * -40),
            child: SafeArea(
              bottom: false,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                    AppSpace.gutter, AppSpace.x4, AppSpace.gutter, 28),
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 9, vertical: 4),
                        decoration: BoxDecoration(
                          color: const Color(AppColors.elevated),
                          borderRadius: AppRadius.rXs,
                        ),
                        child: Text('二楼 · 小程序',
                            style: AppType.micro.copyWith(fontSize: 10.5)),
                      ),
                      const Spacer(),
                      GestureDetector(
                        onTap: _closeFloor,
                        child: Row(
                          children: [
                            Text('上滑收起',
                                style: AppType.micro.copyWith(fontSize: 11)),
                            const Icon(Icons.keyboard_arrow_up_rounded,
                                size: 16, color: Color(AppColors.textTertiary)),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpace.x4),
                  const Text('常用的小工具，都在这一层',
                      style: TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.w800,
                          color: Color(AppColors.textPrimary))),
                  const SizedBox(height: 4),
                  Text('在首页信息流顶部往下拉，拉过一半就出来了',
                      style: AppType.micro.copyWith(fontSize: 11.5)),
                  const SizedBox(height: AppSpace.x5),
                  GridView.count(
                    crossAxisCount: 4,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    mainAxisSpacing: AppSpace.x4,
                    crossAxisSpacing: AppSpace.x2,
                    childAspectRatio: 0.78,
                    children: [
                      _floorApp(
                        label: '流萤航线',
                        icon: Icons.flight_takeoff_rounded,
                        colors: const [Color(0xFF1B6B52), Color(0xFF3DDC97)],
                        onTap: () {
                          _closeFloor();
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => const PetalwakePage()),
                          );
                        },
                      ),
                      _floorApp(
                        label: '发一帖',
                        icon: Icons.add_rounded,
                        colors: const [Color(0xFF2A2A33), Color(0xFF4B3B2E)],
                        onTap: () {
                          _closeFloor();
                          _openEditor();
                        },
                      ),
                      _floorApp(
                        label: '任务中心',
                        icon: Icons.emoji_events_outlined,
                        colors: const [Color(0xFF2B2A20), Color(0xFF6A5A22)],
                        onTap: () {
                          _closeFloor();
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => const TaskCenterPage()),
                          );
                        },
                      ),
                      _floorApp(
                        label: '排行榜',
                        icon: Icons.leaderboard_outlined,
                        colors: const [Color(0xFF20222E), Color(0xFF343A5A)],
                        onTap: () {
                          _closeFloor();
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => const RankingPage()),
                          );
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpace.x6),
                  Text('最近使用',
                      style: AppType.micro.copyWith(fontSize: 11.5)),
                  const SizedBox(height: AppSpace.x3),
                  GestureDetector(
                    onTap: () {
                      _closeFloor();
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const PetalwakePage()),
                      );
                    },
                    child: Container(
                      padding: const EdgeInsets.all(AppSpace.x3),
                      decoration: BoxDecoration(
                        color: const Color(AppColors.card),
                        borderRadius: AppRadius.rMd,
                        border:
                            Border.all(color: const Color(AppColors.border)),
                      ),
                      child: Row(
                        children: [
                          _floorMiniIcon(
                            icon: Icons.flight_takeoff_rounded,
                            colors: const [
                              Color(0xFF1B6B52),
                              Color(0xFF3DDC97)
                            ],
                          ),
                          const SizedBox(width: 10),
                          const Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('流萤航线',
                                    style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                        color: Color(AppColors.textPrimary))),
                                SizedBox(height: 2),
                                Text('骑上扫帚，飞过花甸',
                                    style: TextStyle(
                                        fontSize: 11,
                                        color: Color(AppColors.textTertiary))),
                              ],
                            ),
                          ),
                          const Icon(Icons.chevron_right_rounded,
                              size: 18, color: Color(AppColors.textTertiary)),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpace.x6),
                  Center(
                    child: Text('点空白处或上滑收起二楼',
                        style: AppType.micro.copyWith(fontSize: 11)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _floorApp({
    required String label,
    required IconData icon,
    required List<Color> colors,
    required VoidCallback onTap,
  }) {
    return PressableScale(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: colors,
              ),
              borderRadius: BorderRadius.circular(15),
              border: Border.all(color: const Color(0x1FFFFFFF)),
            ),
            child: Icon(icon, size: 26, color: Colors.white),
          ),
          const SizedBox(height: 7),
          Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 11.5, color: Color(AppColors.textSecondary))),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ 顶部
  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpace.gutter, AppSpace.x3, AppSpace.x3, 0),
      child: Row(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '流萤社区',
                style: TextStyle(
                  fontSize: 24,
                  height: 1.1,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.4,
                  color: Color(AppColors.textPrimary),
                ),
              ),
              const SizedBox(height: 3),
              Text('发现此刻的好内容', style: AppType.micro),
            ],
          ),
          const Spacer(),
          IconCircleButton(
            icon: Icons.emoji_events_outlined,
            size: 36,
            iconSize: 18,
            background: Colors.white.withValues(alpha: 0.06),
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const TaskCenterPage())),
          ),
          const SizedBox(width: AppSpace.x2),
          IconCircleButton(
            icon: Icons.search_rounded,
            size: 36,
            iconSize: 19,
            background: Colors.white.withValues(alpha: 0.06),
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const SearchPage())),
          ),
          const SizedBox(width: AppSpace.x2),
          IconCircleButton(
            icon: Icons.add_rounded,
            size: 36,
            iconSize: 20,
            background: const Color(AppColors.accent),
            color: const Color(AppColors.onAccent),
            onTap: _openEditor,
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ 分段
  Widget _tabs() {
    return FeedTabs(
      labels: const ['关注', '推荐'],
      index: _tab,
      onChanged: _switchTab,
      onTrailing: PressableScale(
        onTap: () => _load(refresh: true),
        child: Row(
          children: [
            const Icon(Icons.sync_rounded,
                size: 15, color: Color(AppColors.textTertiary)),
            const SizedBox(width: 3),
            Text('换一批', style: AppType.micro),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- 运营入口
  Widget _opsRail() {
    return SizedBox(
      height: 52,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.gutter),
        children: [
          Center(
            child: TagPill(
              label: '热门话题',
              icon: Icons.local_fire_department_rounded,
              onTap: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const TopicPage())),
            ),
          ),
          const SizedBox(width: AppSpace.x2),
          Center(
            child: TagPill(
              label: '排行榜',
              icon: Icons.leaderboard_rounded,
              onTap: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const RankingPage())),
            ),
          ),
          const SizedBox(width: AppSpace.x2),
          Center(
            child: TagPill(
              label: '签到任务',
              icon: Icons.task_alt_rounded,
              onTap: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const TaskCenterPage())),
            ),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ 列表
  Widget _feedSliver() {
    if (!_loaded) return const SliverToBoxAdapter(child: FeedSkeleton());
    if (_error != null && _items.isEmpty) {
      return SliverToBoxAdapter(
        child: ErrorState(message: _error!, onRetry: () => _load(refresh: true)),
      );
    }
    if (_items.isEmpty) return SliverToBoxAdapter(child: _empty());
    return SliverPadding(
      padding: EdgeInsets.fromLTRB(
        AppSpace.gutter,
        0,
        AppSpace.gutter,
        28 + tabBarBottomInset(context),
      ),
      sliver: SliverList(
        delegate: SliverChildBuilderDelegate(
          (_, i) {
            if (i == _items.length) {
              return LoadMoreFooter(
                loading: _loading,
                hasMore: _hasMore,
                onTap: () => _load(),
                endLabel: '— 已经到底啦 —',
              );
            }
            final it = _items[i];
            return PostCard(
              item: it,
              onTap: () => _openDetail(it),
              onAuthorTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => UserProfilePage(uid: it.author.id)),
              ),
              onComment: () => _openDetail(it),
            );
          },
          childCount: _items.length + 1,
        ),
      ),
    );
  }

  Widget _empty() {
    final needLogin = _tab == 0 && ApiClient.token == null;
    return EmptyState(
      icon: needLogin ? Icons.lock_outline_rounded : Icons.auto_awesome_outlined,
      title: needLogin ? '登录后查看关注动态' : '这里还很安静',
      message: needLogin
          ? '登录即可同步你关注的人和互动消息'
          : (_tab == 0 ? '去关注感兴趣的作者，动态会出现在这里' : '还没有内容，来发第一帖吧'),
      actionLabel: needLogin ? '去登录' : '去发布',
      onAction: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => needLogin ? const LoginPage() : const PostEditorPage(),
        ),
      ),
    );
  }
}
