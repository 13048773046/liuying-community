/// 短视频单页卡片：全屏沉浸式
/// 复刻音乐 iOS PlayerCard 结构：全屏媒体 + 底部作者行 + 右侧互动列
/// - 播放器懒初始化：进入页面才创建（PageView.builder 天然懒构建）
/// - isActive 切换：当前页 play / 离屏页 pause（高频状态隔离，等效音乐端 isCurrent 优化）
/// - 封面兜底：视频初始化期间展示封面/海报，缓冲时显示加载圈
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

import '../../api/client.dart';
import '../../config.dart';
import '../../design/components.dart';
import '../../features/emoji/text_emoji.dart';
import '../../services/app_route_observer.dart';
import '../../services/follow_bus.dart';
import '../../utils/music_bgm.dart';
import '../../utils/playback_prefs.dart';
import '../../models/feed_item.dart';
import '../mine/login_page.dart';
import '../user/user_profile.dart';
import '../post/post_detail.dart';
import '../share/share_target_sheet.dart';
import '../../widgets/comment_sheet.dart';

import 'dart:async';
import 'dart:ui' as ui;

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
  final int index;
  final int total;
  final VoidCallback? onNotInterested;

  const VideoCard({
    super.key,
    required this.item,
    required this.isActive,
    this.index = 0,
    this.total = 0,
    this.onNotInterested,
  });

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
  bool _followKnown = false;
  bool _followLoading = false;
  bool _followBusy = false;
  Future<void>? _followRequest;

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
      widget.isActive &&
      _routeVisible &&
      _tickerEnabled &&
      _appResumed &&
      !_manualPaused;

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

  /// 用户手动暂停：与「路由不可见/切 Tab/后台」分开，避免自动播放逻辑把它覆盖。
  bool _manualPaused = false;
  double _speed = 1.0;
  double _resumeAt = 0;
  int _lastSavedMs = 0;

  /// 双击点赞的大爱心动画序号：每次双击自增，作为动画 key 重新触发。
  int _burstId = 0;

  /// 上一次视频播放位置（秒）：用于识别视频「循环回 0」并把配乐同步归零
  double? _lastVideoPos;
  bool _lastVideoPlaying = false;

  /// 是否是本卡片启动了当前这路配乐（避免相邻卡片同一首配乐互相误停）
  bool _bgmOwner = false;

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
    _followed = widget.item.author.following;
    _followKnown = widget.item.author.followingKnown;
    FollowBus.relations.addListener(_onFollowBus);
    // 只有接口真的下发了 following 才写总线；未知状态写 false 会让别的页面误以为未关注。
    if (_followKnown) FollowBus.setRelation(widget.item.author.id, _followed);
    if (widget.item.video.isNotEmpty) {
      unawaited(_restoreProgress());
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
        if (!mounted) return;
        _applyPlayback();
        _syncFollowRelation();
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
    // 从作者主页返回时他可能刚点过关注/取关，强制补拉一次关系，避免「+」状态过期。
    _syncFollowRelation(force: true);
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
      _seekResume(c);
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
    // 每 5 秒落一次播放进度，滑走/杀进程后下次能续播。
    final ms = v.value.position.inMilliseconds;
    if (ms - _lastSavedMs >= 5000) {
      _lastSavedMs = ms;
      unawaited(_persistProgress());
    }
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
      if (widget.isActive) {
        _manualPaused = false;
        _syncFollowRelation();
      } else {
        unawaited(_persistProgress());
      }
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

  @override
  void dispose() {
    unawaited(_persistProgress());
    FollowBus.relations.removeListener(_onFollowBus);
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

  /// 手动播放/暂停：单点画面或中央播放键，暂停后不再被自动播放覆盖。
  void _togglePlayPause() {
    final v = _video;
    if (v == null || !v.value.isInitialized) return;
    HapticFeedback.lightImpact();
    if (v.value.isPlaying) {
      v.pause();
      setState(() => _manualPaused = true);
    } else {
      setState(() => _manualPaused = false);
      v.play();
    }
    _syncBgm();
  }

  // ---------- 互动 ----------

  Future<void> _toggleLike() async {
    HapticFeedback.lightImpact();
    if (ApiClient.token == null) {
      _needLogin();
      return;
    }
    // 先本地切换再请求：点击即刻有反馈，失败回滚
    final next = !_liked;
    setState(() {
      _liked = next;
      _likeCount += next ? 1 : -1;
    });
    try {
      final r = await ApiClient.setPostLike(widget.item.id, liked: next);
      if (!mounted) return;
      setState(() {
        _liked = r['liked'] == true;
        _likeCount = ((r['likeCount'] ?? _likeCount) as num).toInt();
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _liked = !next;
        _likeCount += next ? -1 : 1;
      });
    }
  }

  Future<void> _toggleFav() async {
    HapticFeedback.lightImpact();
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

  /// 信息流不一定携带 following；当前卡片激活时补拉一次轻量主页接口。
  void _syncFollowRelation({bool force = false}) {
    final id = widget.item.author.id;
    if (!mounted || !widget.isActive || id.isEmpty) return;
    if (ApiClient.token == null) {
      // 未登录时仍显示「+」，点击后会走登录引导。
      if (!_followKnown && mounted) setState(() => _followKnown = true);
      return;
    }
    if (!force && _followKnown) return;
    if (_followRequest != null) return;
    final future = _fetchFollowRelation(id);
    _followRequest = future;
    future.whenComplete(() {
      _followRequest = null;
    });
  }

  void _onFollowBus() {
    final id = widget.item.author.id;
    if (!mounted || id.isEmpty) return;
    final next = FollowBus.relationOf(id);
    if (next != null && next != _followed) {
      setState(() {
        _followed = next;
        _followKnown = true;
      });
    }
  }

  Future<void> _fetchFollowRelation(String id) async {
    if (mounted) setState(() => _followLoading = true);
    try {
      final following = await FollowBus.sync(id, force: true);
      if (!mounted) return;
      setState(() {
        if (following != null) {
          _followed = following;
          _followKnown = true;
        }
        _followLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _followLoading = false);
    }
  }

  Future<void> _toggleFollow() async {
    if (_followBusy) return;
    HapticFeedback.lightImpact();
    if (ApiClient.token == null) {
      _needLogin();
      return;
    }
    // 关系未知时先拉状态：避免用户其实已关注，点「+」反而触发取关。
    if (!_followKnown) {
      _syncFollowRelation(force: true);
      final pending = _followRequest;
      if (pending != null) await pending;
      if (!_followKnown) {
        if (mounted) showAppToast(context, '关注状态获取失败，请稍后再试');
        return;
      }
    }
    if (_followed) return;
    setState(() => _followBusy = true);
    try {
      final next = await FollowBus.toggle(widget.item.author.id);
      if (!mounted) return;
      setState(() {
        _followed = next;
        _followKnown = true;
        _followBusy = false;
      });
      if (_followed) showAppToast(context, '已关注 ${widget.item.author.name}');
    } catch (_) {
      if (!mounted) return;
      setState(() => _followBusy = false);
      showAppToast(context, '关注失败，请检查网络');
    }
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
    if (!mounted) return;
    final f = widget.item;
    final cover = f.cover.isNotEmpty
        ? f.cover
        : (f.images.isNotEmpty ? f.images.first : '');
    await showPostShareSheet(
      context,
      postId: f.id,
      title: f.content,
      cover: cover,
    );
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
    final v = _video;
    final videoReady = v != null && v.value.isInitialized && !_failed;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // 单点暂停/继续；双击点赞并放大爱心。图集的单击留给左右滑动。
      onTap: widget.item.isVideo ? _togglePlayPause : null,
      onDoubleTap: widget.item.images.isEmpty ? _handleDoubleTapLike : null,
      onLongPress: _openMoreMenu,
      child: Stack(
        fit: StackFit.expand,
        children: [
          _buildAmbientBackdrop(),
          _buildMedia(),
          const _CinemaVignette(),
          if (videoReady && _manualPaused) _buildPausedBadge(),
          // 抖音式结构：右侧竖排互动，左下作者/文案/原声，底部一条细进度线。
          _buildBottomInfo(context),
          _buildActionRail(context),
          if (videoReady) _buildSeekLine(context),
          if (_burstId > 0)
            Positioned.fill(
              child: IgnorePointer(
                child: Center(
                  child: _DoubleTapHeart(key: ValueKey('burst_$_burstId')),
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _handleDoubleTapLike() {
    HapticFeedback.mediumImpact();
    setState(() => _burstId++);
    if (!_liked) _toggleLike();
  }

  /// 封面氛围底：视觉上属于媒体而不是卡片，模糊到只剩色调。
  Widget _buildAmbientBackdrop() {
    final f = widget.item;
    // 视频用封面、图集用首图做整屏氛围底；纯文字帖交给 _TextMedia 自绘。
    final rawCover = f.isVideo
        ? (f.cover == 'auto' ? '${f.video}.jpg' : f.cover)
        : (f.images.isNotEmpty ? f.images.first : '');
    if (rawCover.isEmpty) {
      return f.isVideo || f.images.isNotEmpty
          ? const ColoredBox(color: Color(0xFF070808))
          : const SizedBox.expand();
    }
    final cover = rawCover;
    return Positioned.fill(
      child: Stack(
        fit: StackFit.expand,
        children: [
          RepaintBoundary(
            child: ImageFiltered(
              // 氛围底只需要色块，不需要高清：解码限制到 480 宽、半径收到 24，
              // 避免短视频上下滑时每帧对整屏做 34px 高斯模糊。
              imageFilter: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
              child: CachedNetworkImage(
                imageUrl: mediaUrl(cover),
                fit: BoxFit.cover,
                memCacheWidth: 480,
                filterQuality: FilterQuality.low,
                fadeInDuration: const Duration(milliseconds: 180),
                errorWidget: (_, _, _) =>
                    const ColoredBox(color: Color(0xFF070808)),
              ),
            ),
          ),
          Container(color: Colors.black.withValues(alpha: 0.58)),
        ],
      ),
    );
  }

  Widget _buildPausedBadge() {
    return Center(
      child: PressableScale(
        onTap: _togglePlayPause,
        scale: 0.92,
        child: Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.46),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white.withValues(alpha: 0.28)),
          ),
          child: const Icon(
            Icons.play_arrow_rounded,
            color: Colors.white,
            size: 38,
          ),
        ),
      ),
    );
  }

  String get _progressKey => 'shorts_pos_${widget.item.id}';

  Future<void> _restoreProgress() async {
    try {
      final sp = await SharedPreferences.getInstance();
      _resumeAt = sp.getDouble(_progressKey) ?? 0;
      final v = _video;
      if (v != null && v.value.isInitialized) _seekResume(v);
    } catch (_) {}
  }

  void _seekResume(VideoPlayerController v) {
    if (_resumeAt <= 0.5 || !v.value.isInitialized) return;
    final total = v.value.duration.inMilliseconds / 1000.0;
    if (total <= 0 || _resumeAt >= total - 1.5) return;
    unawaited(v.seekTo(Duration(milliseconds: (_resumeAt * 1000).round())));
  }

  Future<void> _persistProgress() async {
    final v = _video;
    if (v == null || !v.value.isInitialized) return;
    final sec = v.value.position.inMilliseconds / 1000.0;
    if (sec <= 0.5) return;
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setDouble(_progressKey, sec);
    } catch (_) {}
  }

  Future<void> _setSpeed(double speed) async {
    final v = _video;
    if (v == null || !v.value.isInitialized) return;
    await v.setPlaybackSpeed(speed);
    if (!mounted) return;
    setState(() => _speed = speed);
  }

  void _openMoreMenu() {
    HapticFeedback.mediumImpact();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => SafeArea(
        top: false,
        child: Container(
          margin: const EdgeInsets.all(10),
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
            color: const Color(AppColors.elevated),
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: Border.all(color: const Color(AppColors.border)),
            boxShadow: AppEffects.overlay,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _menuTile(
                icon: Icons.speed_rounded,
                label: '倍速播放',
                trailing: '${_speed.toStringAsFixed(_speed == 1 ? 0 : 2)}×',
                onTap: () {
                  Navigator.pop(ctx);
                  _pickSpeed();
                },
              ),
              _menuTile(
                icon: Icons.visibility_off_outlined,
                label: '不感兴趣',
                onTap: () {
                  Navigator.pop(ctx);
                  widget.onNotInterested?.call();
                  showAppToast(context, '已减少此类内容');
                },
              ),
              _menuTile(
                icon: Icons.bookmark_add_outlined,
                label: '保存 / 分享',
                onTap: () {
                  Navigator.pop(ctx);
                  _share();
                },
              ),
              _menuTile(
                icon: Icons.flag_outlined,
                label: '举报',
                danger: true,
                onTap: () {
                  Navigator.pop(ctx);
                  _report();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _menuTile({
    required IconData icon,
    required String label,
    String? trailing,
    bool danger = false,
    required VoidCallback onTap,
  }) {
    final color = danger
        ? const Color(AppColors.heart)
        : const Color(AppColors.textPrimary);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        child: Row(
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: AppType.bodySm.copyWith(
                  color: color,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (trailing != null)
              Text(
                trailing,
                style: AppType.micro.copyWith(
                  color: const Color(AppColors.textSecondary),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickSpeed() async {
    final picked = await showModalBottomSheet<double>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => SafeArea(
        top: false,
        child: Container(
          margin: const EdgeInsets.all(10),
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 22),
          decoration: BoxDecoration(
            color: const Color(AppColors.elevated),
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: Border.all(color: const Color(AppColors.border)),
            boxShadow: AppEffects.overlay,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '播放倍速',
                style: AppType.bodySm.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final s in const [0.75, 1.0, 1.25, 1.5, 2.0])
                    GestureDetector(
                      onTap: () => Navigator.pop(ctx, s),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 9,
                        ),
                        decoration: BoxDecoration(
                          color: s == _speed
                              ? const Color(AppColors.accent)
                                    .withValues(alpha: 0.18)
                              : const Color(AppColors.card),
                          borderRadius: BorderRadius.circular(99),
                          border: Border.all(
                            color: s == _speed
                                ? const Color(AppColors.accent)
                                : const Color(AppColors.hairline),
                          ),
                        ),
                        child: Text(
                          '${s.toStringAsFixed(s == 1 ? 0 : 2)}×',
                          style: AppType.bodySm.copyWith(
                            fontWeight: FontWeight.w700,
                            color: s == _speed
                                ? const Color(AppColors.accent)
                                : const Color(AppColors.textSecondary),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (picked != null) await _setSpeed(picked);
  }

  Future<void> _report() async {
    if (ApiClient.token == null) {
      _needLogin();
      return;
    }
    try {
      await ApiClient.report('post', widget.item.id, '短视频内容举报');
      if (!mounted) return;
      showAppToast(context, '已收到举报，我们会尽快处理');
    } catch (e) {
      if (!mounted) return;
      showAppToast(context, e is ApiException ? e.message : '举报失败，请稍后重试');
    }
  }

  void _openAuthor() {
    final id = widget.item.author.id;
    if (id.isEmpty) return;
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => UserProfilePage(uid: id)));
  }

  void _openDetail() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => PostDetailPage(postId: widget.item.id)),
    );
  }

  /// 抖音式底部拖动进度条：整条固定在底部导航栏上方，可点按/拖动 seek。
  Widget _buildSeekLine(BuildContext context) {
    final v = _video;
    if (!widget.isActive || v == null || !v.value.isInitialized) {
      return const SizedBox.shrink();
    }
    return Positioned(
      left: 0,
      right: 0,
      // 贴着导航栏上沿（轨道距底栏 7px），圆点完整露出。
      bottom: _navBarHeight(context) + 1,
      height: 20,
      child: LayoutBuilder(
        builder: (context, constraints) {
          void seekToX(double dx) {
            final total = v.value.duration.inMilliseconds;
            if (total <= 0) return;
            final f = (dx / constraints.maxWidth).clamp(0.0, 1.0);
            v.seekTo(Duration(milliseconds: (total * f).round()));
            if (_manualPaused) {
              setState(() => _manualPaused = false);
              _applyPlayback();
            }
          }

          return GestureDetector(
            key: const ValueKey('shorts_seek_gesture'),
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => seekToX(d.localPosition.dx),
            onHorizontalDragStart: (d) => seekToX(d.localPosition.dx),
            onHorizontalDragUpdate: (d) => seekToX(d.localPosition.dx),
            child: Semantics(
              label: '播放进度',
              child: ValueListenableBuilder<VideoPlayerValue>(
                valueListenable: v,
                builder: (_, value, _) {
                  final total = value.duration.inMilliseconds;
                  final p = total <= 0
                      ? 0.0
                      : (value.position.inMilliseconds / total).clamp(0.0, 1.0);
                  final w = constraints.maxWidth;
                  return Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 6,
                        height: 3,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.22),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      Positioned(
                        left: 0,
                        bottom: 6,
                        width: (w * p).clamp(0.0, w),
                        height: 3.5,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.95),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      Positioned(
                        left: (w * p - 4.5).clamp(0.0, w - 9).toDouble(),
                        bottom: 3.25,
                        child: Container(
                          key: const ValueKey('shorts_seek_thumb'),
                          width: 9,
                          height: 9,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.35),
                                blurRadius: 5,
                                offset: const Offset(0, 1),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  );
                },
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
        onDoubleTap: _handleDoubleTapLike,
        isActive: widget.isActive,
      );
    }
    final v = _video;
    if (v != null && v.value.isInitialized && !_failed) {
      final ar = v.value.size.height <= 0
          ? 1.0
          : v.value.size.width / v.value.size.height;
      // 竖屏/方形视频铺满整屏（抖音式），横屏视频保留完整画面、上下留黑。
      final fit = ar >= 1.2 ? BoxFit.contain : BoxFit.cover;
      return FittedBox(
        fit: fit,
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
      final width = MediaQuery.sizeOf(context).width;
      final dpr = MediaQuery.devicePixelRatioOf(context);
      return CachedNetworkImage(
        imageUrl: mediaUrl(cover),
        fit: BoxFit.cover,
        memCacheWidth: (width * dpr).ceil().clamp(360, 1080),
        fadeInDuration: const Duration(milliseconds: 160),
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

  /// 左下信息区：@作者 + 文案 + 原声，右侧给互动栏留出安全距离。
  Widget _buildBottomInfo(BuildContext context) {
    final a = widget.item.author;
    final f = widget.item;
    final name = a.name.isEmpty ? '流萤用户' : a.name;
    final musicName = (f.music?['name'] ?? '').toString();
    final extraTopics = f.topic
        .where((t) => !f.content.contains('#$t'))
        .toList(growable: false);
    return Positioned(
      left: 16,
      right: 82,
      bottom: _navBarHeight(context) + 14,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (f.reason.trim().isNotEmpty) ...[
            Row(
              children: [
                const Icon(
                  Icons.auto_awesome_rounded,
                  size: 12,
                  color: Color(AppColors.accent),
                ),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    f.reason,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.micro.copyWith(
                      fontSize: 11.5,
                      color: Colors.white.withValues(alpha: 0.76),
                      fontWeight: FontWeight.w600,
                      shadows: const [
                        Shadow(color: Color(0xCC000000), blurRadius: 8),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 7),
          ],
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Flexible(
                child: Text(
                  '@$name',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.body.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 17,
                    letterSpacing: 0.1,
                    shadows: const [
                      Shadow(color: Color(0xCC000000), blurRadius: 10),
                    ],
                  ),
                ),
              ),
              if (a.isAdmin) ...[
                const SizedBox(width: 6),
                const _AdminRoleChip(),
              ],
              if (f.created > 0) ...[
                const SizedBox(width: 7),
                Text(
                  '· ${timeAgo(f.created)}',
                  style: AppType.micro.copyWith(
                    color: Colors.white.withValues(alpha: 0.62),
                    fontSize: 11.5,
                    shadows: const [
                      Shadow(color: Color(0x99000000), blurRadius: 8),
                    ],
                  ),
                ),
              ],
            ],
          ),
          // 纯文字帖的正文已经在大屏中央展示，左下不再重复一遍；
          // 视频/图集的文案才需要贴在作者行下面。
          if (f.content.isNotEmpty &&
              (widget.item.isVideo || widget.item.images.isNotEmpty)) ...[
            const SizedBox(height: 8),
            _ContentText(
              text: f.content,
              topics: f.topic,
              mentions: f.mentions,
              maxLines: widget.item.isVideo ? 3 : 2,
            ),
            if (!widget.item.isVideo)
              PressableScale(
                onTap: _openDetail,
                child: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '展开',
                    style: AppType.caption.copyWith(
                      color: Colors.white.withValues(alpha: 0.72),
                      fontWeight: FontWeight.w600,
                      shadows: const [
                        Shadow(color: Color(0xAA000000), blurRadius: 8),
                      ],
                    ),
                  ),
                ),
              ),
          ],
          if (extraTopics.isNotEmpty) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 2,
              children: [
                for (final t in extraTopics)
                  Text(
                    '#$t',
                    style: AppType.caption.copyWith(
                      color: const Color(AppColors.sky),
                      fontWeight: FontWeight.w600,
                      shadows: const [
                        Shadow(color: Color(0xAA000000), blurRadius: 8),
                      ],
                    ),
                  ),
              ],
            ),
          ],
          if (musicName.isNotEmpty) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                const Icon(
                  Icons.music_note_rounded,
                  size: 15,
                  color: Colors.white,
                  shadows: [Shadow(color: Color(0xAA000000), blurRadius: 8)],
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    '原声 · $musicName',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.micro.copyWith(
                      fontSize: 12.5,
                      color: Colors.white.withValues(alpha: 0.86),
                      shadows: const [
                        Shadow(color: Color(0xAA000000), blurRadius: 8),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// 右侧竖排互动：头像+关注、点赞、评论、收藏、分享、旋转唱片。
  /// 全部无底板，只靠白色图标 + 数字，避免再切回「玻璃卡片」观感。
  Widget _buildActionRail(BuildContext context) {
    final a = widget.item.author;
    final f = widget.item;
    final cover = (f.music?['cover'] ?? '').toString();
    return Positioned(
      right: 10,
      bottom: _navBarHeight(context) + 13,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              _RailAvatar(
                uid: a.id,
                name: a.name,
                avatar: a.avatar,
                frameId: a.frameId,
                size: 48,
                verified: a.verified,
                isAi: a.isAi,
                onTap: a.id.isEmpty ? null : _openAuthor,
              ),
              if (a.id.isNotEmpty)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: -9,
                  child: Center(
                    child: AnimatedSwitcher(
                      duration: AppMotion.fast,
                      switchInCurve: Curves.easeOutBack,
                      switchOutCurve: Curves.easeIn,
                      transitionBuilder: (child, anim) => FadeTransition(
                        opacity: anim,
                        child: ScaleTransition(scale: anim, child: child),
                      ),
                      child: _followLoading || _followBusy
                          ? const _FollowLoadingBadge(
                              key: ValueKey('follow_loading'),
                            )
                          : (_followed
                                ? const SizedBox.shrink(
                                    key: ValueKey('follow_done'),
                                  )
                                : PressableScale(
                                    key: const ValueKey('follow_plus'),
                                    onTap: _toggleFollow,
                                    scale: 0.88,
                                    child: SizedBox(
                                      width: 40,
                                      height: 40,
                                      child: Center(
                                        child: Container(
                                          width: 22,
                                          height: 22,
                                          decoration: BoxDecoration(
                                            color: const Color(AppColors.heart),
                                            shape: BoxShape.circle,
                                            border: Border.all(
                                              color: Colors.white,
                                              width: 1.6,
                                            ),
                                            boxShadow: const [
                                              BoxShadow(
                                                color: Color(0x66000000),
                                                blurRadius: 6,
                                              ),
                                            ],
                                          ),
                                          child: const Icon(
                                            Icons.add_rounded,
                                            size: 15,
                                            color: Colors.white,
                                          ),
                                        ),
                                      ),
                                    ),
                                  )),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 22),
          _RailAction(
            asset: 'assets/icons/heart.svg',
            semanticLabel: _liked ? '取消点赞' : '点赞',
            color: _liked ? const Color(AppColors.heart) : Colors.white,
            count: _likeCount,
            trigger: _liked,
            onTap: _toggleLike,
          ),
          _RailAction(
            asset: 'assets/icons/chatbubble-ellipses.svg',
            semanticLabel: '评论',
            count: _commentCount,
            trigger: _commentCount,
            onTap: _openComments,
          ),
          _RailAction(
            asset: 'assets/icons/star.svg',
            semanticLabel: _faved ? '取消收藏' : '收藏',
            color: _faved ? const Color(AppColors.warning) : Colors.white,
            count: 0,
            trigger: _faved,
            onTap: _toggleFav,
          ),
          _RailAction(
            asset: 'assets/icons/arrow-redo.svg',
            semanticLabel: '分享',
            count: _shareCount,
            trigger: _shareCount,
            onTap: _share,
          ),
          const SizedBox(height: 6),
          _MusicDisc(
            active: widget.isActive && !_manualPaused,
            cover: cover,
            fallbackAvatar: _authorAvatarUrl(a.id, a.avatar),
            onTap: _openDetail,
          ),
        ],
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
    behavior: HitTestBehavior.opaque,
    onDoubleTap: widget.onDoubleTap,
    child: Center(
      child: CachedNetworkImage(
        imageUrl: mediaUrl(url),
        fit: BoxFit.fitWidth,
        width: double.infinity,
        memCacheWidth:
            (MediaQuery.sizeOf(context).width *
                    MediaQuery.devicePixelRatioOf(context))
                .ceil()
                .clamp(720, 1440),
        fadeInDuration: const Duration(milliseconds: 160),
        placeholder: (_, _) => const _MediaLoading(),
        errorWidget: (_, _, _) => const _MediaLoading(),
      ),
    ),
  );

  /// 图集分段条也支持点按/拖动：按横向位置直接切到对应图片。
  void _seekToX(double dx, double width) {
    final n = widget.images.length;
    if (n <= 1 || width <= 0) return;
    final next = (dx / width * n).floor().clamp(0, n - 1);
    if (next == _idx) return;
    _program = true;
    _pc.animateToPage(
      next,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
    setState(() => _idx = next);
    _ac
      ?..reset()
      ..forward();
  }

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
        // 抖音图集：分段进度条也贴底部导航栏上方，支持点按/拖动切图。
        Positioned(
          key: const ValueKey('shorts_image_progress'),
          left: 12,
          right: 12,
          bottom: _navBarHeight(context) + 1,
          height: 18,
          child: LayoutBuilder(
            builder: (context, constraints) => GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) =>
                  _seekToX(d.localPosition.dx, constraints.maxWidth),
              onHorizontalDragStart: (d) =>
                  _seekToX(d.localPosition.dx, constraints.maxWidth),
              onHorizontalDragUpdate: (d) =>
                  _seekToX(d.localPosition.dx, constraints.maxWidth),
              child: Semantics(
                label: '图集进度',
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: Row(
                    children: List.generate(imgs.length, (i) {
                      return Expanded(
                        child: Padding(
                          padding: EdgeInsets.only(
                            right: i == imgs.length - 1 ? 0 : 4,
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(2),
                            child: _segment(i),
                          ),
                        ),
                      );
                    }),
                  ),
                ),
              ),
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
double _navBarHeight(BuildContext c) => 58 + MediaQuery.viewPaddingOf(c).bottom;

/// 作者头像优先按 uid 走 /music/avatar/{uid}；完整 http 地址原样用；其余再兜底。
String _authorAvatarUrl(String uid, String avatar) {
  final raw = avatar.trim();
  if (raw.startsWith('http://') || raw.startsWith('https://')) return raw;
  if (uid.isNotEmpty) return avatarUrlOf(uid);
  return raw.isEmpty ? '' : avatarUrl(raw);
}

/// 电影暗角：顶部护住状态栏/tab，底部把作者文案与进度线从画面里托出来。
class _CinemaVignette extends StatelessWidget {
  const _CinemaVignette();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            stops: const [0.0, 0.16, 0.62, 1.0],
            colors: [
              Colors.black.withValues(alpha: 0.52),
              Colors.black.withValues(alpha: 0.04),
              Colors.black.withValues(alpha: 0.08),
              Colors.black.withValues(alpha: 0.58),
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

/// 操作栏作者头像（抖音式）：白描边圆环 + 可点击进主页
class _RailAvatar extends StatelessWidget {
  final String uid;
  final String name;
  final String? avatar;
  final String? frameId;
  final bool verified;
  final bool isAi;
  final double size;
  final VoidCallback? onTap;
  const _RailAvatar({
    required this.uid,
    required this.name,
    required this.avatar,
    required this.size,
    this.onTap,
    this.frameId,
    this.verified = false,
    this.isAi = false,
  });

  @override
  Widget build(BuildContext context) {
    final imageUrl = _authorAvatarUrl(uid, avatar ?? '');
    Widget child = Container(
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
        child: imageUrl.isNotEmpty
            ? CachedNetworkImage(
                imageUrl: imageUrl,
                fit: BoxFit.cover,
                memCacheWidth: (size * MediaQuery.devicePixelRatioOf(context))
                    .ceil()
                    .clamp(64, 160),
                maxWidthDiskCache: 128,
                maxHeightDiskCache: 128,
                fadeInDuration: const Duration(milliseconds: 120),
                placeholder: (_, _) => _AvatarFallback(name: name, isAi: isAi),
                errorWidget: (_, _, _) =>
                    _AvatarFallback(name: name, isAi: isAi),
              )
            : _AvatarFallback(name: name, isAi: isAi),
      ),
    );
    final fid = frameId ?? '';
    if (fid.isNotEmpty) {
      final fsz = size * 1.94;
      child = SizedBox(
        width: size,
        height: size,
        child: Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: [
            child,
            Positioned(
              left: (size - fsz) / 2,
              top: (size - fsz) / 2,
              width: fsz,
              height: fsz,
              child: IgnorePointer(
                child: CachedNetworkImage(
                  imageUrl: frameUrlOf(fid),
                  fit: BoxFit.contain,
                  placeholder: (_, _) => const SizedBox.shrink(),
                  errorWidget: (_, _, _) => const SizedBox.shrink(),
                ),
              ),
            ),
          ],
        ),
      );
    }
    if (verified) {
      final badge = VerifiedBadge.forAvatar(size);
      final inset = VerifiedBadge.avatarInsetFor(size);
      child = SizedBox(
        width: size,
        height: size,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            child,
            Positioned(right: inset, bottom: inset, child: badge),
          ],
        ),
      );
    }
    if (onTap == null) return child;
    return PressableScale(onTap: onTap, scale: 0.92, child: child);
  }
}

class _AvatarFallback extends StatelessWidget {
  final String name;
  final bool isAi;
  const _AvatarFallback({this.name = '', this.isAi = false});
  @override
  Widget build(BuildContext context) {
    if (isAi) {
      return Image.asset(
        'assets/ai/xiaoying.png',
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => _initialFallback(name),
      );
    }
    return _initialFallback(name);
  }

  Widget _initialFallback(String name) {
    final initial = name.trim().isEmpty ? '' : name.trim().characters.first;
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF46464C), Color(0xFF232327)],
        ),
      ),
      child: Center(
        child: initial.isEmpty
            ? const Icon(
                Icons.person_rounded,
                color: Color(0xCCFFFFFF),
                size: 20,
              )
            : Text(
                initial,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  height: 1,
                ),
              ),
      ),
    );
  }
}

/// 双击点赞时从屏幕中央弹出的爱心：放大回弹 + 后段淡出，不挡操作。
class _DoubleTapHeart extends StatelessWidget {
  const _DoubleTapHeart({super.key});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      key: const ValueKey('shorts_like_burst'),
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 720),
      curve: Curves.easeOutCubic,
      builder: (context, t, _) {
        final scale = 0.5 + Curves.easeOutBack.transform(t) * 0.55;
        final fade = t < 0.68 ? 1.0 : (1 - (t - 0.68) / 0.32).clamp(0.0, 1.0);
        return Opacity(
          opacity: fade,
          child: Transform.scale(
            scale: scale,
            child: const Icon(
              Icons.favorite_rounded,
              size: 92,
              color: Color(AppColors.heart),
              shadows: [
                Shadow(color: Color(0xCC000000), blurRadius: 22),
                Shadow(color: Color(0x66FFFFFF), blurRadius: 4),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 抖音式旋转唱片：有配乐封面就转封面，没有就用作者头像，再没有就显示音符。
class _MusicDisc extends StatefulWidget {
  final bool active;
  final String cover;
  final String fallbackAvatar;
  final VoidCallback onTap;

  const _MusicDisc({
    required this.active,
    required this.cover,
    required this.fallbackAvatar,
    required this.onTap,
  });

  @override
  State<_MusicDisc> createState() => _MusicDiscState();
}

class _MusicDiscState extends State<_MusicDisc>
    with SingleTickerProviderStateMixin {
  late final AnimationController _rotation;

  @override
  void initState() {
    super.initState();
    _rotation = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 9),
    );
    if (widget.active) _rotation.repeat();
  }

  @override
  void didUpdateWidget(covariant _MusicDisc old) {
    super.didUpdateWidget(old);
    if (old.active == widget.active) return;
    if (widget.active) {
      _rotation.repeat();
    } else {
      _rotation.stop();
    }
  }

  @override
  void dispose() {
    _rotation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = widget.cover.isNotEmpty
        ? mediaUrl(widget.cover)
        : widget.fallbackAvatar;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return Tooltip(
      message: '查看作品',
      child: PressableScale(
        onTap: widget.onTap,
        scale: 0.9,
        child: SizedBox(
          width: 50,
          height: 50,
          child: Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.black.withValues(alpha: 0.55),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.32),
                    width: 1.2,
                  ),
                  boxShadow: const [
                    BoxShadow(color: Color(0x55000000), blurRadius: 8),
                  ],
                ),
              ),
              if (image.isNotEmpty)
                RotationTransition(
                  turns: _rotation,
                  child: Container(
                    width: 38,
                    height: 38,
                    decoration: const BoxDecoration(shape: BoxShape.circle),
                    clipBehavior: Clip.antiAlias,
                    child: CachedNetworkImage(
                      imageUrl: image,
                      fit: BoxFit.cover,
                      memCacheWidth: (38 * dpr).ceil().clamp(48, 128),
                      maxWidthDiskCache: 96,
                      maxHeightDiskCache: 96,
                      fadeInDuration: const Duration(milliseconds: 120),
                      errorWidget: (_, _, _) => const _DiscFallback(),
                    ),
                  ),
                )
              else
                const _DiscFallback(),
              // 唱片中心的小音符，让“这是音乐”这件事一眼可读。
              Container(
                width: 15,
                height: 15,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.60),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.music_note_rounded,
                  size: 10,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DiscFallback extends StatelessWidget {
  const _DiscFallback();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [
            const Color(AppColors.elevated),
            Colors.black.withValues(alpha: 0.88),
          ],
        ),
      ),
      child: const Icon(
        Icons.music_note_rounded,
        size: 16,
        color: Colors.white70,
      ),
    );
  }
}

class _FollowLoadingBadge extends StatelessWidget {
  const _FollowLoadingBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        color: const Color(AppColors.heart),
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 1.6),
      ),
      padding: const EdgeInsets.all(5),
      child: const CircularProgressIndicator(
        strokeWidth: 1.6,
        color: Colors.white,
      ),
    );
  }
}

class _AdminRoleChip extends StatelessWidget {
  const _AdminRoleChip();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
      ),
      child: Text(
        '管理员',
        style: AppType.micro.copyWith(
          color: Colors.white.withValues(alpha: 0.92),
          fontSize: 9.5,
          height: 1.25,
          fontWeight: FontWeight.w600,
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
    final base = AppType.bodySm.copyWith(
      color: Colors.white.withValues(alpha: 0.96),
      fontSize: 15,
      height: 1.45,
      shadows: const [Shadow(color: Color(0xCC000000), blurRadius: 9)],
    );
    final spans = <InlineSpan>[];
    // 简化：按话题/提及切分高亮
    final RegExp kw = RegExp(
      '(#(?:${topics.map(RegExp.escape).join('|')}))|(@(?:${mentions.map(RegExp.escape).join('|')}))',
    );
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
                  ? const Color(AppColors.sky)
                  : const Color(AppColors.lilac),
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
    return Text.rich(
      TextSpan(style: base, children: spans),
      maxLines: maxLines,
      overflow: maxLines == null ? TextOverflow.clip : TextOverflow.ellipsis,
    );
  }
}

// ignore: unused_element
class _RailAction extends StatelessWidget {
  final String asset; // assets/icons/*.svg（网上下载的开源实心图标）
  final String semanticLabel;
  final Color color;
  final int count;
  final VoidCallback onTap;

  /// 状态值变化时图标弹一下（点赞、收藏、分享计数）
  final Object? trigger;
  const _RailAction({
    required this.asset,
    required this.semanticLabel,
    required this.count,
    required this.onTap,
    this.color = Colors.white,
    this.trigger,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      button: true,
      label: semanticLabel,
      child: PressableScale(
        onTap: onTap,
        scale: 0.9,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 15),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              BounceOnChange(
                trigger: trigger,
                child: SvgPicture.asset(
                  asset,
                  width: 35,
                  height: 35,
                  colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
                ),
              ),
              if (count > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: RollingCount(
                    value: count,
                    style: AppType.numeric.copyWith(
                      color: Colors.white,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      shadows: const [
                        Shadow(color: Color(0xCC000000), blurRadius: 6),
                      ],
                    ),
                  ),
                ),
            ],
          ),
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
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0, -0.2),
          radius: 1.1,
          colors: [Color(0xFF191A1D), Color(0xFF080809)],
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned(
            left: 26,
            top: MediaQuery.paddingOf(context).top + 108,
            child: Icon(
              Icons.format_quote_rounded,
              size: 96,
              color: Colors.white.withValues(alpha: 0.055),
            ),
          ),
          Center(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                28,
                MediaQuery.paddingOf(context).top + 96,
                // 窄屏时右侧互动栏会吃掉正文宽度；为它留出 70px，避免文字压到爱心。
                28 + (MediaQuery.sizeOf(context).width < 360 ? 58 : 0),
                154 + _navBarHeight(context),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '流萤手记',
                    style: AppType.micro.copyWith(
                      color: const Color(AppColors.accent),
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 3.2,
                    ),
                  ),
                  const SizedBox(height: 22),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 520),
                    child: TextEmojiText(
                      item.content,
                      textAlign: TextAlign.center,
                      maxLines: 8,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.h2.copyWith(
                        color: Colors.white.withValues(alpha: 0.94),
                        fontSize: MediaQuery.sizeOf(context).width < 360
                            ? 20.5
                            : 26,
                        height: 1.62,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.2,
                        shadows: const [
                          Shadow(color: Color(0x99000000), blurRadius: 14),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 22,
                        height: 2,
                        color: const Color(AppColors.accent),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '上滑继续',
                        style: AppType.micro.copyWith(
                          color: Colors.white.withValues(alpha: 0.38),
                          fontSize: 10.5,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
