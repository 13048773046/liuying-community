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
import '../../utils/playback_prefs.dart';
import 'video_card.dart';
import '../search/search_page.dart';

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
  bool _fresh = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadMore();
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasMore) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // 同源混合：与首页同一内容池（视频+图片/图文帖全类型混排）
      final recommend = _tab == 1;
      final p = await ApiClient.feed(
        tab: recommend ? 'recommend' : 'follow',
        page: recommend ? 1 : _page + 1,
        size: 6,
        exclude: recommend ? _items.take(100).map((e) => e.id).join(',') : '',
        fresh: recommend && _fresh,
      );
      if (!mounted) return;
      setState(() {
        _page = p.page;
        _hasMore = p.hasMore;
        _items.addAll(p.list);
        _loading = false;
        if (recommend && _fresh) _fresh = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 长按「不感兴趣」：本地立即移出当前流，不让用户继续看到同一条。
  void _hideAt(int i) {
    if (i < 0 || i >= _items.length) return;
    setState(() {
      _items.removeAt(i);
      if (_current >= _items.length) {
        _current = _items.isEmpty ? 0 : _items.length - 1;
      }
    });
    if (_items.isEmpty || !_controller.hasClients) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_controller.hasClients) return;
      _controller.jumpToPage(_current.clamp(0, _items.length - 1));
    });
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
      _error = null;
      _current = 0;
      _fresh = i == 1;
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
                index: i,
                total: _items.length,
                onNotInterested: () => _hideAt(i),
              ),
            ),
          _buildTopChrome(context),
        ],
      ),
    );
  }

  /// 抖音式顶部：左侧搜索，中间「关注 / 推荐」，短下划线指示当前流。
  /// 不再放品牌签名和左侧页码尺，让画面成为唯一视觉重心。
  Widget _buildTopChrome(BuildContext context) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: EdgeInsets.fromLTRB(
          14,
          MediaQuery.paddingOf(context).top + 6,
          14,
          12,
        ),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.black.withValues(alpha: 0.58),
              Colors.black.withValues(alpha: 0.14),
              Colors.transparent,
            ],
            stops: const [0.0, 0.62, 1.0],
          ),
        ),
        child: Row(
          children: [
            _ChromeIcon(
              icon: Icons.search_rounded,
              tooltip: '搜索',
              onTap: () => Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => const SearchPage())),
            ),
            Expanded(child: Center(child: _feedTabs())),
            // 全局静音放到右上角；右下角互动列不再挂声音按钮。
            ValueListenableBuilder<bool>(
              valueListenable: PlaybackPrefs.muted,
              builder: (context, muted, _) => _ChromeIcon(
                icon: muted
                    ? Icons.volume_off_rounded
                    : Icons.volume_up_rounded,
                tooltip: muted ? '取消静音' : '静音',
                onTap: () => PlaybackPrefs.muted.value = !muted,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 纯文字 tab，不再用玻璃胶囊：当前项加粗 + 短下划线，未选中降透明度。
  Widget _feedTabs() {
    const labels = ['关注', '推荐'];
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < labels.length; i++) ...[
          if (i > 0) const SizedBox(width: 30),
          Semantics(
            button: true,
            selected: _tab == i,
            label: labels[i],
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _switchTab(i),
              child: SizedBox(
                height: 34,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    AnimatedDefaultTextStyle(
                      duration: AppMotion.fast,
                      curve: AppMotion.emphasized,
                      style: AppType.body.copyWith(
                        fontFamily: Theme.of(context)
                            .textTheme
                            .bodyMedium
                            ?.fontFamily,
                        fontFamilyFallback: Theme.of(context)
                            .textTheme
                            .bodyMedium
                            ?.fontFamilyFallback,
                        fontSize: 16.5,
                        height: 1.1,
                        fontWeight: _tab == i
                            ? FontWeight.w700
                            : FontWeight.w500,
                        color: Colors.white.withValues(
                          alpha: _tab == i ? 0.96 : 0.58,
                        ),
                        shadows: const [
                          Shadow(color: Color(0x99000000), blurRadius: 8),
                        ],
                      ),
                      child: Text(labels[i]),
                    ),
                    const SizedBox(height: 5),
                    AnimatedContainer(
                      key: ValueKey('shorts_tab_underline_$i'),
                      duration: AppMotion.fast,
                      curve: AppMotion.emphasized,
                      width: _tab == i ? 18 : 0,
                      height: 2.5,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(2),
                        boxShadow: const [
                          BoxShadow(color: Color(0x66000000), blurRadius: 4),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildLoading() {
    if (_loading) {
      return Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF101113), Color(0xFF050506)],
          ),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: const [
              SkeletonBox(width: 64, height: 64, radius: 32),
              SizedBox(height: AppSpace.x4),
              SkeletonBox(width: 148, height: 10),
              SizedBox(height: AppSpace.x2),
              SkeletonBox(width: 88, height: 8),
              SizedBox(height: AppSpace.x3),
              Text(
                '正在载入短片…',
                style: TextStyle(
                  color: Color(AppColors.textTertiary),
                  fontSize: 11,
                  letterSpacing: 0.6,
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Container(
      padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF101113), Color(0xFF050506)],
        ),
      ),
      child: Center(
        child: EmptyState(
          icon: _error == null ? Icons.movie_outlined : Icons.cloud_off_rounded,
          title: _error != null
              ? '短片加载失败'
              : (_tab == 0 ? '关注的人还没有作品' : '暂时没有内容'),
          message: _error != null
              ? '网络不太稳定，稍后再试一次'
              : (_tab == 0 ? '去首页发现更多创作者，关注后会出现在这里' : '稍后再来看看，或去发一条短视频'),
          actionLabel: _error != null ? '重新加载' : null,
          onAction: _error != null ? _retry : null,
        ),
      ),
    );
  }

  void _retry() {
    setState(() {
      _error = null;
      _hasMore = true;
      _page = 0;
      _items.clear();
    });
    _loadMore();
  }
}

class _ChromeIcon extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final String tooltip;

  const _ChromeIcon({
    required this.icon,
    required this.onTap,
    required this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: PressableScale(
        onTap: onTap,
        scale: 0.9,
        child: SizedBox(
          width: 40,
          height: 40,
          child: Icon(
            icon,
            size: 25,
            color: Colors.white,
            shadows: const [Shadow(color: Color(0xAA000000), blurRadius: 8)],
          ),
        ),
      ),
    );
  }
}
