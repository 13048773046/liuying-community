/// 搜索页：按抖音搜索页布局 1:1 还原
///
/// 结构：返回箭头 + 胶囊搜索框（相机 / 竖线 / 搜索）→ 搜索历史两列文字 + 「展开更多历史 /
/// 清空」→ 联想词两列（命中片段标红）→ 分类标签（猜你想看 / 热榜 / 同城）
/// → 双列瀑布流卡片（底部渐变 / 标题 / 右下播放钮 / 作者 + 点赞）。
/// 数据走社区接口：猜你想看 = /feed?tab=recommend，热榜 = /rankings?type=post，
/// 搜索仍走 /search（帖子、视频、用户、话题）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../api/client.dart';
import '../../config.dart';
import '../../design/components.dart';
import '../../models/feed_item.dart';
import '../../widgets/image_box.dart';
import '../../widgets/user_avatar.dart';
import '../post/post_detail.dart';
import '../user/user_profile.dart';

/// 命中词高亮色
const _kHitRed = Color(0xFFFE2C55);
/// 搜索框底色
const _kFieldBg = Color(0xFF2A2A2E);

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();
  Timer? _debounce;

  static const _historyKey = 'search_history';

  // 历史 / 联想
  List<String> _history = [];
  bool _historyExpanded = false;
  List<String> _hot = [];
  List<String> _suggestions = [];

  // 结果
  bool _searched = false;
  bool _searching = false;
  List<FeedItem> _postResults = [];
  List<Map<String, dynamic>> _userResults = [];
  List<Map<String, dynamic>> _topicResults = [];

  // 分类标签与瀑布流
  static const _tabs = ['猜你想看', '热榜', '同城'];
  int _tab = 0;
  final Map<int, List<FeedItem>> _tabItems = {};
  int _feedPage = 0;
  bool _feedHasMore = true;
  bool _feedLoading = false;

  @override
  void initState() {
    super.initState();
    _loadHistory();
    _loadHot();
    _loadFeed();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------- 数据

  Future<void> _loadHistory() async {
    final sp = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => _history = sp.getStringList(_historyKey) ?? []);
  }

  Future<void> _loadHot() async {
    try {
      final list = await ApiClient.searchHot();
      if (!mounted) return;
      setState(() => _hot = list
          .map((e) => (e['q'] ?? '') as String)
          .where((s) => s.isNotEmpty)
          .toList());
    } catch (_) {}
  }

  /// 分类标签数据：0=猜你想看（推荐流），1=热榜（点赞榜），2=同城（建设中）
  Future<void> _loadFeed({bool refresh = false}) async {
    if (_feedLoading) return;
    if (!refresh && !_feedHasMore) return;
    final tab = _tab;
    if (tab >= 2) return;
    setState(() => _feedLoading = true);
    try {
      List<FeedItem> list;
      bool hasMore;
      if (tab == 0) {
        final p = await ApiClient.feed(
          tab: 'recommend',
          page: refresh ? 1 : _feedPage + 1,
          size: 12,
        );
        list = p.list;
        hasMore = p.hasMore;
        _feedPage = p.page;
      } else {
        final j = await ApiClient.rankings('post', limit: 20);
        list = ((j['list'] ?? []) as List)
            .whereType<Map<String, dynamic>>()
            .map(FeedItem.fromJson)
            .toList();
        hasMore = false;
      }
      if (!mounted) return;
      setState(() {
        final cur = refresh ? <FeedItem>[] : (_tabItems[tab] ?? <FeedItem>[]);
        final merged = [...cur];
        for (final it in list) {
          if (!merged.any((e) => e.id == it.id)) merged.add(it);
        }
        _tabItems[tab] = merged;
        _feedHasMore = hasMore;
        _feedLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _feedLoading = false);
      if ((_tabItems[_tab] ?? []).isEmpty) showAppToast(context, '加载失败：$e');
    }
  }

  void _onChanged(String q) {
    _debounce?.cancel();
    final kw = q.trim();
    if (kw.isEmpty) {
      if (mounted && _suggestions.isNotEmpty) {
        setState(() => _suggestions = []);
      }
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 260), () async {
      try {
        final j = await ApiClient.searchSuggest(kw);
        if (!mounted || _ctrl.text.trim() != kw) return;
        final topics =
            ((j['topics'] ?? []) as List).whereType<String>().toList();
        final users = ((j['users'] ?? []) as List)
            .whereType<Map<String, dynamic>>()
            .map((e) => (e['name'] ?? '') as String)
            .where((s) => s.isNotEmpty)
            .toList();
        setState(() {
          _suggestions = <String>{
            kw,
            ...topics,
            ...users,
            ..._history.where((h) => h.contains(kw)).take(4),
            ..._hot.where((h) => h.contains(kw)).take(4),
          }.take(12).toList();
        });
      } catch (_) {}
    });
  }

  Future<void> _submit(String raw) async {
    final kw = raw.trim();
    if (kw.isEmpty) return;
    _focus.unfocus();
    setState(() {
      _searched = true;
      _searching = true;
      _postResults = [];
      _userResults = [];
      _topicResults = [];
    });
    final sp = await SharedPreferences.getInstance();
    final hist = [kw, ..._history.where((h) => h != kw)].take(20).toList();
    await sp.setStringList(_historyKey, hist);
    if (mounted) setState(() => _history = hist);
    try {
      final j = await ApiClient.search(kw);
      if (!mounted) return;
      setState(() {
        _postResults = [
          ...(((j['posts'] ?? []) as List)
              .whereType<Map<String, dynamic>>()
              .map(FeedItem.fromJson)),
          ...(((j['videos'] ?? []) as List)
              .whereType<Map<String, dynamic>>()
              .map(FeedItem.fromJson)),
        ];
        _userResults = ((j['users'] ?? []) as List)
            .whereType<Map<String, dynamic>>()
            .toList();
        _topicResults = ((j['topics'] ?? []) as List)
            .whereType<Map<String, dynamic>>()
            .toList();
        _searching = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _searching = false);
      showAppToast(context, '搜索失败：$e');
    }
  }

  void _clearInput() {
    _ctrl.clear();
    _debounce?.cancel();
    setState(() {
      _searched = false;
      _suggestions = [];
    });
    _focus.requestFocus();
  }

  Future<void> _clearHistory() async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_historyKey);
    if (mounted) setState(() => _history = []);
  }

  // -------------------------------------------------------------- 构建

  @override
  Widget build(BuildContext context) {
    return ImmersivePage(
      child: Column(
        children: [
          _topBar(),
          Expanded(child: _searched ? _resultView() : _discoverView()),
        ],
      ),
    );
  }

  /// 顶部：返回箭头 + 胶囊搜索框（相机 / 竖线 / 搜索）
  Widget _topBar() {
    final top = MediaQuery.paddingOf(context).top;
    return Padding(
      padding: EdgeInsets.fromLTRB(4, top + 6, 12, 8),
      child: Row(
        children: [
          InkResponse(
            onTap: () => Navigator.pop(context),
            radius: 22,
            child: const SizedBox(
              width: 40,
              height: 40,
              child: Icon(Icons.arrow_back_ios_new_rounded,
                  size: 19, color: Colors.white),
            ),
          ),
          Expanded(
            child: Container(
              height: 40,
              padding: const EdgeInsets.only(left: 13, right: 5),
              decoration: BoxDecoration(
                color: _kFieldBg,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _ctrl,
                      focusNode: _focus,
                      style: const TextStyle(
                          fontSize: 15, color: Colors.white, height: 1.3),
                      cursorColor: _kHitRed,
                      textInputAction: TextInputAction.search,
                      onChanged: _onChanged,
                      onSubmitted: _submit,
                      decoration: const InputDecoration(
                        isCollapsed: true,
                        filled: false,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        hintText: '搜你想看的',
                        hintStyle: TextStyle(
                            fontSize: 15,
                            color: Color(0xFF8A8A8E),
                            height: 1.3),
                      ),
                    ),
                  ),
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _ctrl,
                    builder: (_, value, _) => value.text.isEmpty
                        ? const SizedBox.shrink()
                        : GestureDetector(
                            onTap: _clearInput,
                            behavior: HitTestBehavior.opaque,
                            child: const Padding(
                              padding: EdgeInsets.symmetric(horizontal: 6),
                              child: Icon(Icons.cancel_rounded,
                                  size: 17, color: Color(0xFF8A8A8E)),
                            ),
                          ),
                  ),
                  const Icon(Icons.photo_camera_outlined,
                      size: 22, color: Colors.white),
                  Container(
                    width: 1,
                    height: 18,
                    margin: const EdgeInsets.symmetric(horizontal: 10),
                    color: Colors.white.withValues(alpha: 0.22),
                  ),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _submit(_ctrl.text),
                    child: const Padding(
                      padding: EdgeInsets.only(right: 8, left: 2),
                      child: Text('搜索',
                          style: TextStyle(
                              fontSize: 15,
                              color: Colors.white,
                              fontWeight: FontWeight.w500)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------- 默认页

  Widget _discoverView() {
    final q = _ctrl.text.trim();
    final items = _tabItems[_tab] ?? <FeedItem>[];
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (_tab <= 1 && n.metrics.extentAfter < 420) _loadFeed();
        return false;
      },
      child: CustomScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics()),
        slivers: [
          if (_history.isNotEmpty) SliverToBoxAdapter(child: _historyBlock()),
          if (q.isNotEmpty && _suggestions.isNotEmpty)
            SliverToBoxAdapter(child: _suggestBlock(q)),
          SliverToBoxAdapter(child: _tabBar()),
          if (_tab >= 2)
            SliverToBoxAdapter(child: _unavailable(_tab))
          else if (items.isEmpty && !_feedLoading)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.only(top: 60),
                child: Center(
                  child: Text('还没有内容，稍后再来',
                      style: TextStyle(color: Color(0xFF8A8A8E), fontSize: 13)),
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              sliver: SliverMasonryGrid.count(
                crossAxisCount: 2,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childCount: items.length,
                itemBuilder: (_, i) => _FeedTile(
                  item: items[i],
                  height: _cardHeight(i),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => PostDetailPage(postId: items[i].id)),
                  ),
                ),
              ),
            ),
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.only(
                  top: 14, bottom: tabBarBottomInset(context) + 26),
              child: Center(
                child: _feedLoading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const SizedBox.shrink(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  double _cardHeight(int i) {
    const hs = [214.0, 286.0, 246.0, 196.0, 268.0, 232.0];
    return hs[i % hs.length];
  }

  /// 搜索历史：两列文字 + 右侧「展开更多历史 ∨ | 清空」
  Widget _historyBlock() {
    final shown = _historyExpanded ? _history : _history.take(6).toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            children: [
              for (final h in shown)
                SizedBox(
                  width: (MediaQuery.sizeOf(context).width - 32) / 2,
                  height: 44,
                  child: InkWell(
                    onTap: () {
                      _ctrl.text = h;
                      _submit(h);
                    },
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        h,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 16, color: Colors.white, height: 1.2),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () =>
                    setState(() => _historyExpanded = !_historyExpanded),
                child: Row(
                  children: [
                    Text(_historyExpanded ? '收起历史' : '展开更多历史',
                        style: const TextStyle(
                            fontSize: 13.5, color: Color(0xFF9A9AA0))),
                    const SizedBox(width: 2),
                    Icon(
                        _historyExpanded
                            ? Icons.keyboard_arrow_up_rounded
                            : Icons.keyboard_arrow_down_rounded,
                        size: 18,
                        color: const Color(0xFF9A9AA0)),
                  ],
                ),
              ),
              if (_history.isNotEmpty) ...[
                Container(
                  width: 1,
                  height: 14,
                  margin: const EdgeInsets.symmetric(horizontal: 10),
                  color: Colors.white.withValues(alpha: 0.16),
                ),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () async {
                    final ok = await _confirmClear();
                    if (ok == true) await _clearHistory();
                  },
                  child: const Icon(Icons.delete_outline_rounded,
                      size: 19, color: Color(0xFF9A9AA0)),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Future<bool?> _confirmClear() {
    return showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(AppColors.elevated),
        title: const Text('清空搜索历史？', style: TextStyle(fontSize: 16)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('清空')),
        ],
      ),
    );
  }

  /// 联想词：两列，命中片段标红
  Widget _suggestBlock(String q) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: Colors.white.withValues(alpha: 0.10), width: 1),
        ),
      ),
      child: Column(
        children: [
          for (var i = 0; i < _suggestions.length; i += 2)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: _suggestCell(_suggestions[i], q)),
                Expanded(
                  child: i + 1 < _suggestions.length
                      ? _suggestCell(_suggestions[i + 1], q)
                      : const SizedBox.shrink(),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _suggestCell(String word, String q) {
    return SizedBox(
      height: 34,
      child: InkWell(
        onTap: () {
          _ctrl.text = word;
          _submit(word);
        },
        child: Align(
          alignment: Alignment.centerLeft,
          child: RichText(
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            text: TextSpan(
              style: const TextStyle(fontSize: 15.5, color: Colors.white),
              children: _highlight(word, q),
            ),
          ),
        ),
      ),
    );
  }

  /// 命中片段红色加粗，其余白色
  List<TextSpan> _highlight(String word, String q) {
    if (q.isEmpty) return [TextSpan(text: word)];
    final lower = word.toLowerCase();
    final ql = q.toLowerCase();
    final spans = <TextSpan>[];
    var from = 0;
    while (true) {
      final at = lower.indexOf(ql, from);
      if (at < 0) {
        spans.add(TextSpan(text: word.substring(from)));
        break;
      }
      if (at > from) spans.add(TextSpan(text: word.substring(from, at)));
      spans.add(TextSpan(
        text: word.substring(at, at + q.length),
        style: const TextStyle(color: _kHitRed, fontWeight: FontWeight.w600),
      ));
      from = at + q.length;
    }
    return spans;
  }

  Widget _tabBar() {
    return SizedBox(
      height: 46,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: _tabs.length,
        separatorBuilder: (_, _) => const SizedBox(width: 22),
        itemBuilder: (_, i) {
          final on = i == _tab;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              if (_tab == i) return;
              setState(() => _tab = i);
              if (i <= 1) _loadFeed(refresh: (_tabItems[i] ?? []).isEmpty);
            },
            child: Center(
              child: Text(
                _tabs[i],
                style: TextStyle(
                  fontSize: on ? 17 : 15,
                  fontWeight: on ? FontWeight.w700 : FontWeight.w400,
                  color: on ? Colors.white : const Color(0xFF8A8A8E),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _unavailable(int tab) {
    final label = _tabs[tab];
    return Padding(
      padding: const EdgeInsets.only(top: 90, bottom: 60),
      child: Center(
        child: Text(
          '$label功能建设中',
          style: const TextStyle(fontSize: 13.5, color: Color(0xFF8A8A8E)),
        ),
      ),
    );
  }

  // -------------------------------------------------------------- 结果页

  Widget _resultView() {
    if (_searching) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    final empty =
        _postResults.isEmpty && _userResults.isEmpty && _topicResults.isEmpty;
    if (empty) {
      return const Center(
        child: EmptyState(
          icon: Icons.search_off_rounded,
          title: '没有找到相关内容',
          message: '换个关键词试试吧',
        ),
      );
    }
    return CustomScrollView(
      physics:
          const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
      slivers: [
        if (_userResults.isNotEmpty)
          SliverToBoxAdapter(
            child: SizedBox(
              height: 96,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
                itemCount: _userResults.length,
                separatorBuilder: (_, _) => const SizedBox(width: 18),
                itemBuilder: (_, i) => _userCell(_userResults[i]),
              ),
            ),
          ),
        if (_postResults.isNotEmpty)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            sliver: SliverMasonryGrid.count(
              crossAxisCount: 2,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childCount: _postResults.length,
              itemBuilder: (_, i) => _FeedTile(
                item: _postResults[i],
                height: _cardHeight(i),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) =>
                          PostDetailPage(postId: _postResults[i].id)),
                ),
              ),
            ),
          ),
        SliverToBoxAdapter(
          child: SizedBox(height: tabBarBottomInset(context) + 30),
        ),
      ],
    );
  }

  Widget _userCell(Map<String, dynamic> u) {
    final name = (u['name'] ?? '用户') as String;
    final avatar = (u['avatar'] ?? '') as String;
    final followers = intOf(u['followers']);
    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => UserProfilePage(uid: (u['id'] ?? '') as String)),
      ),
      child: SizedBox(
        width: 76,
        child: Column(
          children: [
            UserAvatar(url: avatar, name: name, size: 52),
            const SizedBox(height: 6),
            Text(name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12.5, color: Colors.white)),
            if (followers > 0)
              Text('${formatCount(followers)}粉丝',
                  maxLines: 1,
                  style: const TextStyle(
                      fontSize: 10.5, color: Color(0xFF8A8A8E))),
          ],
        ),
      ),
    );
  }
}

/// 瀑布流卡片：缩略图 + 底部渐变 + 标题 + 右下播放钮 / 作者 / 点赞
class _FeedTile extends StatelessWidget {
  final FeedItem item;
  final double height;
  final VoidCallback onTap;

  const _FeedTile(
      {required this.item, required this.height, required this.onTap});

  String get _thumb {
    if (item.type == 'video') return item.cover;
    if (item.images.isNotEmpty) return item.images.first;
    return '';
  }

  String get _title {
    final c = item.content.trim();
    if (c.isNotEmpty) return c;
    if (item.topic.isNotEmpty) return '#${item.topic.first}';
    return '';
  }

  /// 底部渐变层（渐变对象独立定义，避免深层嵌套）
  Widget _shade(double h) {
    const g = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [Colors.transparent, Color(0xC7000000)],
    );
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      height: h,
      child: const DecoratedBox(decoration: BoxDecoration(gradient: g)),
    );
  }

  /// 视频播放钮：圆形半透明黑底 + 白色三角
  Widget _playButton() {
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        shape: BoxShape.circle,
      ),
      child: const Icon(Icons.play_arrow_rounded,
          size: 19, color: Colors.white),
    );
  }

  @override
  Widget build(BuildContext context) {
    final thumb = _thumb;
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: SizedBox(
          height: height,
          width: double.infinity,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (thumb.isNotEmpty)
                CachedNetworkImageCompat(
                  url: thumb.startsWith('http') ? thumb : mediaUrl(thumb),
                  fit: BoxFit.cover,
                )
              else
                Container(
                  color: const Color(AppColors.card),
                  padding: const EdgeInsets.fromLTRB(10, 12, 10, 58),
                  child: Text(
                    _title,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 14, height: 1.45, color: Colors.white),
                  ),
                ),
              _shade(thumb.isEmpty ? 54 : height * 0.55),
              Positioned(
                left: 9,
                right: 9,
                bottom: 8,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (thumb.isNotEmpty && _title.isNotEmpty)
                      Text(
                        _title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15,
                          height: 1.34,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                    const SizedBox(height: 6),
                    if (item.type == 'video') ...[
                      Align(
                        alignment: Alignment.centerRight,
                        child: _playButton(),
                      ),
                      const SizedBox(height: 6),
                    ],
                    Row(
                      children: [
                        UserAvatar(
                            url: item.author.avatar,
                            name: item.author.name,
                            size: 18),
                        const SizedBox(width: 5),
                        Expanded(
                          child: Text(
                            item.author.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 11.5, color: Color(0xCCFFFFFF)),
                          ),
                        ),
                        const SizedBox(width: 4),
                        const Icon(Icons.favorite_rounded,
                            size: 12, color: Color(0xCCFFFFFF)),
                        const SizedBox(width: 3),
                        Text(
                          formatCount(item.likeCount),
                          style: const TextStyle(
                              fontSize: 11.5, color: Color(0xCCFFFFFF)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
