/// 流萤社区 · 全局配置
/// 生产环境与音乐站零侵入共存：社区 API 前缀 /community/api，媒体 /community/api/media/。
library;

import 'package:flutter/widgets.dart';

/// 后端基地址（生产：www.dbmt999.asia；本地调试可改 http://127.0.0.1:8790/community）
const String kApiBase = 'https://www.dbmt999.asia/community/api';

/// 音乐站基地址（账号登录互通：读音乐 users/tokens，登录仍走音乐登录接口）
const String kMusicBase = 'https://www.dbmt999.asia/music';

/// 媒体 URL 拼接
String mediaUrl(String name) => '$kApiBase/media/$name';

/// 头像 URL 拼接
///
/// 音乐端 users.avatar 存的是文件名（如 `{uid}_avatar.jpg`），头像正确访问路径是
/// `GET /music/api/avatar/{uid}`（按用户 id 查文件）。此前前端把文件名直接当完整 URL
/// 使用导致头像一律加载失败，这里统一修复：
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
String avatarUrlOf(String uid) =>
    uid.isEmpty ? '' : '$kMusicBase/api/avatar/$uid';

/// 流萤系列视觉 —— 与流萤音乐 App（Theme.swift）完全一致
class AppTheme {
  /// 主色：低饱和薄荷绿（深底上醒目但不刺眼，同音乐 Theme.accent）
  static const int accent = 0xFF4CD9A5;

  /// 深薄荷底（同音乐 Theme.accentSoft）
  static const int accentSoft = 0xFF1C3A30;

  /// 深黑背景（同音乐 Theme.background）
  static const int bg = 0xFF121214;

  /// 页面画布（比卡片更深的底层，参考小红书深色 tokens #0E0E11）
  static const int canvas = 0xFF0E0E11;

  /// 深灰卡片（同音乐 Theme.card）
  static const int card = 0xFF1C1C1F;

  /// 抬升表面（选中态/浮层/悬停，参考 #282828 层级）
  static const int elevated = 0xFF232327;

  /// 卡片描边（同音乐 Theme.cardBorder）
  static const int border = 0xFF2A2A2E;

  /// 细分割线（参考 rgba(255,255,255,.07)）
  static const int hairline = 0xFF232326;

  /// 点赞激活红（小红书心形红，避免与薄荷绿主色冲突）
  static const int heart = 0xFFFF6B81;

  /// 卡片圆角（小红书 12–16 取中）
  static const double radiusCard = 14;

  /// 弹层顶部圆角（底部 sheet）
  static const double radiusSheet = 16;

  /// 胶囊圆角（按钮）
  static const double radiusPill = 999;

  /// 近白主文字（同音乐 Theme.textPrimary）
  static const int textPrimary = 0xFFECECEC;

  /// 次级文字（同音乐 Theme.textSecondary）
  static const int textSecondary = 0xFF9C9CA0;

  /// 暗灰文字（同音乐 Theme.textTertiary）
  static const int textTertiary = 0xFF626266;

  /// 辅助色：暗紫 / 暗蜜桃 / 暗蓝（同音乐 Theme）
  static const int lilac = 0xFF8F84C7;
  static const int peach = 0xFFC98870;
  static const int sky = 0xFF6FA3C9;

  /// 渐变起点 / 终点（薄荷绿系，用于按钮点缀）
  static const int gradStart = 0xFF4CD9A5;
  static const int gradEnd = 0xFF2FA97E;
}


/// 底部导航栏实际占用高度（不含系统底部安全区的剩余空间）：
/// 内容区避让导航栏时使用，动态随机型安全区变化（导航内容 60 + safeBottom）
double tabBarBottomInset(BuildContext context) =>
    60 + MediaQuery.paddingOf(context).bottom;
