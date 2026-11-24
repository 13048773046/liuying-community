/// 帖子详情页（P0）：图文/视频帖详情 + 评论区
/// 评论区支持：文字评论、图片评论（≤1 图）、表情包（占位，官方素材到达后接入）
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'package:video_player/video_player.dart';

import '../../widgets/video_controls_bar.dart';

import '../../api/client.dart';
import '../../config.dart';
import '../../design/components.dart';
import '../../design/system.dart';
import '../../design/shared_element.dart';
import '../../features/emoji/text_emoji.dart';
import '../../design/spotlight_coach.dart';
import '../../models/feed_item.dart';
import '../../services/app_route_observer.dart';
import '../../services/follow_bus.dart';
import '../../services/secure_links.dart';
import '../../utils/music_bgm.dart';
import '../../utils/share_util.dart';
import '../share/share_friend_sheet.dart';
import '../../widgets/image_box.dart';
import '../../widgets/poll_card.dart';
import '../../widgets/comment_sheet.dart';
import '../mine/login_page.dart';
import '../user/user_profile.dart';
import '../discover/topic_detail_page.dart';

class PostDetailPage extends StatefulWidget {
  final String postId;

  /// 测试/预览注入：让详情页在没有真实网络时也能验证首图/封面的取色背景。
  final ImageProvider? debugHeroImageProvider;

  const PostDetailPage({
    super.key,
    required this.postId,
    @visibleForTesting this.debugHeroImageProvider,
  });

  @override
  State<PostDetailPage> createState() => _PostDetailPageState();
}

class _PostDetailPageState extends State<PostDetailPage> {
  final GlobalKey _spotCommentKey = GlobalKey();
  final GlobalKey _spotLikeKey = GlobalKey();
  final GlobalKey _spotShareKey = GlobalKey();
  FeedItem? _post;
  bool _liked = false;
  bool _faved = false;
  bool _latered = false;
  bool _likeBusy = false;
  bool _favBusy = false;
  bool _laterBusy = false;
  int _likeCount = 0;
  Map<String, int> _hotTopicCounts = {};
  final Map<String, bool> _attachmentBusy = {};
  final Map<String, String> _attachmentLocal = {};

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

  /// 视频封面比例（详情页容器跟随封面，不在初始化前写死 16:9）。
  double _videoAspect = 16 / 9;

  /// 详情页背景色：图文取首图、视频取封面；取不到才回品牌绿。
  Color? _heroTone;
  bool _heroToneFailed = false;

  @override
  void initState() {
    super.initState();
    FollowBus.relations.addListener(_onFollowBus);
    _load();
    _loadHotTopics();
  }

  void _onFollowBus() {
    final id = _post?.author.id ?? '';
    if (!mounted || id.isEmpty) return;
    final next = FollowBus.relationOf(id);
    if (next != null && next != _following) {
      setState(() => _following = next);
    }
  }

  @override
  void didUpdateWidget(covariant PostDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.postId != widget.postId) {
      _post = null;
      _comments = [];
      _following = false;
      _load();
    }
  }

  Future<void> _loadHotTopics() async {
    try {
      final list = await ApiClient.topicsHot();
      if (!mounted) return;
      setState(() {
        _hotTopicCounts = {
          for (final t in list)
            (t['name'] ?? '') as String: ((t['count'] ?? 0) as num).toInt(),
        };
      });
    } catch (_) {}
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loadFailed = false;
        _heroTone = null;
        _heroToneFailed = false;
      });
    }
    try {
      final j = await ApiClient.postDetail(widget.postId);
      if (!mounted) return;
      final pj = Map<String, dynamic>.from(j['post'] as Map);
      final post = FeedItem.fromJson(pj);
      setState(() {
        _post = post;
        _liked = pj['liked'] ?? false;
        _faved = pj['faved'] ?? false;
        _latered = pj['later'] ?? false;
        _likeCount = ((pj['likeCount'] ?? 0) as num).toInt();
        _following = post.author.following;
      });
      FollowBus.setRelation(post.author.id, post.author.following);
      if (!post.author.followingKnown &&
          post.author.id.isNotEmpty &&
          post.author.id != ApiClient.userId) {
        // 兼容尚未下发 following 的旧接口：只补拉一次，不阻塞渲染。
        unawaited(
          FollowBus.sync(post.author.id).then((v) {
            if (!mounted || v == null) return;
            setState(() => _following = v);
          }),
        );
      }
      _cCount = post.commentCount;
      // 配乐：打开图文/视频详情自动播放所选 BGM
      final m = _post!.music;
      if (m != null && m['url'] is String && (m['url'] as String).isNotEmpty) {
        MusicBgm.I.setVolume(_post!.musicVolume / 100.0);
        MusicBgm.I.play(m['url'] as String);
      }
      await _loadComments(refresh: true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadFailed = true);
      showAppToast(context, '加载失败，请重试');
    }
  }

  /// 首图/视频封面解码后回报。只接受第一张图的色，滑动图集不回改页面背景。
  void _onHeroTone(Color tone) {
    if (!mounted) return;
    if (_heroTone == tone && !_heroToneFailed) return;
    setState(() {
      _heroTone = tone;
      _heroToneFailed = false;
    });
  }

  void _onHeroToneFailed() {
    if (!mounted || _heroTone != null) return;
    if (_heroToneFailed) return;
    setState(() => _heroToneFailed = true);
  }

  /// 页面顶部的氛围色。图文/视频没有成功取到颜色时保持中性暗底，
  /// 只有无媒体或取色失败才回品牌绿；避免加载瞬间先闪一层绿色。
  Widget _heroBackdrop(bool reduceMotion) {
    final post = _post;
    final hasMedia = post != null && (post.isVideo || post.images.isNotEmpty);
    final base = const Color(AppTheme.bg);
    final accent = const Color(AppTheme.accent);
    final tone = _heroTone;
    final top = tone != null
        ? Color.lerp(tone, base, 0.76)!
        : (!hasMedia || _heroToneFailed)
        ? Color.lerp(accent, base, 0.93)!
        : Color.lerp(const Color(AppColors.elevated), base, 0.88)!;
    final wash = tone != null ? Color.lerp(tone, base, 0.94)! : base;
    return Positioned.fill(
      child: AnimatedContainer(
        key: const ValueKey('post-hero-backdrop'),
        duration: reduceMotion
            ? Duration.zero
            : const Duration(milliseconds: 520),
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [top, wash, base],
            stops: const [0, 0.30, 1],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    FollowBus.relations.removeListener(_onFollowBus);
    _mediaPageController.dispose();
    MusicBgm.I.stop();
    super.dispose();
  }

  Future<void> _toggleLike() async {
    HapticFeedback.lightImpact();
    if (_post == null || _likeBusy) return;
    _likeBusy = true;
    final wasLiked = _liked;
    setState(() {
      _liked = !wasLiked;
      _likeCount += _liked ? 1 : -1;
    });
    try {
      await ApiClient.setPostLike(_post!.id, liked: _liked);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _liked = wasLiked;
        _likeCount += _liked ? 1 : -1;
      });
    } finally {
      _likeBusy = false;
    }
  }

  Future<void> _toggleFav() async {
    HapticFeedback.lightImpact();
    if (_post == null || _favBusy) return;
    // 接口语义：faved=true 表示「当前已收藏」→ 走 DELETE；所以传切换前的状态
    final wasFaved = _faved;
    _favBusy = true;
    setState(() => _faved = !wasFaved);
    try {
      await ApiClient.toggleFav(_post!.id, faved: wasFaved);
    } catch (_) {
      if (!mounted) return;
      setState(() => _faved = wasFaved);
    } finally {
      _favBusy = false;
    }
  }

  Future<void> _toggleLater() async {
    if (_post == null || _laterBusy) return;
    final wasLater = _latered;
    _laterBusy = true;
    setState(() => _latered = !wasLater);
    try {
      await ApiClient.toggleFav(_post!.id, kind: 'later', faved: wasLater);
    } catch (_) {
      if (!mounted) return;
      setState(() => _latered = wasLater);
    } finally {
      _laterBusy = false;
    }
  }

  /// 举报弹窗（帖子/评论通用）
  Future<void> _report(String targetType, String targetId) async {
    if (ApiClient.token == null) {
      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const LoginPage()),
      );
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
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 14),
            const Text(
              '举报',
              style: TextStyle(
                color: Color(AppTheme.textPrimary),
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              '请选择举报原因，我们会尽快核实处理',
              style: TextStyle(
                color: Color(AppTheme.textTertiary),
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 8),
            for (final r in reasons)
              ListTile(
                dense: true,
                title: Text(
                  r,
                  style: const TextStyle(
                    color: Color(AppTheme.textPrimary),
                    fontSize: 13.5,
                  ),
                ),
                trailing: const Icon(
                  Icons.chevron_right_rounded,
                  size: 18,
                  color: Color(AppTheme.textTertiary),
                ),
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e is ApiException ? e.message : '举报失败，请稍后再试'),
          backgroundColor: const Color(AppTheme.card),
          behavior: SnackBarBehavior.floating,
        ),
      );
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
              icon: _faved
                  ? Icons.bookmark_rounded
                  : Icons.bookmark_border_rounded,
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
          horizontal: AppSpace.x4,
          vertical: AppSpace.x4,
        ),
        decoration: BoxDecoration(
          color: const Color(AppColors.card),
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(
            color: active
                ? color.withValues(alpha: 0.55)
                : const Color(AppColors.border),
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
              child: Icon(
                icon,
                color: active ? color : const Color(AppColors.textSecondary),
                size: 18,
              ),
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
    final loading = _post == null;
    return SkeletonSwap(
      loading: loading,
      skeleton: _loadingState(safeTop),
      child: loading ? const SizedBox.shrink() : _loadedPage(safeTop),
    );
  }

  Widget _loadedPage(double safeTop) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return ImmersivePage(
      // 键盘只顶起评论编辑器，不改变正文滚动位置
      resizeToAvoidBottomInset: false,
      child: Stack(
        children: [
          _heroBackdrop(reduceMotion),
          CustomScrollView(
            physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics(),
            ),
            slivers: [
              SliverToBoxAdapter(child: _heroBlock(safeTop)),
              SliverToBoxAdapter(child: _authorStrip()),
              SliverToBoxAdapter(child: _storyIntro()),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 18),
                      _topicBar(),
                      if (_hasMusic) ...[
                        const SizedBox(height: 12),
                        _musicStrip(),
                      ],
                      if (_post!.attachments.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        _attachmentsBlock(),
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
                    ],
                  ),
                ),
              ),
              SliverToBoxAdapter(child: _discussionZone()),
              const SliverToBoxAdapter(child: SizedBox(height: 110)),
            ],
          ),
          _topDock(safeTop),
          Positioned(left: 0, right: 0, bottom: 0, child: _bottomDock()),
          if (SpotlightFlags.postActions)
            Positioned.fill(
              child: SpotlightCoach(
                steps: [
                  SpotlightStep(
                    targetKey: _spotCommentKey,
                    title: '先留下你的回应',
                    body: '写一句评论，作者和同频的人都会看到。',
                    radius: 14,
                  ),
                  SpotlightStep(
                    targetKey: _spotLikeKey,
                    title: '点亮喜欢',
                    body: '喜欢这条内容就点一下，之后还能在收藏里回看。',
                    radius: 22,
                  ),
                  SpotlightStep(
                    targetKey: _spotShareKey,
                    title: '分享给同频的人',
                    body: '把这条内容发给朋友，或复制链接分享出去。',
                    radius: 22,
                  ),
                ],
                onDone: _finishSpotlight,
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _finishSpotlight() async {
    SpotlightFlags.postActions = false;
    if (mounted) setState(() {});
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setBool('post_actions_guide_v1_seen', true);
    } catch (_) {}
  }

  Widget _loadingState(double safeTop) {
    return ImmersivePage(
      child: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(0, -0.55),
                  radius: 1.1,
                  colors: [
                    const Color(AppTheme.accent).withValues(alpha: 0.12),
                    const Color(AppTheme.bg),
                  ],
                ),
              ),
            ),
          ),
          if (_loadFailed)
            Center(
              child: ErrorState(message: '这条内容暂时没有加载出来', onRetry: _load),
            )
          else
            ShimmerScope(
              child: CustomScrollView(
                physics: const NeverScrollableScrollPhysics(),
                slivers: [
                  SliverToBoxAdapter(
                    child: ShimmerBox(
                      width: double.infinity,
                      height: 318,
                      radius: 0,
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
                      child: Row(
                        children: [
                          const ShimmerBox(width: 42, height: 42, radius: 21),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: const [
                                ShimmerBox(width: 112, height: 13),
                                SizedBox(height: 8),
                                ShimmerBox(width: 168, height: 9),
                              ],
                            ),
                          ),
                          const ShimmerBox(width: 62, height: 27, radius: 13),
                        ],
                      ),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: const [
                          ShimmerBox(width: 286, height: 18),
                          SizedBox(height: 10),
                          ShimmerBox(width: 330, height: 12),
                          SizedBox(height: 8),
                          ShimmerBox(width: 210, height: 12),
                          SizedBox(height: 28),
                          ShimmerBox(width: 92, height: 15),
                          SizedBox(height: 14),
                          ShimmerBox(width: double.infinity, height: 1),
                        ],
                      ),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 22, 20, 0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: const [
                          ShimmerBox(width: 104, height: 14),
                          SizedBox(height: 18),
                          Row(
                            children: [
                              ShimmerBox(width: 34, height: 34, radius: 17),
                              SizedBox(width: 10),
                              Expanded(child: ShimmerBox(height: 44)),
                            ],
                          ),
                          SizedBox(height: 14),
                          Row(
                            children: [
                              ShimmerBox(width: 34, height: 34, radius: 17),
                              SizedBox(width: 10),
                              Expanded(child: ShimmerBox(height: 44)),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          Positioned(
            top: safeTop + 10,
            left: 14,
            child: _glassIcon(
              Icons.arrow_back_rounded,
              onTap: () => Navigator.of(context).maybePop(),
            ),
          ),
        ],
      ),
    );
  }

  /// 顶栏：返回 + 版面标识 + 分享，浮在封面之上。
  Widget _topDock(double safeTop) {
    return Positioned(
      top: safeTop + 8,
      left: 12,
      right: 12,
      child: Row(
        children: [
          _glassIcon(
            Icons.arrow_back_rounded,
            onTap: () => Navigator.of(context).maybePop(),
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xE60B0C0D),
              borderRadius: BorderRadius.circular(99),
              border: Border.all(
                color: const Color(AppTheme.accent).withValues(alpha: 0.32),
              ),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.auto_awesome_rounded,
                  size: 12,
                  color: Color(AppTheme.accent),
                ),
                SizedBox(width: 6),
                Text(
                  '帖子信息',
                  style: TextStyle(
                    color: Color(AppTheme.textPrimary),
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.4,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _glassIcon(Icons.ios_share_rounded, onTap: _sharePost),
        ],
      ),
    );
  }

  Widget _glassIcon(IconData icon, {required VoidCallback onTap}) {
    return PressableScale(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: const Color(0x990B0C0D),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
        ),
        child: Icon(icon, size: 19, color: const Color(AppTheme.textPrimary)),
      ),
    );
  }

  /// 封面：图像帖 / 视频帖用真实媒体，纯文字帖生成一张“文字封面”。
  Widget _heroBlock(double safeTop) {
    final post = _post!;
    final hasMedia = post.isVideo || post.images.isNotEmpty;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, safeTop + 62, 16, 0),
      child: GestureDetector(
        onTap: post.images.isNotEmpty ? () => _openGallery(0) : null,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(26),
          child: AspectRatio(
            key: const ValueKey('postVideoHeroFrame'),
            // 视频：先按封面比例撑开，封面解码后由 _InlineVideo 回填真实比例。
            aspectRatio: post.isVideo
                ? _videoAspect
                : (post.images.isEmpty ? 1.0 : 4 / 5),
            child: Stack(
              fit: StackFit.expand,
              children: [
                _heroMedia(),
                // 顶部的轻微压暗只负责标签可读，不遮住画面主体
                Positioned.fill(
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.center,
                          colors: [
                            Colors.black.withValues(alpha: 0.42),
                            Colors.transparent,
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(left: 14, top: 14, child: _coverKicker(post)),
                if (hasMedia)
                  Positioned(
                    right: 14,
                    top: 14,
                    child: _metaPill(
                      post.isVideo
                          ? '动态影像'
                          : '${_mediaIndex + 1} / ${post.images.length}',
                    ),
                  ),
                if (hasMedia && post.shareCount > 0)
                  Positioned(
                    left: 14,
                    bottom: 14,
                    child: _metaPill('已分享 ${formatCount(post.shareCount)} 次'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _heroMedia() {
    final post = _post!;
    if (post.isVideo) {
      final cover = post.cover == 'auto' ? '${post.video}.jpg' : post.cover;
      return _InlineVideo(
        url: mediaUrl(post.video),
        coverUrl: cover.trim().isEmpty ? '' : mediaUrl(cover),
        audioVolume: post.audioVolume,
        borderRadius: 0,
        heroTag: SharedElementTags.postCover(post.id),
        coverProvider: widget.debugHeroImageProvider,
        onToneExtracted: _onHeroTone,
        onToneFailed: _onHeroToneFailed,
        onAspectRatio: (ratio) {
          if (!mounted || !post.isVideo) return;
          final next = ratio.clamp(0.3, 3.0);
          if ((next - _videoAspect).abs() <= 0.001) return;
          // 封面解码可能发生在首帧构建中，延迟到帧后回填，避免 build 期间 setState。
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || (next - _videoAspect).abs() <= 0.001) return;
            setState(() => _videoAspect = next);
          });
        },
      );
    }
    if (post.images.isNotEmpty) {
      return Stack(
        fit: StackFit.expand,
        children: [
          PageView.builder(
            controller: _mediaPageController,
            itemCount: post.images.length,
            onPageChanged: (i) {
              _mediaIndex = i;
              setState(() {});
            },
            itemBuilder: (_, i) => AppHero(
              tag: SharedElementTags.galleryImage(post.id, i),
              child: GestureDetector(
                onTap: () => _openGallery(i),
                child: BlurUpImage(
                  url: mediaUrl(post.images[i]),
                  fit: BoxFit.cover,
                  cacheWidth: 780,
                  imageProvider: i == 0 ? widget.debugHeroImageProvider : null,
                  onToneExtracted: i == 0 ? _onHeroTone : null,
                  onToneFailed: i == 0 ? _onHeroToneFailed : null,
                ),
              ),
            ),
          ),
          if (post.images.length > 1)
            Positioned(
              left: 0,
              right: 0,
              bottom: 16,
              child: AnimatedBuilder(
                animation: _mediaPageController,
                builder: (_, child) => Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(post.images.length, (i) {
                    final active = i == _mediaIndex;
                    return AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      width: active ? 16 : 5,
                      height: 5,
                      decoration: BoxDecoration(
                        color: active
                            ? const Color(AppTheme.accent)
                            : Colors.white.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(99),
                      ),
                    );
                  }),
                ),
              ),
            ),
        ],
      );
    }
    // 纯文字帖：用版面语言做一张“文字封面”，正文标题仍留在下方，
    // 这里只负责定调，不再重复正文段落。
    final topics = post.topic;
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1C2A24), Color(AppTheme.card), Color(0xFF141517)],
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            right: 8,
            bottom: 4,
            child: Text(
              '“',
              style: TextStyle(
                fontSize: 132,
                height: 1,
                fontWeight: FontWeight.w700,
                color: const Color(AppTheme.accent).withValues(alpha: 0.09),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 26, 22, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: const BoxDecoration(
                        color: Color(AppTheme.accent),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 7),
                    Text(
                      '文字随笔',
                      style: AppType.label.copyWith(
                        color: const Color(AppTheme.accent),
                        fontSize: 10,
                        letterSpacing: 1.5,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 22),
                Expanded(
                  child: TextEmojiText(
                    post.content.trim().isEmpty
                        ? '一则安静的记录'
                        : post.content.trim(),
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.display.copyWith(
                      fontSize: 26,
                      height: 1.38,
                      color: const Color(AppTheme.textPrimary),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Container(
                      width: 22,
                      height: 1.5,
                      color: const Color(AppTheme.accent)
                          .withValues(alpha: 0.5),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '向下阅读正文',
                      style: AppType.micro.copyWith(
                        color: const Color(AppTheme.textTertiary),
                        fontSize: 10,
                        letterSpacing: 0.8,
                      ),
                    ),
                    const Spacer(),
                    if (topics.isNotEmpty)
                      Text(
                        '# ${topics.first}',
                        style: AppType.micro.copyWith(
                          color: const Color(AppTheme.accent),
                          fontSize: 10,
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

  Widget _coverKicker(FeedItem post) {
    final label = post.isVideo
        ? '影像记录'
        : (post.images.isNotEmpty ? '图像记录' : '文字随笔');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xCC0B0C0D),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 5,
            height: 5,
            decoration: const BoxDecoration(
              color: Color(AppTheme.accent),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(
              color: Color(AppTheme.textPrimary),
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.2,
            ),
          ),
        ],
      ),
    );
  }

  Widget _metaPill(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0x990B0C0D),
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Color(AppTheme.textPrimary),
          fontSize: 10,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  /// 作者条不塞进封面，单独成为正文之前的“署名”。
  Widget _authorStrip() {
    final post = _post!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 16, 0),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => Navigator.push(
              context,
              AppPageRoute(
                builder: (_) => UserProfilePage(
                  uid: post.author.id,
                  heroTag: SharedElementTags.postAvatar(
                    post.author.id,
                    post.id,
                  ),
                ),
              ),
            ),
            child: AppHero(
              tag: SharedElementTags.postAvatar(post.author.id, post.id),
              child: AppAvatar(
                name: post.author.name,
                url: post.author.avatarUrlResolved.isEmpty
                    ? avatarUrlOf(post.author.id)
                    : post.author.avatarUrlResolved,
                frameUrl: frameUrlOf(post.author.frameId),
                size: 46,
                ring: true,
                verified: post.author.verified,
                isAi: post.author.isAi,
              ),
            ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: GestureDetector(
                        onTap: () => Navigator.push(
                          context,
                          AppPageRoute(
                            builder: (_) => UserProfilePage(
                              uid: post.author.id,
                              heroTag: SharedElementTags.postAvatar(
                                post.author.id,
                                post.id,
                              ),
                            ),
                          ),
                        ),
                        child: Text(
                          post.author.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppType.title.copyWith(fontSize: 16),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(AppTheme.accent)
                            .withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        post.author.isAdmin ? '作者' : '成员',
                        style: const TextStyle(
                          color: Color(AppTheme.accent),
                          fontSize: 8.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '${dateText(post.created)} · 来自流萤社区',
                  style: AppType.micro.copyWith(
                    color: const Color(AppTheme.textTertiary),
                    fontSize: 10.5,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (post.author.id != ApiClient.userId) _followPill(),
        ],
      ),
    );
  }

  Widget _storyIntro() {
    final post = _post!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'NOTE / ${dateText(post.created)}',
                style: AppType.label.copyWith(
                  color: const Color(AppTheme.accent),
                  fontSize: 10,
                  letterSpacing: 1.6,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Container(
                  height: 1,
                  color: Colors.white.withValues(alpha: 0.08),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _contentBlock(),
          if (post.topic.isNotEmpty) ...[
            const SizedBox(height: 14),
            Wrap(
              spacing: 7,
              runSpacing: 7,
              children: post.topic
                  .map(
                    (t) => GestureDetector(
                      onTap: () => _openTopic(t),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(AppTheme.accent)
                              .withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: const Color(AppTheme.accent)
                                .withValues(alpha: 0.18),
                          ),
                        ),
                        child: Text(
                          '# $t',
                          style: const TextStyle(
                            color: Color(AppTheme.accent),
                            fontSize: 11.5,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ],
          const SizedBox(height: 18),
          _engagementRail(),
        ],
      ),
    );
  }

  /// 互动数据做成一条信息带，而不是旧版的按钮串。
  Widget _engagementRail() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
          bottom: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: _railMetric(
              formatCount(_likeCount),
              '共鸣',
              Icons.favorite_border_rounded,
            ),
          ),
          _railDivider(),
          Expanded(
            child: _railMetric(
              '$_cCount',
              '讨论',
              Icons.chat_bubble_outline_rounded,
            ),
          ),
          _railDivider(),
          Expanded(
            child: _railMetric(
              _faved || _latered ? '已收录' : '收藏',
              _faved || _latered ? '在书架里' : '稍后阅读',
              _faved || _latered
                  ? Icons.bookmark_rounded
                  : Icons.bookmark_border_rounded,
            ),
          ),
        ],
      ),
    );
  }

  Widget _railMetric(String value, String label, IconData icon) {
    return Row(
      children: [
        Icon(icon, size: 16, color: const Color(AppTheme.textTertiary)),
        const SizedBox(width: 7),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              value,
              style: AppType.title.copyWith(
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
            Text(
              label,
              style: AppType.micro.copyWith(
                color: const Color(AppTheme.textTertiary),
                fontSize: 10,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _railDivider() => Container(
    width: 1,
    height: 28,
    color: Colors.white.withValues(alpha: 0.08),
  );

  Widget _discussionZone() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 26, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text('讨论', style: AppType.title.copyWith(fontSize: 18)),
              const SizedBox(width: 8),
              Text(
                '$_cCount 条回应',
                style: AppType.micro.copyWith(
                  color: const Color(AppTheme.textTertiary),
                  fontSize: 10.5,
                ),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                decoration: BoxDecoration(
                  color: const Color(AppTheme.card),
                  borderRadius: BorderRadius.circular(99),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.08),
                  ),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '最热',
                      style: TextStyle(
                        color: Color(AppTheme.textSecondary),
                        fontSize: 11,
                      ),
                    ),
                    SizedBox(width: 2),
                    Icon(
                      Icons.keyboard_arrow_down_rounded,
                      size: 14,
                      color: Color(AppTheme.textTertiary),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _replyRow(),
          const SizedBox(height: 14),
          if (_comments.isEmpty && !_cLoading)
            _emptyComments('还没有人回应，留下你的第一句话')
          else if (_comments.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: CircularProgressIndicator(
                  color: Color(AppTheme.accent),
                  strokeWidth: 2,
                ),
              ),
            )
          else
            ..._comments.map((c) => _commentTile(c)),
          if (_cHasMore)
            Center(
              child: TextButton(
                onPressed: _loadComments,
                child: Text(
                  '继续展开讨论',
                  style: AppType.label.copyWith(
                    color: const Color(AppTheme.accent),
                    letterSpacing: 0.6,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _emptyComments(String text) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 16),
      decoration: BoxDecoration(
        color: const Color(AppTheme.card),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.chat_bubble_outline_rounded,
            size: 18,
            color: Color(AppTheme.textTertiary),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              text,
              style: AppType.caption.copyWith(
                color: const Color(AppTheme.textTertiary),
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _bottomDock() {
    final liked = _liked;
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xF2111213),
        border: Border(
          top: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          child: Row(
            children: [
              Expanded(
                child: PressableScale(
                  key: _spotCommentKey,
                  onTap: _openComments,
                  child: Container(
                    height: 44,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(
                      color: const Color(AppTheme.card),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.08),
                      ),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.edit_note_rounded,
                          size: 19,
                          color: Color(AppTheme.accent),
                        ),
                        const SizedBox(width: 7),
                        Expanded(
                          child: Text(
                            '写下你的回应…',
                            style: AppType.caption.copyWith(
                              color: const Color(AppTheme.textTertiary),
                              fontSize: 12,
                            ),
                          ),
                        ),
                        const Icon(
                          Icons.arrow_upward_rounded,
                          size: 16,
                          color: Color(AppTheme.accent),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _dockAction(
                liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                formatCount(_likeCount),
                liked ? const Color(AppTheme.accent) : null,
                _toggleLike,
                targetKey: _spotLikeKey,
              ),
              _dockAction(
                _faved || _latered
                    ? Icons.bookmark_rounded
                    : Icons.bookmark_border_rounded,
                _faved || _latered ? '已藏' : '收藏',
                _faved || _latered ? const Color(AppTheme.accent) : null,
                _showFavSheet,
              ),
              _dockAction(
                Icons.ios_share_rounded,
                '分享',
                null,
                _sharePost,
                targetKey: _spotShareKey,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _dockAction(
    IconData icon,
    String label,
    Color? color,
    VoidCallback onTap, {
    GlobalKey? targetKey,
  }) {
    return PressableScale(
      onTap: onTap,
      child: SizedBox(
        key: targetKey,
        width: 48,
        height: 44,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 21,
              color: color ?? const Color(AppTheme.textSecondary),
            ),
            const SizedBox(height: 3),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: color ?? const Color(AppTheme.textTertiary),
                fontSize: 9.5,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openTopic(String topic) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            TopicDetailPage(topic: topic, count: _hotTopicCounts[topic] ?? 0),
      ),
    );
  }

  Widget _topicBar() {
    final topics = _post!.topic;
    if (topics.isEmpty) return const SizedBox.shrink();
    final t = topics.first;
    final count = _hotTopicCounts[t];
    return PressableScale(
      onTap: () => _openTopic(t),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
        decoration: BoxDecoration(
          color: const Color(AppTheme.card),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
        ),
        child: Row(
          children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: const Color(AppTheme.accent).withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.tag_rounded,
                color: Color(AppTheme.accent),
                size: 16,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '相关话题',
                    style: AppType.label.copyWith(
                      color: const Color(AppTheme.accent),
                      fontSize: 9.5,
                      letterSpacing: 0.8,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '# $t',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.title.copyWith(fontSize: 14),
                  ),
                ],
              ),
            ),
            Text(
              count != null ? '$count 条讨论' : '参与话题',
              style: AppType.micro.copyWith(
                color: const Color(AppTheme.textTertiary),
                fontSize: 10.5,
              ),
            ),
            const SizedBox(width: 2),
            const Icon(
              Icons.arrow_forward_ios_rounded,
              color: Color(AppTheme.textTertiary),
              size: 13,
            ),
          ],
        ),
      ),
    );
  }

  /// 相关搜索（抖音"看后搜"点位，用热门话题替代，点击进话题页）
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
              HapticFeedback.lightImpact();
              setState(() => _followBusy = true);
              try {
                final next = await FollowBus.toggle(a.id);
                if (!mounted) return;
                setState(() {
                  _following = next;
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
              title: '复制短链',
              subtitle: '站内私信与站外分享统一使用',
              onTap: () async {
                Navigator.pop(ctx);
                final url = await resolvePostShareUrl(p.id);
                await AppClipboard.copy(url);
                if (!mounted) return;
                showAppToast(context, '短链已复制');
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
                final title = p.content.trim().isEmpty
                    ? p.author.name
                    : p.content;
                Navigator.pop(ctx);
                await sharePostLink(title, p.id, origin: origin);
                if (!mounted) return;
                showAppToast(context, '已打开系统分享');
              },
            ),
            ListRow(
              leading: _sheetIcon(Icons.forum_outlined),
              title: '分享给互关好友',
              subtitle: '发到对方私信，点卡片直达这条帖子',
              onTap: () {
                Navigator.pop(ctx);
                final title = p.content.trim().isEmpty
                    ? p.author.name
                    : p.content;
                final cover = p.cover.isNotEmpty
                    ? p.cover
                    : (p.images.isNotEmpty ? p.images.first : '');
                showShareFriendSheet(
                  context,
                  ShareFriendTarget(
                    type: 'post',
                    id: p.id,
                    title: title,
                    subtitle: '帖子分享',
                    iconUrl: cover.isEmpty ? '' : mediaUrl(cover),
                  ),
                );
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
      AppPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          body: PhotoViewGallery.builder(
            scrollPhysics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics(),
            ),
            itemCount: imgs.length,
            pageController: PageController(initialPage: index),
            onPageChanged: (_) {},
            builder: (_, i) => PhotoViewGalleryPageOptions(
              imageProvider: cachedImageProvider(mediaUrl(imgs[i])),
              minScale: PhotoViewComputedScale.contained,
              maxScale: PhotoViewComputedScale.covered * 2.5,
              heroAttributes: i == index
                  ? PhotoViewHeroAttributes(
                      tag: SharedElementTags.galleryImage(_post?.id ?? '', i),
                    )
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
          TextEmojiText(
            title,
            style: const TextStyle(
              fontSize: 26,
              height: 1.3,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.6,
              color: Color(AppColors.textPrimary),
            ),
          ),
        if (rest.isNotEmpty) ...[
          const SizedBox(height: 10),
          _HighlightContent(text: rest, topics: p.topic, mentions: p.mentions),
        ],
      ],
    );
  }

  /// 帖子附件：文件卡片，点击后下载到应用私有目录并用系统预览打开。
  Widget _attachmentsBlock() {
    final items = _post!.attachments;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (items.length > 1)
          Padding(
            padding: const EdgeInsets.only(bottom: 7),
            child: Text(
              '附件 · ${items.length}',
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Color(AppColors.textTertiary),
              ),
            ),
          ),
        for (final a in items) _attachmentCard(a),
      ],
    );
  }

  Widget _attachmentCard(PostAttachment a) {
    final busy = _attachmentBusy[a.name] == true;
    final local = _attachmentLocal[a.name];
    final downloaded = local != null && File(local).existsSync();
    final tint = _attachmentTint(a.ext);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: PressableScale(
        onTap: busy ? null : () => _downloadAttachment(a),
        child: Container(
          padding: const EdgeInsets.fromLTRB(11, 10, 10, 10),
          decoration: BoxDecoration(
            color: const Color(AppTheme.card),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: tint.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: tint.withValues(alpha: 0.24)),
                ),
                alignment: Alignment.center,
                child: Icon(_attachmentIcon(a.ext), size: 20, color: tint),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      a.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Color(AppColors.textPrimary),
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${_attachmentKind(a.ext)}'
                      '${a.size > 0 ? ' · ${fileSizeText(a.size)}' : ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 10,
                        color: Color(AppColors.textTertiary),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (busy)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Container(
                  height: 32,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: downloaded
                        ? const Color(AppColors.accentSoft)
                        : const Color(AppColors.elevated),
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                    border: Border.all(
                      color: downloaded
                          ? const Color(AppColors.accent).withValues(alpha: .3)
                          : Colors.white.withValues(alpha: 0.08),
                    ),
                  ),
                  alignment: Alignment.center,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        downloaded
                            ? Icons.open_in_new_rounded
                            : Icons.download_rounded,
                        size: 14,
                        color: downloaded
                            ? const Color(AppColors.accent)
                            : const Color(AppColors.textSecondary),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        downloaded ? '打开' : '下载',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: downloaded
                              ? const Color(AppColors.accent)
                              : const Color(AppColors.textSecondary),
                        ),
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

  Color _attachmentTint(String ext) {
    return switch (ext.toLowerCase()) {
      'pdf' => const Color(AppColors.info),
      'xls' || 'xlsx' || 'csv' => const Color(AppColors.success),
      'ppt' || 'pptx' => const Color(AppColors.warning),
      'zip' || 'rar' || '7z' => const Color(AppColors.warning),
      'txt' || 'md' => const Color(AppColors.accent),
      _ => const Color(AppColors.lilac),
    };
  }

  IconData _attachmentIcon(String ext) {
    return switch (ext.toLowerCase()) {
      'pdf' => Icons.picture_as_pdf_outlined,
      'xls' || 'xlsx' || 'csv' => Icons.table_chart_outlined,
      'ppt' || 'pptx' => Icons.slideshow_outlined,
      'zip' || 'rar' || '7z' => Icons.folder_zip_outlined,
      'txt' || 'md' => Icons.article_outlined,
      _ => Icons.description_outlined,
    };
  }

  String _attachmentKind(String ext) {
    return switch (ext.toLowerCase()) {
      'pdf' => 'PDF 文档',
      'doc' || 'docx' => 'Word 文档',
      'xls' || 'xlsx' => 'Excel 表格',
      'ppt' || 'pptx' => '演示文稿',
      'txt' || 'md' => '文本文件',
      'csv' => 'CSV 表格',
      'zip' || 'rar' || '7z' => '压缩包',
      _ => '文件',
    };
  }

  String _safeAttachmentName(String raw, String fallback) {
    final name = raw.replaceAll('\\', '/').split('/').last.trim();
    final cleaned = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f\x7f]'), '_');
    if (cleaned.isEmpty) return fallback;
    return cleaned.length > 120 ? cleaned.substring(0, 120) : cleaned;
  }

  Future<void> _downloadAttachment(PostAttachment a) async {
    if (_attachmentBusy[a.name] == true) return;
    final known = _attachmentLocal[a.name];
    if (known != null && File(known).existsSync()) {
      await _openAttachmentFile(known);
      return;
    }
    setState(() => _attachmentBusy[a.name] = true);
    http.Client? client;
    File? target;
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory(
        '${docs.path}/post_attachments/${widget.postId}/${a.name}',
      );
      if (!dir.existsSync()) await dir.create(recursive: true);
      final safe = _safeAttachmentName(
        a.label,
        a.ext.isEmpty ? a.name : '${a.name}.${a.ext}',
      );
      target = File('${dir.path}/$safe');
      if (target.existsSync() && target.lengthSync() > 0) {
        if (!mounted) return;
        setState(() => _attachmentLocal[a.name] = target!.path);
        await _openAttachmentFile(target.path);
        return;
      }
      client = http.Client();
      final uri = Uri.parse(a.url);
      if (!SecureLinks.isTrustedApiOrigin(uri)) {
        throw Exception('附件地址不在社区受信任域名');
      }
      final request = http.Request('GET', uri);
      final resp = await client
          .send(request)
          .timeout(const Duration(seconds: 90));
      if (resp.statusCode != 200) {
        throw Exception('HTTP ${resp.statusCode}');
      }
      final sink = target.openWrite();
      await sink.addStream(resp.stream);
      await sink.flush();
      await sink.close();
      final got = target.lengthSync();
      if (got <= 0 || (a.size > 0 && got != a.size)) {
        throw Exception('文件大小校验失败');
      }
      if (!mounted) return;
      setState(() => _attachmentLocal[a.name] = target!.path);
      await _openAttachmentFile(target.path);
    } catch (_) {
      if (target != null && target.existsSync()) {
        try {
          target.deleteSync();
        } catch (_) {}
      }
      if (!mounted) return;
      showAppToast(context, '附件下载失败，请检查网络后重试');
    } finally {
      client?.close();
      if (mounted) setState(() => _attachmentBusy.remove(a.name));
    }
  }

  Future<void> _openAttachmentFile(String path) async {
    try {
      final r = await OpenFilex.open(path);
      if (r.type == ResultType.done) return;
      if (!mounted) return;
      final msg = switch (r.type) {
        ResultType.noAppToOpen => '没有可预览此文件的应用，可分享到其他 App 打开',
        ResultType.permissionDenied => '没有文件访问权限，请到系统设置中开启',
        ResultType.fileNotFound => '文件已失效，请重新下载',
        _ => '打开失败：${r.message}',
      };
      showAppToast(context, msg);
    } catch (_) {
      if (mounted) showAppToast(context, '文件已下载，但暂时无法打开');
    }
  }

  /// 作者行（V16）：封面下方第一行，头像 26 + 昵称 + 时间·话题 + 关注
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
              color: const Color(AppTheme.accent).withValues(alpha: 0.35),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: const BoxDecoration(
                  color: Color(AppTheme.accent),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.music_note_rounded,
                  size: 15,
                  color: Colors.black,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(AppTheme.textPrimary),
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              GestureDetector(
                onTap: () => MusicBgm.I.toggle(),
                child: Container(
                  width: 30,
                  height: 30,
                  decoration: const BoxDecoration(
                    color: Color(AppTheme.card),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
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
  Widget _replyRow() {
    final uid = ApiClient.userId ?? '';
    return PressableScale(
      onTap: _openComments,
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 9, 9, 9),
        decoration: BoxDecoration(
          color: const Color(AppTheme.card),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        ),
        child: Row(
          children: [
            AppAvatar(
              url: uid.isEmpty ? null : avatarUrlOf(uid),
              size: 30,
              verified:
                  verifiedOf(ApiClient.meProfile?['verified']) ||
                  (ApiClient.meProfile?['verifiedLabel'] ?? '')
                      .toString()
                      .trim()
                      .isNotEmpty,
              isAi:
                  boolOf(ApiClient.meProfile?['isAi']) ||
                  (ApiClient.meProfile?['verifiedLabel'] ?? '')
                          .toString()
                          .trim()
                          .toUpperCase() ==
                      'AI',
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '加入这场讨论',
                    style: AppType.label.copyWith(
                      color: const Color(AppTheme.accent),
                      fontSize: 11,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '写下一句真诚的回应…',
                    style: AppType.caption.copyWith(
                      color: const Color(AppTheme.textTertiary),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            Container(
              width: 34,
              height: 34,
              decoration: const BoxDecoration(
                color: Color(AppTheme.accent),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.arrow_upward_rounded,
                size: 17,
                color: Color(AppColors.onAccent),
              ),
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
      final j = await ApiClient.comments(
        widget.postId,
        page: refresh ? 1 : _cPage + 1,
        size: 20,
      );
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
      c['likeCount'] =
          ((c['likeCount'] ?? 0) as num).toInt() + (wasLiked ? -1 : 1);
    });
    try {
      await ApiClient.setCommentLike(cid, liked: !wasLiked);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        c['liked'] = wasLiked;
        c['likeCount'] =
            ((c['likeCount'] ?? 0) as num).toInt() + (wasLiked ? 1 : -1);
      });
    }
  }

  /// 评论卡：用“对话卡”承载头像、徽标、正文与互动，而不是旧版的纯文本行。
  Widget _commentTile(Map<String, dynamic> c) {
    final author = (c['author'] ?? const {}) as Map;
    final name = (author['name'] ?? '用户') as String;
    final avatar = (author['avatar'] ?? '') as String;
    final adminLevel = ((author['adminLevel'] ?? 0) as num).toInt();
    final adminName = (author['adminName'] ?? '') as String;
    final frameId = (author['frameId'] ?? '') as String;
    final verifiedLabel = (author['verifiedLabel'] ?? '').toString().trim();
    final verified = verifiedOf(author['verified']) || verifiedLabel.isNotEmpty;
    final isAi = boolOf(author['isAi']) || verifiedLabel.toUpperCase() == 'AI';
    final content = (c['content'] ?? '') as String;
    final images = (c['images'] ?? const []) as List;
    final sticker = (c['sticker'] ?? '') as String;
    final created = ((c['created'] ?? 0) as num).toInt();
    final liked = (c['liked'] ?? false) == true;
    final likeCount = ((c['likeCount'] ?? 0) as num).toInt();

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
      decoration: BoxDecoration(
        color: const Color(AppTheme.card).withValues(alpha: 0.86),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PressableScale(
            onTap: () {
              final uid = (author['id'] ?? '').toString();
              if (uid.isEmpty) return;
              Navigator.of(
                context,
              ).push(AppPageRoute(builder: (_) => UserProfilePage(uid: uid)));
            },
            scale: 0.92,
            child: AppAvatar(
              url: avatar.isEmpty
                  ? avatarUrlOf((author['id'] ?? '') as String)
                  : avatarUrl(avatar),
              size: 34,
              name: name,
              frameUrl: frameUrlOf(frameId),
              ring: adminLevel > 0,
              verified: verified,
              isAi: isAi,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppType.label.copyWith(
                          color: const Color(AppTheme.textPrimary),
                          fontSize: 12,
                        ),
                      ),
                    ),
                    if (adminLevel > 0) ...[
                      const SizedBox(width: 5),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(AppTheme.accent)
                              .withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          adminName.isEmpty ? '管理员' : adminName,
                          style: const TextStyle(
                            color: Color(AppTheme.accent),
                            fontSize: 8.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                    const Spacer(),
                    Text(
                      timeAgo(created),
                      style: AppType.micro.copyWith(
                        color: const Color(AppTheme.textTertiary),
                        fontSize: 9.5,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                if (sticker.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: CachedNetworkImageCompat(
                      url: mediaUrl(upgradeEmojiMediaPath(sticker)),
                      width: 62,
                      height: 62,
                      fit: BoxFit.contain,
                      placeholder: const SizedBox.shrink(),
                      errorWidget: const SizedBox.shrink(),
                    ),
                  )
                else if (content.isNotEmpty)
                  TextEmojiText(
                    content,
                    style: AppType.bodySm.copyWith(
                      color: const Color(AppTheme.textPrimary),
                      fontSize: 14,
                      height: 1.5,
                    ),
                  ),
                if (images.isNotEmpty) ...[
                  const SizedBox(height: 7),
                  BlurUpImage(
                    url: mediaUrl(images.first.toString()),
                    width: 132,
                    height: 132,
                    borderRadius: 10,
                    fit: BoxFit.cover,
                    cacheWidth: 396,
                  ),
                ],
                const SizedBox(height: 6),
                Row(
                  children: [
                    GestureDetector(
                      onTap: _openComments,
                      child: Text(
                        '回应',
                        style: AppType.micro.copyWith(
                          color: const Color(AppTheme.textSecondary),
                          fontSize: 10.5,
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    GestureDetector(
                      onTap: () => _toggleCommentLike(c),
                      child: Row(
                        children: [
                          Icon(
                            liked
                                ? Icons.favorite_rounded
                                : Icons.favorite_border_rounded,
                            size: 13,
                            color: liked
                                ? const Color(AppTheme.accent)
                                : const Color(AppTheme.textTertiary),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '$likeCount',
                            style: TextStyle(
                              color: liked
                                  ? const Color(AppTheme.accent)
                                  : const Color(AppTheme.textTertiary),
                              fontSize: 10.5,
                            ),
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

  Future<void> _openComments() async {
    if (_post == null) return;
    await showCommentSheet(
      context,
      postId: _post!.id,
      pureInput: true,
      onChanged: (n) {
        if (!mounted) return;
        setState(() => _cCount = n);
      },
    );
    if (!mounted) return;
    // 评论提交后重新拉取一次，避免列表停留在发布前的旧数据。
    await _loadComments(refresh: true);
  }
}

// ---------- 详情页辅助组件 ----------

/// 正文高亮：话题 #xxx（主题色）+ @提及（天蓝），与短视频卡一致
class _HighlightContent extends StatelessWidget {
  final String text;
  final List<String> topics;
  final List<String> mentions;
  const _HighlightContent({
    required this.text,
    required this.topics,
    required this.mentions,
  });

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox.shrink();
    const base = TextStyle(
      color: Color(AppTheme.textPrimary),
      fontSize: 16,
      height: 1.55,
    );
    final RegExp kw = RegExp(
      '(#(?:${topics.map(RegExp.escape).join('|')}))|(@(?:${mentions.map(RegExp.escape).join('|')}))',
    );
    final spans = <InlineSpan>[];
    if (topics.isEmpty && mentions.isEmpty) {
      spans.addAll(textEmojiSpans(text, base));
    } else {
      var last = 0;
      for (final m in kw.allMatches(text)) {
        if (m.start > last) {
          spans.addAll(textEmojiSpans(text.substring(last, m.start), base));
        }
        final isTopic = m.group(1) != null;
        spans.add(
          TextSpan(
            text: m.group(0),
            style: TextStyle(
              color: isTopic
                  ? const Color(AppTheme.lilac)
                  : const Color(AppTheme.sky),
              fontWeight: FontWeight.w600,
            ),
          ),
        );
        last = m.end;
      }
      if (last < text.length) {
        spans.addAll(textEmojiSpans(text.substring(last), base));
      }
    }
    return Text.rich(TextSpan(style: base, children: spans));
  }
}

/// 视频帖详情内嵌播放器：点击播放/暂停，加载失败回退封面
class _InlineVideo extends StatefulWidget {
  final String url;
  final String coverUrl;
  final double borderRadius;
  final int audioVolume;
  final String? heroTag;
  final ImageProvider? coverProvider;
  final ValueChanged<Color>? onToneExtracted;
  final VoidCallback? onToneFailed;
  final ValueChanged<double>? onAspectRatio;
  const _InlineVideo({
    required this.url,
    required this.coverUrl,
    this.borderRadius = 12,
    this.audioVolume = 100,
    this.heroTag,
    this.coverProvider,
    this.onToneExtracted,
    this.onToneFailed,
    this.onAspectRatio,
  });

  @override
  State<_InlineVideo> createState() => _InlineVideoState();
}

class _InlineVideoState extends State<_InlineVideo>
    with RouteAware, WidgetsBindingObserver {
  VideoPlayerController? _vc;
  bool _failed = false;
  bool _controls = false;
  double _frameAspect = 16 / 9;
  ImageStream? _coverStream;
  ImageStreamListener? _coverListener;
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
    _resolveCoverAspect();
    _init();
  }

  void _setFrameAspect(double ratio) {
    final next = ratio.clamp(0.3, 3.0);
    if ((next - _frameAspect).abs() <= 0.001) return;
    if (mounted) setState(() => _frameAspect = next);
    widget.onAspectRatio?.call(next);
  }

  void _resolveCoverAspect() {
    if (widget.coverUrl.trim().isEmpty && widget.coverProvider == null) return;
    final provider =
        widget.coverProvider ?? cachedImageProvider(widget.coverUrl);
    _coverStream = provider.resolve(const ImageConfiguration());
    _coverListener = ImageStreamListener((info, _) {
      final w = info.image.width;
      final h = info.image.height;
      if (w <= 0 || h <= 0) return;
      _setFrameAspect(w / h);
    }, onError: (_, _) {});
    _coverStream!.addListener(_coverListener!);
  }

  void _detachCoverAspect() {
    if (_coverStream != null && _coverListener != null) {
      _coverStream!.removeListener(_coverListener!);
    }
    _coverStream = null;
    _coverListener = null;
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
      // 没有封面尺寸时，至少用视频真实比例，不再固定 16:9。
      if ((_frameAspect - 16 / 9).abs() <= 0.001) {
        _setFrameAspect(c.value.aspectRatio);
      }
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
    v.setVolume(widget.audioVolume / 100.0);
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
    _detachCoverAspect();
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
              // 封面比例决定详情容器；视频用 FittedBox 完整居中，不裁不拉伸。
              aspectRatio: _frameAspect,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Center(
                    child: FittedBox(
                      fit: BoxFit.contain,
                      child: SizedBox(
                        width: v.value.size.width,
                        height: v.value.size.height,
                        child: VideoPlayer(v),
                      ),
                    ),
                  ),
                  // 暂停态给出明确的中心播放入口，不再让用户只能猜底部控制条。
                  if (!v.value.isPlaying && !_failed)
                    Center(
                      child: PressableScale(
                        onTap: () {
                          v.play();
                          _restartHideTimer();
                        },
                        scale: 0.9,
                        child: Container(
                          width: 64,
                          height: 64,
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.46),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.28),
                            ),
                          ),
                          child: const Icon(
                            Icons.play_arrow_rounded,
                            color: Colors.white,
                            size: 34,
                          ),
                        ),
                      ),
                    ),
                  AnimatedOpacity(
                    opacity: _controls ? 1 : 0,
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOutCubic,
                    child: IgnorePointer(
                      ignoring: !_controls,
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        child: VideoControlsBar(
                          controller: v,
                          onAutoHide: () {
                            if (mounted) setState(() => _controls = false);
                          },
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    final cover = ClipRRect(
      borderRadius: BorderRadius.circular(widget.borderRadius),
      child: AspectRatio(
        aspectRatio: _frameAspect,
        child: BlurUpImage(
          url: widget.coverUrl,
          imageProvider: widget.coverProvider,
          fit: BoxFit.cover,
          cacheWidth: 720,
          onToneExtracted: widget.onToneExtracted,
          onToneFailed: widget.onToneFailed,
        ),
      ),
    );
    final tag = widget.heroTag;
    return GestureDetector(
      onTap: _init,
      child: tag == null ? cover : AppHero(tag: tag, child: cover),
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
