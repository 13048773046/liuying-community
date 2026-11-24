/// AI 工坊 · 新版视觉色板（深空蓝黑 + 极光青）。
///
/// 只作用于 AI 工坊相关页面（工作台 / 会话抽屉 / 额度与充值 / 账单明细）；
/// 社区其它页面继续用 [AppColors] 的薄荷体系，互不影响。
///
/// 弹窗（推理档位卡片、模型两级选择、＋添加 API）保持原有样式，不引用本文件。
library;

import 'package:flutter/material.dart';

class AfPalette {
  const AfPalette._();

  // ---- 底 ----
  static const int bg = 0xFF06070A;
  static const int bg2 = 0xFF0A0C11;
  static const int card = 0xFF11141B;
  static const int card2 = 0xFF161A23;

  // ---- 线 ----
  static const int line = 0x12FFFFFF; // 7%
  static const int lineStrong = 0x1FFFFFFF; // 12%

  // ---- 文字 ----
  static const int text = 0xFFE9EFF6;
  static const int text2 = 0xA6E9EFF6; // 65%
  static const int text3 = 0x5CE9EFF6; // 36%

  // ---- 主色：极光青 ----
  static const int accent = 0xFF3AC9F5;
  static const int accentDeep = 0xFF1E8FB8;
  static const int accentSoft = 0x143AC9F5; // 背景淡填充 8%
  static const int accentLine = 0x383AC9F5; // 描边 22%
  static const int accentLineStrong = 0x663AC9F5; // 描边 40%
  static const int onAccent = 0xFF04141B;

  // ---- 辅助 ----
  static const int warm = 0xFFFFB35C; // 自有 Key / 额度提醒
  static const int ok = 0xFF4FD6A8;
  static const int danger = 0xFFFF4D4F;

  // ---- 渐变 ----
  static const LinearGradient accentGrad = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF3AC9F5), Color(0xFF22A6D6)],
  );

  static const LinearGradient barGrad = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [Color(0xFF1E8FB8), Color(0xFF3AC9F5)],
  );

  /// 文件卡左侧竖条（自上而下淡出）
  static const LinearGradient edgeGrad = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xFF3AC9F5), Color(0x003AC9F5)],
  );

  /// 发送按钮光晕
  static List<BoxShadow> glow({double opacity = 0.32}) => [
        BoxShadow(
          color: const Color(AfPalette.accent).withValues(alpha: opacity),
          blurRadius: 16,
          spreadRadius: 0,
          offset: const Offset(0, 4),
        ),
      ];
}
