// 分段标签：下划线实时跟手，拖动时先伸长再收尾，松手按速度吸附。
//
// 用于首页「关注 / 推荐」这类 2–3 项切换。内容切换仍由页面自己的
// 数据状态负责，这里只把「标签+下划线」的手感做对，避免为了动画把
// 整页数据复制成两份。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import 'tokens.dart';

class SegmentedTabs extends StatefulWidget {
  const SegmentedTabs({
    super.key,
    required this.labels,
    required this.index,
    required this.onChanged,
    this.large = false,
    this.cellWidth,
    this.padding = const EdgeInsets.symmetric(horizontal: 4),
  });

  final List<String> labels;
  final int index;
  final ValueChanged<int> onChanged;

  /// 首页用大号字（22/14），常规页面用小号字。
  final bool large;
  final double? cellWidth;
  final EdgeInsets padding;

  @override
  State<SegmentedTabs> createState() => _SegmentedTabsState();
}

class _SegmentedTabsState extends State<SegmentedTabs>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  double _cell = 64;

  int get _count => widget.labels.length;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      lowerBound: 0,
      upperBound: math.max(1, _count - 1).toDouble(),
      value: widget.index.toDouble(),
    );
  }

  @override
  void didUpdateWidget(covariant SegmentedTabs oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.index != oldWidget.index && !_ctrl.isAnimating) {
      _ctrl.animateTo(
        widget.index.toDouble(),
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _onDragStart(DragStartDetails _) {
    _ctrl.stop();
  }

  void _onDragUpdate(DragUpdateDetails d) {
    if (_count < 2) return;
    final next = (_ctrl.value - d.delta.dx / _cell).clamp(
      0.0,
      (_count - 1).toDouble(),
    );
    _ctrl.value = next;
  }

  void _onDragEnd(DragEndDetails d) {
    if (_count < 2) return;
    final v = -(d.primaryVelocity ?? 0) / _cell;
    var target = _ctrl.value.round();
    if (v.abs() > 2.2) {
      target = v > 0 ? _ctrl.value.floor() + 1 : _ctrl.value.ceil() - 1;
    }
    target = target.clamp(0, _count - 1);
    final sim = SpringSimulation(
      const SpringDescription(mass: 0.9, stiffness: 250, damping: 26),
      _ctrl.value,
      target.toDouble(),
      v.clamp(-6.0, 6.0),
    );
    _ctrl.animateWith(sim);
    if (target != widget.index) widget.onChanged(target);
  }

  void _tap(int i) {
    if (i == widget.index) return;
    _ctrl.animateTo(
      i.toDouble(),
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
    widget.onChanged(i);
  }

  @override
  Widget build(BuildContext context) {
    _cell = widget.cellWidth ?? (widget.large ? 64.0 : 58.0);
    final width = _cell * _count + widget.padding.horizontal;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragStart: _onDragStart,
      onHorizontalDragUpdate: _onDragUpdate,
      onHorizontalDragEnd: _onDragEnd,
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, _) {
          final pos = _ctrl.value;
          final frac = pos - pos.floorToDouble();
          final stretch = math.sin(math.pi * frac) * (widget.large ? 14 : 9);
          final indicatorW = (widget.large ? 24.0 : 18.0) + stretch;
          return SizedBox(
            width: width,
            height: widget.large ? 42 : 30,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Row(
                  children: [
                    for (var i = 0; i < _count; i++)
                      _tab(i, (pos - i).abs().clamp(0.0, 1.0)),
                  ],
                ),
                Positioned(
                  left:
                      widget.padding.left +
                      pos * _cell +
                      (_cell - indicatorW) / 2,
                  bottom: 0,
                  width: indicatorW,
                  height: widget.large ? 2.5 : 2,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: const Color(AppColors.accent),
                      borderRadius: BorderRadius.circular(99),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(AppColors.accent)
                              .withValues(alpha: 0.35),
                          blurRadius: 8,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _tab(int i, double distance) {
    final on = distance < 0.5;
    final fontSize = widget.large ? 22 - 8 * distance : 15 - 1.5 * distance;
    final color = Color.lerp(
      const Color(AppColors.textTertiary),
      const Color(AppColors.textPrimary),
      1 - distance,
    )!;
    return SizedBox(
      width: _cell,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _tap(i),
        child: Center(
          child: Text(
            widget.labels[i],
            maxLines: 1,
            style: TextStyle(
              fontFamily: 'NotoSansSC',
              fontSize: fontSize,
              height: 1.1,
              fontWeight: on ? FontWeight.w800 : FontWeight.w500,
              letterSpacing: on ? -0.6 : -0.1,
              color: color,
            ),
          ),
        ),
      ),
    );
  }
}
