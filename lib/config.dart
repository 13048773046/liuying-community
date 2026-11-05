/// 流萤社区 · 全局配置
/// 生产环境与音乐站零侵入共存：社区 API 前缀 /community/api，媒体 /community/api/media/。
library;

import 'package:flutter/widgets.dart';

import 'design/tokens.dart';

/// 后端基地址（生产：www.dbmt999.asia；本地调试可改 http://127.0.0.1:8790/community）
const String kApiBase = 'https://www.dbmt999.asia/community/api';

/// 音乐站基地址（账号登录互通：读音乐 users/tokens，登录仍走音乐登录接口）
const String kMusicBase = 'https://www.dbmt999.asia/music';

/// 媒体 URL 拼接
String mediaUrl(String name) => '$kApiBase/media/$name';

/// 头像 URL 拼接
///
/// 音乐端 users.avatar 存的是文件名（如 `{uid}_avatar.jpg`），头像正确访问路径是
/// `GET /music/api/avatar/{uid}`（按用户 id 查文件）。
/// - 完整 URL（http/https）→ 原样返回
/// - `{uid}_avatar.xxx` 文件名 → 提取 uid 拼 `/music/api/avatar/{uid}`
/// - 其余无法识别 → 原样返回（兜底）
String avatarUrl(String raw) {
  if (raw.isEmpty) return '';
  if (raw.startsWith('http://') || raw.startsWith('https://')) return raw;
  final m = RegExp(r'^([0-9a-zA-Z_\-]+)_avatar\.[a-zA-Z0-9]+$').firstMatch(raw);
  if (m != null) return '$kMusicBase/api/avatar/${m.group(1)}';
  return raw;
}

/// 按用户 id 直接取头像 URL（后端 /music/api/avatar/{uid} 按 id 查 users.avatar）。
/// 优先使用此函数——只要有 uid 即可拿到头像，不依赖 avatar 字段格式。
String avatarUrlOf(String uid) => uid.isEmpty ? '' : '$kMusicBase/api/avatar/$uid';

/// 旧色板兼容层：全量迁移到 [AppColors]（lib/design/tokens.dart）后，此类别名保留，
/// 让尚未迁移的页面继续可用，同时自动继承新设计体系的值。
class AppTheme {
  const AppTheme._();

  /// 主色：低饱和薄荷绿（深底上醒目但不刺眼）
  static const int accent = AppColors.accent;
  static const int accentSoft = AppColors.accentSoft;
  static const int accentPressed = AppColors.accentPressed;
  static const int onAccent = AppColors.onAccent;

  /// 画布 / 表面
  static const int bg = AppColors.bg;
  static const int canvas = AppColors.canvas;
  static const int card = AppColors.card;
  static const int elevated = AppColors.elevated;

  /// 描边 / 分割
  static const int border = AppColors.border;
  static const int hairline = AppColors.hairline;

  /// 语义色
  static const int heart = AppColors.heart;
  static const int warning = AppColors.warning;
  static const int danger = AppColors.danger;

  /// 圆角
  static const double radiusCard = AppRadius.md;
  static const double radiusSheet = 24;
  static const double radiusPill = AppRadius.pill;

  /// 文字
  static const int textPrimary = AppColors.textPrimary;
  static const int textSecondary = AppColors.textSecondary;
  static const int textTertiary = AppColors.textTertiary;
  static const int textDisabled = AppColors.textDisabled;

  /// 辅助色
  static const int lilac = AppColors.lilac;
  static const int peach = AppColors.peach;
  static const int sky = AppColors.sky;

  /// 渐变
  static const int gradStart = AppColors.gradStart;
  static const int gradEnd = AppColors.gradEnd;
}

/// 底部导航栏实际占用高度（不含系统底部安全区的剩余空间）：
/// 内容区避让导航栏时使用，动态随机型安全区变化（导航内容 60 + safeBottom）
double tabBarBottomInset(BuildContext context) =>
    60 + MediaQuery.paddingOf(context).bottom;
