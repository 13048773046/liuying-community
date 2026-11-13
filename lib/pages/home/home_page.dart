/// 社区首页：沉浸黑单列信息流（关注 / 推荐）
///
/// 版式：品牌标题 → 关注·推荐分段 →（二楼分开口）→ 运营入口 → Banner → 内容卡。
/// 手势：下拉只进二楼。分开口在「关注/推荐」与「热门话题」之间，
/// 下拉时顶部块（标题+关注/推荐）均匀渐隐，二楼从这条缝向上下撑开，
/// 松手用弹簧动画归位（参考微信小程序二楼、SecondFloorBehavior 的交互模型）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/physics.dart';

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

  /// 下拉进度 0..1：0=一楼，1=二楼。拖拽与松手后的弹簧动画共用这一个值，
  /// 所有位移/透明度都由它推导，保证「跟手 → 松手」不会有跳变。
  late final AnimationController _pullCtl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
  )..addListener(() {
      if (mounted) setState(() {});
    });

  /// 拉满二楼所需的手指行程（像素）。不是阈值，只是「拖多远算拉满」。
  static const double kFloorPx = 210;

  /// 松手时超过这个进度就直接展开二楼；以下则弹回一楼
  static const double kCommitProgress = 0.34;

  bool _floorOpen = false;
  bool _pulling = false;
  double _dragStartY = 0;
  double _lastMoveY = 0;
  int _lastMoveTs = 0;
  double _flingVel = 0; // px/s，松手时作为弹簧初速度

  /// 分开口的纵坐标 = 顶部块（标题 + 关注/推荐）的真实高度，首帧后实测回填
  final GlobalKey _topKey = GlobalKey();
  double _seamY = 132;

  @override
  void initState() {
    super.initState();
    _pullCtl.addStatusListener((st) {
      // 弹簧彻底回到一楼：关闭二楼，恢复一楼手势
      if (st == AnimationStatus.dismissed && _floorOpen && mounted) {
        setState(() => _floorOpen = false);
      }
    });
    _load(refresh: true);
  }

  void _measureSeam() {
    final h = _topKey.currentContext?.size?.height;
    if (h == null || h <= 0) return;
    if ((h - _seamY).abs() > 0.5 && mounted) {
      setState(() => _seamY = h);
    }
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
    WidgetsBinding.instance.addPostFrameCallback((_) => _measureSeam());
    return ImmersivePage(
      child: SafeArea(
        bottom: false,
        child: LayoutBuilder(
          builder: (context, box) {
            final h = box.maxHeight;
            final p = _pullCtl.value.clamp(0.0, 1.0);
            final seam = _seamY.clamp(0.0, h);
            // 缝隙以下的内容被往下推；缝隙以上的顶部块轻微上移并均匀渐隐
            final push = p * (h - seam + 32);
            final lift = p * seam * 0.35;
            final body = Stack(
              children: [
                // 二楼：用裁剪矩形从分开口向上下撑开，而不是整页平移
                if (p > 0.0001)
                  Positioned.fill(
                    child: ClipRect(
                      clipper: _SeamClipper(seam: seam, progress: p, height: h),
                      child: IgnorePointer(
                        ignoring: !_floorOpen,
                        child: _floorPanel(),
                      ),
                    ),
                  ),
                // 一楼下半部分：热门话题 / Banner / 信息流，整体被向下推
                Positioned.fill(
                  child: Transform.translate(
                    offset: Offset(0, push),
                    child: Opacity(
                      opacity: (1 - p * 0.45).clamp(0.0, 1.0),
                      child: IgnorePointer(
                        ignoring: p > 0.02,
                        child: _homeList(),
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
                    opacity: (1 - p).clamp(0.0, 1.0),
                    child: IgnorePointer(
                      ignoring: p > 0.02,
                      child: Column(
                        key: _topKey,
                        mainAxisSize: MainAxisSize.min,
                        children: [_header(), _tabs()],
                      ),
                    ),
                  ),
                ),
                // 分开口的小把手：只有图形，没有文字
                if (p > 0.02 && p < 0.995)
                  Positioned(
                    top: seam - 7,
                    left: 0,
                    right: 0,
                    child: IgnorePointer(
                      child: Center(
                        child: Container(
                          width: 30 + 26 * p,
                          height: 4,
                          decoration: BoxDecoration(
                            color: Colors.white
                                .withValues(alpha: 0.20 + 0.35 * (1 - p)),
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
    );
  }

  Widget _homeList() {
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.extentAfter < 500) _load();
        return false;
      },
      child: Padding(
        // 顶部这块留给「标题 + 关注/推荐」，分开口就落在它与热门话题之间
        padding: EdgeInsets.only(top: _seamY),
        child: CustomScrollView(
          controller: _scroll,
          physics: const AlwaysScrollableScrollPhysics(
              parent: ClampingScrollPhysics()),
          slivers: [
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

  // ---------------------------------------------------------------- 下拉手势
  void _onPullDown(PointerDownEvent e) {
    if (_floorOpen) return;
    if (!_scroll.hasClients || _scroll.position.pixels > 0) return;
    _pulling = true;
    _pullCtl.stop();
    _dragStartY = e.position.dy;
    _lastMoveY = e.position.dy;
    _lastMoveTs = e.timeStamp.inMilliseconds;
    _flingVel = 0;
  }

  void _onPullMove(PointerMoveEvent e) {
    if (!_pulling) return;
    final dy = e.position.dy - _dragStartY;
    if (dy <= 0) {
      if (_pullCtl.value != 0) _pullCtl.value = 0;
      return;
    }
    // 轻微阻尼：行程越长越费力，手感更接近微信
    final px = dy * 0.82;
    _pullCtl.value = (px / kFloorPx).clamp(0.0, 1.0);

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
    if (p <= 0) return;
    // 下拉只进二楼：拉过阈值、或明显快速一甩，就展开；否则弹回
    final open = p >= kCommitProgress || (_flingVel > 1100 && p > 0.06);
    _springTo(open ? 1.0 : 0.0, velocity: _flingVel / kFloorPx);
  }

  /// 弹簧归位：临界阻尼，没有生硬的 ease 停顿，也不会来回弹
  void _springTo(double target, {double velocity = 0}) {
    if (target == 1.0) {
      HapticFeedback.mediumImpact();
      if (!_floorOpen) setState(() => _floorOpen = true);
    }
    _pullCtl.animateWith(SpringSimulation(
      const SpringDescription(mass: 1, stiffness: 250, damping: 32),
      _pullCtl.value,
      target,
      velocity.clamp(-5.0, 5.0),
    ));
  }

  void _closeFloor() {
    if (!_floorOpen) return;
    HapticFeedback.lightImpact();
    // 弹簧回到一楼后，由状态监听把 _floorOpen 摘掉
    _springTo(0);
  }

  // ---------------------------------------------------------------- 二楼
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

  Widget _floorPanel() {
    return GestureDetector(
      onTap: _closeFloor,
      onVerticalDragUpdate: (d) {
        if (d.delta.dy < -18) _closeFloor();
      },
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF0B0D10), Color(AppColors.bg)],
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
                AppSpace.gutter, AppSpace.x4, AppSpace.gutter, 96),
            children: [
              Row(
                children: [
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
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
              Text('在首页往下拉，就能从这条缝进来',
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
              Text('最近使用', style: AppType.micro.copyWith(fontSize: 11.5)),
              const SizedBox(height: AppSpace.x3),
              GestureDetector(
                onTap: () {
                  _closeFloor();
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const PetalwakePage()),
                  );
                },
                child: Container(
                  padding: const EdgeInsets.all(AppSpace.x3),
                  decoration: BoxDecoration(
                    color: const Color(AppColors.card),
                    borderRadius: AppRadius.rMd,
                    border: Border.all(color: const Color(AppColors.border)),
                  ),
                  child: Row(
                    children: [
                      _floorMiniIcon(
                        icon: Icons.flight_takeoff_rounded,
                        colors: const [Color(0xFF1B6B52), Color(0xFF3DDC97)],
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

/// 二楼的露出区域：以分开口为中心，随进度同时向上、向下撑开。
/// 这样视觉上是「缝隙被拉开」，而不是一页从旁边滑过来。
class _SeamClipper extends CustomClipper<Rect> {
  _SeamClipper(
      {required this.seam, required this.progress, required this.height});
  final double seam;
  final double progress;
  final double height;

  @override
  Rect getClip(Size size) {
    final p = progress.clamp(0.0, 1.0);
    final up = seam * p;
    final down = (height - seam) * p;
    return Rect.fromLTRB(0, seam - up, size.width, seam + down);
  }

  @override
  bool shouldReclip(_SeamClipper old) =>
      old.seam != seam || old.progress != progress || old.height != height;
}
