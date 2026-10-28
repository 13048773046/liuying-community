/// 社区首页：双列瀑布流信息流（feed?tab=follow|recommend，图文+视频混排）
/// 布局对齐概念稿：标题+搜索(+任务按钮) → 关注/推荐 Tab+换一批 → 瀑布流
library;

import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

import '../../api/client.dart';
import '../../config.dart';
import '../../models/feed_item.dart';
import '../mine/login_page.dart';
import '../mine/task_center_page.dart';
import '../post/post_detail.dart';
import '../post/post_editor.dart';
import '../search/search_page.dart';
import '../discover/ranking_page.dart';
import '../discover/topic_page.dart';
import '../../widgets/banner_carousel.dart';
import '../user/user_profile.dart';
import '../../widgets/waterfall_card.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _tab = 1; // 0=关注 1=推荐（UI 顺序：关注 | 推荐，默认选中推荐）
  final List<FeedItem> _items = [];
  bool _loading = false;
  bool _loaded = false;
  int _page = 0;
  bool _hasMore = true;
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
    setState(() => _loading = true);
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
      });
      if (_items.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('加载失败：$e'),
          backgroundColor: const Color(AppTheme.card),
          behavior: SnackBarBehavior.floating,
          action: SnackBarAction(
            label: '重试',
            textColor: const Color(AppTheme.accent),
            onPressed: () => _load(refresh: true),
          ),
        ));
      }
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
    });
    _load(refresh: true);
  }

  /// 发布菜单：发图文帖 / 发短视频
  Future<void> _showPublishMenu() async {
    await showModalBottomSheet(
      context: context,
      backgroundColor: const Color(AppTheme.card),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 10),
              child: Text('发布内容',
                  style: TextStyle(
                      color: Color(AppTheme.textPrimary),
                      fontSize: 16,
                      fontWeight: FontWeight.bold)),
            ),
            _menuItem(Icons.article_outlined, '发布图文帖', () {
              Navigator.pop(ctx);
              Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const PostEditorPage(mode: 'text')))
                  .then((ok) {
                if (ok == true) _load(refresh: true);
              });
            }),
            _menuItem(Icons.video_library_outlined, '发布短视频', () {
              Navigator.pop(ctx);
              Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const PostEditorPage(mode: 'video')))
                  .then((ok) {
                if (ok == true) _load(refresh: true);
              });
            }),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _menuItem(IconData icon, String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
        child: Row(
          children: [
            Icon(icon, color: const Color(AppTheme.accent), size: 22),
            const SizedBox(width: 12),
            Text(label,
                style: const TextStyle(
                    color: Color(AppTheme.textPrimary), fontSize: 15)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(AppTheme.bg),
      floatingActionButton: FloatingActionButton(
        onPressed: _showPublishMenu,
        backgroundColor: const Color(AppTheme.accent),
        foregroundColor: Colors.black,
        shape: const CircleBorder(),
        child: const Icon(Icons.edit, size: 22),
      ),
      body: SafeArea(
        // 只避让顶部状态栏；底部导航栏避让由 RootPage 的 Padding(60+safe) 统一处理，
        // 避免与 SafeArea/瀑布流留白三重叠加导致导航栏上方多出一截空白
        bottom: false,
        // 整页滚动：标题/运营栏/Banner/Tab 全部随内容一起滚走（不吸顶）
        child: RefreshIndicator(
          onRefresh: () => _load(refresh: true),
          color: const Color(AppTheme.accent),
          backgroundColor: const Color(AppTheme.card),
          child: NotificationListener<ScrollNotification>(
            onNotification: (n) {
              if (n.metrics.extentAfter < 400) _load();
              return false;
            },
            child: CustomScrollView(
              controller: _scroll,
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                // 顶部标题 + 搜索 / 任务按钮
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 12, 2),
                    child: Row(
                      children: [
                        const Expanded(
                          child: Text(
                            '流萤社区',
                            style: TextStyle(
                                color: Color(AppTheme.textPrimary),
                                fontSize: 22,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 0.5),
                          ),
                        ),
                        _taskButton(),
                        const SizedBox(width: 10),
                        _headerIcon(
                          Icons.search,
                          () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => const SearchPage())),
                        ),
                        const SizedBox(width: 4),
                      ],
                    ),
                  ),
                ),
                // 首页运营栏：话题 / 排行榜 入口
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                    child: Row(
                      children: [
                        _opsPill(
                          Icons.local_fire_department_rounded,
                          '话题',
                          () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => const TopicPage())),
                        ),
                        const SizedBox(width: 10),
                        _opsPill(
                          Icons.leaderboard_rounded,
                          '排行榜',
                          () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => const RankingPage())),
                        ),
                        const Spacer(),
                        GestureDetector(
                          onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => const TaskCenterPage())),
                          child: const Row(
                            children: [
                              Icon(Icons.emoji_events_outlined,
                                  color: Color(AppTheme.accent), size: 15),
                              SizedBox(width: 3),
                              Text('任务中心',
                                  style: TextStyle(
                                      color: Color(AppTheme.accent),
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                // Banner 运营位轮播（无限自动）
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(16, 10, 16, 4),
                    child: BannerCarousel(),
                  ),
                ),
                // 关注 / 推荐 Tab + 换一批
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 2, 16, 6),
                    child: Row(
                      children: [
                        _tabIndicator(),
                        const Spacer(),
                        GestureDetector(
                          onTap: () => _load(refresh: true),
                          behavior: HitTestBehavior.opaque,
                          child: const Padding(
                            padding: EdgeInsets.all(6),
                            child: Row(
                              children: [
                                Icon(Icons.refresh, size: 14,
                                    color: Color(AppTheme.textTertiary)),
                                SizedBox(width: 3),
                                Text('换一批',
                                    style: TextStyle(
                                        color: Color(AppTheme.textTertiary),
                                        fontSize: 12)),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                    ),
                  ),
                ),
                // 瀑布流信息流
                _feedSliver(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 顶部普通图标按钮
  Widget _headerIcon(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Icon(icon,
            color: const Color(AppTheme.textPrimary), size: 22),
      ),
    );
  }

  /// 运营栏胶囊入口
  Widget _opsPill(IconData icon, String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(AppTheme.card),
          borderRadius: BorderRadius.circular(AppTheme.radiusPill),
          border: Border.all(color: const Color(AppTheme.border)),
        ),
        child: Row(
          children: [
            Icon(icon, color: const Color(AppTheme.accent), size: 14),
            const SizedBox(width: 4),
            Text(label,
                style: const TextStyle(
                    color: Color(AppTheme.textPrimary),
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }

  /// 任务按钮（独立入口 → 任务中心，对齐概念稿：任务不嵌在帖子里）
  Widget _taskButton() {
    return GestureDetector(
      onTap: () => Navigator.push(context,
          MaterialPageRoute(builder: (_) => const TaskCenterPage())),
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: const Color(AppTheme.accent).withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(AppTheme.radiusPill),
          border: Border.all(
              color: const Color(AppTheme.accent).withValues(alpha: 0.35)),
        ),
        child: const Row(
          children: [
            Icon(Icons.emoji_events_outlined,
                color: Color(AppTheme.accent), size: 14),
            SizedBox(width: 4),
            Text('任务',
                style: TextStyle(
                    color: Color(AppTheme.accent),
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }

  /// 文字 Tab + 2px 下划线（概念稿：关注 | 推荐）
  Widget _tabIndicator() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _seg(0, '关注'),
          const SizedBox(width: 28),
          _seg(1, '推荐'),
        ],
      ),
    );
  }

  Widget _seg(int i, String label) {
    final sel = _tab == i;
    return GestureDetector(
      onTap: () => _switchTab(i),
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                color: sel
                    ? const Color(AppTheme.textPrimary)
                    : const Color(AppTheme.textSecondary),
                fontSize: 15,
                fontWeight: sel ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
            const SizedBox(height: 4),
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              width: 20,
              height: 2,
              decoration: BoxDecoration(
                color: sel ? const Color(AppTheme.accent) : Colors.transparent,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 瀑布流信息流（sliver 版，整页滚动）
  Widget _feedSliver() {
    if (!_loaded) {
      return const SliverFillRemaining(
        hasScrollBody: false,
        child: Center(
          child: CircularProgressIndicator(
              color: Color(AppTheme.accent), strokeWidth: 2.5),
        ),
      );
    }
    if (_items.isEmpty) return _empty();
    return SliverPadding(
      // 底部避让：动态取导航栏实际高度（背景延伸由 Scaffold 底色承担，不露空白）
      padding: EdgeInsets.fromLTRB(12, 2, 12, tabBarBottomInset(context)),
      sliver: SliverMasonryGrid.count(
        crossAxisCount: 2,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childCount: _items.length + 1,
        itemBuilder: (_, i) {
          if (i == _items.length) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Center(
                child: _hasMore
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Color(AppTheme.accent)))
                    : const Text('— 到底啦 —',
                        style: TextStyle(
                            color: Color(AppTheme.textTertiary),
                            fontSize: 11)),
              ),
            );
          }
          final it = _items[i];
          return _card(it);
        },
      ),
    );
  }

  /// 信息流卡片（复用瀑布流卡片组件）
  Widget _card(FeedItem it) {
    return WaterfallCard(
      item: it,
      onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => PostDetailPage(postId: it.id))),
      onAuthorTap: () => Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => UserProfilePage(uid: it.author.id))),
    );
  }


  Widget _empty() {
    final notLogin = _tab == 1 && ApiClient.token == null;
    return SliverFillRemaining(
      hasScrollBody: false,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(notLogin ? Icons.lock_outline : Icons.inbox_outlined,
              size: 56, color: const Color(AppTheme.textTertiary)),
          const SizedBox(height: 12),
          Text(
            notLogin
                ? '登录后查看关注动态'
                : _tab == 1
                    ? '还没有关注内容\n去关注感兴趣的作者吧'
                    : '还没有内容，去发第一帖吧',
            textAlign: TextAlign.center,
            style: const TextStyle(
                color: Color(AppTheme.textSecondary), fontSize: 13.5),
          ),
          const SizedBox(height: 16),
          if (!notLogin)
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(AppTheme.accent),
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(22)),
              ),
              onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const PostEditorPage(mode: 'text'))),
              child: const Text('去发布'),
            )
          else
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(AppTheme.accent),
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(22)),
              ),
              onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const LoginPage())),
              child: const Text('去登录'),
            ),
        ],
      ),
    );
  }

}
