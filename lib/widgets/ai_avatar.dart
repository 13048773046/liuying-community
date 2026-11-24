import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

/// 小萤 AI 形象。
///
/// 大尺寸默认播放一遍动图，播完停在静态图；`animate: false` 时始终显示静态图。
/// [replay] 变化会从头重播，用于「每开一个新对话播一次」。
class AiAvatar extends StatefulWidget {
  const AiAvatar({
    super.key,
    this.size = 48,
    this.animate = true,
    this.replay = 0,
    this.gifAsset = 'assets/ai/xiaoying_wave.gif',
    this.staticAsset = 'assets/ai/xiaoying.png',
  });

  final double size;
  final bool animate;
  final int replay;
  final String gifAsset;
  final String staticAsset;

  @override
  State<AiAvatar> createState() => _AiAvatarState();
}

class _AiAvatarState extends State<AiAvatar> {
  static final Map<String, Future<_GifFrames>> _cache = {};

  _GifFrames? _frames;
  bool _done = false;
  int _index = 0;
  int _run = 0;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(covariant AiAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.replay != widget.replay ||
        oldWidget.animate != widget.animate ||
        oldWidget.gifAsset != widget.gifAsset) {
      _start();
    }
  }

  @override
  void dispose() {
    _run++;
    super.dispose();
  }

  Future<_GifFrames> _loadFrames() {
    return _cache.putIfAbsent(widget.gifAsset, () async {
      final data = await rootBundle.load(widget.gifAsset);
      final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      final codec = await ui.instantiateImageCodec(bytes);
      final frames = <ui.Image>[];
      final durations = <Duration>[];
      for (var i = 0; i < codec.frameCount; i++) {
        final info = await codec.getNextFrame();
        frames.add(info.image);
        durations.add(info.duration);
      }
      if (frames.isEmpty) {
        final info = await codec.getNextFrame();
        frames.add(info.image);
        durations.add(const Duration(milliseconds: 100));
      }
      return _GifFrames(frames, durations);
    });
  }

  Future<void> _start() async {
    final run = ++_run;
    if (!widget.animate) {
      if (mounted) setState(() => _done = true);
      return;
    }
    if (mounted) setState(() { _done = false; _index = 0; });
    try {
      final frames = await _loadFrames();
      if (!mounted || run != _run) return;
      _frames = frames;
      for (var i = 0; i < frames.images.length; i++) {
        if (!mounted || run != _run) return;
        setState(() => _index = i);
        await Future<void>.delayed(frames.durations[i]);
      }
      if (!mounted || run != _run) return;
      setState(() => _done = true);
    } catch (_) {
      if (mounted && run == _run) setState(() => _done = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final side = widget.size;
    Widget fallback() => Image.asset(
          widget.staticAsset,
          width: side,
          height: side,
          fit: BoxFit.cover,
          filterQuality: FilterQuality.medium,
          errorBuilder: (_, __, ___) => Container(
            width: side,
            height: side,
            color: const Color(0xFF0D1A17),
            alignment: Alignment.center,
            child: Icon(Icons.auto_awesome_rounded,
                size: side * .45, color: const Color(0xFF3DDC97)),
          ),
        );
    final frames = _frames;
    final widgetImage = (!_done && frames != null && frames.images.isNotEmpty)
        ? RawImage(
            image: frames.images[_index % frames.images.length],
            width: side,
            height: side,
            fit: BoxFit.cover,
            filterQuality: FilterQuality.medium,
          )
        : fallback();
    return ClipOval(
      child: SizedBox(width: side, height: side, child: widgetImage),
    );
  }
}

class _GifFrames {
  _GifFrames(this.images, this.durations);
  final List<ui.Image> images;
  final List<Duration> durations;
}
