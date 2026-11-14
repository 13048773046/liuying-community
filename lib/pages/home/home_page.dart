/// 社区首页：沉浸黑单列信息流（关注 / 推荐）
///
/// 版式：品牌标题 → 关注·推荐分段 →（二楼分开口）→ 运营入口 → Banner → 内容卡。
/// 手势：下拉只进二楼。分开口在「关注/推荐」与「热门话题」之间，
/// 手往下拉时顶部块（标题+关注/推荐）均匀渐隐，二楼从这条缝向上下撑开，
/// 松手按「已拉开比例 / 甩动速度」判定进二楼还是回弹（参考微信小程序二楼、SecondFloorBehavior）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/physics.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../api/client.dart';
import '../../config.dart';
import '../../design/components.dart';
import '../../models/feed_item.dart';
import '../../widgets/banner_carousel.dart';
import '../../widgets/post_card.dart';
import '../game/petalwake_page.dart';
import '../discover/ranking_page.dart';
import '../mine/login_page.dart';
import '../mine/task_center_page.dart';
import '../post/post_detail.dart';
import '../post/post_editor.dart';
import '../search/search_page.dart';
import '../user/user_profile.dart';
import '../message/notif_list_page.dart';

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
  final ScrollController _panelScroll = ScrollController();

  /// 二楼上滑收起：原始指针跟踪，避免和面板自己的 ListView 抢手势
  bool _panelDragReady = false;
  bool _panelPulling = false;
  double _panelStartY = 0;

  /// 下拉进度 0..1：0=一楼，1=二楼。拖拽与松手后的弹簧动画共用这一个值，
  /// 所有位移/透明度都由它推导，保证「跟手 → 松手」不会有跳变。
  late final AnimationController _pullCtl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
  )..addListener(() {
      if (mounted) setState(() {});
    });

  /// 列表到顶后先走这么多「准备」行程，避免 iOS 回弹或误触直接撩开二楼
  static const double kStartIntercept = 36;

  /// 阻尼：真正拉开缝隙的距离略小于手指行程（SecondFloorBehavior 的 dampingRatio）
  static const double kDragScale = 0.92;

  /// 松手时已拉开满开行程的多少比例 → 直接进二楼，否则回弹一楼
  static const double kCommitProgress = 0.30;

  /// 二楼上滑收起：手指行程超过满开行程的多少比例就判定关闭
  static const double kCloseProgress = 0.66;

  bool _floorOpen = false;
  bool _pulling = false;
  double _dragStartY = 0;
  double _lastMoveY = 0;
  int _lastMoveTs = 0;
  double _flingVel = 0; // px/s，松手时作为弹簧初速度

  /// 分开口的纵坐标 = 顶部块（标题 + 关注/推荐）的真实高度，首帧后实测回填
  final GlobalKey _topKey = GlobalKey();
  double _seamY = 132;

  /// 二楼满开所需的手指行程 = 分开口到屏幕底部的距离。
  /// 位移按像素 1:1 映射到手指，拖多少画面就走多少，手感才跟得住。
  double _maxOpen = 700;

  @override
  void initState() {
    super.initState();
    _load(refresh: true);
    _loadRecentTool();
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
    _panelScroll.dispose();
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
            // 满开时下半部分正好退出屏幕；手指移动多少像素，画面就移动多少
            _maxOpen = (h - seam + 24).clamp(1.0, h + 24);
            final px = p * _maxOpen;
            final push = px;
            final lift = px * 0.10;
            final body = Stack(
              children: [
                // 二楼：用裁剪矩形从分开口向上下撑开，而不是整页平移
                if (p > 0.0001)
                  Positioned.fill(
                    child: ClipRect(
                      clipper: _SeamClipper(seam: seam, px: px, height: h),
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
                    opacity: (1 - p * 1.6).clamp(0.0, 1.0),
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
                            color: const Color(AppColors.textPrimary)
                                .withValues(alpha: 0.18 + 0.22 * (1 - p)),
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
    // 先吃掉一段准备行程，之后按阻尼系数 1:1 跟手
    final px = (dy - kStartIntercept) * kDragScale;
    if (px <= 0) {
      if (_pullCtl.value != 0) _pullCtl.value = 0;
      return;
    }
    _pullCtl.value = (px / _maxOpen).clamp(0.0, 1.0);

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
    final open = p >= kCommitProgress || (_flingVel > 900 && p > 0.05);
    _springTo(open ? 1.0 : 0.0, velocity: _flingVel / _maxOpen);
  }

  /// 弹簧归位：临界阻尼，没有生硬的 ease 停顿，也不会来回弹
  void _springTo(double target, {double velocity = 0}) {
    if (target == 1.0) {
      HapticFeedback.mediumImpact();
      if (!_floorOpen) setState(() => _floorOpen = true);
    }
    final f = _pullCtl.animateWith(SpringSimulation(
      const SpringDescription(mass: 1, stiffness: 210, damping: 26),
      _pullCtl.value,
      target,
      velocity.clamp(-8.0, 8.0),
    ));
    // animateWith 结束后状态是 completed 而不是 dismissed，
    // 必须在这里复位，否则收起一次后 _floorOpen 永远为 true，再拉就拉不动了
    if (target == 0) {
      f.whenCompleteOrCancel(() {
        if (!mounted) return;
        if (_pullCtl.value <= 0.02) {
          _pullCtl.value = 0;
          if (_floorOpen) setState(() => _floorOpen = false);
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
    _panelDragReady = _floorOpen &&
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
    return Listener(
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
              colors: [Color(0xFF0B0D10), Color(AppColors.bg)],
            ),
          ),
          child: SafeArea(
            bottom: false,
            child: ListView(
              controller: _panelScroll,
              physics: const ClampingScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(
                  AppSpace.gutter, AppSpace.x2, AppSpace.gutter, 96),
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
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        border: Border.all(color: const Color(0x4245E0AE)),
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
                              color: const Color(AppColors.textTertiary),
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
                        bottom: BorderSide(color: Color(AppColors.hairline)),
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
                          _recentAt == null ? '' : _agoLabel(_recentAt!),
                          style: AppType.micro,
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: AppSpace.x6),
                Center(
                  child: Text(
                    '点空白处或上滑收起二楼',
                    style: AppType.micro.copyWith(fontSize: 11),
                  ),
                ),
              ],
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
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: cells[0]),
              Expanded(child: cells[1]),
            ],
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: cells[2]),
              Expanded(child: cells[3]),
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
  }) {
    final bg = amber ? const Color(0x22FFB020) : const Color(0x0FFFFFFF);
    final fg = accent
        ? const Color(AppColors.onAccent)
        : amber
            ? const Color(AppColors.warning)
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
  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: const Color(0x1F45E0AE),
              borderRadius: BorderRadius.circular(9),
            ),
            child: const Icon(Icons.flare_rounded,
                size: 17, color: Color(AppColors.accent)),
          ),
          const SizedBox(width: 9),
          const Text(
            '流萤社区',
            style: TextStyle(
              fontSize: 17,
              height: 1.1,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.34,
              color: Color(AppColors.textPrimary),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: PressableScale(
              onTap: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const SearchPage())),
              child: Container(
                height: 36,
                padding: const EdgeInsets.symmetric(horizontal: 13),
                decoration: BoxDecoration(
                  color: const Color(AppColors.card),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: const Color(AppColors.hairline)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.search_rounded,
                        size: 15, color: Color(AppColors.textTertiary)),
                    const SizedBox(width: 7),
                    const Flexible(
                      child: Text(
                        '搜帖子、话题、用户',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: Color(AppColors.textTertiary),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          PressableScale(
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const NotifListPage())),
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: const Color(AppColors.card),
                shape: BoxShape.circle,
                border: Border.all(color: const Color(AppColors.hairline)),
              ),
              child: Stack(
                children: [
                  const Center(
                    child: Icon(Icons.notifications_none_rounded,
                        size: 19, color: Color(AppColors.textPrimary)),
                  ),
                  Positioned(
                    right: 9,
                    top: 8,
                    child: Container(
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
        ],
      ),
    );
  }

  Widget _tabs() {
    const labels = ['关注', '推荐'];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 18),
      child: Row(
        children: [
          for (var i = 0; i < labels.length; i++)
            PressableScale(
              onTap: () => _switchTab(i),
              child: Padding(
                padding: const EdgeInsets.only(right: 26),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AnimatedDefaultTextStyle(
                      duration: AppMotion.base,
                      style: TextStyle(
                        fontSize: 15,
                        height: 1.2,
                        fontWeight:
                            i == _tab ? FontWeight.w700 : FontWeight.w500,
                        color: i == _tab
                            ? const Color(AppColors.textPrimary)
                            : const Color(AppColors.textTertiary),
                      ),
                      child: Text(labels[i]),
                    ),
                    const SizedBox(height: 6),
                    AnimatedContainer(
                      duration: AppMotion.base,
                      curve: AppMotion.standard,
                      width: i == _tab ? 18 : 0,
                      height: 2,
                      decoration: BoxDecoration(
                        color: const Color(AppColors.accent),
                        borderRadius: BorderRadius.circular(1),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

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
  _SeamClipper({required this.seam, required this.px, required this.height});

  final double seam;

  /// 二楼已经露出来的像素高度（1:1 跟手）：向下全量展开，向上只掀开三成
  final double px;
  final double height;

  @override
  Rect getClip(Size size) {
    final down = px.clamp(0.0, (height - seam).clamp(0.0, double.infinity));
    final up = (px * 0.30).clamp(0.0, seam);
    return Rect.fromLTRB(0, seam - up, size.width, seam + down);
  }

  @override
  bool shouldReclip(_SeamClipper old) =>
      old.seam != seam || old.px != px || old.height != height;
}
