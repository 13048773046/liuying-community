/// 版块帖子流（双列瀑布流，feed?board_id=），供板块页二级直切与独立页复用
library;

import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

import '../api/client.dart';
import '../config.dart';
import '../models/feed_item.dart';
import 'waterfall_card.dart';
import '../pages/post/post_detail.dart';

class BoardFeedGrid extends StatefulWidget {
  final String boardId;
  const BoardFeedGrid({super.key, required this.boardId});

  @override
  State<BoardFeedGrid> createState() => _BoardFeedGridState();
}

class _BoardFeedGridState extends State<BoardFeedGrid> {
  final List<FeedItem> _items = [];
  bool _loading = false;
  bool _loaded = false;
  int _page = 0;
  bool _hasMore = true;

  @override
  void initState() {
    super.initState();
    _load(refresh: true);
  }

  @override
  void didUpdateWidget(covariant BoardFeedGrid old) {
    super.didUpdateWidget(old);
    if (old.boardId != widget.boardId) {
      _items.clear();
      _page = 0;
      _hasMore = true;
      _loaded = false;
      _load(refresh: true);
    }
  }

  Future<void> _load({bool refresh = false}) async {
    if (_loading || (!_hasMore && !refresh)) return;
    setState(() => _loading = true);
    try {
      final p = await ApiClient.feed(
        tab: 'all',
        page: refresh ? 1 : _page + 1,
        size: 10,
        boardId: widget.boardId,
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
        ));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Center(
        child: CircularProgressIndicator(
            color: Color(AppTheme.accent), strokeWidth: 2.5),
      );
    }
    if (_items.isEmpty) {
      return RefreshIndicator(
        color: const Color(AppTheme.accent),
        backgroundColor: const Color(AppTheme.card),
        onRefresh: () => _load(refresh: true),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const [
            SizedBox(height: 100),
            Icon(Icons.forum_outlined,
                size: 48, color: Color(AppTheme.textTertiary)),
            SizedBox(height: 10),
            Center(
              child: Text('该版块还没有内容\n去发布第一帖吧',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: Color(AppTheme.textSecondary),
                      fontSize: 13.5,
                      height: 1.6)),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      color: const Color(AppTheme.accent),
      backgroundColor: const Color(AppTheme.card),
      onRefresh: () => _load(refresh: true),
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n.metrics.extentAfter < 400) _load();
          return false;
        },
        child: MasonryGridView.count(
          physics: const AlwaysScrollableScrollPhysics(),
          crossAxisCount: 2,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          // 底部避让：动态取导航栏实际高度（背景延伸由 Scaffold 底色承担）
          padding: EdgeInsets.fromLTRB(12, 4, 12, tabBarBottomInset(context)),
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
            );
          },
        ),
      ),
    );
  }
}
