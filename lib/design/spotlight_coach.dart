// 聚光灯功能引导：像舞台追光，只照亮当前该点的地方。
//
// 遮罩挖一个可移动、可变形的圆角洞；洞边缘做呼吸描边，白色气泡跟着目标换位，
// 最后一步按钮变成「知道了」。页面只负责给目标 GlobalKey 和文案。
library;

import 'package:flutter/material.dart';

import 'tokens.dart';

/// 一次性引导开关。测试默认关闭；生产在 main() 里按本地标记打开。
class SpotlightFlags {
  static bool postActions = false;
}

class SpotlightStep {
  const SpotlightStep({
    required this.targetKey,
    required this.title,
    required this.body,
    this.radius = 18,
  });

  final GlobalKey targetKey;
  final String title;
  final String body;
  final double radius;
}

class SpotlightCoach extends StatefulWidget {
  const SpotlightCoach({
    super.key,
    required this.steps,
    required this.onDone,
    this.onSkip,
  });

  final List<SpotlightStep> steps;
  final VoidCallback onDone;
  final VoidCallback? onSkip;

  @override
  State<SpotlightCoach> createState() => _SpotlightCoachState();
}

class _SpotlightCoachState extends State<SpotlightCoach>
    with TickerProviderStateMixin {
  late final AnimationController _morph = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 400),
  );
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  );
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );

  int _index = 0;
  Rect? _rect;
  Rect? _fromRect;
  Rect? _toRect;
  double _fromRadius = 18;
  double _toRadius = 18;
  Size? _viewport;
  bool _finished = false;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _morph.addListener(_tick);
    _pulse.addListener(_tick);
    _fade.addListener(_tick);
    _pulse.repeat(reverse: true);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _syncRect(initial: true),
    );
  }

  void _tick() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _morph.removeListener(_tick);
    _pulse.removeListener(_tick);
    _fade.removeListener(_tick);
    _morph.dispose();
    _pulse.dispose();
    _fade.dispose();
    super.dispose();
  }

  Rect? _measure(GlobalKey key) {
    final ctx = key.currentContext;
    if (ctx == null) return null;
    final target = ctx.findRenderObject();
    if (target is! RenderBox || !target.hasSize) return null;
    final overlay = context.findRenderObject();
    if (overlay is! RenderBox || !overlay.hasSize) return null;
    // 目标可能在 SafeArea / 父级 padding / 嵌套 Stack 里；统一换算到
    // SpotlightCoach 所在的 overlay 本地坐标，painter 才能画在同一个洞里。
    final topLeft = overlay.globalToLocal(target.localToGlobal(Offset.zero));
    return topLeft & target.size;
  }

  void _syncRect({bool initial = false}) {
    if (!mounted || _finished) return;
    final overlay = context.findRenderObject();
    final viewport = overlay is RenderBox && overlay.hasSize
        ? overlay.size
        : MediaQuery.sizeOf(context);
    final next = _measure(widget.steps[_index].targetKey);
    if (next == null) return;
    if (initial || _viewport != viewport) {
      setState(() {
        _viewport = viewport;
        _rect = next;
        _fromRect = next;
        _toRect = next;
        _fromRadius = widget.steps[_index].radius;
        _toRadius = _fromRadius;
      });
      return;
    }
    if (_rect != next) {
      setState(() {
        _viewport = viewport;
        _rect = next;
      });
    }
  }

  void _next() {
    if (_finished) return;
    if (_index >= widget.steps.length - 1) {
      _finish();
      return;
    }
    final current = _rect;
    final next = _measure(widget.steps[_index + 1].targetKey);
    setState(() {
      _index++;
      _fromRect = current;
      _toRect = next;
      _fromRadius = widget.steps[_index - 1].radius;
      _toRadius = widget.steps[_index].radius;
    });
    if (next == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _syncRect());
    } else {
      _morph.forward(from: 0);
    }
  }

  void _finish() => _close(widget.onDone);

  void _skip() => _close(widget.onSkip ?? widget.onDone);

  void _close(VoidCallback done) {
    if (_closing) return;
    _closing = true;
    _fade.forward(from: 0).whenComplete(() {
      if (!mounted) return;
      setState(() => _finished = true);
      done();
    });
  }

  Rect? get _currentRect {
    if (_fromRect == null || _toRect == null) return _rect;
    return Rect.lerp(_fromRect, _toRect, _morph.value);
  }

  double get _currentRadius {
    final t = Curves.easeOutCubic.transform(_morph.value);
    return _fromRadius + (_toRadius - _fromRadius) * t;
  }

  @override
  Widget build(BuildContext context) {
    if (_finished) return const SizedBox.shrink();
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return Opacity(
      opacity: 1 - _fade.value,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(constraints.maxWidth, constraints.maxHeight);
          final rect = _currentRect;
          final step = widget.steps[_index];
          final bubbleAbove = rect != null && rect.top > 260;
          final bubbleWidth = (size.width - 36).clamp(240.0, 320.0);
          final targetCenter = rect?.center;
          final left = targetCenter == null
              ? 18.0
              : (targetCenter.dx - bubbleWidth / 2).clamp(
                  12.0,
                  size.width - bubbleWidth - 12,
                );
          final pointerX = targetCenter == null
              ? bubbleWidth / 2
              : (targetCenter.dx - left).clamp(24.0, bubbleWidth - 24);

          return Stack(
            fit: StackFit.expand,
            children: [
              // 拦截遮罩外的点击，避免引导期间误触底层。
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {},
                child: CustomPaint(
                  painter: _SpotlightPainter(
                    rect: rect,
                    radius: _currentRadius,
                    pulse: reduceMotion ? 0.5 : _pulse.value,
                  ),
                ),
              ),
              if (rect != null)
                Positioned(
                  left: left,
                  width: bubbleWidth,
                  bottom: bubbleAbove ? size.height - rect.top + 8 : null,
                  top: bubbleAbove ? null : rect.bottom + 8,
                  child: TweenAnimationBuilder<double>(
                    key: ValueKey('spotlight-$_index'),
                    tween: Tween(begin: 0.88, end: 1),
                    duration: reduceMotion
                        ? Duration.zero
                        : const Duration(milliseconds: 320),
                    curve: Curves.easeOutBack,
                    builder: (context, scale, child) => Transform.scale(
                      scale: scale,
                      alignment: Alignment.topCenter,
                      child: child,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (!bubbleAbove)
                          Padding(
                            padding: EdgeInsets.only(left: pointerX - 9),
                            child: const _Pointer(up: true),
                          ),
                        _Bubble(
                          step: step,
                          index: _index,
                          total: widget.steps.length,
                          onNext: _next,
                        ),
                        if (bubbleAbove)
                          Padding(
                            padding: EdgeInsets.only(left: pointerX - 9),
                            child: const _Pointer(up: false),
                          ),
                      ],
                    ),
                  ),
                ),
              Positioned(
                top: MediaQuery.paddingOf(context).top + 52,
                right: 14,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.38),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.14),
                    ),
                  ),
                  child: TextButton(
                    onPressed: _skip,
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 5,
                      ),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      foregroundColor: Colors.white.withValues(alpha: 0.78),
                    ),
                    child: const Text(
                      '跳过',
                      style: TextStyle(fontSize: 12, height: 1.2),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.step,
    required this.index,
    required this.total,
    required this.onNext,
  });

  final SpotlightStep step;
  final int index;
  final int total;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final last = index == total - 1;
    return Container(
      padding: const EdgeInsets.fromLTRB(17, 14, 17, 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: const [
          BoxShadow(
            color: Color(0x66000000),
            blurRadius: 28,
            offset: Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 22,
                height: 22,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: const Color(AppColors.accent).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(7),
                ),
                child: const Icon(
                  Icons.auto_awesome_rounded,
                  size: 13,
                  color: Color(AppColors.accent),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${index + 1}/$total',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1,
                  color: Color(0xFF6B7280),
                ),
              ),
              const Spacer(),
              if (!last)
                Text(
                  '点这里试试',
                  style: TextStyle(
                    fontSize: 10.5,
                    color: Colors.black.withValues(alpha: 0.34),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            step.title,
            style: const TextStyle(
              fontSize: 18,
              height: 1.2,
              fontWeight: FontWeight.w800,
              color: Color(0xFF111315),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            step.body,
            style: const TextStyle(
              fontSize: 12.5,
              height: 1.55,
              color: Color(0xFF5B6068),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    for (var i = 0; i < total; i++)
                      Container(
                        margin: const EdgeInsets.only(right: 5),
                        width: i == index ? 16 : 5,
                        height: 5,
                        decoration: BoxDecoration(
                          color: i == index
                              ? const Color(AppColors.accent)
                              : const Color(0xFFD9DDE3),
                          borderRadius: BorderRadius.circular(9),
                        ),
                      ),
                  ],
                ),
              ),
              GestureDetector(
                onTap: onNext,
                behavior: HitTestBehavior.opaque,
                child: Container(
                  height: 32,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: const Color(AppColors.accent),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        last ? '知道了' : '下一步',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                      if (!last) ...[
                        const SizedBox(width: 4),
                        const Icon(
                          Icons.arrow_forward_rounded,
                          size: 13,
                          color: Colors.white,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Pointer extends StatelessWidget {
  const _Pointer({required this.up});

  final bool up;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(18, 9),
      painter: _PointerPainter(up: up),
    );
  }
}

class _PointerPainter extends CustomPainter {
  const _PointerPainter({required this.up});

  final bool up;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Path();
    if (up) {
      p
        ..moveTo(size.width / 2, 0)
        ..lineTo(size.width, size.height)
        ..lineTo(0, size.height);
    } else {
      p
        ..moveTo(0, 0)
        ..lineTo(size.width, 0)
        ..lineTo(size.width / 2, size.height);
    }
    canvas.drawPath(p, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant _PointerPainter oldDelegate) =>
      oldDelegate.up != up;
}

class _SpotlightPainter extends CustomPainter {
  const _SpotlightPainter({
    required this.rect,
    required this.radius,
    required this.pulse,
  });

  final Rect? rect;
  final double radius;
  final double pulse;

  @override
  void paint(Canvas canvas, Size size) {
    final outer = Path()..addRect(Offset.zero & size);
    Path? hole;
    RRect? holeRrect;
    if (rect != null) {
      final holeRect = rect!.inflate(6);
      holeRrect = RRect.fromRectAndRadius(
        holeRect,
        Radius.circular(radius + 4),
      );
      hole = Path()..addRRect(holeRrect);
      // 一层很淡的主色光晕，让洞口边缘像舞台灯。
      canvas.drawRRect(
        holeRrect.inflate(10),
        Paint()
          ..color = const Color(AppColors.accent).withValues(alpha: 0.12)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12),
      );
    }
    final mask = hole == null
        ? outer
        : Path.combine(PathOperation.difference, outer, hole);
    canvas.drawPath(
      mask,
      Paint()..color = Colors.black.withValues(alpha: 0.70),
    );

    if (holeRrect != null) {
      final alpha = 0.30 + 0.45 * pulse;
      canvas.drawRRect(
        holeRrect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4
          ..color = Colors.white.withValues(alpha: alpha),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SpotlightPainter oldDelegate) =>
      oldDelegate.rect != rect ||
      oldDelegate.radius != radius ||
      oldDelegate.pulse != pulse;
}
