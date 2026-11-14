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

/// 视频「循环回 0」判定（纯函数，便于单测）：
/// 播放位置从后段突然回跳（且上一刻已过 1 秒）即视为播完一轮回到开头。
/// - `prev`：上一帧位置（秒）；`pos`：当前位置（秒）
bool videoLoopRestartDetected(double? prev, double pos) {
  if (prev == null) return false;
  if (prev <= 1.0) return false;
  return pos < prev - 0.3;
}

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

  /// 初值必须保守为 false：RootPage 五个 Tab 常驻构建，短视频页在后台也会 initState，
  /// 若这里默认 true，图文卡片的首次配乐同步会脱离真实可见性直接出声（「一开 App 就有歌」）。
  /// 真实值在 didChangeDependencies 里由 TickerMode 读取后覆盖。
  bool _tickerEnabled = false;
  bool _appResumed = true;

  /// 真正允许出声的条件：当前页 + 页面可见 + Tab 活跃 + App 在前台
  bool get _shouldPlay =>
      widget.isActive && _routeVisible && _tickerEnabled && _appResumed;

  /// 是否带配乐（有配乐时原声照常播放，两路混音，音量取自发布者设定）
  bool get _useBgm {
    final m = widget.item.music;
    if (m == null) return false;
    final u = m['url'];
    return u is String && u.isNotEmpty;
  }

  /// 是否视频内容（视频内容的配乐要与视频时间轴对齐）
  bool get _isVideoItem => widget.item.video.isNotEmpty;

  /// 原声音量（发布者设定 0-100 → 0-1）
  double get _audioVol => widget.item.audioVolume / 100.0;

  /// 配乐音量（发布者设定 0-100 → 0-1）
  double get _bgmVol => widget.item.musicVolume / 100.0;

  bool _controls = false;

  /// 上一次视频播放位置（秒）：用于识别视频「循环回 0」并把配乐同步归零
  double? _lastVideoPos;
  bool _lastVideoPlaying = false;

  /// 是否是本卡片启动了当前这路配乐（避免相邻卡片同一首配乐互相误停）
  bool _bgmOwner = false;
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
    }
    // 图文/纯文帖的配乐**不能在这里起播**：initState 阶段 TickerMode（Tab 是否活跃）
    // 与路由可见性都还没拿到，短视频页在后台被常驻构建时会立刻出声。
    // 首次同步统一放到 didChangeDependencies 之后（见 _firstSyncDone）。
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
    if (!_firstSyncDone) {
      _firstSyncDone = true;
      // 首帧之后再走一次统一入口：此时 Tab 活跃状态已确定，
      // 活跃的图文/纯文帖能正常起播，后台 Tab 的卡片则保持静默。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _applyPlayback();
      });
    }
  }

  /// 首次「可见性判定 + 起播」是否已完成（防止 initState 期间误起播）
  bool _firstSyncDone = false;

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
      c.addListener(_onVideoTick);
      _applyPlayback();
    } catch (_) {
      if (!mounted) return;
      setState(() => _failed = true);
    }
  }

  /// 配乐同步：
  /// - 有配乐时原声不静音，两路按发布者设定的音量混播；
  /// - 视频内容：配乐与视频同起点，视频循环回 0 时配乐也从 0 重来（见 `_onVideoTick`）；
  /// - 图集/图文：整首无限循环，轮播换图不重置进度。
  void _syncBgm() {
    final m = widget.item.music;
    final u = m?['url'];
    if (u is! String || u.isEmpty) return;
    final vol = _muted ? 0.0 : _bgmVol;

    if (!_shouldPlay) {
      // 只停「自己启动的那一路」，避免相邻卡片共用同一首配乐时互相误停
      if (_bgmOwner && MusicBgm.I.url == u) {
        MusicBgm.I.pause();
        _bgmOwner = false;
      }
      return;
    }

    if (_isVideoItem) {
      final v = _video;
      final playing = v != null && v.value.isInitialized && v.value.isPlaying;
      if (!playing) {
        if (_bgmOwner && MusicBgm.I.url == u) {
          MusicBgm.I.pause();
          _bgmOwner = false;
        }
        return;
      }
      if (MusicBgm.I.url != u) {
        // 新曲：与视频起点对齐
        MusicBgm.I.playFrom(u, loop: true, volume: vol);
      } else {
        // 已在播/已暂停过的同一首：只调音量，不动进度
        MusicBgm.I.setVolume(vol);
        MusicBgm.I.resume();
      }
      _bgmOwner = true;
      return;
    }

    // 图集/图文：整首循环
    MusicBgm.I.play(u, loop: true, volume: vol);
    _bgmOwner = true;
  }

  /// 视频逐帧回调：识别「起播/暂停」与「循环回 0」，让配乐与视频时间轴对齐
  void _onVideoTick() {
    final v = _video;
    if (v == null || !v.value.isInitialized) return;
    final pos = v.value.position.inMilliseconds / 1000.0;
    final prev = _lastVideoPos;
    _lastVideoPos = pos;
    final playing = v.value.isPlaying;
    if (playing != _lastVideoPlaying) {
      _lastVideoPlaying = playing;
      // 视频真正开始播了（play() 是异步生效的，_applyPlayback 那一刻可能还没播起来）
      if (playing) _syncBgm();
    }
    if (!_useBgm || !_bgmOwner || prev == null) return;
    // 位置回跳且上一刻在视频前段之后 → 视频完成了一次循环，配乐也回 0
    if (videoLoopRestartDetected(prev, pos)) {
      MusicBgm.I.restart();
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
  /// 有配乐不再是「视频静音」，而是原声按发布者音量 + 配乐按发布者音量混播。
  void _applyPlayback() {
    final v = _video;
    if (v != null && v.value.isInitialized) {
      if (_shouldPlay) {
        v.setLooping(true);
        v.play();
        v.setVolume(_muted ? 0 : _audioVol);
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
    _video?.removeListener(_onVideoTick);
    _video?.dispose();
    // 只停「自己启动的那一路」配乐，避免影响别的卡片/页面
    final u = widget.item.music?['url'];
    if (_bgmOwner && u is String && u.isNotEmpty && MusicBgm.I.url == u) {
      MusicBgm.I.stop();
    }
    _bgmOwner = false;
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
      setState(
        () =>
            _shareCount = ((r['shareCount'] ?? _shareCount + 1) as num).toInt(),
      );
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
      Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => const LoginPage()));
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
          // 播放进度：常驻细线，紧贴导航栏上沿
          _buildSeekLine(context),
          // 隐藏式控制条：进度条 + 播放/暂停 + 时长（仅视频初始化后）
          if (_controls && _video != null && _video!.value.isInitialized)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: VideoControlsBar(
                controller: _video!,
                bottomInset: _navBarHeight(context) + 14,
                onAutoHide: () {
                  if (mounted) setState(() => _controls = false);
                },
              ),
            ),
        ],
      ),
    );
  }

  /// 常驻播放进度：2px 细线贴住导航栏上沿（抖音式），不再藏在点击控制条里
  Widget _buildSeekLine(BuildContext context) {
    final v = _video;
    if (!widget.isActive || v == null) return const SizedBox.shrink();
    return Positioned(
      left: 0,
      right: 0,
      bottom: _navBarHeight(context),
      child: ValueListenableBuilder<VideoPlayerValue>(
        valueListenable: v,
        builder: (_, value, _) {
          final total = value.duration.inMilliseconds;
          final p = total <= 0
              ? 0.0
              : (value.position.inMilliseconds / total).clamp(0.0, 1.0);
          return SizedBox(
            height: 2,
            child: LinearProgressIndicator(
              value: p.toDouble(),
              minHeight: 2,
              backgroundColor: Colors.white.withValues(alpha: 0.12),
              valueColor: AlwaysStoppedAnimation<Color>(
                Colors.white.withValues(alpha: 0.92),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildMedia() {
    // 图片/图文帖：全屏铺图（多图左右滑，与抖音图集一致），复用同一布局壳
    if (!widget.item.isVideo) {
      final imgs = widget.item.images;
      if (imgs.isEmpty) return _TextMedia(item: widget.item);
      return _ImageMedia(
        images: imgs,
        onDoubleTap: _toggleLike,
        isActive: widget.isActive,
      );
    }
    final v = _video;
    if (v != null && v.value.isInitialized && !_failed) {
      return FittedBox(
        // contain：按真实比例完整显示、居中，不充满全屏、不裁切，留黑边
        fit: BoxFit.contain,
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
        fit: BoxFit.contain, // 与视频一致：完整居中，不 cover 裁切
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
                const Icon(
                  Icons.refresh_rounded,
                  color: Color(AppColors.textSecondary),
                  size: 34,
                ),
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
            AppSpace.x3,
            0,
            AppSpace.x2,
            AppSpace.x3 + _navBarHeight(context),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // 作者行：昵称 + 认证LOGO（关注入口在右侧操作栏头像上）
              Row(
                children: [
                  Flexible(
                    child: Text(
                      '@${a.name}',
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
                  maxLines: 3,
                ),
              if (!widget.item.isVideo && f.content.isNotEmpty) ...[
                const SizedBox(height: AppSpace.x1),
                PressableScale(
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => PostDetailPage(postId: widget.item.id),
                    ),
                  ),
                  child: Text(
                    '展开',
                    style: AppType.label.copyWith(
                      color: const Color(AppColors.accent),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: AppSpace.x2),
              // 原声行：唱片图标 + 原声名（设计稿 capbar 第三行）
              if (f.music != null && (f.music!['name'] ?? '') != '') ...[
                const SizedBox(height: AppSpace.x2),
                Row(
                  children: [
                    Container(
                      width: 16,
                      height: 16,
                      decoration: const BoxDecoration(
                        color: Colors.white12,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.play_arrow_rounded,
                          size: 11, color: Colors.white),
                    ),
                    const SizedBox(width: 5),
                    Flexible(
                      child: Text(
                        '原声 · ${f.music!['name']}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppType.micro.copyWith(
                          fontSize: 11.5,
                          color: Colors.white70,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              // 话题 tag 行
              if (f.topic.isNotEmpty)
                Wrap(
                  spacing: AppSpace.x2,
                  children: [
                    for (final t in f.topic)
                      Text(
                        '#$t',
                        style: AppType.label.copyWith(
                          color: const Color(AppColors.lilac),
                        ),
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
                            builder: (_) => UserProfilePage(uid: a.id),
                          ),
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
                            border: Border.all(color: Colors.white, width: 1.5),
                          ),
                          child: const Icon(
                            Icons.add,
                            size: 14,
                            color: Colors.white,
                          ),
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
              trigger: _liked,
              onTap: _toggleLike,
            ),
            _RailAction(
              asset: 'assets/icons/chatbubble-ellipses.svg',
              count: _commentCount,
              trigger: _commentCount,
              onTap: _openComments,
            ),
            _RailAction(
              asset: 'assets/icons/star.svg',
              color: _faved ? const Color(AppColors.accent) : Colors.white,
              count: 0,
              trigger: _faved,
              onTap: _toggleFav,
            ),
            _RailAction(
              asset: 'assets/icons/arrow-redo.svg',
              count: _shareCount,
              trigger: _shareCount,
              onTap: _share,
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
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.35),
                  ),
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
  final bool isActive;

  const _ImageMedia({
    required this.images,
    required this.onDoubleTap,
    required this.isActive,
  });

  @override
  State<_ImageMedia> createState() => _ImageMediaState();
}

class _ImageMediaState extends State<_ImageMedia>
    with SingleTickerProviderStateMixin {
  /// 每张图停留时长（抖音图集节奏，进度条走完即切下一张）
  static const _perImage = Duration(seconds: 3);

  final PageController _pc = PageController();
  AnimationController? _ac;
  int _idx = 0;
  bool _program = false; // 区分程序化翻页与手动滑动

  @override
  void initState() {
    super.initState();
    if (widget.images.length > 1) {
      _ac = AnimationController(vsync: this, duration: _perImage)
        ..addStatusListener((s) {
          if (s == AnimationStatus.completed) _advance();
        });
      if (widget.isActive) _ac!.forward();
    }
  }

  /// 自动翻到下一页；到最后一页停住（抖音图集播完停在最后，不回滚）
  void _advance() {
    if (!mounted) return;
    final n = widget.images.length;
    if (_idx >= n - 1) {
      // 无限连续：最后一张后无缝回绕到第一张（jump 瞬间切换，不播回滚动画）
      _program = true;
      _pc.jumpToPage(0);
      setState(() => _idx = 0);
      _ac!
        ..reset()
        ..forward();
      return;
    }
    final next = _idx + 1;
    _program = true;
    _pc.animateToPage(
      next,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
    setState(() => _idx = next);
    _ac!
      ..reset()
      ..forward();
  }

  /// 手动滑动：重置当前段进度，从新位置继续自动轮播
  void _onManual(int i) {
    if (_program) {
      _program = false; // 程序化翻页触发的回调，忽略
      return;
    }
    setState(() => _idx = i);
    final ac = _ac;
    if (ac == null) return;
    ac.reset();
    if (widget.isActive) ac.forward(); // 无限循环：手动到任意页都继续
  }

  @override
  void didUpdateWidget(covariant _ImageMedia old) {
    super.didUpdateWidget(old);
    if (old.isActive != widget.isActive) {
      final ac = _ac;
      if (ac == null) return;
      if (widget.isActive) {
        ac.forward(); // 回到屏幕：无限循环，任意页都继续
      } else {
        ac.stop(); // 离屏暂停自动轮播
      }
    }
  }

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

  /// 抖音式分段进度条：已看=全白，当前=进度动画，未到=半透明
  Widget _segment(int i) {
    const h = 3.0;
    if (i < _idx) {
      return Container(height: h, color: Colors.white);
    }
    if (i > _idx) {
      return Container(height: h, color: Colors.white.withValues(alpha: 0.35));
    }
    return Container(
      height: h,
      color: Colors.white.withValues(alpha: 0.35),
      child: Align(
        alignment: Alignment.centerLeft,
        child: AnimatedBuilder(
          animation: _ac!,
          builder: (_, _) => FractionallySizedBox(
            widthFactor: _ac!.value.clamp(0.0, 1.0),
            child: Container(height: h, color: Colors.white),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _pc.dispose();
    _ac?.dispose();
    super.dispose();
  }

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
          controller: _pc,
          itemCount: imgs.length,
          onPageChanged: _onManual,
          itemBuilder: (_, i) => _image(imgs[i]),
        ),
        // 顶部轻微暗化：保证白色分段条在任何颜色图片上都清晰（抖音式）
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          height: MediaQuery.viewPaddingOf(context).top + 26,
          child: DecoratedBox(
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
          ),
        ),
        // 抖音式顶部分段进度条（状态栏下方，已看段数即当前位置）
        Positioned(
          left: 12,
          right: 12,
          top: MediaQuery.viewPaddingOf(context).top + 8,
          child: Row(
            children: List.generate(imgs.length, (i) {
              return Expanded(
                child: Padding(
                  padding: EdgeInsets.only(right: i == imgs.length - 1 ? 0 : 4),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: _segment(i),
                  ),
                ),
              );
            }),
          ),
        ),
      ],
    );
  }
}

// ---------- 子组件 ----------

/// 短视频 tab 透明导航栏高度（本体 54 = 6+22+2+14+6+4 与 _AppTabBar 布局同步）
/// 内容需整体避让，背景（视频画面）可延伸到导航栏区域
double _navBarHeight(BuildContext c) => 58 + MediaQuery.viewPaddingOf(c).bottom;

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
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.35),
          width: 1,
        ),
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
  const _RailAvatar({required this.avatar, required this.size, this.onTap});

  @override
  Widget build(BuildContext context) {
    final child = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.6),
          width: 1.5,
        ),
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
      child: const Icon(
        Icons.person,
        color: Color(AppColors.textSecondary),
        size: 18,
      ),
    );
  }
}

class _VerifiedBadge extends StatelessWidget {
  final String name;
  const _VerifiedBadge({required this.name});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.x1, vertical: 2),
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
  const _FollowButton({
    required this.followed,
    required this.self,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    if (self) return const SizedBox.shrink();
    return PressableScale(
      onTap: onTap,
      scale: 0.94,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpace.x3,
          vertical: AppSpace.x1,
        ),
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
  const _ContentText({
    required this.text,
    required this.topics,
    required this.mentions,
    this.maxLines,
  });

  @override
  Widget build(BuildContext context) {
    final spans = <TextSpan>[];
    // 简化：按话题/提及切分高亮
    final RegExp kw = RegExp(
      '(#(?:${topics.map(RegExp.escape).join('|')}))|(@(?:${mentions.map(RegExp.escape).join('|')}))',
    );
    if (topics.isEmpty && mentions.isEmpty) {
      spans.add(TextSpan(text: text));
    } else {
      var last = 0;
      for (final m in kw.allMatches(text)) {
        if (m.start > last) {
          spans.add(TextSpan(text: text.substring(last, m.start)));
        }
        final isTopic = m.group(1) != null;
        spans.add(
          TextSpan(
            text: m.group(0),
            style: TextStyle(
              color: isTopic
                  ? const Color(AppColors.lilac)
                  : const Color(AppColors.sky),
              fontWeight: FontWeight.w600,
            ),
          ),
        );
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

  /// 状态值变化时图标弹一下（点赞、收藏、分享计数）
  final Object? trigger;
  const _RailAction({
    required this.asset,
    required this.count,
    required this.onTap,
    this.color = Colors.white,
    this.trigger,
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
            BounceOnChange(
              trigger: trigger,
              child: SvgPicture.asset(
                asset,
                width: 36,
                height: 36,
                colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
              ),
            ),
            if (count > 0)
              Padding(
                padding: const EdgeInsets.only(top: AppSpace.x1),
                child: RollingCount(
                  value: count,
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
        AppSpace.x6,
        AppSpace.x8,
        AppSpace.x6,
        120,
      ),
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
