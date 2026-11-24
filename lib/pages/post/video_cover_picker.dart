import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

import '../../design/components.dart';

/// 用户从视频里选中的封面帧。
class VideoCoverSelection {
  const VideoCoverSelection({
    required this.time,
    this.bytes,
    this.auto = false,
  });

  const VideoCoverSelection.auto() : time = 0, bytes = null, auto = true;

  final double time;
  final Uint8List? bytes;
  final bool auto;
}

/// 视频抽帧：本地视频 + 秒数 → JPEG 字节。
///
/// 插件在部分测试/无原生实现环境会抛 MissingPluginException，
/// 这里统一兜底返回 null，让 UI 走占位态而不是崩溃。
Future<Uint8List?> videoFrameBytes(
  File video,
  double seconds, {
  int maxWidth = 720,
  int quality = 82,
}) async {
  try {
    return await VideoThumbnail.thumbnailData(
      video: video.path,
      imageFormat: ImageFormat.JPEG,
      maxWidth: maxWidth,
      quality: quality,
      timeMs: (seconds.clamp(0, 86400) * 1000).round(),
    );
  } catch (_) {
    return null;
  }
}

/// 抖音式封面选择器：大画面预览 + 可拖动时间轴 + 视频帧条。
///
/// 交互：点帧条选帧、拖时间轴选帧、播放暂停预览；
/// 完成后把选中时间返回给发布页，发布时交给后端按秒抽帧。
class VideoCoverPickerPage extends StatefulWidget {
  const VideoCoverPickerPage({
    super.key,
    required this.video,
    this.initialTime = 0,
    @visibleForTesting this.debugPreview,
    @visibleForTesting this.debugThumbnails = const [],
    @visibleForTesting this.debugDuration,
  });

  final File video;
  final double initialTime;

  /// 测试注入：不启动原生 video_player 也能验证视觉。
  final Uint8List? debugPreview;
  final List<Uint8List?> debugThumbnails;
  final double? debugDuration;

  @override
  State<VideoCoverPickerPage> createState() => _VideoCoverPickerPageState();
}

class _VideoCoverPickerPageState extends State<VideoCoverPickerPage> {
  VideoPlayerController? _ctrl;
  bool _ready = false;
  bool _exporting = false;
  String? _error;
  double _duration = 0;
  double _time = 0;
  List<Uint8List?> _thumbs = const [];
  bool _loadingThumbs = false;
  Timer? _seekTimer;
  DateTime _lastTick = DateTime.fromMillisecondsSinceEpoch(0);

  bool get _debug => widget.debugPreview != null;

  @override
  void initState() {
    super.initState();
    _time = widget.initialTime;
    if (_debug) {
      _ready = true;
      _duration = widget.debugDuration ?? 8.4;
      _thumbs = widget.debugThumbnails;
      return;
    }
    _initVideo();
  }

  Future<void> _initVideo() async {
    final ctrl = VideoPlayerController.file(widget.video);
    _ctrl = ctrl;
    try {
      await ctrl.initialize();
      if (!mounted) {
        await ctrl.dispose();
        return;
      }
      await ctrl.pause();
      final d = ctrl.value.duration.inMilliseconds / 1000.0;
      final t = widget.initialTime.clamp(0.0, d <= 0 ? 0.0 : d);
      if (d > 0) await ctrl.seekTo(Duration(milliseconds: (t * 1000).round()));
      ctrl.addListener(_onControllerTick);
      setState(() {
        _ready = true;
        _duration = d;
        _time = t;
      });
      _generateFilmstrip();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _ready = false;
        _error = '这个视频暂时无法预览，可以直接发布，系统会自动取首帧。';
      });
    }
  }

  void _onControllerTick() {
    final c = _ctrl;
    if (!mounted || c == null || !c.value.isInitialized) return;
    if (!c.value.isPlaying) return;
    final now = DateTime.now();
    if (now.difference(_lastTick).inMilliseconds < 180) return;
    _lastTick = now;
    final t = c.value.position.inMilliseconds / 1000.0;
    if (mounted) setState(() => _time = t.clamp(0, _duration));
  }

  Future<void> _generateFilmstrip() async {
    if (_duration <= 0) return;
    final n = 10;
    final next = List<Uint8List?>.filled(n, null);
    setState(() {
      _thumbs = List<Uint8List?>.from(next);
      _loadingThumbs = true;
    });
    for (var i = 0; i < n; i++) {
      final at = _duration * (i + 0.5) / n;
      final bytes = await videoFrameBytes(
        widget.video,
        at,
        maxWidth: 160,
        quality: 68,
      );
      if (!mounted) return;
      next[i] = bytes;
      setState(() => _thumbs = List<Uint8List?>.from(next));
    }
    if (mounted) setState(() => _loadingThumbs = false);
  }

  @override
  void dispose() {
    _seekTimer?.cancel();
    _ctrl?.removeListener(_onControllerTick);
    _ctrl?.dispose();
    super.dispose();
  }

  double _timeForThumb(int i) {
    final n = _thumbs.length;
    if (n == 0) return 0;
    return _duration * (i + 0.5) / n;
  }

  int? get _selectedThumb {
    if (_thumbs.isEmpty || _duration <= 0) return null;
    var best = 0;
    var gap = double.infinity;
    for (var i = 0; i < _thumbs.length; i++) {
      final g = (_timeForThumb(i) - _time).abs();
      if (g < gap) {
        gap = g;
        best = i;
      }
    }
    return best;
  }

  void _seekTo(double t, {bool pause = true}) {
    final safe = t.clamp(0.0, _duration <= 0 ? 0.0 : _duration);
    setState(() => _time = safe);
    final c = _ctrl;
    if (c == null || !c.value.isInitialized) return;
    if (pause && c.value.isPlaying) c.pause();
    c.seekTo(Duration(milliseconds: (safe * 1000).round()));
  }

  void _onSlide(double t) {
    setState(() => _time = t.clamp(0.0, _duration <= 0 ? 0.0 : _duration));
    _seekTimer?.cancel();
    _seekTimer = Timer(const Duration(milliseconds: 90), () {
      final c = _ctrl;
      if (c != null && c.value.isInitialized) {
        c.pause();
        c.seekTo(Duration(milliseconds: (_time * 1000).round()));
      }
    });
  }

  Future<void> _togglePlay() async {
    final c = _ctrl;
    if (c == null || !c.value.isInitialized) return;
    if (c.value.isPlaying) {
      await c.pause();
    } else {
      await c.seekTo(Duration(milliseconds: (_time * 1000).round()));
      await c.play();
    }
    if (mounted) setState(() {});
  }

  Future<void> _confirm() async {
    if (_exporting) return;
    if (_debug) {
      Navigator.pop(
        context,
        VideoCoverSelection(time: _time, bytes: widget.debugPreview),
      );
      return;
    }
    setState(() => _exporting = true);
    final bytes = await videoFrameBytes(widget.video, _time, maxWidth: 720);
    if (!mounted) return;
    final fallback = _selectedThumb == null ? null : _thumbs[_selectedThumb!];
    Navigator.pop(
      context,
      VideoCoverSelection(time: _time, bytes: bytes ?? fallback),
    );
  }

  void _useAuto() {
    Navigator.pop(context, const VideoCoverSelection.auto());
  }

  String _fmt(double s) {
    final m = s ~/ 60;
    final sec = (s % 60).floor().toString().padLeft(2, '0');
    final tenth = ((s - s.floor()) * 10).floor();
    return '$m:$sec.$tenth';
  }

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Scaffold(
      backgroundColor: const Color(AppColors.bg),
      body: Column(
        children: [
          SizedBox(height: top + 8),
          _topBar(),
          Expanded(
            child: Column(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
                    child: _preview(),
                  ),
                ),
                const SizedBox(height: 12),
                _filmstrip(),
                _timeline(),
                _bottombar(bottom),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _topBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 12, 8),
      child: Row(
        children: [
          PressableScale(
            onTap: () => Navigator.maybePop(context),
            scale: 0.92,
            child: Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.07),
                shape: BoxShape.circle,
                border: Border.all(color: const Color(AppColors.border)),
              ),
              child: const Icon(
                Icons.close_rounded,
                size: 19,
                color: Color(AppColors.textPrimary),
              ),
            ),
          ),
          const Spacer(),
          Column(
            children: [
              Text(
                '选择封面',
                style: AppType.title.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 2),
              Text(
                '拖动时间轴 · 挑一帧做封面',
                style: AppType.micro.copyWith(
                  color: const Color(AppColors.textTertiary),
                ),
              ),
            ],
          ),
          const Spacer(),
          PressableScale(
            onTap: _ready && !_exporting ? _confirm : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Text(
                _exporting ? '处理中' : '完成',
                style: AppType.label.copyWith(
                  color: _ready
                      ? const Color(AppColors.accent)
                      : const Color(AppColors.textDisabled),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _preview() {
    final radius = BorderRadius.circular(AppRadius.xl);
    Widget child;
    if (_error != null) {
      child = Container(
        decoration: BoxDecoration(
          color: const Color(AppColors.card),
          borderRadius: radius,
          border: Border.all(color: const Color(AppColors.border)),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.movie_creation_outlined,
              size: 36,
              color: Color(AppColors.textTertiary),
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                _error!,
                textAlign: TextAlign.center,
                style: AppType.caption,
              ),
            ),
          ],
        ),
      );
    } else if (!_ready) {
      child = Container(
        decoration: BoxDecoration(
          color: const Color(AppColors.card),
          borderRadius: radius,
        ),
        child: const Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Color(AppColors.accent),
            ),
          ),
        ),
      );
    } else if (_debug) {
      child = Center(
        child: AspectRatio(
          aspectRatio: 9 / 16,
          child: ClipRRect(
            borderRadius: radius,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image.memory(widget.debugPreview!, fit: BoxFit.cover),
                _previewOverlay(),
              ],
            ),
          ),
        ),
      );
    } else {
      final aspect = _ctrl?.value.aspectRatio ?? 9 / 16;
      child = Center(
        child: AspectRatio(
          aspectRatio: aspect <= 0 ? 9 / 16 : aspect,
          child: ClipRRect(
            borderRadius: radius,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (_ctrl != null && _ctrl!.value.isInitialized)
                  FittedBox(
                    fit: BoxFit.contain,
                    clipBehavior: Clip.hardEdge,
                    child: SizedBox(
                      width: _ctrl!.value.size.width,
                      height: _ctrl!.value.size.height,
                      child: VideoPlayer(_ctrl!),
                    ),
                  )
                else
                  Container(color: Colors.black),
                _previewOverlay(),
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: radius,
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.5),
            blurRadius: 28,
            offset: const Offset(0, 16),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }

  Widget _previewOverlay() {
    return Stack(
      children: [
        // 顶部渐变，保证时间胶囊可读
        Align(
          alignment: Alignment.topCenter,
          child: Container(
            height: 72,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.55),
                  Colors.transparent,
                ],
              ),
            ),
          ),
        ),
        Positioned(
          left: 12,
          top: 12,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.55),
              borderRadius: AppRadius.rPill,
              border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
            ),
            child: Text(
              '封面帧',
              style: AppType.micro.copyWith(
                color: const Color(AppColors.textPrimary),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
        Positioned(
          right: 12,
          top: 12,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.55),
              borderRadius: AppRadius.rPill,
              border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
            ),
            child: Text(
              _fmt(_time),
              style: AppType.numeric.copyWith(
                color: const Color(AppColors.accent),
                fontSize: 12,
              ),
            ),
          ),
        ),
        if (!_debug)
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: PressableScale(
                onTap: _togglePlay,
                scale: 0.9,
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.5),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.18),
                    ),
                  ),
                  child: Icon(
                    (_ctrl?.value.isPlaying ?? false)
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 24,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _filmstrip() {
    final n = _thumbs.isEmpty ? 10 : _thumbs.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            children: [
              Text('视频帧', style: AppType.label),
              const SizedBox(width: 8),
              Text(
                _loadingThumbs ? '抽取中…' : '点一帧，画面会跳过去',
                style: AppType.micro,
              ),
              const Spacer(),
              Text(
                '${_fmt(_time)} / ${_fmt(_duration)}',
                style: AppType.numeric.copyWith(
                  color: const Color(AppColors.textSecondary),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 74,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            itemCount: n,
            separatorBuilder: (_, _) => const SizedBox(width: 5),
            itemBuilder: (context, i) {
              final selected = _selectedThumb == i;
              final bytes = i < _thumbs.length ? _thumbs[i] : null;
              return PressableScale(
                scale: 0.96,
                onTap: _duration <= 0
                    ? null
                    : () {
                        _seekTo(_timeForThumb(i));
                      },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  width: 44,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(9),
                    border: Border.all(
                      color: selected ? Colors.white : Colors.white24,
                      width: selected ? 2 : 1,
                    ),
                    color: const Color(AppColors.card),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: bytes == null
                      ? Center(
                          child: Text(
                            _fmt(_timeForThumb(i)).split('.').first,
                            style: AppType.micro.copyWith(
                              color: const Color(AppColors.textTertiary),
                              fontSize: 10,
                            ),
                          ),
                        )
                      : Image.memory(
                          bytes,
                          fit: BoxFit.cover,
                          gaplessPlayback: true,
                        ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _timeline() {
    final max = _duration <= 0 ? 0.001 : _duration;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
      child: SliderTheme(
        data: SliderTheme.of(context).copyWith(
          trackHeight: 2,
          activeTrackColor: Colors.white,
          inactiveTrackColor: Colors.white.withValues(alpha: 0.18),
          thumbColor: const Color(AppColors.accent),
          overlayShape: SliderComponentShape.noOverlay,
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
        ),
        child: Slider(
          min: 0,
          max: max,
          value: _time.clamp(0, max),
          onChanged: _ready ? _onSlide : null,
          onChangeEnd: _ready ? (v) => _seekTo(v) : null,
        ),
      ),
    );
  }

  Widget _bottombar(double bottom) {
    return Container(
      padding: EdgeInsets.fromLTRB(20, 10, 20, 10 + bottom),
      decoration: const BoxDecoration(
        border: Border(
          top: BorderSide(color: Color(AppColors.hairline), width: 0.5),
        ),
      ),
      child: Row(
        children: [
          PressableScale(
            onTap: _ready ? _useAuto : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '自动首帧',
                    style: AppType.caption.copyWith(
                      color: const Color(AppColors.textSecondary),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text('不用手动选', style: AppType.micro),
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: PillButton(
              label: _exporting ? '正在取这一帧…' : '使用这一帧',
              size: PillSize.lg,
              expand: true,
              glow: true,
              loading: _exporting,
              enabled: _ready && !_exporting,
              onTap: _confirm,
            ),
          ),
        ],
      ),
    );
  }
}
