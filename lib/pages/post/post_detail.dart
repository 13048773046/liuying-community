/// 帖子详情页（P0）：图文/视频帖详情 + 评论区
/// 评论区支持：文字评论、图片评论（≤1 图）、表情包（占位，官方素材到达后接入）
library;


import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'package:video_player/video_player.dart';
import 'dart:async';
import '../../widgets/video_controls_bar.dart';

import '../../api/client.dart';
import '../../config.dart';
import '../../models/feed_item.dart';
import '../../utils/music_bgm.dart';
import '../../widgets/image_box.dart';
import '../../widgets/poll_card.dart';
import '../../widgets/comment_sheet.dart';
import '../mine/login_page.dart';
import '../user/user_profile.dart';
import '../discover/topic_detail_page.dart';

class PostDetailPage extends StatefulWidget {
  final String postId;
  const PostDetailPage({super.key, required this.postId});

  @override
  State<PostDetailPage> createState() => _PostDetailPageState();
}

class _PostDetailPageState extends State<PostDetailPage> {
  FeedItem? _post;
  bool _liked = false;
  bool _faved = false;
  bool _latered = false;
  int _likeCount = 0;
  bool _loading = true;
  bool _loadError = false;
  Map<String, int> _hotTopicCounts = {};
  bool _following = false;
  bool _followBusy = false;
  int _cCount = 0;
  List<Map<String, dynamic>> _comments = [];
  int _cPage = 1;
  bool _cHasMore = false;
  bool _cLoading = false;

  // 多图图集：同一位置 PageView 切换 + 指示点
  final PageController _mediaPageController = PageController();
  int _mediaIndex = 0;

  @override
  void initState() {
    super.initState();
    _load();
    _loadHotTopics();
  }

  Future<void> _loadHotTopics() async {
    try {
      final list = await ApiClient.topicsHot();
      if (!mounted) return;
      setState(() {
        _hotTopicCounts = {
          for (final t in list) (t['name'] ?? '') as String: ((t['count'] ?? 0) as num).toInt()
        };
      });
    } catch (_) {}
  }

  Future<void> _load() async {
    try {
      final j = await ApiClient.postDetail(widget.postId);
      if (!mounted) return;
      final pj = Map<String, dynamic>.from(j['post'] as Map);
      setState(() {
        _post = FeedItem.fromJson(pj);
        _liked = pj['liked'] ?? false;
        _faved = pj['faved'] ?? false;
        _latered = pj['later'] ?? false;
        _likeCount = ((pj['likeCount'] ?? 0) as num).toInt();
        _loading = false;
      });
      _cCount = _post!.commentCount;
      // 配乐：打开图文/视频详情自动播放所选 BGM
      final m = _post!.music;
      if (m != null && m['url'] is String && (m['url'] as String).isNotEmpty) {
        MusicBgm.I.play(m['url'] as String);
      }
      await _loadComments(refresh: true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = true;
      });
    }
  }

  @override
  void dispose() {
    _mediaPageController.dispose();
    MusicBgm.I.stop();
    super.dispose();
  }

  Future<void> _toggleLike() async {
    if (_post == null) return;
    setState(() {
      _liked = !_liked;
      _likeCount += _liked ? 1 : -1;
    });
    try {
      await ApiClient.toggleLike(_post!.id);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _liked = !_liked;
        _likeCount += _liked ? 1 : -1;
      });
    }
  }

  Future<void> _toggleFav() async {
    if (_post == null) return;
    setState(() => _faved = !_faved);
    try {
      await ApiClient.toggleFav(_post!.id, faved: _faved);
    } catch (_) {
      if (!mounted) return;
      setState(() => _faved = !_faved);
    }
  }

  Future<void> _toggleLater() async {
    if (_post == null) return;
    setState(() => _latered = !_latered);
    try {
      await ApiClient.toggleFav(_post!.id, kind: 'later', faved: _latered);
    } catch (_) {
      if (!mounted) return;
      setState(() => _latered = !_latered);
    }
  }

  /// 举报弹窗（帖子/评论通用）
  Future<void> _report(String targetType, String targetId) async {
    if (ApiClient.token == null) {
      if (!mounted) return;
      Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const LoginPage()));
      return;
    }
    const reasons = ['垃圾广告', '色情低俗', '不实信息', '人身攻击', '违法违规', '其他'];
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(AppTheme.card),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 14),
            const Text('举报',
                style: TextStyle(
                    color: Color(AppTheme.textPrimary),
                    fontSize: 16,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            const Text('请选择举报原因，我们会尽快核实处理',
                style: TextStyle(
                    color: Color(AppTheme.textTertiary), fontSize: 12)),
            const SizedBox(height: 8),
            for (final r in reasons)
              ListTile(
                dense: true,
                title: Text(r,
                    style: const TextStyle(
                        color: Color(AppTheme.textPrimary),
                        fontSize: 13.5)),
                trailing: const Icon(Icons.chevron_right_rounded,
                    size: 18, color: Color(AppTheme.textTertiary)),
                onTap: () => Navigator.pop(ctx, r),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    try {
      await ApiClient.report(targetType, targetId, picked);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('已收到举报，我们会尽快处理'),
        backgroundColor: Color(AppTheme.card),
        behavior: SnackBarBehavior.floating,
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(e is ApiException ? e.message : '举报失败，请稍后再试'),
        backgroundColor: const Color(AppTheme.card),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  void _reportPost() {
    if (_post == null) return;
    _report('post', _post!.id);
  }

  /// 收藏按钮弹层：收藏 / 稍后看 二选一（概念稿：稍后看独立入口）
  Future<void> _showFavSheet() async {
    if (_post == null) return;
    await showModalBottomSheet(
      context: context,
      backgroundColor: const Color(AppTheme.card),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 14),
            const Text('收藏内容',
                style: TextStyle(
                    color: Color(AppTheme.textPrimary),
                    fontSize: 16,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            const Text('选择收藏方式',
                style: TextStyle(
                    color: Color(AppTheme.textTertiary), fontSize: 12)),
            const SizedBox(height: 12),
            _favOption(
              icon: _faved ? Icons.star_rounded : Icons.star_border_rounded,
              label: '收藏',
              sub: '在我的页「收藏」中查看',
              active: _faved,
              color: const Color(AppTheme.peach),
              onTap: () {
                Navigator.pop(ctx);
                _toggleFav();
              },
            ),
            _favOption(
              icon: _latered ? Icons.schedule_rounded : Icons.schedule_outlined,
              label: '稍后看',
              sub: '在我的页「稍后看」中查看',
              active: _latered,
              color: const Color(AppTheme.sky),
              onTap: () {
                Navigator.pop(ctx);
                _toggleLater();
              },
            ),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );
  }

  Widget _favOption(
      {required IconData icon,
      required String label,
      required String sub,
      required bool active,
      required Color color,
      required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        decoration: BoxDecoration(
          color: const Color(AppTheme.bg),
          borderRadius: BorderRadius.circular(AppTheme.radiusCard),
        ),
        child: Row(
          children: [
            Icon(icon, color: active ? color : const Color(AppTheme.textSecondary), size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: const TextStyle(
                          color: Color(AppTheme.textPrimary),
                          fontSize: 14,
                          fontWeight: FontWeight.w500)),
                  const SizedBox(height: 2),
                  Text(sub,
                      style: const TextStyle(
                          color: Color(AppTheme.textTertiary), fontSize: 11)),
                ],
              ),
            ),
            if (active)
              Icon(Icons.check_circle, color: color, size: 18),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final safeTop = MediaQuery.of(context).padding.top;
    // 顶部固定栏高度（状态栏 + 44），列表内容从下方开始滚动
    const topBarH = 44.0;
    return Scaffold(
      backgroundColor: const Color(AppTheme.bg),
      // 键盘弹出只顶弹窗输入框，页面媒体/评论不被顶起
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          // 整个页面整体滚动：视频/首图 → 描述 → 话题 → 时间 → 评论区
          ListView(
            padding: EdgeInsets.only(top: safeTop + topBarH + 4),
            children: [
              _mediaBlock(),
              _topicBar(),
              _contentBlock(),
              _relatedSearch(),
              if (_post!.topic.isNotEmpty) ...[
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  children: _post!.topic
                      .map((t) => Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: const Color(AppTheme.accentSoft),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text('#$t',
                                style: const TextStyle(
                                    color: Color(AppTheme.accent),
                                    fontSize: 12)),
                          ))
                      .toList(),
                ),
              ],
              if (_hasMusic) ...[
                const SizedBox(height: 10),
                _musicStrip(),
              ],
              const SizedBox(height: 8),
              Text(dateText(_post!.created),
                  style: const TextStyle(
                      color: Color(AppTheme.textTertiary), fontSize: 11.5)),
              if (_post!.poll != null) ...[
                const SizedBox(height: 10),
                PollCard(
                  postId: _post!.id,
                  poll: _post!.poll!,
                  onChanged: () {
                    if (!mounted) return;
                    setState(() {});
                  },
                ),
              ],
              const SizedBox(height: 14),
              const Divider(color: Color(AppTheme.border), height: 28),
              Row(
                children: [
                  Text('共$_cCount条评论',
                      style: const TextStyle(
                          color: Color(AppTheme.textPrimary),
                          fontSize: 15,
                          fontWeight: FontWeight.w600)),
                  const Spacer(),
                  if (_cHasMore)
                    GestureDetector(
                      onTap: () => _loadComments(),
                      child: const Text('加载更多',
                          style: TextStyle(
                              color: Color(AppTheme.textSecondary),
                              fontSize: 12)),
                    ),
                ],
              ),
              // 有爱评论引导条（对齐抖音）
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: const Text('有爱评论，说点儿好听的',
                    style: TextStyle(
                        color: Color(AppTheme.textTertiary), fontSize: 12)),
              ),
              const SizedBox(height: 6),
              _replyRow(),
              if (_comments.isEmpty && !_cLoading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(
                    child: Text('还没有评论，来抢沙发',
                        style: TextStyle(
                            color: Color(AppTheme.textTertiary),
                            fontSize: 13)),
                  ),
                )
              else if (_comments.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(
                    child: CircularProgressIndicator(
                        color: Color(AppTheme.accent), strokeWidth: 2),
                  ),
                )
              else
                ..._comments.map((c) => _commentTile(c)),
              const SizedBox(height: 90), // 底部输入栏+数据栏避让
            ],
          ),
          // 顶部固定栏（不随页面滚动）：× 返回 + 用户名 + 关注
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              padding: EdgeInsets.only(top: safeTop, bottom: 6),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.45),
                    Colors.transparent,
                  ],
                ),
              ),
              child: Row(
                children: [
                  const SizedBox(width: 6),
                  _roundIconBtn(Icons.close_rounded,
                      onTap: () => Navigator.of(context).maybePop()),
                  const SizedBox(width: 12),
                  // 用户名（点击进主页）
                  if (_post != null)
                    GestureDetector(
                      onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) =>
                                  UserProfilePage(uid: _post!.author.id))),
                      child: Row(
                        children: [
                          // 作者头像（用户名左侧，26px，无头像首字兜底）
                          CircleAvatar(
                            radius: 13,
                            backgroundColor:
                                const Color(AppTheme.elevated),
                            backgroundImage: NetworkImage(
                                avatarUrlOf(_post!.author.id)),
                            onBackgroundImageError: (_, __) {},
                            child: Text(
                              _post!.author.name.isNotEmpty
                                  ? _post!.author.name.characters.first
                                  : '?',
                              style: const TextStyle(
                                  color: Color(AppTheme.textSecondary),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600),
                            ),
                          ),
                          const SizedBox(width: 7),
                          Text(_post!.author.name,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 14.5,
                                  fontWeight: FontWeight.w600)),
                          if (_post!.author.isAdmin) ...[
                            const SizedBox(width: 4),
                            Text(
                                _post!.author.adminName.isEmpty
                                    ? '认证'
                                    : _post!.author.adminName,
                                style: const TextStyle(
                                    color: Color(AppTheme.accent),
                                    fontSize: 10)),
                          ],
                        ],
                      ),
                    ),
                  const Spacer(),
                  if (_post != null && _post!.author.id != ApiClient.userId)
                    _followPill(),
                  const SizedBox(width: 12),
                ],
              ),
            ),
          ),
          // 底部固定：说点什么… + 互动数据栏
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _commentInput(),
                _actionBar(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 话题聚合条（抖音式：#话题 + N条内容，点击进话题页）
  Widget _topicBar() {
    final topics = _post!.topic;
    if (topics.isEmpty) return const SizedBox.shrink();
    final t = topics.first;
    final count = _hotTopicCounts[t];
    return GestureDetector(
      onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => TopicDetailPage(topic: t, count: count ?? 0))),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
        decoration: BoxDecoration(
          color: const Color(AppTheme.accentSoft),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            const Icon(Icons.local_fire_department_rounded,
                color: Color(AppTheme.accent), size: 17),
            const SizedBox(width: 8),
            Text('#$t',
                style: const TextStyle(
                    color: Color(AppTheme.textPrimary),
                    fontSize: 14,
                    fontWeight: FontWeight.w600)),
            const SizedBox(width: 8),
            Text(count != null ? '$count条内容' : '参与话题',
                style: const TextStyle(
                    color: Color(AppTheme.textSecondary), fontSize: 12)),
            const Spacer(),
            const Icon(Icons.chevron_right_rounded,
                color: Color(AppTheme.textTertiary), size: 18),
          ],
        ),
      ),
    );
  }

  /// 相关搜索（抖音"看后搜"点位，用热门话题替代，点击进话题页）
  Widget _relatedSearch() {
    final hot = _hotTopicCounts.keys.take(3).toList();
    if (hot.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('相关搜索',
              style: TextStyle(
                  color: Color(AppTheme.textTertiary), fontSize: 12)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final t in hot)
                GestureDetector(
                  onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => TopicDetailPage(
                              topic: t, count: _hotTopicCounts[t] ?? 0))),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(AppTheme.card),
                      borderRadius: BorderRadius.circular(16),
                      border:
                          Border.all(color: const Color(AppTheme.border)),
                    ),
                    child: Text('#$t',
                        style: const TextStyle(
                            color: Color(AppTheme.textPrimary),
                            fontSize: 12.5)),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// 媒体块（列表第一项）：视频帖=全宽视频；文图帖=首图大图
  Widget _mediaBlock() {
    final p = _post!;
    if (p.isVideo) {
      return Container(
        color: Colors.black,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: _InlineVideo(
            url: mediaUrl(p.video),
            coverUrl: mediaUrl(
                p.cover == 'auto' ? '${p.video}.jpg' : p.cover),
            borderRadius: 0,
          ),
        ),
      );
    }
    if (p.images.isNotEmpty) {
      if (p.images.length == 1) {
        // 单图：自适应比例，点击进全屏查看
        return GestureDetector(
          onTap: () => _openGallery(0),
          child: AspectRatio(
            aspectRatio: 4 / 3,
            child: CachedNetworkImageCompat(
              url: mediaUrl(p.images[0]),
              fit: BoxFit.cover,
            ),
          ),
        );
      }
      // 多图：同一位置图集式（PageView 左右滑动切换）+ 指示点，不堆叠
      return AspectRatio(
        aspectRatio: 1,
        child: Stack(
          fit: StackFit.expand,
          children: [
            PageView.builder(
              controller: _mediaPageController,
              itemCount: p.images.length,
              onPageChanged: (i) => setState(() => _mediaIndex = i),
              itemBuilder: (_, i) => GestureDetector(
                onTap: () => _openGallery(i),
                child: CachedNetworkImageCompat(
                  url: mediaUrl(p.images[i]),
                  fit: BoxFit.cover,
                ),
              ),
            ),
            // 指示点（当前页品牌绿，其余半透明白）
            Positioned(
              left: 0,
              right: 0,
              bottom: 10,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var i = 0; i < p.images.length; i++)
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 220),
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      width: i == _mediaIndex ? 6 : 5,
                      height: 5,
                      decoration: BoxDecoration(
                        color: i == _mediaIndex
                            ? const Color(AppTheme.accent)
                            : Colors.white.withValues(alpha: 0.45),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      );
    }
    return const SizedBox.shrink();
  }

  /// 圆形浮层按钮（半透明黑底）
  Widget _roundIconBtn(IconData icon, {required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.45),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: Colors.white, size: 18),
      ),
    );
  }

  /// 关注胶囊（顶部栏右侧，抖音式）
  Widget _followPill() {
    final a = _post!.author;
    return GestureDetector(
      onTap: _followBusy
          ? null
          : () async {
              setState(() => _followBusy = true);
              try {
                await ApiClient.toggleFollow(a.id);
                if (!mounted) return;
                setState(() {
                  _following = !_following;
                  _followBusy = false;
                });
              } catch (_) {
                if (!mounted) return;
                setState(() => _followBusy = false);
              }
            },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: _following
              ? const Color(AppTheme.elevated).withValues(alpha: 0.8)
              : const Color(AppTheme.accent),
          borderRadius: BorderRadius.circular(18),
          border: _following
              ? Border.all(color: const Color(AppTheme.border))
              : null,
        ),
        child: _followBusy
            ? const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Color(AppTheme.accent)))
            : Text(_following ? '已关注' : '关注',
                style: TextStyle(
                    color: _following
                        ? const Color(AppTheme.textTertiary)
                        : Colors.black,
                    fontSize: 13,
                    fontWeight: FontWeight.w600)),
      ),
    );
  }




  /// 分享帖子：底部面板（复制链接等）
  void _sharePost() {
    final p = _post;
    if (p == null) return;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(AppTheme.card),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 14, 16, 4),
              child: Text('分享帖子',
                  style: TextStyle(
                      color: Color(AppTheme.textPrimary),
                      fontSize: 15,
                      fontWeight: FontWeight.w600)),
            ),
            const Divider(color: Color(AppTheme.border), height: 18),
            ListTile(
              leading: const Icon(Icons.link,
                  color: Color(AppTheme.accent)),
              title: const Text('复制链接',
                  style: TextStyle(
                      color: Color(AppTheme.textPrimary), fontSize: 14)),
              onTap: () {
                Navigator.pop(ctx);
                Clipboard.setData(ClipboardData(text: 'https://www.dbmt999.asia/post/${p.id}'));
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text('链接已复制'), duration: Duration(seconds: 1)));
              },
            ),
            ListTile(
              leading: const Icon(Icons.ios_share,
                  color: Color(AppTheme.sky)),
              title: const Text('分享给好友',
                  style: TextStyle(
                      color: Color(AppTheme.textPrimary), fontSize: 14)),
              onTap: () {
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text('暂未开放，敬请期待'), duration: Duration(seconds: 1)));
              },
            ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }

  /// 全屏图片查看器：多图左右滑 + 双指缩放（开源 photo_view）
  void _openGallery(int index) {
    final imgs = _post?.images ?? const <String>[];
    if (imgs.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          body: PhotoViewGallery.builder(
            itemCount: imgs.length,
            pageController: PageController(initialPage: index),
            onPageChanged: (_) {},
            builder: (_, i) => PhotoViewGalleryPageOptions(
              imageProvider: NetworkImage(mediaUrl(imgs[i])),
              minScale: PhotoViewComputedScale.contained,
              maxScale: PhotoViewComputedScale.covered * 2.5,
              heroAttributes: i == index
                  ? PhotoViewHeroAttributes(tag: 'post-gallery-$i')
                  : null,
            ),
            backgroundDecoration: const BoxDecoration(color: Colors.black),
            scrollDirection: Axis.horizontal,
          ),
        ),
      ),
    );
  }

  Widget _contentBlock() {
    final p = _post!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _HighlightContent(
          text: p.content,
          topics: p.topic,
          mentions: p.mentions,
        ),
        // 文图帖：首图已在顶部媒体区，这里展示其余图片
        if (p.images.length > 1) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var i = 1; i < p.images.length; i++)
                GestureDetector(
                  onTap: () => _openGallery(i),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: AspectRatio(
                      aspectRatio: 1,
                      child: CachedNetworkImageCompat(
                        url: mediaUrl(p.images[i]),
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }

  bool get _hasMusic {
    final m = _post?.music;
    if (m == null) return false;
    final n = m['name'];
    return n is String && n.isNotEmpty;
  }

  /// 配乐条：封面音符 + 歌名 + 播放/暂停（StreamBuilder 跟随播放状态）
  Widget _musicStrip() {
    final name = (_post!.music!['name'] ?? '') as String;
    return StreamBuilder<bool>(
      stream: MusicBgm.I.playingStream,
      builder: (_, snap) {
        final playing = snap.data ?? false;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: const Color(AppTheme.accentSoft),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: const Color(AppTheme.accent).withValues(alpha: 0.35)),
          ),
          child: Row(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: const BoxDecoration(
                    color: Color(AppTheme.accent), shape: BoxShape.circle),
                child: const Icon(Icons.music_note_rounded,
                    size: 15, color: Colors.black),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Color(AppTheme.textPrimary),
                        fontSize: 13,
                        fontWeight: FontWeight.w600)),
              ),
              GestureDetector(
                onTap: () => MusicBgm.I.toggle(),
                child: Container(
                  width: 30,
                  height: 30,
                  decoration: const BoxDecoration(
                      color: Color(AppTheme.card), shape: BoxShape.circle),
                  child: Icon(
                    playing
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    size: 18,
                    color: const Color(AppTheme.accent),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 底部互动数据栏（抖音式：点赞/评论/收藏/分享 图标+数字）
  Widget _actionBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      decoration: const BoxDecoration(
        color: Color(AppTheme.card),
        border: Border(top: BorderSide(color: Color(AppTheme.border), width: 0.5)),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            _actionItem(Icons.thumb_up_alt_rounded, countText(_likeCount),
                _liked ? const Color(AppTheme.accent) : const Color(AppTheme.textSecondary),
                _toggleLike),
            const SizedBox(width: 18),
            _actionItem(Icons.comment_rounded, countText(_cCount),
                const Color(AppTheme.textSecondary), _openComments),
            const SizedBox(width: 18),
            _actionItem(
                _faved || _latered ? Icons.star_rounded : Icons.star_border_rounded,
                _faved || _latered ? '已收藏' : '收藏',
                (_faved || _latered)
                    ? const Color(AppTheme.peach)
                    : const Color(AppTheme.textSecondary),
                _showFavSheet),
            const SizedBox(width: 18),
            _actionItem(Icons.share_outlined, '分享',
                const Color(AppTheme.textSecondary), () {}),
          ],
        ),
      ),
    );
  }

  Widget _actionItem(IconData icon, String label, Color color, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Row(
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 4),
          Text(label,
              style: TextStyle(color: color, fontSize: 11.5)),
        ],
      ),
    );
  }

  /// 评论列表上方：当前用户头像 + 圆角输入卡 + 发布图标（点击弹评论输入弹窗）
  Widget _replyRow() {
    final uid = ApiClient.userId ?? '';
    return GestureDetector(
      onTap: _openComments,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            CircleAvatar(
              radius: 15,
              backgroundColor: const Color(AppTheme.elevated),
              backgroundImage:
                  uid.isNotEmpty ? NetworkImage(avatarUrlOf(uid)) : null,
              onBackgroundImageError: uid.isNotEmpty ? (_, __) {} : null,
              child: const Icon(Icons.person,
                  size: 16, color: Color(AppTheme.textSecondary)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Container(
                height: 38,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                alignment: Alignment.centerLeft,
                decoration: BoxDecoration(
                  color: const Color(AppTheme.card),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: const Color(AppTheme.border)),
                ),
                child: const Text('说点什么...',
                    style: TextStyle(
                        color: Color(AppTheme.textTertiary), fontSize: 13.5)),
              ),
            ),
            const SizedBox(width: 10),
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: const Color(AppTheme.accent),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.send_rounded,
                  size: 17, color: Color(0xFF06221A)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _commentInput() {
    return GestureDetector(
      onTap: _openComments,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        decoration: const BoxDecoration(
          color: Color(AppTheme.card),
          border: Border(top: BorderSide(color: Color(AppTheme.border), width: 0.5)),
        ),
        child: SafeArea(
          top: false,
          child: Row(
            children: [
              const CircleAvatar(
                radius: 14,
                backgroundColor: Color(AppTheme.elevated),
                child: Icon(Icons.person,
                    size: 15, color: Color(AppTheme.textSecondary)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: const Text('说点什么...',
                      style: TextStyle(
                          color: Color(AppTheme.textTertiary),
                          fontSize: 14)),
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.emoji_emotions_outlined,
                  color: Color(AppTheme.textTertiary), size: 20),
              const SizedBox(width: 14),
              const Icon(Icons.image_outlined,
                  color: Color(AppTheme.textTertiary), size: 20),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _loadComments({bool refresh = false}) async {
    if (_cLoading || (!_cHasMore && !refresh)) return;
    setState(() => _cLoading = true);
    try {
      final j = await ApiClient.comments(widget.postId,
          page: refresh ? 1 : _cPage + 1, size: 20);
      if (!mounted) return;
      setState(() {
        final list = ((j['list'] ?? []) as List)
            .whereType<Map<String, dynamic>>()
            .toList();
        if (refresh) {
          _comments = list;
          _cPage = 1;
        } else {
          _comments.addAll(list);
          _cPage++;
        }
        _cHasMore = boolOf(j['hasMore']);
        _cLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _cLoading = false);
    }
  }

  /// 评论点赞（本地翻转）
  Future<void> _toggleCommentLike(Map<String, dynamic> c) async {
    final cid = (c['id'] ?? '') as String;
    if (cid.isEmpty) return;
    final wasLiked = (c['liked'] ?? false) == true;
    setState(() {
      c['liked'] = !wasLiked;
      c['likeCount'] = ((c['likeCount'] ?? 0) as num).toInt() + (wasLiked ? -1 : 1);
    });
    try {
      await ApiClient.commentLike(cid);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        c['liked'] = wasLiked;
        c['likeCount'] = ((c['likeCount'] ?? 0) as num).toInt() + (wasLiked ? 1 : -1);
      });
    }
  }

  Widget _commentTile(Map<String, dynamic> c) {
    final author = (c['author'] ?? const {}) as Map;
    final name = (author['name'] ?? '用户') as String;
    final avatar = (author['avatar'] ?? '') as String;
    final adminLevel = ((author['adminLevel'] ?? 0) as num).toInt();
    final adminName = (author['adminName'] ?? '') as String;
    final content = (c['content'] ?? '') as String;
    final images = (c['images'] ?? const []) as List;
    final sticker = (c['sticker'] ?? '') as String;
    final created = ((c['created'] ?? 0) as num).toInt();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 14,
            backgroundColor: const Color(AppTheme.card),
            backgroundImage:
                avatar.isNotEmpty ? NetworkImage(avatarUrl(avatar)) : null,
            child: avatar.isEmpty
                ? const Icon(Icons.person,
                    size: 15, color: Color(AppTheme.textSecondary))
                : null,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(name,
                        style: const TextStyle(
                            color: Color(AppTheme.textSecondary),
                            fontSize: 12)),
                    if (adminLevel > 0) ...[
                      const SizedBox(width: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 1),
                        decoration: BoxDecoration(
                          color: const Color(AppTheme.accentSoft),
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: Text(adminName.isEmpty ? '认证' : adminName,
                            style: const TextStyle(
                                color: Color(AppTheme.accent), fontSize: 9)),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                if (sticker.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: CachedNetworkImageCompat(
                        url: mediaUrl(sticker),
                        width: 64,
                        height: 64,
                        fit: BoxFit.contain),
                  )
                else if (content.isNotEmpty)
                  Text(content,
                      style: const TextStyle(
                          color: Color(AppTheme.textPrimary),
                          fontSize: 14,
                          height: 1.4)),
                if (images.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: CachedNetworkImageCompat(
                      url: mediaUrl(images.first.toString()),
                      width: 140,
                      height: 140,
                      fit: BoxFit.cover,
                    ),
                  ),
                ],
                const SizedBox(height: 4),
                Row(
                  children: [
                    Text(timeAgo(created),
                        style: const TextStyle(
                            color: Color(AppTheme.textTertiary),
                            fontSize: 11)),
                    const SizedBox(width: 10),
                    GestureDetector(
                      onTap: _openComments,
                      child: const Text('回复',
                          style: TextStyle(
                              color: Color(AppTheme.accent),
                              fontSize: 11)),
                    ),
                    const Spacer(),
                    GestureDetector(
                      onTap: () => _toggleCommentLike(c),
                      child: Row(
                        children: [
                          Icon(
                            (c['liked'] ?? false) == true
                                ? Icons.thumb_up_rounded
                                : Icons.thumb_up_alt_outlined,
                            size: 12,
                            color: (c['liked'] ?? false) == true
                                ? const Color(AppTheme.accent)
                                : const Color(AppTheme.textTertiary),
                          ),
                          const SizedBox(width: 3),
                          Text(
                            '${((c['likeCount'] ?? 0) as num).toInt()}',
                            style: TextStyle(
                                color: (c['liked'] ?? false) == true
                                    ? const Color(AppTheme.accent)
                                    : const Color(AppTheme.textTertiary),
                                fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 打开评论弹窗：图文/视频详情页统一直接弹完整抖音式评论弹窗
  /// （详情页内嵌评论列表展示，页面底部「说点什么…」直接打开弹窗）
  Future<void> _openComments() async {
    if (_post == null) return;
    await showCommentSheet(context,
        postId: _post!.id,
        pureInput: true,
        onChanged: (n) {
          if (!mounted) return;
          setState(() => _cCount = n);
        });
  }

}

// ---------- 详情页辅助组件 ----------

/// 正文高亮：话题 #xxx（主题色）+ @提及（天蓝），与短视频卡一致
class _HighlightContent extends StatelessWidget {
  final String text;
  final List<String> topics;
  final List<String> mentions;
  const _HighlightContent(
      {required this.text, required this.topics, required this.mentions});

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox.shrink();
    final RegExp kw = RegExp(
        '(#(?:${topics.map(RegExp.escape).join('|')}))|(@(?:${mentions.map(RegExp.escape).join('|')}))');
    final spans = <TextSpan>[];
    if (topics.isEmpty && mentions.isEmpty) {
      spans.add(TextSpan(text: text));
    } else {
      var last = 0;
      for (final m in kw.allMatches(text)) {
        if (m.start > last) {
          spans.add(TextSpan(text: text.substring(last, m.start)));
        }
        final isTopic = m.group(1) != null;
        spans.add(TextSpan(
          text: m.group(0),
          style: TextStyle(
            color: isTopic
                ? const Color(AppTheme.lilac)
                : const Color(AppTheme.sky),
            fontWeight: FontWeight.w600,
          ),
        ));
        last = m.end;
      }
      if (last < text.length) {
        spans.add(TextSpan(text: text.substring(last)));
      }
    }
    return Text.rich(
      TextSpan(
        style: const TextStyle(
            color: Color(AppTheme.textPrimary), fontSize: 16, height: 1.55),
        children: spans,
      ),
    );
  }
}

/// 视频帖详情内嵌播放器：点击播放/暂停，加载失败回退封面
class _InlineVideo extends StatefulWidget {
  final String url;
  final String coverUrl;
  final double borderRadius;
  const _InlineVideo(
      {required this.url, required this.coverUrl, this.borderRadius = 12});

  @override
  State<_InlineVideo> createState() => _InlineVideoState();
}

class _InlineVideoState extends State<_InlineVideo> {
  VideoPlayerController? _vc;
  bool _failed = false;
  bool _controls = false;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final c = VideoPlayerController.networkUrl(
        Uri.parse(widget.url),
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
      );
      await c.initialize();
      if (!mounted) {
        c.dispose();
        return;
      }
      setState(() => _vc = c);
    } catch (_) {
      if (!mounted) return;
      setState(() => _failed = true);
    }
  }

  void _restartHideTimer() {
    _hideTimer?.cancel();
    if (!_controls) return;
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _controls = false);
    });
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _vc?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final v = _vc;
    if (v != null && v.value.isInitialized && !_failed) {
      return GestureDetector(
        // 点画面：调出/隐藏底部控制条（3 秒无操作自动隐藏）
        onTap: () {
          setState(() => _controls = !_controls);
          _restartHideTimer();
        },
        child: ClipRRect(
          borderRadius: BorderRadius.circular(widget.borderRadius),
          child: Container(
            color: Colors.black,
            child: AspectRatio(
              // 按视频真实宽高比显示（16:9 显示 16:9 空间，9:16 显示 9:16 空间，不裁不拉伸）
              aspectRatio: v.value.aspectRatio,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Center(child: VideoPlayer(v)),
                  if (_controls)
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: VideoControlsBar(
                        controller: v,
                        onAutoHide: () {
                          if (mounted) setState(() => _controls = false);
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return GestureDetector(
      onTap: _init,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(widget.borderRadius),
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: CachedNetworkImageCompat(
            url: widget.coverUrl,
            fit: BoxFit.cover,
          ),
        ),
      ),
    );
  }
}

/// 发布时间：当年显示 M-d（9-20），跨年显示 yyyy-M-d
String dateText(int ts) {
  final t = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
  final now = DateTime.now();
  final m = t.month.toString();
  final d = t.day.toString();
  return (t.year == now.year) ? '$m-$d' : '${t.year}-$m-$d';
}

