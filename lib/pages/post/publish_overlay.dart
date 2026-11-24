/// 发布悬浮窗：页面关闭、回到首页后，用一张竖版小卡展示发布物与进度。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../design/tokens.dart';
import '../../services/publish_job.dart';

/// 把发布悬浮窗挂到根 Overlay 上；它不随发布页一起销毁。
class PublishOverlay {
  PublishOverlay._();

  static void show(BuildContext context, PublishJob job) {
    final overlay = Overlay.of(context, rootOverlay: true);
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => PublishHoverCard(
        job: job,
        onFinished: () {
          if (entry.mounted) entry.remove();
        },
      ),
    );
    overlay.insert(entry);
  }
}

class PublishHoverCard extends StatefulWidget {
  const PublishHoverCard({
    super.key,
    required this.job,
    required this.onFinished,
  });

  final PublishJob job;
  final VoidCallback onFinished;

  @override
  State<PublishHoverCard> createState() => _PublishHoverCardState();
}

class _PublishHoverCardState extends State<PublishHoverCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim;
  late final Animation<double> _fade;
  late final Animation<double> _scale;
  bool _closing = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
    )..forward();
    _fade = CurvedAnimation(parent: _anim, curve: AppMotion.standard);
    _scale = Tween<double>(
      begin: 0.92,
      end: 1,
    ).animate(CurvedAnimation(parent: _anim, curve: AppMotion.enter));
    widget.job.progress.addListener(_repaint);
    widget.job.stage.addListener(_repaint);
    widget.job.error.addListener(_repaint);
    widget.job.done.then((ok) {
      if (!mounted) return;
      if (ok) {
        HapticFeedback.mediumImpact();
        final wait = widget.job.auditPending
            ? const Duration(milliseconds: 2200)
            : const Duration(milliseconds: 850);
        Future.delayed(wait, () {
          if (mounted) _close();
        });
      } else {
        HapticFeedback.heavyImpact();
        if (mounted) setState(() => _failed = true);
      }
    });
  }

  void _repaint() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.job.progress.removeListener(_repaint);
    widget.job.stage.removeListener(_repaint);
    widget.job.error.removeListener(_repaint);
    _anim.dispose();
    super.dispose();
  }

  void _close() {
    if (_closing) return;
    _closing = true;
    _anim.reverse().whenComplete(() {
      if (mounted) widget.onFinished();
    });
  }

  @override
  Widget build(BuildContext context) {
    final screenW = MediaQuery.sizeOf(context).width;
    // 体积 20：按屏宽 20% 的小竖卡，右上角贴边，顶部留一点呼吸。
    final cardW = screenW * 0.20;
    final cardH = cardW * 1.34;
    final percent = (widget.job.progress.value * 100).round().clamp(0, 100);
    final error = widget.job.error.value;
    final safeTop = MediaQuery.paddingOf(context).top;

    // 不做全屏压黑：发布任务可能持续几分钟，用户仍可正常浏览首页。
    // 半透明黑只罩在卡片自身内容上，保证白色进度环与百分比可读。
    return Stack(
      children: [
        Positioned(
          top: safeTop + 10,
          right: 0,
          child: FadeTransition(
            opacity: _fade,
            child: ScaleTransition(
              scale: _scale,
              child: GestureDetector(
                onTap: _failed ? _close : null,
                child: SizedBox(
                  width: cardW,
                  height: cardH,
                  child: Material(
                    color: Colors.transparent,
                    child: _card(context, percent, error, cardW),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _card(BuildContext context, int percent, String? error, double cardW) {
    final p = widget.job.preview;
    final ring = (cardW * 0.58).clamp(36.0, 50.0);
    final ringInner = ring - 8;
    final percentFont = (cardW * 0.155).clamp(9.5, 13.5);
    final stageFont = (cardW * 0.09).clamp(7.0, 8.0);
    final radius = cardW * 0.18;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.55),
            blurRadius: cardW * 0.30,
            offset: Offset(0, cardW * 0.10),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          _background(p),
          ColoredBox(color: Colors.black.withValues(alpha: 0.22)),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0x4D000000),
                  Color(0x12000000),
                  Color(0xB3000000),
                ],
                stops: [0, 0.52, 1],
              ),
            ),
          ),
          Positioned(
            left: cardW * 0.07,
            top: cardW * 0.07,
            child: Container(
              padding: EdgeInsets.symmetric(
                horizontal: cardW * 0.045,
                vertical: cardW * 0.018,
              ),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.42),
                borderRadius: BorderRadius.circular(cardW * 0.06),
                border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
              ),
              child: Text(
                p.badge,
                style: AppType.micro.copyWith(
                  color: Colors.white.withValues(alpha: 0.9),
                  fontSize: (cardW * 0.095).clamp(7.0, 9.0),
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.3,
                ),
              ),
            ),
          ),
          if (!p.hasMedia && p.content.trim().isNotEmpty)
            Positioned(
              left: cardW * 0.07,
              right: cardW * 0.07,
              top: cardW * 0.25,
              child: Text(
                p.content.trim(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppType.caption.copyWith(
                  color: Colors.white.withValues(alpha: 0.72),
                  fontSize: (cardW * 0.095).clamp(7.2, 9.5),
                  height: 1.3,
                ),
              ),
            ),
          Center(
            child: Container(
              width: ring,
              height: ring,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.26),
                shape: BoxShape.circle,
              ),
              child: Center(
                child: SizedBox(
                  width: ringInner,
                  height: ringInner,
                  child: CustomPaint(
                    painter: _ProgressRingPainter(
                      value: widget.job.progress.value,
                      color: Colors.white,
                      strokeWidth: ring * 0.065,
                    ),
                    child: Center(
                      child: Text(
                        '$percent%',
                        style: AppType.numeric.copyWith(
                          color: Colors.white,
                          fontSize: percentFont,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: cardW * 0.07,
            right: cardW * 0.07,
            bottom: cardW * 0.06,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  error != null && _failed
                      ? '发布失败 · 点此关闭'
                      : widget.job.stage.value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: AppType.micro.copyWith(
                    color: _failed
                        ? const Color(AppColors.danger)
                        : Colors.white.withValues(alpha: 0.82),
                    fontSize: stageFont,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (error != null && _failed) ...[
                  const SizedBox(height: 1),
                  Text(
                    error,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: AppType.micro.copyWith(
                      color: Colors.white.withValues(alpha: 0.52),
                      fontSize: (cardW * 0.075).clamp(6.2, 7.5),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _background(PublishPreview p) {
    Widget fallback() => DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: p.kind == PublishKind.video
              ? const [Color(0xFF13231E), Color(0xFF070B0A)]
              : const [Color(0xFF1A1712), Color(0xFF090909)],
        ),
      ),
      child: Center(
        child: Icon(
          p.kind == PublishKind.video
              ? Icons.movie_creation_outlined
              : Icons.format_quote_rounded,
          size: 32,
          color: Colors.white.withValues(alpha: 0.10),
        ),
      ),
    );

    if (p.imagePath != null && p.imagePath!.isNotEmpty) {
      final f = File(p.imagePath!);
      if (f.existsSync()) {
        return Image.file(
          f,
          fit: BoxFit.cover,
          cacheWidth: 720,
          errorBuilder: (_, _, _) => fallback(),
        );
      }
    }
    if (p.imageBytes != null) {
      return Image.memory(
        p.imageBytes!,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => fallback(),
      );
    }
    return fallback();
  }
}

class _ProgressRingPainter extends CustomPainter {
  _ProgressRingPainter({
    required this.value,
    required this.color,
    this.strokeWidth = 3.4,
  });

  final double value;
  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = (size.shortestSide - strokeWidth) / 2;
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..color = Colors.white.withValues(alpha: 0.20);
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..color = color;
    canvas.drawCircle(center, radius, track);
    final sweep = (value.clamp(0, 1)) * 3.141592653589793 * 2;
    if (sweep > 0) {
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        -3.141592653589793 / 2,
        sweep,
        false,
        arc,
      );
    }
  }

  @override
  bool shouldRepaint(_ProgressRingPainter old) =>
      old.value != value ||
      old.color != color ||
      old.strokeWidth != strokeWidth;
}
