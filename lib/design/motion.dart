/// 流萤社区 · 全局动效原语
///
/// 这一层只放「可复用、可组合」的运动与加载语义，页面不要各自造一套：
/// - [ShimmerScope] / [ShimmerBox]：所有骨架共用的 1.5s 斜向扫光；
/// - [StaggerReveal]：列表项错峰淡入 + 位移；
/// - [SkeletonSwap]：骨架与真实内容交叉淡出，骨架和真实卡片同尺寸；
/// - [LoadMoreDots]：触底加载的三点依次跳动；
/// - [ThinkingDots] / [PhraseRevealText] / [BlinkingCaret]：AI 回复的思考与逐段显现。
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'tokens.dart';

// ============================================================================
// 骨架扫光
// ============================================================================

/// 一个骨架组共享的扫光时钟。所有 [ShimmerBox] 从同一个 controller 取值，
/// 因此同一屏的骨架的亮带是同一道、同步从左往右扫。
///
/// 时钟按「当前是否有骨架」启停：没有骨架时不会常驻调度帧。
class ShimmerScope extends StatefulWidget {
  const ShimmerScope({
    super.key,
    required this.child,
    this.duration = const Duration(milliseconds: 1500),
  });

  final Widget child;
  final Duration duration;

  static ShimmerHandle? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_ShimmerInherited>()
      ?.state
      .handle;

  @override
  State<ShimmerScope> createState() => _ShimmerScopeState();
}

/// 骨架向扫光时钟借用的句柄；最后一个骨架释放后时钟暂停。
class ShimmerHandle {
  const ShimmerHandle({
    required this.controller,
    required this.acquire,
    required this.release,
  });

  final AnimationController controller;
  final VoidCallback acquire;
  final VoidCallback release;
}

class _ShimmerScopeState extends State<ShimmerScope>
    with SingleTickerProviderStateMixin {
  late final AnimationController controller = AnimationController(
    vsync: this,
    duration: widget.duration,
  );
  late final ShimmerHandle handle = ShimmerHandle(
    controller: controller,
    acquire: _acquire,
    release: _release,
  );
  int _users = 0;

  void _acquire() {
    if (!mounted) return;
    _users++;
    if (!controller.isAnimating) controller.repeat();
  }

  void _release() {
    if (!mounted) return;
    _users = math.max(0, _users - 1);
    if (_users == 0 && controller.isAnimating) controller.stop();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _ShimmerInherited(state: this, child: widget.child);
  }
}

class _ShimmerInherited extends InheritedWidget {
  const _ShimmerInherited({required this.state, required super.child});

  final _ShimmerScopeState state;

  @override
  bool updateShouldNotify(_ShimmerInherited oldWidget) =>
      state != oldWidget.state;
}

/// 单个骨架块：保持原有圆角/尺寸，只把呼吸明暗换成共享斜向扫光。
class ShimmerBox extends StatefulWidget {
  const ShimmerBox({
    super.key,
    this.width,
    this.height = 14,
    this.radius = AppRadius.xs,
  });

  final double? width;
  final double height;
  final double radius;

  @override
  State<ShimmerBox> createState() => _ShimmerBoxState();
}

class _ShimmerBoxState extends State<ShimmerBox>
    with SingleTickerProviderStateMixin {
  AnimationController? _own;
  ShimmerHandle? _handle;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final handle = ShimmerScope.maybeOf(context);
    if (handle != _handle) {
      _handle?.release();
      _handle = handle;
      handle?.acquire();
    }
    if (handle != null && _own != null) {
      _own!.dispose();
      _own = null;
    }
    if (handle == null && _own == null) {
      _own = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 1500),
      )..repeat();
    }
  }

  @override
  void dispose() {
    _handle?.release();
    _own?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _handle?.controller ?? _own;
    if (controller == null) return const SizedBox.shrink();
    if (MediaQuery.disableAnimationsOf(context)) {
      return SizedBox(
        width: widget.width ?? double.infinity,
        height: widget.height,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(AppColors.skeletonBase),
            borderRadius: BorderRadius.circular(widget.radius),
          ),
        ),
      );
    }

    return AnimatedBuilder(
      animation: controller,
      builder: (_, _) {
        final w = widget.width;
        final renderWidth = w ?? double.infinity;
        return SizedBox(
          width: renderWidth,
          height: widget.height,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(widget.radius),
            child: ShaderMask(
              blendMode: BlendMode.srcATop,
              shaderCallback: (rect) {
                final travel = (controller.value * 1.8 - 0.4) * rect.width;
                return ui.Gradient.linear(
                  Offset(travel - rect.width * 0.42, -rect.height * 0.2),
                  Offset(travel + rect.width * 0.42, rect.height * 1.2),
                  const [
                    Color(AppColors.skeletonBase),
                    Color(AppColors.skeletonHighlight),
                    Color(AppColors.skeletonBase),
                  ],
                  const [0.0, 0.46, 1.0],
                );
              },
              child: ColoredBox(
                color: const Color(AppColors.skeletonBase),
                child: SizedBox(width: renderWidth, height: widget.height),
              ),
            ),
          ),
        );
      },
    );
  }
}

// ============================================================================
// 错峰出现
// ============================================================================

/// 列表项错峰进入：默认每个 60ms，淡入 + 向上 8px。
///
/// 卡片数量很多时把前 12 个之外共用最后一档延迟，避免用户等 1 秒以上。
class StaggerReveal extends StatefulWidget {
  const StaggerReveal({
    super.key,
    required this.child,
    this.index = 0,
    this.delay = const Duration(milliseconds: 60),
    this.duration = const Duration(milliseconds: 320),
    this.offsetY = 8,
    this.curve = Curves.easeOutCubic,
  });

  final Widget child;
  final int index;
  final Duration delay;
  final Duration duration;
  final double offsetY;
  final Curve curve;

  @override
  State<StaggerReveal> createState() => _StaggerRevealState();
}

class _StaggerRevealState extends State<StaggerReveal>
    with SingleTickerProviderStateMixin {
  late final int _slot = widget.index.clamp(0, 12);
  late final int _delayMs = widget.delay.inMilliseconds * _slot;
  late final int _durationMs = math.max(1, widget.duration.inMilliseconds);
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: _delayMs + _durationMs),
  );
  late final Animation<double> _animation = CurvedAnimation(
    parent: _controller,
    curve: Interval(
      _delayMs / (_delayMs + _durationMs),
      1,
      curve: widget.curve,
    ),
  );

  @override
  void initState() {
    super.initState();
    _controller.forward();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) _controller.value = 1;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (_, child) {
        final v = _animation.value;
        return Opacity(
          opacity: v.clamp(0, 1),
          child: Transform.translate(
            offset: Offset(0, widget.offsetY * (1 - v)),
            child: child,
          ),
        );
      },
      child: widget.child,
    );
  }
}

// ============================================================================
// 骨架 → 内容
// ============================================================================

/// 骨架与真实内容交叉淡出。
///
/// 调用方负责让 [skeleton] 和 [child] 的卡片尺寸一致；这里只做视觉切换，
/// 不改变页面滚动位置。骨架淡出时真实内容同时在下面 60ms 错峰出现。
class SkeletonSwap extends StatelessWidget {
  const SkeletonSwap({
    super.key,
    required this.loading,
    required this.skeleton,
    required this.child,
    this.duration = const Duration(milliseconds: 280),
  });

  final bool loading;
  final Widget skeleton;
  final Widget child;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    final effectiveDuration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : duration;
    return AnimatedSwitcher(
      duration: effectiveDuration,
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      layoutBuilder: (current, previous) => Stack(
        alignment: Alignment.topCenter,
        children: [...previous, ?current],
      ),
      transitionBuilder: (child, animation) =>
          FadeTransition(opacity: animation, child: child),
      child: loading
          ? KeyedSubtree(key: const ValueKey('skeleton'), child: skeleton)
          : KeyedSubtree(key: const ValueKey('content'), child: child),
    );
  }
}

// ============================================================================
// 触底加载
// ============================================================================

/// 三个依次跳动的小圆点。用于列表底部「正在加载下一页」。
class LoadMoreDots extends StatefulWidget {
  const LoadMoreDots({super.key, this.color, this.size = 6});

  final Color? color;
  final double size;

  @override
  State<LoadMoreDots> createState() => _LoadMoreDotsState();
}

class _LoadMoreDotsState extends State<LoadMoreDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  Widget _staticDots(Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(
        3,
        (_) => Padding(
          padding: EdgeInsets.symmetric(horizontal: widget.size * 0.35),
          child: Container(
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? const Color(AppColors.accent);
    if (MediaQuery.disableAnimationsOf(context)) {
      return _staticDots(color);
    }
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            final phase = (_c.value + i * 0.18) % 1.0;
            final active = phase < 0.5 ? math.sin(phase / 0.5 * math.pi) : 0.0;
            return Padding(
              padding: EdgeInsets.symmetric(horizontal: widget.size * 0.35),
              child: Transform.translate(
                offset: Offset(0, -3.4 * active),
                child: Opacity(
                  opacity: 0.32 + 0.68 * active,
                  child: Container(
                    width: widget.size,
                    height: widget.size,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
            );
          }),
        );
      },
    );
  }
}

// ============================================================================
// AI 思考与逐段显现
// ============================================================================

/// 回复气泡里的三点呼吸「正在思考」。
class ThinkingDots extends StatefulWidget {
  const ThinkingDots({super.key, this.color, this.size = 5});

  final Color? color;
  final double size;

  @override
  State<ThinkingDots> createState() => _ThinkingDotsState();
}

class _ThinkingDotsState extends State<ThinkingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? const Color(AppColors.accent);
    if (MediaQuery.disableAnimationsOf(context)) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(
          3,
          (_) => Padding(
            padding: EdgeInsets.symmetric(horizontal: widget.size * 0.28),
            child: Container(
              width: widget.size,
              height: widget.size,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
          ),
        ),
      );
    }
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            final phase = (_c.value + i * 0.16) % 1.0;
            final wave = 0.5 + 0.5 * math.sin(phase * math.pi * 2);
            return Padding(
              padding: EdgeInsets.symmetric(horizontal: widget.size * 0.28),
              child: Opacity(
                opacity: 0.34 + 0.66 * wave,
                child: Transform.scale(
                  scale: 0.85 + 0.25 * wave,
                  child: Container(
                    width: widget.size,
                    height: widget.size,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
            );
          }),
        );
      },
    );
  }
}

/// 流式回复末尾的闪烁光标。
class BlinkingCaret extends StatefulWidget {
  const BlinkingCaret({super.key, this.color, this.height = 13});

  final Color? color;
  final double height;

  @override
  State<BlinkingCaret> createState() => _BlinkingCaretState();
}

class _BlinkingCaretState extends State<BlinkingCaret>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) {
      return Container(
        width: 1.6,
        height: widget.height,
        margin: const EdgeInsets.only(left: 1),
        color: widget.color ?? const Color(AppColors.accent),
      );
    }
    return FadeTransition(
      opacity: Tween<double>(
        begin: 0.18,
        end: 1,
      ).animate(CurvedAnimation(parent: _c, curve: Curves.easeInOut)),
      child: Container(
        width: 1.6,
        height: widget.height,
        margin: const EdgeInsets.only(left: 1),
        color: widget.color ?? const Color(AppColors.accent),
      ),
    );
  }
}

/// 把流式文本切成 2–4 个中文字符左右的小段；英文按单词保留，
/// 避免把 URL、单词切成两半。返回的 chunks 拼接后必须等于原文。
List<String> phraseChunks(String text) {
  if (text.isEmpty) return const [];
  final tokens = <String>[];
  final re = RegExp(r'\s+|[A-Za-z0-9_@#./:%+-]+|[^\sA-Za-z0-9_@#./:%+-]');
  for (final m in re.allMatches(text)) {
    final t = m.group(0);
    if (t != null && t.isNotEmpty) tokens.add(t);
  }

  final chunks = <String>[];
  final buffer = StringBuffer();
  var count = 0;
  void flush() {
    if (buffer.isEmpty) return;
    chunks.add(buffer.toString());
    buffer.clear();
    count = 0;
  }

  for (final token in tokens) {
    final isWord = RegExp(r'^[A-Za-z0-9_@#./:%+-]+$').hasMatch(token);
    final isSpace = token.trim().isEmpty;
    if (isSpace) {
      buffer.write(token);
      continue;
    }
    if (isWord && count > 0) flush();
    buffer.write(token);
    count += token.runes.length;
    if (!isWord && count >= 4) flush();
    if (isWord && count >= 4) flush();
  }
  flush();
  return chunks;
}

/// 流式正文：每段从透明 + 4px 高斯模糊 + 下移 4px 进入，末尾跟一个闪烁光标。
/// 气泡高度用 [AnimatedSize] 平滑增长，文字块不会闪白。
class PhraseRevealText extends StatefulWidget {
  const PhraseRevealText({
    super.key,
    required this.text,
    required this.style,
    this.animate = true,
    this.showCaret = true,
    this.tick = const Duration(milliseconds: 38),
  });

  final String text;
  final TextStyle style;
  final bool animate;
  final bool showCaret;
  final Duration tick;

  @override
  State<PhraseRevealText> createState() => _PhraseRevealTextState();
}

class _PhraseRevealTextState extends State<PhraseRevealText> {
  List<String> _chunks = const [];
  int _shown = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _rebuildChunks(reset: true);
  }

  @override
  void didUpdateWidget(covariant PhraseRevealText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.animate) {
      _timer?.cancel();
      _chunks = phraseChunks(widget.text);
      _shown = _chunks.length;
      return;
    }
    if (!widget.text.startsWith(oldWidget.text) ||
        widget.text.length < oldWidget.text.length) {
      _rebuildChunks(reset: true);
      return;
    }
    _rebuildChunks(reset: false);
  }

  void _rebuildChunks({required bool reset}) {
    _chunks = phraseChunks(widget.text);
    if (!widget.animate) {
      _shown = _chunks.length;
      return;
    }
    if (reset) _shown = 0;
    if (_shown > _chunks.length) _shown = 0;
    if (_shown < _chunks.length) _startTimer();
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(widget.tick, (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_shown >= _chunks.length) {
        timer.cancel();
        return;
      }
      setState(() {
        _shown = math.min(_chunks.length, _shown + 1);
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.animate || MediaQuery.disableAnimationsOf(context)) {
      return Text(widget.text, style: widget.style);
    }
    if (_shown == 0) return const SizedBox(width: 1, height: 1);
    final spans = <InlineSpan>[];
    for (var i = 0; i < _shown && i < _chunks.length; i++) {
      final chunk = _chunks[i];
      if (chunk.trim().isEmpty) {
        spans.add(TextSpan(text: chunk, style: widget.style));
      } else {
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: _RevealChunk(
              key: ValueKey('$i-$chunk'),
              text: chunk,
              style: widget.style,
            ),
          ),
        );
      }
    }
    if (widget.showCaret) {
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: BlinkingCaret(
            color: widget.style.color ?? const Color(AppColors.accent),
          ),
        ),
      );
    }
    return AnimatedSize(
      alignment: Alignment.topLeft,
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOutCubic,
      child: Text.rich(
        TextSpan(style: widget.style, children: spans),
        textAlign: TextAlign.start,
      ),
    );
  }
}

class _RevealChunk extends StatelessWidget {
  const _RevealChunk({super.key, required this.text, required this.style});

  final String text;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
      child: Text(text, style: style),
      builder: (_, v, child) {
        final blur = 4.0 * (1 - v);
        final content = blur <= 0.2
            ? child!
            : ImageFiltered(
                imageFilter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
                child: child,
              );
        return Opacity(
          opacity: v.clamp(0, 1),
          child: Transform.translate(
            offset: Offset(0, 4 * (1 - v)),
            child: content,
          ),
        );
      },
    );
  }
}
