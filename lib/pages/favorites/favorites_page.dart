/// 收藏页：收藏 / 稍后看 双 Tab，瀑布流卡片复用首页组件
library;

import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

import '../../api/client.dart';
import '../../config.dart';
import '../../models/feed_item.dart';
import '../../widgets/waterfall_card.dart';
import '../post/post_detail.dart';
import '../user/user_profile.dart';

class FavoritesPage extends StatefulWidget {
  const FavoritesPage({super.key});

  @override
  State<FavoritesPage> createState() => _FavoritesPageState();
}

class _FavoritesPageState extends State<FavoritesPage> {
  int _tab = 0; // 0=收藏 1=稍后看
  final List<FeedItem> _items = [];
  bool _loading = true;
  bool _loaded = false;
  int _page = 0;
  bool _hasMore = true;

  @override
  void initState() {
    super.initState();
    _load(refresh: true);
  }

  Future<void> _load({bool refresh = false}) async {
    if (_loading || (!_hasMore && !refresh)) return;
    setState(() => _loading = true);
    try {
      final j = await ApiClient.favorites(
        kind: _tab == 0 ? 'fav' : 'later',
        page: refresh ? 1 : _page + 1,
      );
      if (!mounted) return;
      final list = FeedPage.fromJson(j).list;
      setState(() {
        if (refresh) {
          _items.clear();
          _page = 0;
        }
        _page = FeedPage.fromJson(j).page;
        _hasMore = boolOf(j['hasMore']);
        _items.addAll(list);
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(AppTheme.bg),
      appBar: AppBar(
        backgroundColor: const Color(AppTheme.bg),
        foregroundColor: const Color(AppTheme.textPrimary),
        elevation: 0,
        title: const Text('收藏'),
        centerTitle: true,
      ),
      body: Column(
        children: [
          // Tab 指示器
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _seg(0, '收藏'),
                const SizedBox(width: 8),
                _seg(1, '稍后看'),
              ],
            ),
          ),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _seg(int i, String label) {
    final sel = _tab == i;
    return GestureDetector(
      onTap: () => _switchTab(i),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        decoration: BoxDecoration(
          color: sel ? const Color(AppTheme.accent) : const Color(AppTheme.card),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: sel ? Colors.black : const Color(AppTheme.textSecondary),
            fontSize: 13,
            fontWeight: sel ? FontWeight.bold : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _body() {
    if (!_loaded) {
      return const Center(
        child: CircularProgressIndicator(
            color: Color(AppTheme.accent), strokeWidth: 2.5),
      );
    }
    if (_items.isEmpty) {
      return ListView(
        padding: EdgeInsets.only(bottom: 24+ MediaQuery.paddingOf(context).bottom),
        children: [
          const SizedBox(height: 120),
          const Icon(Icons.bookmark_border,
              size: 56, color: Color(AppTheme.textTertiary)),
          const SizedBox(height: 12),
          Center(
            child: Text(
              _tab == 0 ? '还没有收藏\n看到喜欢的帖子点♥收藏' : '还没有稍后看',
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: Color(AppTheme.textSecondary),
                  fontSize: 13.5,
                  height: 1.6),
            ),
          ),
        ],
      );
    }
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.extentAfter < 400) _load();
        return false;
      },
      child: MasonryGridView.count(
        physics: const AlwaysScrollableScrollPhysics(),
        crossAxisCount: 2,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        padding: EdgeInsets.fromLTRB(12, 4, 12, 24+ MediaQuery.paddingOf(context).bottom),
        itemCount: _items.length + 1,
        itemBuilder: (_, i) {
          if (i == _items.length) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 18),
              child: Center(
                child: _hasMore
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Color(AppTheme.accent)))
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
}
