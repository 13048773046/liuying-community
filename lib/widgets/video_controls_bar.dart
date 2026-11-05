/// 视频隐藏式控制条（抖音式）：细白进度条 + 黑底半透明胶囊
///
/// 由父级控制显隐（点画面调出/隐藏），本组件只负责渲染与交互：
///  - 内部监听 controller 更新进度/时长
///  - 拖动进度条 seek（拖动中不跳帧，松手生效）
///  - 播放/暂停按钮
///  - 3 秒无操作自动隐藏（回调给父级归位）
library;

import 'dart:async';
import 'package:flutter/material.dart';

import 'package:video_player/video_player.dart';

import '../design/components.dart';

/// 时间格式 mm:ss / h:mm:ss
String fmtDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final s = d.inSeconds % 60;
  final mm = m.toString().padLeft(2, '0');
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
}

class VideoControlsBar extends StatefulWidget {
  const VideoControlsBar({
    super.key,
    required this.controller,
    this.autoHideAfter = const Duration(seconds: 3),
    this.onAutoHide,
    this.bottomInset = 0,
  });

  final VideoPlayerController controller;
  final Duration autoHideAfter;

  /// 3 秒无操作自动隐藏回调（父级据此收起控制条）
  final VoidCallback? onAutoHide;

  /// 底部避让（短视频流需避让透明导航栏）
  final double bottomInset;

  @override
  State<VideoControlsBar> createState() => _VideoControlsBarState();
}

class _VideoControlsBarState extends State<VideoControlsBar> {
  Duration _pos = Duration.zero;
  Duration _dur = Duration.zero;
  double _dragMs = -1;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTick);
    _restartTimer();
  }

  @override
  void didUpdateWidget(covariant VideoControlsBar old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_onTick);
      widget.controller.addListener(_onTick);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTick);
    _hideTimer?.cancel();
    super.dispose();
  }

  void _onTick() {
    if (!mounted) return;
    setState(() {
      _pos = widget.controller.value.position;
      _dur = widget.controller.value.duration;
    });
  }

  void _restartTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(widget.autoHideAfter, () {
      if (!mounted) return;
      widget.onAutoHide?.call();
    });
  }

  void _seek(double ms) {
    widget.controller.seekTo(Duration(milliseconds: ms.round()));
    _restartTimer();
  }

  void _togglePlay() {
    final v = widget.controller.value;
    if (v.isPlaying) {
      widget.controller.pause();
    } else {
      widget.controller.play();
    }
    _restartTimer();
  }

  @override
  Widget build(BuildContext context) {
    final durMs = _dur.inMilliseconds.toDouble();
    final posMs = _pos.inMilliseconds.toDouble();
    final val = _dragMs >= 0
        ? _dragMs
        : (durMs > 0 ? posMs.clamp(0.0, durMs) : 0.0);
    final playing = widget.controller.value.isPlaying;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpace.x3,
        0,
        AppSpace.x3,
        AppSpace.x3 + widget.bottomInset,
      ),
      child: Container(
        padding: const EdgeInsets.fromLTRB(AppSpace.x1, 2, AppSpace.x3, 2),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.55),
          borderRadius: AppRadius.rPill,
          border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
        ),
        child: Row(
          children: [
            IconCircleButton(
              icon: playing
                  ? Icons.pause_rounded
                  : Icons.play_arrow_rounded,
              size: 30,
              iconSize: 18,
              background: Colors.white.withValues(alpha: 0.12),
              onTap: _togglePlay,
            ),
            const SizedBox(width: AppSpace.x1),
            Expanded(
              child: SizedBox(
                height: 26,
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 2,
                    activeTrackColor: Colors.white,
                    inactiveTrackColor: Colors.white.withValues(alpha: 0.22),
                    thumbColor: Colors.white,
                    thumbShape:
                        const RoundSliderThumbShape(enabledThumbRadius: 4),
                    overlayShape:
                        const RoundSliderOverlayShape(overlayRadius: 10),
                    trackShape: const RoundedRectSliderTrackShape(),
                  ),
                  child: Slider(
                    value: val,
                    max: durMs > 0 ? durMs : 1,
                    onChanged: (x) => setState(() => _dragMs = x),
                    onChangeEnd: (x) {
                      setState(() => _dragMs = -1);
                      _seek(x);
                    },
                  ),
                ),
              ),
            ),
            const SizedBox(width: AppSpace.x1),
            Text(
              '${fmtDuration(_pos)} / ${fmtDuration(_dur)}',
              style: AppType.micro.copyWith(
                color: const Color(AppColors.textSecondary),
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
