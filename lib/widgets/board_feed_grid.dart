/// 版块帖子流（三列作品网格，feed?board_id=），供版块页二级直切与独立页复用
///
/// 沉浸黑：黑底 + 三列圆角网格（[PostGridTile]）+ 底部加载更多；
/// 请求、分页、下拉刷新、滚动加载逻辑保持原样。
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

import '../api/client.dart';
import '../config.dart';
import '../design/components.dart';
import '../models/feed_item.dart';
import '../pages/post/post_detail.dart';
import 'post_card.dart';

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
      if (_items.isEmpty) showAppToast(context, '加载失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = 28 + tabBarBottomInset(context);
    final content = RefreshIndicator(
      color: const Color(AppColors.accent),
      backgroundColor: const Color(AppColors.elevated),
      onRefresh: () => _load(refresh: true),
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n.metrics.extentAfter < n.metrics.viewportDimension) _load();
          return false;
        },
        child: CustomScrollView(
          scrollCacheExtent: const ScrollCacheExtent.pixels(300),
          physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics(),
          ),
          slivers: [
            if (_items.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Padding(
                  padding: EdgeInsets.only(bottom: bottom),
                  child: const Center(
                    child: EmptyState(
                      icon: Icons.forum_outlined,
                      title: '该版块还没有内容',
                      message: '去发布第一帖吧',
                    ),
                  ),
                ),
              )
            else ...[
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpace.gutter,
                  AppSpace.x2,
                  AppSpace.gutter,
                  0,
                ),
                sliver: SliverMasonryGrid.count(
                  crossAxisCount: 2,
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 8,
                  childCount: _items.length,
                  itemBuilder: (context, i) {
                    final it = _items[i];
                    final cover = it.isVideo
                        ? it.cover
                        : (it.images.isNotEmpty ? it.images.first : '');
                    final tile = PostGridTile(
                      item: it,
                      centerText: true,
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => PostDetailPage(postId: it.id),
                        ),
                      ),
                    );
                    // 有封面按竖版卡片；纯文字帖按内容行数收紧，避免大片空卡。
                    Widget content;
                    if (cover.isNotEmpty) {
                      content = AspectRatio(aspectRatio: 0.80, child: tile);
                    } else {
                      final chars = it.content.trim().runes.length;
                      final lines = (chars / 11).ceil().clamp(2, 5).toInt();
                      final top = it.isVideo ? 34.0 : 12.0;
                      content = SizedBox(
                        height: top + lines * 19.0 + 38.0,
                        child: tile,
                      );
                    }
                    return StaggerReveal(
                      key: ValueKey('board-post-${it.id}'),
                      index: i,
                      child: content,
                    );
                  },
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.only(bottom: bottom),
                  child: LoadMoreFooter(
                    loading: _loading,
                    hasMore: _hasMore,
                    onTap: () => _load(),
                    endLabel: '— 到底啦 —',
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
    return SkeletonSwap(
      loading: !_loaded,
      skeleton: const ShimmerScope(child: _GridSkeleton()),
      child: content,
    );
  }
}

/// 首屏骨架：三列圆角占位，避免白屏跳动。
class _GridSkeleton extends StatelessWidget {
  const _GridSkeleton();

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.gutter,
        AppSpace.x2,
        AppSpace.gutter,
        0,
      ),
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 10,
        crossAxisSpacing: 8,
        childAspectRatio: 0.86,
      ),
      itemCount: 6,
      itemBuilder: (_, _) => const SkeletonBox(radius: AppRadius.sm),
    );
  }
}
