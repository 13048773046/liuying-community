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
import '../../config.dart';
import '../../models/feed_item.dart';
import '../post/post_editor.dart';
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

  @override
  void initState() {
    super.initState();
    _loadMore();
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasMore) return;
    setState(() => _loading = true);
    try {
      final p = await ApiClient.feed(type: 'video', page: _page + 1, size: 6);
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(AppTheme.bg),
      floatingActionButton: Padding(
        // 透明导航栏上方悬浮，不遮挡内容
        padding: EdgeInsets.only(
            bottom: 54 + MediaQuery.viewPaddingOf(context).bottom + 6),
        child: FloatingActionButton.small(
          onPressed: () async {
            final ok = await Navigator.of(context).push<bool>(
              MaterialPageRoute(
                  builder: (_) => const PostEditorPage(mode: 'video')),
            );
            if (ok == true) {
              _items.clear();
              _page = 0;
              _hasMore = true;
              _loadMore();
            }
          },
          backgroundColor: const Color(AppTheme.card),
          foregroundColor: const Color(AppTheme.accent),
          shape: const CircleBorder(),
          elevation: 0,
          child: const Icon(Icons.add_a_photo_outlined, size: 20),
        ),
      ),
      body: _items.isEmpty
          ? _buildLoading()
          : PageView.builder(
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
    );
  }

  Widget _buildLoading() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              color: Color(AppTheme.accent),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            _loading ? '加载短视频…' : '暂时没有短视频',
            style: const TextStyle(color: Color(AppTheme.textSecondary), fontSize: 13),
          ),
        ],
      ),
    );
  }
}
