/// 通用用户头像组件（沉浸黑：统一走 [AppAvatar] 语义）
///
/// - 有 URL → 网络头像（失败自动回退「名字首字」/ AI 官方图）
/// - 无 URL（未设置头像/解析失败）→ 优先按 [uid] 走头像代理；AI 账号用官方图
/// - [borderColor] 非空时渲染一圈描边（管理员/头像框语义，沿用旧参数）
///
/// 全站头像统一从这里补认证与 AI 语义，避免每个页面各自判断。
library;

import 'package:flutter/material.dart';

import '../config.dart';
import '../design/components.dart';

class UserAvatar extends StatelessWidget {
  const UserAvatar({
    super.key,
    required this.url,
    this.uid = '',
    this.name = '',
    this.size = 40,
    this.borderColor,
    this.verified = false,
    this.verifiedLabel = '',
    this.isAi = false,
    this.frameUrl = '',
  });

  /// 头像 URL（可传空串/文件名，内部走 avatarUrl 智能拼接）
  final String url;
  final String name;
  final double size;

  /// 用户 id：URL 为空或文件名无法解析时，直接用 `avatarUrlOf(uid)` 兜底。
  final String uid;

  /// 描边颜色（管理员环 / 头像框）：非空即渲染描边
  final Color? borderColor;

  /// 已认证；[verifiedLabel] 非空（如 AI/官方）也视为已认证。
  final bool verified;
  final String verifiedLabel;

  /// AI 官方账号：无头像 URL 或网络加载失败时展示小萤官方静态图。
  final bool isAi;

  /// 头像框 URL（透明 PNG）
  final String frameUrl;

  @override
  Widget build(BuildContext context) {
    final raw = url.trim();
    final label = verifiedLabel.trim();
    final resolved = avatarUrlFor(raw, uid);
    final aiAccount = isAi || label.toUpperCase() == 'AI';
    return AppAvatar(
      url: resolved.isEmpty ? null : resolved,
      size: size,
      name: name,
      ring: borderColor != null,
      ringColor: borderColor,
      verified: verified || label.isNotEmpty,
      isAi: aiAccount,
      frameUrl: frameUrl.isEmpty ? null : frameUrl,
    );
  }
}
