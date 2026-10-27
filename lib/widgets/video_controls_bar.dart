/// 视频隐藏式控制条（抖音式）：可拖进度条 + 播放/暂停 + 当前时间/总时长
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
    return Container(
      padding: EdgeInsets.fromLTRB(12, 16, 8, 8 + widget.bottomInset),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Colors.black87, Colors.black38, Colors.transparent],
          stops: [0.0, 0.55, 1.0],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text(fmtDuration(_pos),
                  style: const TextStyle(color: Colors.white, fontSize: 11)),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 2.5,
                    activeTrackColor: Colors.white,
                    inactiveTrackColor: Colors.white24,
                    thumbColor: Colors.white,
                    thumbShape:
                        const RoundSliderThumbShape(enabledThumbRadius: 5),
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
              Text(fmtDuration(_dur),
                  style: const TextStyle(color: Colors.white70, fontSize: 11)),
              const SizedBox(width: 4),
              IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                iconSize: 22,
                color: Colors.white,
                icon: Icon(
                  widget.controller.value.isPlaying
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                ),
                onPressed: _togglePlay,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
