/// 短视频单页卡片：全屏沉浸式
/// 复刻音乐 iOS PlayerCard 结构：全屏媒体 + 底部作者行 + 右侧互动列
/// - 播放器懒初始化：进入页面才创建（PageView.builder 天然懒构建）
/// - isActive 切换：当前页 play / 离屏页 pause（高频状态隔离，等效音乐端 isCurrent 优化）
/// - 封面兜底：视频初始化期间展示封面/海报，缓冲时显示加载圈
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:video_player/video_player.dart';

import '../../api/client.dart';
import '../../config.dart';
import '../../design/components.dart';
import '../../services/app_route_observer.dart';
import '../../utils/music_bgm.dart';
import '../../utils/playback_prefs.dart';
import '../../utils/share_util.dart';
import '../../models/feed_item.dart';
import '../mine/login_page.dart';
import '../user/user_profile.dart';
import '../post/post_detail.dart';
import '../../widgets/comment_sheet.dart';
import '../../widgets/video_controls_bar.dart';
import 'dart:async';

class VideoCard extends StatefulWidget {
  final FeedItem item;
  final bool isActive;

  const VideoCard({super.key, required this.item, required this.isActive});

  @override
  State<VideoCard> createState() => _VideoCardState();
}

class _VideoCardState extends State<VideoCard>
    with RouteAware, WidgetsBindingObserver {
  VideoPlayerController? _video;
  bool _failed = false;
  bool _liked = false;
  int _likeCount = 0;
  bool _faved = false;
  int _commentCount = 0;
  int _shareCount = 0;
  bool _followed = false;

  /// 静音（视频原声与配乐一起静音，全局共享：滑到下一条也保持）
  bool _muted = PlaybackPrefs.muted.value;

  /// 三个可见性条件任一为 false 就必须暂停：
  /// - `_routeVisible`：短视频页被别的路由盖住（进了详情/评论等）
  /// - `_tickerEnabled`：所在 Tab 不再活跃（RootPage 的 TickerMode）
  /// - `_appResumed`：App 退到后台
  bool _routeVisible = true;
  bool _tickerEnabled = true;
  bool _appResumed = true;

  /// 真正允许出声的条件：当前页 + 页面可见 + Tab 活跃 + App 在前台
  bool get _shouldPlay =>
      widget.isActive && _routeVisible && _tickerEnabled && _appResumed;

  /// 是否带配乐（有配乐时视频静音、BGM 作为声音，抖音式）
  bool get _useBgm {
    final m = widget.item.music;
    if (m == null) return false;
    final u = m['url'];
    return u is String && u.isNotEmpty;
  }

  bool _controls = false;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    PlaybackPrefs.muted.addListener(_onMuteChanged);
    _liked = widget.item.liked;
    _likeCount = widget.item.likeCount;
    _faved = widget.item.faved;
    _commentCount = widget.item.commentCount;
    _shareCount = widget.item.shareCount;
    if (widget.item.video.isNotEmpty) {
      _initVideo();
    } else {
      // 图文/纯文帖：短视频 tab 同样播放所选配乐（抖音式图集有 BGM）
      _syncBgm();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null) appRouteObserver.subscribe(this, route);

    // RootPage 用 TickerMode 标记「当前活跃的 Tab」：切走 Tab 时这里会收到变化
    final enabled = TickerMode.valuesOf(context).enabled;
    if (enabled != _tickerEnabled) {
      _tickerEnabled = enabled;
      _applyPlayback();
    }
  }

  // ---------------- RouteAware：被别的页面盖住 / 回到本页 ----------------

  @override
  void didPushNext() {
    // 从短视频页 push 了详情/评论等页面：立刻停声
    _routeVisible = false;
    _applyPlayback();
  }

  @override
  void didPopNext() {
    _routeVisible = true;
    _applyPlayback();
  }

  // ---------------- 前后台 ----------------

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final resumed = state == AppLifecycleState.resumed;
    if (resumed == _appResumed) return;
    _appResumed = resumed;
    _applyPlayback();
  }

  Future<void> _initVideo() async {
    setState(() {
      _failed = false;
    });
    try {
      final c = VideoPlayerController.networkUrl(
        Uri.parse(mediaUrl(widget.item.video)),
        videoPlayerOptions: VideoPlayerOptions(
          // 移动端混合模式：视频覆盖层避免系统播放器
          mixWithOthers: true,
        ),
      );
      await c.initialize();
      if (!mounted) {
        c.dispose();
        return;
      }
      setState(() {
        _video = c;
      });
      _applyPlayback();
    } catch (_) {
      if (!mounted) return;
      setState(() => _failed = true);
    }
  }

  /// 配乐同步：只有允许出声且本条带配乐时才播；否则只在「当前播的就是这条」时停，
  /// 避免误停别的页面正在播放的配乐。
  void _syncBgm() {
    final m = widget.item.music;
    final u = m?['url'];
    final hasBgm = u is String && u.isNotEmpty;
    if (_shouldPlay && hasBgm) {
      MusicBgm.I.play(u);
      MusicBgm.I.setMuted(_muted);
      return;
    }
    if (hasBgm && MusicBgm.I.url == u) {
      MusicBgm.I.stop();
    }
  }

  @override
  void didUpdateWidget(covariant VideoCard old) {
    super.didUpdateWidget(old);
    if (old.isActive != widget.isActive) {
      _applyPlayback();
    }
  }

  /// 统一入口：按可见性决定「播还是停」，视频与配乐一起处理。
  void _applyPlayback() {
    final v = _video;
    if (v != null && v.value.isInitialized) {
      if (_shouldPlay) {
        v.setLooping(true);
        v.play();
        v.setVolume((_useBgm || _muted) ? 0 : 1);
      } else {
        v.pause();
        v.setVolume(0);
      }
    }
    _syncBgm();
  }

  /// 别的卡片切换了静音 → 本卡片同步
  void _onMuteChanged() {
    if (!mounted || _muted == PlaybackPrefs.muted.value) return;
    setState(() => _muted = PlaybackPrefs.muted.value);
    _applyPlayback();
  }

  /// 静音开关（视频原声 + 配乐，写入全局）
  void _toggleMute() {
    PlaybackPrefs.muted.value = !_muted;
    setState(() => _muted = PlaybackPrefs.muted.value);
    _applyPlayback();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    PlaybackPrefs.muted.removeListener(_onMuteChanged);
    appRouteObserver.unsubscribe(this);
    _video?.dispose();
    // 只停「自己正在播的」配乐，避免影响别的页面
    final u = widget.item.music?['url'];
    if (u is String && u.isNotEmpty && MusicBgm.I.url == u) {
      MusicBgm.I.stop();
    }
    super.dispose();
  }

  void _toggleControls() {
    setState(() => _controls = !_controls);
    _hideTimer?.cancel();
    if (_controls) {
      _hideTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) setState(() => _controls = false);
      });
    }
  }

  // ---------- 互动 ----------

  Future<void> _toggleLike() async {
    if (ApiClient.token == null) {
      _needLogin();
      return;
    }
    try {
      final r = await ApiClient.setPostLike(widget.item.id, liked: _liked);
      if (!mounted) return;
      setState(() {
        _liked = r['liked'] == true;
        // 服务端返回 likeCount（此前误读 count 导致点赞计数永不更新）
        _likeCount = ((r['likeCount'] ?? _likeCount) as num).toInt();
      });
    } catch (_) {}
  }

  Future<void> _toggleFav() async {
    if (ApiClient.token == null) {
      _needLogin();
      return;
    }
    final next = !_faved;
    setState(() => _faved = next);
    try {
      // faved 传「当前是否已收藏」：true → DELETE 取消，false → POST 收藏
      final r = await ApiClient.toggleFav(widget.item.id, faved: !next);
      if (!mounted) return;
      setState(() => _faved = boolOf(r['faved'], next));
    } catch (_) {
      if (!mounted) return;
      setState(() => _faved = !next);
    }
  }

  Future<void> _toggleFollow() async {
    if (ApiClient.token == null) {
      _needLogin();
      return;
    }
    try {
      final r = await ApiClient.toggleFollow(widget.item.author.id);
      if (!mounted) return;
      setState(() => _followed = boolOf(r['following'], !_followed));
    } catch (_) {}
  }

  Future<void> _share() async {
    try {
      final r = await ApiClient.reportShare(widget.item.id);
      if (!mounted) return;
      // 服务端返回 shareCount（此前误读 count 导致分享计数永不更新）
      setState(() => _shareCount =
          ((r['shareCount'] ?? _shareCount + 1) as num).toInt());
    } catch (_) {
      // 上报失败不影响系统分享
    }
    if (!mounted) return;
    // 当前渲染位置（iPad 上 sharePositionOrigin 必填）
    Rect? origin;
    final ro = context.findRenderObject();
    if (ro is RenderBox && ro.hasSize) {
      origin = ro.localToGlobal(Offset.zero) & ro.size;
    }
    // 系统分享面板：失败由 share_util 内部静默，不影响上面的计数
    await sharePostLink(widget.item.content, widget.item.id, origin: origin);
  }

  /// 打开评论：先弹抖音式完整弹窗（50% 屏高）；
  /// 弹窗内评论列表加载完成后为空 → 自动叠纯输入弹窗并唤起输入法（弹窗内部处理）
  Future<void> _openComments() async {
    await showCommentSheet(
      context,
      postId: widget.item.id,
      autoInputWhenEmpty: true,
      onChanged: (n) {
        if (!mounted) return;
        setState(() => _commentCount = n);
      },
    );
  }

  /// 未登录：弹提示并跳转登录页（登录后自动恢复）
  void _needLogin() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('请先登录（账号与流萤音乐互通）'),
        duration: Duration(seconds: 2),
      ),
    );
    Future<void>.delayed(const Duration(milliseconds: 600), () {
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const LoginPage()),
      );
    });
  }

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      // 点屏幕：调出/隐藏底部控制条（抖音式，3 秒无操作自动隐藏）
      onTap: _toggleControls,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 全屏媒体：视频 / 封面兜底
          _buildMedia(),
          // 底部渐变压暗，保证文字可读
          const _BottomGradient(),
          // 底部：作者行 + 文案
          _buildBottomInfo(),
          // 右侧互动列
          _buildActionRail(),
          // 隐藏式控制条：进度条 + 播放/暂停 + 时长（仅视频初始化后）
          if (_controls &&
              _video != null &&
              _video!.value.isInitialized)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: VideoControlsBar(
                controller: _video!,
                bottomInset: _navBarHeight(context) + 8,
                onAutoHide: () {
                  if (mounted) setState(() => _controls = false);
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildMedia() {
    // 图片/图文帖：全屏铺图（多图左右滑，与抖音图集一致），复用同一布局壳
    if (!widget.item.isVideo) {
      final imgs = widget.item.images;
      if (imgs.isEmpty) return _TextMedia(item: widget.item);
      return _ImageMedia(images: imgs, onDoubleTap: _toggleLike);
    }
    final v = _video;
    if (v != null && v.value.isInitialized && !_failed) {
      return FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: v.value.size.width,
          height: v.value.size.height,
          child: VideoPlayer(v),
        ),
      );
    }
    // 封面兜底（视频初始化中 / 加载失败）
    // cover=auto 时使用转码自动生成的首帧封面（community_video_*.jpg）
    if (widget.item.cover.isNotEmpty && !_failed) {
      final cover = widget.item.cover == 'auto'
          ? '${widget.item.video}.jpg'
          : widget.item.cover;
      return CachedNetworkImage(
        imageUrl: mediaUrl(cover),
        fit: BoxFit.cover,
        placeholder: (_, _) => const _MediaLoading(),
        errorWidget: (_, _, _) => const _MediaLoading(),
      );
    }
    // 加载失败：显示重试
    if (_failed) {
      return PressableScale(
        onTap: _initVideo,
        scale: 0.98,
        child: Container(
          color: const Color(AppColors.canvas),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.refresh_rounded,
                    color: Color(AppColors.textSecondary), size: 34),
                const SizedBox(height: AppSpace.x2),
                Text('视频加载失败，点击重试', style: AppType.caption),
              ],
            ),
          ),
        ),
      );
    }
    return const _MediaLoading();
  }

  Widget _buildBottomInfo() {
    final a = widget.item.author;
    final f = widget.item;
    return Positioned(
      left: 0,
      right: 64,
      bottom: 0,
      child: SafeArea(
        child: Padding(
          // 底部避让透明导航栏：导航栏本体 + 底部安全区 + 间距
          padding: EdgeInsets.fromLTRB(
              AppSpace.x3, 0, AppSpace.x2, AppSpace.x3 + _navBarHeight(context)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // 作者行：昵称 + 认证LOGO（关注入口在右侧操作栏头像上）
              Row(
                children: [
                  Flexible(
                    child: Text(
                      a.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.body.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (a.isAdmin) ...[
                    const SizedBox(width: AppSpace.x1),
                    const _VerifiedBadge(name: '管理员'),
                  ],
                ],
              ),
              const SizedBox(height: AppSpace.x2),
              // 文案：话题高亮 + @提及高亮
              // 图文帖：正文收起两行 + 「展开」按钮，点击进入帖子详情（抖音式）
              if (f.content.isNotEmpty)
                _ContentText(
                  text: f.content,
                  topics: f.topic,
                  mentions: f.mentions,
                  maxLines: widget.item.isVideo ? null : 2,
                ),
              if (!widget.item.isVideo && f.content.isNotEmpty) ...[
                const SizedBox(height: AppSpace.x1),
                PressableScale(
                  onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) =>
                              PostDetailPage(postId: widget.item.id),
                        ),
                      ),
                  child: Text('展开',
                      style: AppType.label
                          .copyWith(color: const Color(AppColors.accent))),
                ),
              ],
              const SizedBox(height: AppSpace.x2),
              // 话题 tag 行
              if (f.topic.isNotEmpty)
                Wrap(
                  spacing: AppSpace.x2,
                  children: [
                    for (final t in f.topic)
                      Text(
                        '#$t',
                        style: AppType.label
                            .copyWith(color: const Color(AppColors.lilac)),
                      ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildActionRail() {
    final a = widget.item.author;
    return Positioned(
      right: AppSpace.x3,
      bottom: AppSpace.x5 + _navBarHeight(context),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 抖音式：作者头像 + 关注加号叠在头像正下方水平居中（上缘遮住头像一点）
            Stack(
              clipBehavior: Clip.none,
              children: [
                _RailAvatar(
                  avatar: a.avatar,
                  size: 48,
                  onTap: a.id.isEmpty
                      ? null
                      : () => Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) => UserProfilePage(uid: a.id)),
                          ),
                ),
                if (!_followed && a.id.isNotEmpty)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: -8,
                    child: Center(
                      child: PressableScale(
                        onTap: _toggleFollow,
                        scale: 0.9,
                        child: Container(
                          width: 22,
                          height: 22,
                          decoration: BoxDecoration(
                            color: const Color(AppColors.heart),
                            shape: BoxShape.circle,
                            border:
                                Border.all(color: Colors.white, width: 1.5),
                          ),
                          child: const Icon(Icons.add,
                              size: 14, color: Colors.white),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: AppSpace.x5),
            _RailAction(
              asset: 'assets/icons/heart.svg',
              color: _liked ? const Color(AppColors.heart) : Colors.white,
              count: _likeCount,
              onTap: _toggleLike,
            ),
            _RailAction(
              asset: 'assets/icons/chatbubble-ellipses.svg',
              count: _commentCount,
              onTap: _openComments,
            ),
            _RailAction(
              asset: 'assets/icons/arrow-redo.svg',
              count: _shareCount,
              onTap: _share,
            ),
            _RailAction(
              asset: 'assets/icons/star.svg',
              color: _faved ? const Color(AppColors.warning) : Colors.white,
              count: 0,
              onTap: _toggleFav,
            ),
            const SizedBox(height: AppSpace.x3),
            // 静音开关（视频原声 + 配乐）
            PressableScale(
              onTap: _toggleMute,
              scale: 0.86,
              child: Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.35),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white.withValues(alpha: 0.35)),
                ),
                child: Icon(
                  _muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                  size: 19,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}


/// 图片/图文帖的全屏媒体区：复用视频卡同一布局壳
/// - 单图：全屏铺满（cover）
/// - 多图：左右滑动切换（与抖音图集一致），右下角页码指示
/// - 双击点赞
class _ImageMedia extends StatefulWidget {
  final List<String> images;
  final VoidCallback onDoubleTap;

  const _ImageMedia({required this.images, required this.onDoubleTap});

  @override
  State<_ImageMedia> createState() => _ImageMediaState();
}

class _ImageMediaState extends State<_ImageMedia> {
  int _idx = 0;

  /// 单张图：宽撑满屏幕、高按原比例自适应、垂直居中（不裁切，抖音图集式）
  Widget _image(String url) => GestureDetector(
        onDoubleTap: widget.onDoubleTap,
        child: Center(
          child: CachedNetworkImage(
            imageUrl: mediaUrl(url),
            fit: BoxFit.fitWidth,
            width: double.infinity,
            placeholder: (_, _) => const _MediaLoading(),
            errorWidget: (_, _, _) => const _MediaLoading(),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final imgs = widget.images;
    if (imgs.length == 1) {
      return _image(imgs.first);
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        PageView.builder(
          itemCount: imgs.length,
          onPageChanged: (i) => setState(() => _idx = i),
          itemBuilder: (_, i) => _image(imgs[i]),
        ),
        // 页码指示（右下角，抖音图集式）
        Positioned(
          right: AppSpace.x3,
          bottom: AppSpace.x4 + _navBarHeight(context),
          child: Container(
            padding: const EdgeInsets.symmetric(
                horizontal: AppSpace.x3, vertical: AppSpace.x1),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.45),
              borderRadius: AppRadius.rSm,
            ),
            child: Text(
              '${_idx + 1}/${imgs.length}',
              style: AppType.numeric.copyWith(color: Colors.white),
            ),
          ),
        ),
      ],
    );
  }
}

// ---------- 子组件 ----------

/// 短视频 tab 透明导航栏高度（本体 54 = 6+22+2+14+6+4 与 _AppTabBar 布局同步）
/// 内容需整体避让，背景（视频画面）可延伸到导航栏区域
double _navBarHeight(BuildContext c) =>
    54 + MediaQuery.viewPaddingOf(c).bottom;

class _BottomGradient extends StatelessWidget {
  const _BottomGradient();
  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      height: MediaQuery.of(context).size.height * 0.42,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [
              Colors.black.withValues(alpha: 0.72),
              Colors.black.withValues(alpha: 0.30),
              Colors.transparent,
            ],
          ),
        ),
      ),
    );
  }
}

class _MediaLoading extends StatelessWidget {
  const _MediaLoading();
  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(AppColors.canvas),
      child: const Center(
        child: SizedBox(
          width: 30,
          height: 30,
          child: CircularProgressIndicator(
            strokeWidth: 2.5,
            color: Color(AppColors.accent),
          ),
        ),
      ),
    );
  }
}

// ignore: unused_element
class _Avatar extends StatelessWidget {
  final dynamic a;
  final double size;
  const _Avatar({required this.a, required this.size});

  @override
  Widget build(BuildContext context) {
    final url = a.avatar;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border:
            Border.all(color: Colors.white.withValues(alpha: 0.35), width: 1),
      ),
      child: ClipOval(
        child: url != null && url.toString().isNotEmpty
            ? CachedNetworkImage(
                imageUrl: url.toString(),
                fit: BoxFit.cover,
                errorWidget: (_, _, _) => const _AvatarFallback(),
              )
            : const _AvatarFallback(),
      ),
    );
  }
}

/// 操作栏作者头像（抖音式）：白描边圆环 + 可点击进主页
class _RailAvatar extends StatelessWidget {
  final String? avatar;
  final double size;
  final VoidCallback? onTap;
  const _RailAvatar(
      {required this.avatar, required this.size, this.onTap});

  @override
  Widget build(BuildContext context) {
    final child = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border:
            Border.all(color: Colors.white.withValues(alpha: 0.6), width: 1.5),
      ),
      child: ClipOval(
        child: avatar != null && avatar!.isNotEmpty
            ? CachedNetworkImage(
                imageUrl: avatar!,
                fit: BoxFit.cover,
                errorWidget: (_, _, _) => const _AvatarFallback(),
              )
            : const _AvatarFallback(),
      ),
    );
    if (onTap == null) return child;
    return PressableScale(onTap: onTap, scale: 0.92, child: child);
  }
}

class _AvatarFallback extends StatelessWidget {
  const _AvatarFallback();
  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(AppColors.elevated),
      child: const Icon(Icons.person,
          color: Color(AppColors.textSecondary), size: 18),
    );
  }
}

class _VerifiedBadge extends StatelessWidget {
  final String name;
  const _VerifiedBadge({required this.name});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpace.x1, vertical: 2),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(AppColors.accent), Color(AppColors.sky)],
        ),
        borderRadius: AppRadius.rXs,
      ),
      child: Text(
        name,
        style: AppType.micro.copyWith(color: Colors.white, height: 1.2),
      ),
    );
  }
}

// ignore: unused_element
class _FollowButton extends StatelessWidget {
  final bool followed;
  final bool self;
  final VoidCallback onTap;
  const _FollowButton(
      {required this.followed, required this.self, required this.onTap});

  @override
  Widget build(BuildContext context) {
    if (self) return const SizedBox.shrink();
    return PressableScale(
      onTap: onTap,
      scale: 0.94,
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpace.x3, vertical: AppSpace.x1),
        decoration: BoxDecoration(
          color: followed
              ? Colors.white.withValues(alpha: 0.16)
              : const Color(AppColors.accent),
          borderRadius: AppRadius.rSm,
        ),
        child: Text(
          followed ? '已关注' : '关注',
          style: AppType.caption.copyWith(
            color: followed
                ? Colors.white.withValues(alpha: 0.85)
                : const Color(AppColors.onAccent),
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

/// 文案：话题与 @提及 高亮（富文本简化渲染）
class _ContentText extends StatelessWidget {
  final String text;
  final List<String> topics;
  final List<String> mentions;
  final int? maxLines;
  const _ContentText(
      {required this.text,
      required this.topics,
      required this.mentions,
      this.maxLines});

  @override
  Widget build(BuildContext context) {
    final spans = <TextSpan>[];
    // 简化：按话题/提及切分高亮
    final RegExp kw = RegExp(
        '(#(?:${topics.map(RegExp.escape).join('|')}))|(@(?:${mentions.map(RegExp.escape).join('|')}))');
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
                ? const Color(AppColors.lilac)
                : const Color(AppColors.sky),
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
        style: AppType.bodySm.copyWith(color: Colors.white, height: 1.45),
        children: spans,
      ),
      maxLines: maxLines,
      overflow: maxLines == null ? TextOverflow.clip : TextOverflow.ellipsis,
    );
  }
}

class _RailAction extends StatelessWidget {
  final String asset; // assets/icons/*.svg（网上下载的开源实心图标）
  final Color color;
  final int count;
  final VoidCallback onTap;
  const _RailAction({
    required this.asset,
    required this.count,
    required this.onTap,
    this.color = Colors.white,
  });

  @override
  Widget build(BuildContext context) {
    return PressableScale(
      onTap: onTap,
      scale: 0.9,
      child: Padding(
        padding: const EdgeInsets.only(bottom: AppSpace.x5),
        child: Column(
          children: [
            // 无圆形卡片背景：网上下载的开源实心图标（抖音式操作栏）
            SvgPicture.asset(
              asset,
              width: 36,
              height: 36,
              colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
            ),
            if (count > 0)
              Padding(
                padding: const EdgeInsets.only(top: AppSpace.x1),
                child: Text(
                  countText(count),
                  style: AppType.numeric.copyWith(color: Colors.white),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 纯文字/投票帖：深色底 + 居中大字正文（避免空媒体一直转圈）
class _TextMedia extends StatelessWidget {
  final FeedItem item;
  const _TextMedia({required this.item});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(AppColors.card), Color(AppColors.canvas)],
        ),
      ),
      alignment: Alignment.center,
      padding: const EdgeInsets.fromLTRB(
          AppSpace.x6, AppSpace.x8, AppSpace.x6, 120),
      child: Text(
        item.content,
        textAlign: TextAlign.center,
        maxLines: 8,
        overflow: TextOverflow.ellipsis,
        style: AppType.h2.copyWith(height: 1.6),
      ),
    );
  }
}
