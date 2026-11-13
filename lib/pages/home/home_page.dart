/// 社区首页：沉浸黑单列信息流（关注 / 推荐）
///
/// 版式：品牌标题 + 顶部操作（任务/搜索/发布）→ 关注·推荐分段 → 二楼入口 → 运营入口 →
/// Banner → 全幅内容卡（[PostCard]）。整页一起滚动，不做吸顶。
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

  /// 二楼（下滑取出的小程序面板）
  late final AnimationController _floorCtl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 240),
  );
  double _floorPull = 0;

  @override
  void initState() {
    super.initState();
    _load(refresh: true);
  }

  @override
  void dispose() {
    _floorCtl.dispose();
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
        child: AnimatedBuilder(
          animation: _floorCtl,
          builder: (context, _) {
            final t = Curves.easeOutCubic.transform(_floorCtl.value);
            return Stack(
              children: [
                if (t > 0) Positioned.fill(child: _floorPanel(t)),
                Transform.translate(
                  offset: Offset(0, t * 26),
                  child: Opacity(
                    opacity: 1 - t * 0.5,
                    child: IgnorePointer(ignoring: t > 0, child: _homeList()),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _homeList() {
    return RefreshIndicator(
      onRefresh: () => _load(refresh: true),
      color: const Color(AppColors.accent),
      backgroundColor: const Color(AppColors.elevated),
      edgeOffset: 8,
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n.metrics.extentAfter < 500) _load();
          return false;
        },
        child: CustomScrollView(
          controller: _scroll,
          physics: const AlwaysScrollableScrollPhysics(
              parent: BouncingScrollPhysics()),
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

  // ---------------------------------------------------------------- 二楼入口
  Widget _floorEntry() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpace.gutter, AppSpace.x3, AppSpace.gutter, 0),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _openFloor,
        onVerticalDragStart: (_) => _floorPull = 0,
        onVerticalDragUpdate: (d) {
          _floorPull += d.delta.dy;
          if (_floorPull > 46) {
            _floorPull = 0;
            _openFloor();
          }
        },
        onVerticalDragEnd: (_) => _floorPull = 0,
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
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
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('二楼 · 下滑取出小工具',
                        style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: Color(AppColors.textPrimary))),
                    const SizedBox(height: 3),
                    Text('流萤航线 · 创作 · 任务 · 榜单',
                        style: AppType.micro.copyWith(fontSize: 11)),
                  ],
                ),
              ),
              const Icon(Icons.keyboard_arrow_down_rounded,
                  size: 18, color: Color(AppColors.textTertiary)),
            ],
          ),
        ),
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

  void _openFloor() {
    _floorCtl.forward();
    HapticFeedback.lightImpact();
  }

  Future<void> _closeFloor() async {
    await _floorCtl.reverse();
  }

  Widget _floorPanel(double t) {
    return GestureDetector(
      onTap: _closeFloor,
      onVerticalDragUpdate: (d) {
        if (d.delta.dy < -30) _closeFloor();
      },
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
                  AppSpace.gutter, AppSpace.x5, AppSpace.gutter, 28),
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
                        color: Color(AppColors.textPrimary)),
                ),
                const SizedBox(height: 4),
                Text('在首页往下轻轻一拉就出来了',
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
                      MaterialPageRoute(
                          builder: (_) => const PetalwakePage()),
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
