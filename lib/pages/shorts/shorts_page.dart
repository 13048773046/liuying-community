/// 短视频页：沉浸式上下滑动切换（复刻流萤音乐 iOS VerticalPager 交互）
///
/// 交互等价映射：
/// - UIPageViewController(vertical)          → PageView(scrollDirection: vertical)
/// - 控制器懒创建（滑到哪页建哪页）           → PageView.builder 仅构建可见页 + 预取前后页
/// - 手势翻页中禁止程序化回跳                 → PageController 仅监听 onPageChanged，不做回写
/// - 只渲染当前页播放，离屏页暂停             → isActive 驱动 VideoCard 播放/暂停
/// - LRU 内存防护（音乐端 maxCachedPages=32）→ 滑过的页自动释放播放器，保留前后 2 页
library;

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../design/components.dart';
import '../../models/feed_item.dart';
import 'video_card.dart';

class ShortsPage extends StatefulWidget {
  const ShortsPage({super.key});

  @override
  State<ShortsPage> createState() => _ShortsPageState();
}

class _ShortsPageState extends State<ShortsPage> {
  final PageController _controller = PageController(viewportFraction: 1.0);
  final List<FeedItem> _items = [];
  bool _loading = false;
  bool _hasMore = true;
  int _page = 0;
  int _current = 0;
  int _tab = 1; // 0=关注 1=推荐（默认推荐，与首页一致）

  @override
  void initState() {
    super.initState();
    _loadMore();
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasMore) return;
    setState(() => _loading = true);
    try {
      // 同源混合：与首页同一内容池（视频+图片/图文帖全类型混排）
      final p = await ApiClient.feed(
        tab: _tab == 0 ? 'follow' : 'recommend',
        page: _page + 1,
        size: 6,
      );
      if (!mounted) return;
      setState(() {
        _page = p.page;
        _hasMore = p.hasMore;
        _items.addAll(p.list);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      if (_items.isEmpty) {
        // 首屏加载失败：显示重试
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('加载失败：$e')));
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 切换关注/推荐：清空当前流并回到顶部重新加载
  Future<void> _switchTab(int i) async {
    if (_tab == i) return;
    setState(() {
      _tab = i;
      _items.clear();
      _page = 0;
      _hasMore = true;
      _loading = false;
      _current = 0;
    });
    if (_controller.hasClients) _controller.jumpToPage(0);
    await _loadMore();
  }

  @override
  Widget build(BuildContext context) {
    return ImmersivePage(
      // 键盘弹出只顶弹窗输入框，页面（视频/导航栏）不被顶起
      resizeToAvoidBottomInset: false,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 发布入口已移至底部中间按钮（短视频页内显示发布 + 号）
          if (_items.isEmpty)
            _buildLoading()
          else
            PageView.builder(
              controller: _controller,
              scrollDirection: Axis.vertical,
              // 隐式滚动：预取相邻页，视频初始化提前，切页即播
              allowImplicitScrolling: true,
              itemCount: _items.length,
              onPageChanged: (i) {
                setState(() => _current = i);
                // 滑近末尾自动加载下一页（音乐端"追加队列"等价）
                if (i >= _items.length - 3) _loadMore();
              },
              itemBuilder: (_, i) => VideoCard(
                item: _items[i],
                isActive: i == _current,
              ),
            ),
          // 顶部分段：关注 / 推荐（V16 文字级指示器）
          Positioned(
            top: MediaQuery.paddingOf(context).top + 10,
            left: 0,
            right: 0,
            child: Center(child: _tabSwitch()),
          ),
        ],
      ),
    );
  }

  Widget _tabSwitch() {
    final labels = const ['关注', '推荐'];
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < labels.length; i++)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _switchTab(i),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: i == 0 ? 0 : 26),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    labels[i],
                    style: TextStyle(
                      fontSize: 15,
                      height: 1.2,
                      letterSpacing: -0.15,
                      fontWeight:
                          i == _tab ? FontWeight.w700 : FontWeight.w500,
                      color: i == _tab
                          ? const Color(AppColors.textPrimary)
                          : const Color(AppColors.textTertiary),
                      shadows: const [
                        Shadow(color: Color(0x99000000), blurRadius: 6),
                      ],
                    ),
                  ),
                  const SizedBox(height: 7),
                  AnimatedContainer(
                    duration: AppMotion.fast,
                    width: i == _tab ? 16 : 0,
                    height: 2.5,
                    decoration: BoxDecoration(
                      color: const Color(AppColors.accent),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildLoading() {
    if (!_loading) {
      return Center(
        child: EmptyState(
          icon: Icons.movie_outlined,
          title: _tab == 0 ? '关注的人还没有作品' : '暂时没有内容',
          message: _tab == 0
              ? '去首页发现更多创作者，关注后会出现在这里'
              : '稍后再来看看，或去发一条短视频',
        ),
      );
    }
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: const [
          SkeletonBox(width: 120, height: 120, radius: AppRadius.lg),
          SizedBox(height: AppSpace.x4),
          SkeletonBox(width: 180, height: 12),
          SizedBox(height: AppSpace.x2),
          SkeletonBox(width: 120, height: 10),
        ],
      ),
    );
  }
}
