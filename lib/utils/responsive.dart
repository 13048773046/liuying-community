/// 响应式工具：以主流机型宽度 390 为设计基准，区块尺寸按屏幕宽度等比缩放
///
/// 约定：
/// - 区块/容器/图片等"结构性尺寸"用 [rw]/[rh]（随屏幕宽度缩放）
/// - 间距、字号、圆角、图标等保持 dp（Flutter 已按像素密度与系统字号自适应）
/// - 涉及安全区（刘海/打孔/home indicator）统一用 [safeTop]/[safeBottom]
library;

import 'package:flutter/material.dart';

/// 设计基准宽度（主流机型逻辑宽度）
const double kDesignWidth = 390;

/// 按屏幕宽度等比缩放：小屏缩小、大屏放大；横屏/平板取短边，避免溢出
double rw(BuildContext context, double px) {
  final size = MediaQuery.sizeOf(context);
  final base = size.width < size.height ? size.width : size.height;
  return px * base / kDesignWidth;
}

/// 区块高度同 [rw]
double rh(BuildContext context, double px) => rw(context, px);

/// 顶部安全区（状态栏 + 刘海）
double safeTop(BuildContext context) => MediaQuery.paddingOf(context).top;

/// 底部安全区（home indicator）
double safeBottom(BuildContext context) => MediaQuery.paddingOf(context).bottom;
