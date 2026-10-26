/// 社区首页：双列瀑布流信息流（feed?tab=recommend|follow，图文+视频混排）
/// 顶部「推荐 / 关注」胶囊指示器；卡片按内容高度自适应两列排布。
library;

import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

import '../../api/client.dart';
import '../../config.dart';
import '../../models/feed_item.dart';
import '../boards/boards_page.dart';
import '../mine/login_page.dart';
import '../post/post_detail.dart';
import '../post/post_editor.dart';
import '../search/search_page.dart';
import '../user/user_profile.dart';
import '../../widgets/waterfall_card.dart';

/// 运营推广卡（概念稿：发帖赢好礼 → 跳发布器）
class _CampaignCard extends StatelessWidget {
  const _CampaignCard();

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => const PostEditorPage(mode: 'text'))),
      child: Container(
        height: 76,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [Color(0xFF1E3A31), Color(0xFF14221E)],
          ),
          borderRadius: BorderRadius.circular(AppTheme.radiusCard),
          border: Border.all(
              color: const Color(AppTheme.accent).withValues(alpha: 0.25)),
        ),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: const Color(AppTheme.accent).withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.emoji_events_outlined,
                  color: Color(AppTheme.accent), size: 24),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('发帖赢好礼',
                      style: TextStyle(
                          color: Color(AppTheme.textPrimary),
                          fontSize: 14.5,
                          fontWeight: FontWeight.w600)),
                  SizedBox(height: 3),
                  Text('晒出你的瞬间，赢取限定装扮',
                      style: TextStyle(
                          color: Color(AppTheme.textSecondary),
                          fontSize: 12)),
                ],
              ),
            ),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                color: const Color(AppTheme.accent),
                borderRadius: BorderRadius.circular(AppTheme.radiusPill),
              ),
              child: const Text('立即参与',
                  style: TextStyle(
                      color: Colors.black,
                      fontSize: 12.5,
                      fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _tab = 0; // 0=推荐 1=关注
  final List<FeedItem> _items = [];
  bool _loading = false;
  bool _loaded = false;
  int _page = 0;
  bool _hasMore = true;
  final ScrollController _scroll = ScrollController();
  // 版块分类横滑 + 话题 chips（对齐概念稿：标题 → 分类 → 话题 → Tab+换一批 → 推广卡 → 瀑布流）
  final List<Board> _boards = [];
  String _boardId = '';
  final List<String> _topics = [];
  String _topic = '';

  @override
  void initState() {
    super.initState();
    _load(refresh: true);
    _loadMeta();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// 版块分类 + 热门话题（头部横滑条）
  Future<void> _loadMeta() async {
    try {
      final bj = await ApiClient.get('/boards');
      final tj = await ApiClient.topics();
      if (!mounted) return;
      setState(() {
        _boards
          ..clear()
          ..addAll(((bj['list'] ?? []) as List)
              .whereType<Map<String, dynamic>>()
              .map(Board.fromJson)
              .take(8));
        _topics
          ..clear()
          ..addAll(((tj['list'] ?? []) as List)
              .whereType<Map<String, dynamic>>()
              .map((t) => (t['name'] ?? '') as String)
              .where((n) => n.isNotEmpty)
              .take(6));
      });
    } catch (_) {
      if (!mounted) return;
    }
  }

  Future<void> _load({bool refresh = false}) async {
    if (_loading || (!_hasMore && !refresh)) return;
    setState(() => _loading = true);
    try {
      final p = await ApiClient.feed(
        tab: _tab == 0 ? 'recommend' : 'follow',
        page: refresh ? 1 : _page + 1,
        size: 10,
        boardId: _boardId,
        topic: _topic,
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

  /// 切换版块分类 / 话题（过滤信息流）
  void _filter(String boardId, String topic) {
    setState(() {
      _boardId = boardId;
      _topic = topic;
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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 顶部标题 + 搜索 / 通知图标（概念稿对齐）
            Padding(
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
            // 版块分类横滑（概念稿：推荐/关注/游戏/生活/影音/科技）
            if (_boards.isNotEmpty) _boardStrip(),
            // 话题 chips（概念稿：#今日话题 #夏日挑战 #我的城市）
            if (_topics.isNotEmpty) _topicStrip(),
            // 推荐 / 关注 Tab + 换一批
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
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
            // 运营推广卡（概念稿：发帖赢好礼）
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: _CampaignCard(),
            ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: () => _load(refresh: true),
                color: const Color(AppTheme.accent),
                backgroundColor: const Color(AppTheme.card),
                child: _body(),
              ),
            ),
          ],
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

  /// 版块分类横滑条
  Widget _boardStrip() {
    return SizedBox(
      height: 34,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          _chip('全部', _boardId.isEmpty, () => _filter('', _topic)),
          for (final b in _boards) ...[
            const SizedBox(width: 8),
            _chip(b.name, _boardId == b.id, () => _filter(b.id, _topic)),
          ],
        ],
      ),
    );
  }

  /// 话题 chips 横滑条
  Widget _topicStrip() {
    return SizedBox(
      height: 30,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          _chip('#热门', _topic.isEmpty,
              () => _filter(_boardId, '')),
          for (final t in _topics) ...[
            const SizedBox(width: 8),
            _chip('#$t', _topic == t, () => _filter(_boardId, t)),
          ],
        ],
      ),
    );
  }

  Widget _chip(String label, bool sel, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 13),
        decoration: BoxDecoration(
          color: sel
              ? const Color(AppTheme.accent).withValues(alpha: 0.16)
              : const Color(AppTheme.card),
          borderRadius: BorderRadius.circular(AppTheme.radiusPill),
          border: sel
              ? Border.all(
                  color: const Color(AppTheme.accent).withValues(alpha: 0.6))
              : null,
        ),
        child: Text(label,
            style: TextStyle(
                color: sel
                    ? const Color(AppTheme.accent)
                    : const Color(AppTheme.textPrimary),
                fontSize: 12.5,
                fontWeight: sel ? FontWeight.w600 : FontWeight.w400)),
      ),
    );
  }

  /// 文字 Tab + 2px 下划线（小红书式）：推荐 / 关注
  Widget _tabIndicator() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _seg(0, '推荐'),
          const SizedBox(width: 28),
          _seg(1, '关注'),
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

  Widget _body() {
    if (!_loaded) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 200),
          Center(
            child: CircularProgressIndicator(
                color: Color(AppTheme.accent), strokeWidth: 2.5),
          ),
        ],
      );
    }
    if (_items.isEmpty) return _empty();
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.extentAfter < 400) _load();
        return false;
      },
      child: MasonryGridView.count(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        crossAxisCount: 2,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        padding: const EdgeInsets.fromLTRB(12, 2, 12, 84),
        itemCount: _items.length + 1,
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
        },
      ),
    );
  }

  Widget _empty() {
    final notLogin = _tab == 1 && ApiClient.token == null;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        const SizedBox(height: 120),
        Icon(notLogin ? Icons.lock_outline : Icons.inbox_outlined,
            size: 56, color: const Color(AppTheme.textTertiary)),
        const SizedBox(height: 12),
        Center(
          child: Text(
            notLogin
                ? '登录后查看关注动态'
                : _tab == 1
                    ? '还没有关注内容\n去关注感兴趣的作者吧'
                    : '还没有内容，去发第一帖吧',
            textAlign: TextAlign.center,
            style: const TextStyle(
                color: Color(AppTheme.textSecondary),
                fontSize: 13.5,
                height: 1.6),
          ),
        ),
        if (notLogin)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Center(
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(AppTheme.accent),
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(22)),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 28, vertical: 10),
                ),
                onPressed: () => Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const LoginPage())),
                child: const Text('去登录', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
          ),
      ],
    );
  }
}
