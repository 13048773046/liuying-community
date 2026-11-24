// 验证码倒计时：按下回弹、每秒翻牌、结束时轻轻弹一下。
//
// 登录页里只保留「能不能发」的业务判断；倒计时、翻牌与按压反馈都在这里，
// 避免每个入口各写一套 Timer 和数字切换。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'tokens.dart';

class FlipCountdownButton extends StatefulWidget {
  const FlipCountdownButton({
    super.key,
    required this.onSend,
    this.idleLabel = '发送验证码',
    this.resendLabel = '重新获取',
    this.countdownSuffix = 's 后重发',
    this.seconds = 60,
    this.enabled = true,
    this.width,
  });

  /// 返回 true 时才进入倒计时；发送失败/邮箱不合法返回 false。
  final Future<bool> Function() onSend;
  final String idleLabel;
  final String resendLabel;
  final String countdownSuffix;
  final int seconds;
  final bool enabled;
  final double? width;

  @override
  State<FlipCountdownButton> createState() => _FlipCountdownButtonState();
}

class _FlipCountdownButtonState extends State<FlipCountdownButton>
    with TickerProviderStateMixin {
  late final AnimationController _bounce = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );
  late final Animation<double> _bounceScale = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween<double>(
        begin: 1.0,
        end: 1.065,
      ).chain(CurveTween(curve: Curves.easeOutCubic)),
      weight: 28,
    ),
    TweenSequenceItem(
      tween: Tween<double>(
        begin: 1.065,
        end: 1.0,
      ).chain(CurveTween(curve: Curves.elasticOut)),
      weight: 72,
    ),
  ]).animate(_bounce);

  Timer? _timer;
  int _left = 0;
  bool _sending = false;
  bool _pressed = false;
  bool _everSent = false;

  bool get _cooling => _left > 0;
  bool get _active => widget.enabled && !_cooling && !_sending;

  @override
  void dispose() {
    _timer?.cancel();
    _bounce.dispose();
    super.dispose();
  }

  Future<void> _tap() async {
    if (!_active) return;
    setState(() => _sending = true);
    var ok = false;
    try {
      ok = await widget.onSend();
    } finally {
      if (mounted) setState(() => _sending = false);
    }
    if (!mounted || !ok) return;
    _startCountdown();
  }

  void _startCountdown() {
    _timer?.cancel();
    setState(() {
      _left = widget.seconds;
      _everSent = true;
    });
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      if (_left <= 1) {
        t.cancel();
        setState(() => _left = 0);
        _bounce.forward(from: 0);
      } else {
        setState(() => _left--);
      }
    });
  }

  String get _label {
    if (_sending) return '发送中…';
    if (_cooling) return '$_left${widget.countdownSuffix}';
    return _everSent ? widget.resendLabel : widget.idleLabel;
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final fg = _cooling || !widget.enabled
        ? const Color(AppColors.textSecondary)
        : const Color(AppColors.onAccent);
    final bg = _cooling
        ? const Color(0xFF27272E)
        : widget.enabled
        ? const Color(AppColors.accent)
        : Colors.white.withValues(alpha: 0.08);

    return Semantics(
      button: true,
      enabled: _active,
      label: _label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: _active ? (_) => setState(() => _pressed = true) : null,
        onTapUp: _active ? (_) => setState(() => _pressed = false) : null,
        onTapCancel: _active ? () => setState(() => _pressed = false) : null,
        onTap: _active ? _tap : null,
        child: AnimatedScale(
          scale: _pressed ? 0.94 : 1,
          duration: reduceMotion
              ? Duration.zero
              : const Duration(milliseconds: 90),
          curve: Curves.easeOut,
          child: ScaleTransition(
            scale: reduceMotion
                ? const AlwaysStoppedAnimation<double>(1)
                : _bounceScale,
            child: AnimatedContainer(
              duration: reduceMotion
                  ? Duration.zero
                  : const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              width: widget.width,
              height: 40,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(999),
                boxShadow: !_cooling && widget.enabled
                    ? AppEffects.accentGlow()
                    : null,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (_sending)
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.8,
                        color: fg,
                      ),
                    ),
                  if (_sending) const SizedBox(width: 6),
                  if (_cooling) ...[
                    _FlipNumber(
                      value: _left,
                      animate: !reduceMotion,
                      style: AppType.label.copyWith(
                        color: fg,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    Text(
                      widget.countdownSuffix,
                      style: AppType.label.copyWith(
                        color: fg,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ] else
                    Flexible(
                      child: Text(
                        _label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppType.label.copyWith(
                          color: fg,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FlipNumber extends StatelessWidget {
  const _FlipNumber({
    required this.value,
    required this.style,
    this.animate = true,
  });

  final int value;
  final TextStyle style;
  final bool animate;

  @override
  Widget build(BuildContext context) {
    final text = value.toString().padLeft(2, '0');
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final d in text.split(''))
          _FlipDigit(digit: d, style: style, animate: animate),
      ],
    );
  }
}

class _FlipDigit extends StatefulWidget {
  const _FlipDigit({
    required this.digit,
    required this.style,
    required this.animate,
  });

  final String digit;
  final TextStyle style;
  final bool animate;

  @override
  State<_FlipDigit> createState() => _FlipDigitState();
}

class _FlipDigitState extends State<_FlipDigit>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
    value: 1,
  );
  late String _old = widget.digit;

  @override
  void didUpdateWidget(covariant _FlipDigit oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.digit != widget.digit) {
      _old = oldWidget.digit;
      if (widget.animate) {
        _ctl.forward(from: 0);
      } else {
        _ctl.value = 1;
      }
    }
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curve = CurvedAnimation(parent: _ctl, curve: Curves.easeOutCubic);
    final oldY = Tween(
      begin: Offset.zero,
      end: const Offset(0, -1),
    ).animate(curve);
    final newY = Tween(
      begin: const Offset(0, 1),
      end: Offset.zero,
    ).animate(curve);
    final digitHeight = (widget.style.fontSize ?? 13) * 1.25;
    return SizedBox(
      width: (widget.style.fontSize ?? 13) * 0.72,
      height: digitHeight,
      child: ClipRect(
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (_ctl.value < 1)
              SlideTransition(
                position: oldY,
                child: Text(_old, style: widget.style),
              ),
            SlideTransition(
              position: newY,
              child: Text(widget.digit, style: widget.style),
            ),
          ],
        ),
      ),
    );
  }
}
