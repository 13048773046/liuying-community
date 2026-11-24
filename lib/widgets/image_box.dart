/// 通用网络图片（沉浸黑：加载/失败统一用 [ImagePlaceholder]，布局不跳）
library;

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../design/components.dart';

/// 给需要 `ImageProvider` 的场景（全屏查看器、Hero、取色）提供同一套缓存策略。
/// 测试环境退回 `NetworkImage`，避免 flutter_cache_manager 的清理定时器。
ImageProvider cachedImageProvider(String url) {
  if (Platform.environment['FLUTTER_TEST'] == 'true') {
    return NetworkImage(url);
  }
  return CachedNetworkImageProvider(url);
}

class CachedNetworkImageCompat extends StatelessWidget {
  final String url;
  final double? width;
  final double? height;
  final BoxFit fit;
  final double borderRadius;
  final int? memCacheWidth;
  final Widget? placeholder;
  final Widget? errorWidget;

  const CachedNetworkImageCompat({
    super.key,
    required this.url,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.borderRadius = 0,
    this.memCacheWidth,
    this.placeholder,
    this.errorWidget,
  });

  @override
  Widget build(BuildContext context) {
    final decodeWidth =
        memCacheWidth ??
        (((width ?? MediaQuery.sizeOf(context).width) *
                    MediaQuery.devicePixelRatioOf(context))
                .ceil())
            .clamp(64, 2048)
            .toInt();
    final ph = placeholder ?? ImagePlaceholder(radius: borderRadius);
    // flutter_test 的 fake 时钟不会推进 flutter_cache_manager 的 10s 清理
    // 定时器；测试环境仍走 Image.network（HTTP 400 → errorWidget），
    // 保证水合后 widget 树不会留下 pending timer。
    final testMode = Platform.environment['FLUTTER_TEST'] == 'true';
    final image = testMode
        ? Image.network(
            url,
            width: width,
            height: height,
            fit: fit,
            errorBuilder: (_, _, _) =>
                errorWidget ??
                ImagePlaceholder(
                  icon: Icons.broken_image_outlined,
                  radius: borderRadius,
                ),
          )
        : CachedNetworkImage(
            imageUrl: url,
            cacheKey: url,
            fit: fit,
            width: width,
            height: height,
            memCacheWidth: decodeWidth,
            // 同一张图只从网络取一次；再次进入页面时直接从磁盘/解码缓存出图。
            maxWidthDiskCache: 1600,
            maxHeightDiskCache: 1600,
            fadeInDuration: const Duration(milliseconds: 120),
            fadeOutDuration: Duration.zero,
            placeholder: (_, _) => ph,
            errorWidget: (_, _, _) =>
                errorWidget ??
                ImagePlaceholder(
                  icon: Icons.broken_image_outlined,
                  radius: borderRadius,
                ),
          );
    return SizedBox(
      width: width,
      height: height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: image,
      ),
    );
  }
}

/// 照片墙 / 信息流图片的「模糊占位 → 清晰」入场。
///
/// 1. 先用与图片同色调的模糊缩略图占位（主色 + 20px 高斯模糊）；
/// 2. 原图解码完成后，清晰图从 1.04 倍缩回 1 倍，并在 500ms 内淡入；
/// 3. 外层尺寸由父级固定，切换前/后布局不跳。
class BlurUpImage extends StatefulWidget {
  const BlurUpImage({
    super.key,
    required this.url,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.borderRadius = 0,
    this.cacheWidth,
    this.placeholder,
    this.imageProvider,
    this.transparentBackground = false,
    this.onToneExtracted,
    this.onToneFailed,
  });

  final String url;
  final BoxFit fit;
  final double? width;
  final double? height;
  final double borderRadius;
  final int? cacheWidth;
  final Widget? placeholder;

  /// 透明素材（表情包、贴纸）专用：不铺同色底、不做模糊小图垫底，
  /// 也不做 1.04→1.0 的缩放入场，避免 alpha 背景被方形底色填满或边缘发糊。
  final bool transparentBackground;

  /// 测试 / 本地图片可注入 provider；正式网络图片留空。
  final ImageProvider? imageProvider;

  /// 图片解码后回报画面主色。详情页用它把首图/封面色调带到页面背景；
  /// 回调只触发一次，避免同一张图重复 setState。
  final ValueChanged<Color>? onToneExtracted;

  /// 图片不可用（空 URL / 加载失败 / 取色失败）时回报，供调用方回退品牌色。
  final VoidCallback? onToneFailed;

  @override
  State<BlurUpImage> createState() => _BlurUpImageState();
}

class _BlurUpImageState extends State<BlurUpImage> {
  ImageStream? _stream;
  ImageStreamListener? _listener;
  bool _ready = false;
  bool _failed = false;
  bool _showBlur = true;
  Timer? _blurTimer;
  Color? _tone;
  bool _toneReported = false;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(covariant BlurUpImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _detach();
      _blurTimer?.cancel();
      _ready = false;
      _failed = false;
      _showBlur = true;
      _tone = null;
      _resolve();
    }
  }

  void _resolve() {
    _toneReported = false;
    if (widget.url.trim().isEmpty && widget.imageProvider == null) {
      _failed = true;
      _reportToneFailure();
      return;
    }
    final provider = _provider();
    _stream = provider.resolve(const ImageConfiguration());
    _listener = ImageStreamListener(
      (info, _) {
        if (!mounted) return;
        setState(() => _ready = true);
        // 清晰图 500ms 淡入完成后撤掉模糊底，长列表不再为每张已加载图片
        // 保留一整层高斯模糊。
        _blurTimer?.cancel();
        _blurTimer = Timer(const Duration(milliseconds: 620), () {
          if (mounted) setState(() => _showBlur = false);
        });
        _extractTone(info.image);
      },
      onError: (_, _) {
        if (!mounted) return;
        setState(() => _failed = true);
        _reportToneFailure();
      },
    );
    _stream!.addListener(_listener!);
  }

  void _reportTone(Color color) {
    if (_toneReported) return;
    _toneReported = true;
    widget.onToneExtracted?.call(color);
  }

  void _reportToneFailure() {
    if (_toneReported) return;
    _toneReported = true;
    // 空 URL / 解码失败可能发生在 initState/build 期间，延后一帧再把
    // 失败状态交给父级，避免父级在 build 中 setState。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onToneFailed?.call();
    });
  }

  ImageProvider _provider() {
    final base = widget.imageProvider ?? cachedImageProvider(widget.url);
    final width = widget.cacheWidth;
    return width == null ? base : ResizeImage(base, width: width);
  }

  Future<void> _extractTone(ui.Image image) async {
    ui.Image? small;
    try {
      small = await _downsample(image, 18);
      final data = await small.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null || !mounted) return;
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      var r = 0, g = 0, b = 0, n = 0;
      for (var i = 0; i + 3 < bytes.length; i += 16) {
        final a = bytes[i + 3];
        if (a < 80) continue;
        r += bytes[i];
        g += bytes[i + 1];
        b += bytes[i + 2];
        n++;
      }
      if (n == 0) {
        _reportToneFailure();
        return;
      }
      final color = Color.fromARGB(255, r ~/ n, g ~/ n, b ~/ n);
      // 太暗的主色在黑底上会和背景融在一起，抬一档亮度再当占位。
      final lifted = Color.lerp(color, const Color(AppColors.elevated), 0.18)!;
      if (mounted) setState(() => _tone = lifted);
      _reportTone(color);
    } catch (_) {
      // 取色失败不阻塞图片本身，保留中性占位底。
      _reportToneFailure();
    } finally {
      if (!identical(small, image)) small?.dispose();
    }
  }

  Future<ui.Image> _downsample(ui.Image source, int maxSide) async {
    final w = source.width;
    final h = source.height;
    final longSide = w > h ? w : h;
    if (longSide <= maxSide) return source;
    final scale = maxSide / longSide;
    final tw = (w * scale).round().clamp(1, maxSide);
    final th = (h * scale).round().clamp(1, maxSide);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawImageRect(
      source,
      Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      Rect.fromLTWH(0, 0, tw.toDouble(), th.toDouble()),
      Paint()..filterQuality = FilterQuality.low,
    );
    final picture = recorder.endRecording();
    final out = await picture.toImage(tw, th);
    picture.dispose();
    return out;
  }

  void _detach() {
    if (_stream != null && _listener != null) {
      _stream!.removeListener(_listener!);
    }
    _listener = null;
    _stream = null;
  }

  @override
  void dispose() {
    _blurTimer?.cancel();
    _detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fallback = widget.placeholder ?? const ImagePlaceholder(radius: 0);
    if ((widget.url.trim().isEmpty && widget.imageProvider == null) ||
        _failed) {
      return SizedBox(
        width: widget.width,
        height: widget.height,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(widget.borderRadius),
          child: fallback,
        ),
      );
    }

    final thumbProvider = ResizeImage(
      widget.imageProvider ?? cachedImageProvider(widget.url),
      width: 64,
    );
    final fullProvider = _provider();
    if (widget.transparentBackground) {
      return SizedBox(
        width: widget.width,
        height: widget.height,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(widget.borderRadius),
          child: Image(
            image: fullProvider,
            fit: widget.fit,
            gaplessPlayback: true,
            // 表情原图 1024，气泡按 540 解码；高质量缩放保证边缘不发糊。
            filterQuality: FilterQuality.high,
            errorBuilder: (_, _, _) => fallback,
          ),
        ),
      );
    }
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(widget.borderRadius),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 同色调底：图片还没解码时也不会露出纯白或纯黑空洞。
            ColoredBox(color: _tone ?? const Color(AppColors.elevated)),
            // 模糊小图：只在清晰图淡入的 500ms 内垫底，之后撤掉。
            if (_ready && _showBlur)
              ImageFiltered(
                imageFilter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                child: Image(
                  image: thumbProvider,
                  fit: widget.fit,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) => fallback,
                ),
              ),
            // 清晰图：500ms 淡入 + 1.04 → 1.0 缩回。
            AnimatedOpacity(
              opacity: _ready ? 1 : 0,
              duration: const Duration(milliseconds: 500),
              curve: Curves.easeOutCubic,
              child: AnimatedScale(
                scale: _ready ? 1 : 1.04,
                duration: const Duration(milliseconds: 500),
                curve: Curves.easeOutCubic,
                child: Image(
                  image: fullProvider,
                  fit: widget.fit,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) => fallback,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
