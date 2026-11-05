/// 收藏页：收藏 / 稍后看 双分段（[FeedTabs]）+ 三列作品网格（[PostGridTile]）
///
/// 请求、分页与切换逻辑保持原样。
library;

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../design/components.dart';
import '../../models/feed_item.dart';
import '../../widgets/post_card.dart';
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
      if (_items.isEmpty) showAppToast(context, '加载失败：$e');
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
    return ImmersivePage(
      child: Column(
        children: [
          const GlassTopBar(title: '我的收藏', solid: true),
          FeedTabs(
            labels: const ['收藏', '稍后看'],
            index: _tab,
            onChanged: _switchTab,
          ),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _body() {
    if (!_loaded) return const _FavSkeleton();

    final bottom = MediaQuery.paddingOf(context).bottom + 28;
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.extentAfter < 400) _load();
        return false;
      },
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics()),
        slivers: [
          if (_items.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: EmptyState(
                  icon: _tab == 0
                      ? Icons.bookmark_border_rounded
                      : Icons.watch_later_outlined,
                  title: _tab == 0 ? '还没有收藏' : '还没有稍后看',
                  message: _tab == 0
                      ? '看到喜欢的帖子点收藏，就会出现在这里'
                      : '遇到好内容先存着，空闲时再看',
                ),
              ),
            )
          else ...[
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpace.gutter, AppSpace.x2, AppSpace.gutter, 0),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  mainAxisSpacing: AppSpace.x2,
                  crossAxisSpacing: AppSpace.x2,
                  childAspectRatio: 0.78,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, i) {
                    final it = _items[i];
                    return PostGridTile(
                      item: it,
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => PostDetailPage(postId: it.id)),
                      ),
                      onAuthorTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) =>
                                UserProfilePage(uid: it.author.id)),
                      ),
                    );
                  },
                  childCount: _items.length,
                ),
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
    );
  }
}

/// 首屏骨架：三列圆角占位。
class _FavSkeleton extends StatelessWidget {
  const _FavSkeleton();

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(
          AppSpace.gutter, AppSpace.x2, AppSpace.gutter, 0),
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: AppSpace.x2,
        crossAxisSpacing: AppSpace.x2,
        childAspectRatio: 0.78,
      ),
      itemCount: 9,
      itemBuilder: (_, _) => const SkeletonBox(radius: AppRadius.sm),
    );
  }
}
