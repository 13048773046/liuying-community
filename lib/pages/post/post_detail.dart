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
import '../../design/components.dart';
import '../../models/feed_item.dart';
import '../../services/app_route_observer.dart';
import '../../utils/music_bgm.dart';
import '../../utils/share_util.dart';
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
  Map<String, int> _hotTopicCounts = {};

  /// 详情加载失败（用于空态重试，避免 _post 为 null 时 build 崩溃）
  bool _loadFailed = false;
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
    if (mounted) setState(() => _loadFailed = false);
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
      setState(() => _loadFailed = true);
      showAppToast(context, '加载失败，请重试');
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
      await ApiClient.setPostLike(_post!.id, liked: _liked);
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
    // 接口语义：faved=true 表示「当前已收藏」→ 走 DELETE；所以传切换前的状态
    final wasFaved = _faved;
    setState(() => _faved = !wasFaved);
    try {
      await ApiClient.toggleFav(_post!.id, faved: wasFaved);
    } catch (_) {
      if (!mounted) return;
      setState(() => _faved = wasFaved);
    }
  }

  Future<void> _toggleLater() async {
    if (_post == null) return;
    final wasLater = _latered;
    setState(() => _latered = !wasLater);
    try {
      await ApiClient.toggleFav(_post!.id, kind: 'later', faved: wasLater);
    } catch (_) {
      if (!mounted) return;
      setState(() => _latered = wasLater);
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
      sheetAnimationStyle: const AnimationStyle(
        duration: AppMotion.page,
        curve: AppMotion.standard,
        reverseCurve: AppMotion.exit,
      ),
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
      showAppToast(context, '举报已提交，我们会尽快处理');
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

  /// 收藏按钮弹层：收藏 / 稍后看 二选一
  Future<void> _showFavSheet() async {
    if (_post == null) return;
    await showModalBottomSheet(
      context: context,
      sheetAnimationStyle: const AnimationStyle(
        duration: AppMotion.page,
        curve: AppMotion.standard,
        reverseCurve: AppMotion.exit,
      ),
            isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => SheetShell(
        title: '收藏内容',
        subtitle: '选择收藏方式',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _favOption(
              icon: _faved ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
              label: '收藏',
              sub: '在我的页「收藏」中查看',
              active: _faved,
              color: const Color(AppColors.warning),
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
              color: const Color(AppColors.accent),
              onTap: () {
                Navigator.pop(ctx);
                _toggleLater();
              },
            ),
            const SizedBox(height: AppSpace.x4),
          ],
        ),
      ),
    );
  }

  Widget _favOption({
    required IconData icon,
    required String label,
    required String sub,
    required bool active,
    required Color color,
    required VoidCallback onTap,
  }) {
    return PressableScale(
      onTap: onTap,
      scale: 0.98,
      child: Container(
        margin: const EdgeInsets.only(bottom: AppSpace.x2),
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpace.x4, vertical: AppSpace.x4),
        decoration: BoxDecoration(
          color: const Color(AppColors.card),
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(
            color: active ? color.withValues(alpha: 0.55) : const Color(AppColors.border),
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              child: Icon(icon,
                  color: active ? color : const Color(AppColors.textSecondary),
                  size: 18),
            ),
            const SizedBox(width: AppSpace.x3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(label, style: AppType.label),
                  const SizedBox(height: 2),
                  Text(sub, style: AppType.micro),
                ],
              ),
            ),
            if (active)
              Icon(Icons.check_circle_rounded, color: color, size: 18),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final safeTop = MediaQuery.of(context).padding.top;
    // 还没加载出帖子：给加载/失败态，避免 _post! 空指针崩溃
    if (_post == null) {
      return ImmersivePage(
        child: Stack(
          children: [
            if (_loadFailed)
              Center(
                child: ErrorState(
                  message: '帖子暂时加载不出来',
                  onRetry: _load,
                ),
              )
            else
              const Center(
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2.2),
                ),
              ),
            Positioned(
              top: safeTop + 6,
              left: 8,
              child: IconCircleButton(
                icon: Icons.arrow_back_ios_new_rounded,
                size: 36,
                iconSize: 17,
                background: Colors.black.withValues(alpha: 0.4),
                onTap: () => Navigator.of(context).maybePop(),
              ),
            ),
          ],
        ),
      );
    }
    return ImmersivePage(
      // 键盘弹出只顶弹窗输入框，页面媒体/评论不被顶起
      resizeToAvoidBottomInset: false,
      child: Stack(
        children: [
          // 整个页面整体滚动：视频/首图(全宽) → 下方内容统一 16 左右间距
          ListView(
            // 视频帖：媒体顶到状态栏下沿（沉浸式，顶栏浮在画面上）
            // 图文帖：留出顶栏高度，避免图片被浮层遮挡
            padding: EdgeInsets.only(
              top: (_post?.isVideo ?? false) ? safeTop + 4 : safeTop + 52,
            ),
            children: [
              _mediaBlock(),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 16),
                    _authorRow(),
                    const SizedBox(height: 14),
                    _contentBlock(),
                    if (_post!.topic.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 6,
                        runSpacing: 8,
                        children: _post!.topic
                            .map((t) => Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 4),
                                  decoration: BoxDecoration(
                                    border: Border.all(
                                        color: const Color(AppTheme.border)),
                                    borderRadius: BorderRadius.circular(99),
                                  ),
                                  child: Text('#$t',
                                      style: const TextStyle(
                                          color: Color(AppTheme.textSecondary),
                                          fontSize: 12)),
                                ))
                            .toList(),
                      ),
                    ],
                    _statsRow(),
                    const SizedBox(height: 12),
                    _topicBar(),
                    if (_hasMusic) ...[
                      const SizedBox(height: 12),
                      _musicStrip(),
                    ],
                    if (_post!.poll != null) ...[
                      const SizedBox(height: 12),
                      PollCard(
                        postId: _post!.id,
                        poll: _post!.poll!,
                        onChanged: () {
                          if (!mounted) return;
                          setState(() {});
                        },
                      ),
                    ],
                    const SizedBox(height: 18),
                    const Divider(
                        color: Color(AppTheme.border), height: 1),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        const Text('评论',
                            style: TextStyle(
                                color: Color(AppTheme.textPrimary),
                                fontSize: 15,
                                fontWeight: FontWeight.w700)),
                        const SizedBox(width: 6),
                        Text('$_cCount',
                            style: const TextStyle(
                                color: Color(AppTheme.textTertiary),
                                fontSize: 11.5)),
                        if (_cHasMore) ...[
                          const SizedBox(width: 10),
                          GestureDetector(
                            onTap: () => _loadComments(),
                            child: const Text('加载更多',
                                style: TextStyle(
                                    color: Color(AppTheme.textSecondary),
                                    fontSize: 11.5)),
                          ),
                        ],
                        const Spacer(),
                        const Text('最热',
                            style: TextStyle(
                                color: Color(AppTheme.textTertiary),
                                fontSize: 11.5)),
                        const Icon(Icons.keyboard_arrow_down_rounded,
                            size: 14, color: Color(AppTheme.textTertiary)),
                      ],
                    ),
                    // 有爱评论引导条（对齐抖音）
                    const SizedBox(height: 8),
                    const Text('有爱评论，说点儿好听的',
                        style: TextStyle(
                            color: Color(AppTheme.textTertiary),
                            fontSize: 12)),
                    const SizedBox(height: 4),
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
                    const SizedBox(height: 100), // 底部单行栏避让
                  ],
                ),
              ),
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
                  _roundIconBtn(Icons.arrow_back_rounded,
                      onTap: () => Navigator.of(context).maybePop()),
                  const SizedBox(width: 12),

                    _followPill(),
                  const SizedBox(width: 12),
                ],
              ),
            ),
          ),
          // 底部固定：单行（抖音式，约 50dp）——输入条+表情/图片+点赞/评论/收藏/分享同排
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: _bottomBar(),
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
        // 单图：出血铺满、无圆角（V16 详情封面）
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
      // 多图：同一位置图集式（PageView 左右滑动切换）+ 指示点
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
                // 指示点（当前页薄荷绿，其余半透明白）
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 10,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      for (var i = 0; i < p.images.length; i++)
                        AnimatedContainer(
                          duration: AppMotion.fast,
                          margin: const EdgeInsets.symmetric(horizontal: 3),
                          width: i == _mediaIndex ? 16 : 5,
                          height: 5,
                          decoration: BoxDecoration(
                            color: i == _mediaIndex
                                ? const Color(AppColors.accent)
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

  /// 圆形浮层按钮（沉浸式：半透明黑底 + 白图标）
  Widget _roundIconBtn(IconData icon, {required VoidCallback onTap}) {
    return IconCircleButton(
      icon: icon,
      size: 36,
      iconSize: 18,
      background: Colors.black.withValues(alpha: 0.38),
      onTap: onTap,
    );
  }

  /// 关注胶囊（顶部栏右侧）
  Widget _followPill() {
    final a = _post!.author;
    return PillButton(
      label: _following ? '已关注' : '关注',
      size: PillSize.sm,
      variant: _following ? PillVariant.tonal : PillVariant.primary,
      loading: _followBusy,
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
    );
  }




  /// 分享帖子：底部面板（复制链接等）
  void _sharePost() {
    final p = _post;
    if (p == null) return;
    showModalBottomSheet<void>(
      context: context,
      sheetAnimationStyle: const AnimationStyle(
        duration: AppMotion.page,
        curve: AppMotion.standard,
        reverseCurve: AppMotion.exit,
      ),
            isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => SheetShell(
        title: '分享帖子',
        subtitle: '把这份内容分享给朋友',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListRow(
              leading: _sheetIcon(Icons.link_rounded),
              title: '复制链接',
              subtitle: 'https://www.dbmt999.asia/post/${p.id}',
              onTap: () {
                Navigator.pop(ctx);
                Clipboard.setData(
                    ClipboardData(text: 'https://www.dbmt999.asia/post/${p.id}'));
                showAppToast(context, '链接已复制');
              },
            ),
            ListRow(
              leading: _sheetIcon(Icons.ios_share_rounded),
              title: '分享给好友',
              subtitle: '打开系统分享面板',
              onTap: () async {
                // iPad 上 sharePositionOrigin 必填：先取当前渲染位置，再关闭弹层
                final ro = context.findRenderObject();
                final origin = ro is RenderBox && ro.hasSize
                    ? ro.localToGlobal(Offset.zero) & ro.size
                    : null;
                final title =
                    p.content.trim().isEmpty ? p.author.name : p.content;
                Navigator.pop(ctx);
                await sharePostLink(title, p.id, origin: origin);
                if (!mounted) return;
                showAppToast(context, '已打开系统分享');
              },
            ),
            ListRow(
              leading: _sheetIcon(Icons.flag_outlined),
              title: '举报',
              subtitle: '违规内容可举报，我们会尽快核实',
              onTap: () {
                Navigator.pop(ctx);
                _reportPost();
              },
            ),
            const SizedBox(height: AppSpace.x4),
          ],
        ),
      ),
    );
  }

  Widget _sheetIcon(IconData icon) {
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        color: const Color(AppColors.accent).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Icon(icon, color: const Color(AppColors.accent), size: 18),
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
    final content = p.content.trim();
    // 首句作为标题（≤40 字，遇到句末标点或换行截断），其余作为正文
    final m = RegExp(r'^(.{0,40}?)([。！？\n]|$)').firstMatch(content);
    final title = (m?.group(1) ?? content).trim();
    final rest = (m != null && m.end < content.length)
        ? content.substring(m.end).trim()
        : '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title.isNotEmpty)
          Text(
            title,
            style: const TextStyle(
              fontSize: 20,
              height: 1.35,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.4,
              color: Color(AppColors.textPrimary),
            ),
          ),
        if (rest.isNotEmpty) ...[
          const SizedBox(height: 10),
          _HighlightContent(
            text: rest,
            topics: p.topic,
            mentions: p.mentions,
          ),
        ],
      ],
    );
  }

  /// 作者行（V16）：封面下方第一行，头像 26 + 昵称 + 时间·话题 + 关注
  Widget _authorRow() {
    final a = _post!.author;
    final meta = _post!.topic.isEmpty
        ? dateText(_post!.created)
        : '${dateText(_post!.created)} · ${_post!.topic.first}';
    return Row(
      children: [
        GestureDetector(
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => UserProfilePage(uid: a.id)),
          ),
          child: AppAvatar(
            url: avatarUrlOf(a.id),
            size: 26,
            name: a.name,
            ring: a.isAdmin,
          ),
        ),
        const SizedBox(width: 9),
        Expanded(
          child: GestureDetector(
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => UserProfilePage(uid: a.id)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(a.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: Color(AppColors.textPrimary))),
                const SizedBox(height: 2),
                Text(meta,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 10.5,
                        color: Color(AppColors.textTertiary))),
              ],
            ),
          ),
        ),
        if (a.id != ApiClient.userId) _followPill(),
      ],
    );
  }

  /// 数据行：点赞 / 评论 / 收藏（V16 dstats）
  Widget _statsRow() {
    final items = <String>[
      '${formatCount(_likeCount)} 点赞',
      '${formatCount(_cCount)} 评论',
      if (_faved || _latered) '已收藏' else '收藏',
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Row(
        children: [
          for (final t in items)
            Padding(
              padding: const EdgeInsets.only(right: 18),
              child: Text(
                t,
                style: const TextStyle(
                  fontSize: 12,
                  color: Color(AppColors.textTertiary),
                ),
              ),
            ),
        ],
      ),
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

  /// 底部单行栏（沉浸式）：圆角输入条 + 点赞/评论/收藏/分享同排
  Widget _bottomBar() {
    return Container(
      decoration: const BoxDecoration(
        color: Color(AppColors.canvas),
        border: Border(top: BorderSide(color: Color(AppColors.hairline), width: 0.5)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: PressableScale(
                  onTap: _openComments,
                  child: Container(
                    height: 36,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    alignment: Alignment.centerLeft,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.07),
                      borderRadius: AppRadius.rPill,
                      border: Border.all(color: const Color(AppColors.border)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.edit_outlined,
                            size: 15, color: Color(AppColors.textTertiary)),
                        const SizedBox(width: 8),
                        Text('说点什么...', style: AppType.bodySm),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              _miniAction(
                  _liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                  '',
                  _liked ? const Color(AppColors.heart) : null, _toggleLike,
                  trigger: _liked),
              _miniAction(
                  _faved || _latered
                      ? Icons.bookmark_rounded
                      : Icons.bookmark_border_rounded,
                  '',
                  (_faved || _latered) ? const Color(AppColors.warning) : null,
                  _showFavSheet),
              _miniIcon(Icons.ios_share_rounded, _sharePost),
            ],
          ),
        ),
      ),
    );
  }

  /// 底部单行小图标按钮
  Widget _miniIcon(IconData icon, VoidCallback onTap) {
    return PressableScale(
      onTap: onTap,
      scale: 0.85,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 6),
        child: Icon(icon, size: 21, color: const Color(AppColors.textSecondary)),
      ),
    );
  }

  /// 底部单行动作：图标 + 可选数字（激活时高亮）
  Widget _miniAction(
      IconData icon, String label, Color? active, VoidCallback onTap,
      {Object? trigger}) {
    final color = active ?? const Color(AppColors.textSecondary);
    return PressableScale(
      onTap: onTap,
      scale: 0.85,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            BounceOnChange(
              trigger: trigger,
              child: Icon(icon, size: 21, color: color),
            ),
            if (label.isNotEmpty) ...[
              const SizedBox(width: 3),
              RollingText(
                text: label,
                style: TextStyle(
                    color: color,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600),
              ),
            ],
          ],
        ),
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
            AppAvatar(
              url: uid.isEmpty ? null : avatarUrlOf(uid),
              size: 32,
            ),
            const SizedBox(width: AppSpace.x3),
            Expanded(
              child: Container(
                height: 38,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                alignment: Alignment.centerLeft,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.07),
                  borderRadius: AppRadius.rPill,
                  border: Border.all(color: const Color(AppColors.border)),
                ),
                child: Text('说点什么...', style: AppType.bodySm),
              ),
            ),
            const SizedBox(width: AppSpace.x2),
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: const Color(AppColors.accent),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.send_rounded,
                  size: 17, color: Color(AppColors.onAccent)),
            ),
          ],
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
      await ApiClient.setCommentLike(cid, liked: !wasLiked);
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
          AppAvatar(
            url: avatar.isEmpty ? null : avatarUrl(avatar),
            size: 30,
            name: name,
            ring: adminLevel > 0,
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
                                ? Icons.favorite_rounded
                                : Icons.favorite_border_rounded,
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

class _InlineVideoState extends State<_InlineVideo>
    with RouteAware, WidgetsBindingObserver {
  VideoPlayerController? _vc;
  bool _failed = false;
  bool _controls = false;
  bool _userPaused = false; // 用户通过控制条主动暂停
  bool _routeVisible = true; // 本路由是否在最顶层
  bool _appResumed = true; // App 是否在前台
  Timer? _hideTimer;

  /// 期望播放：路由可见 + App 前台 + 用户没主动暂停
  bool get _wantPlay => _routeVisible && _appResumed && !_userPaused;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null) appRouteObserver.subscribe(this, route);
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
      c.addListener(_onValue);
      setState(() => _vc = c);
      _apply(); // 挂载后统一走播放控制：自动播放 + 循环
    } catch (_) {
      if (!mounted) return;
      setState(() => _failed = true);
    }
  }

  /// 同步用户在控制条里的手动播放/暂停（仅路由可见、App 前台时才归因于用户，
  /// 避免把路由/生命周期触发的暂停误判成用户暂停）
  void _onValue() {
    final v = _vc;
    if (v == null || !v.value.isInitialized) return;
    if (_routeVisible && _appResumed) {
      _userPaused = !v.value.isPlaying;
    }
  }

  /// 统一入口：按当前状态决定播/停。详情页有声、循环
  void _apply() {
    final v = _vc;
    if (v == null || !v.value.isInitialized) return;
    v.setVolume(1);
    if (_wantPlay) {
      v.setLooping(true);
      v.play();
    } else {
      v.pause();
    }
  }

  // ---------------- RouteAware：被盖住 / 回到本页 ----------------
  @override
  void didPushNext() {
    _routeVisible = false;
    _apply();
  }

  @override
  void didPopNext() {
    _routeVisible = true;
    _apply();
  }

  // ---------------- 前后台 ----------------
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appResumed = state == AppLifecycleState.resumed;
    _apply();
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
    appRouteObserver.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    _vc?.removeListener(_onValue);
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

