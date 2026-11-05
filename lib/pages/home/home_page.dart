/// 社区首页：沉浸黑单列信息流（关注 / 推荐）
///
/// 版式：品牌标题 + 顶部操作（任务/搜索/发布）→ 关注·推荐分段 → 运营入口 →
/// Banner → 全幅内容卡（[PostCard]）。整页一起滚动，不做吸顶。
library;

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../config.dart';
import '../../design/components.dart';
import '../../models/feed_item.dart';
import '../../widgets/banner_carousel.dart';
import '../../widgets/post_card.dart';
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

class _HomePageState extends State<HomePage> {
  int _tab = 1; // 0=关注 1=推荐（默认推荐）
  final List<FeedItem> _items = [];
  bool _loading = false;
  bool _loaded = false;
  int _page = 0;
  bool _hasMore = true;
  String? _error;
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _load(refresh: true);
  }

  @override
  void dispose() {
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
        child: RefreshIndicator(
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
        ),
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
