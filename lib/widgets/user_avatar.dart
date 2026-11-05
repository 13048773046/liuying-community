/// 通用用户头像组件（沉浸黑：统一走 [AppAvatar] 语义）
///
/// - 有 URL → 网络头像（失败自动回退「名字首字」占位）
/// - 无 URL（未设置头像/解析失败）→ 占位字
/// - [borderColor] 非空时渲染一圈描边（管理员/头像框语义，沿用旧参数）
///
/// 注意：构造参数与旧版完全一致，外部页面（消息、榜单、设置、审核等）直接复用。
library;

import 'package:flutter/material.dart';

import '../config.dart';
import '../design/components.dart';

class UserAvatar extends StatelessWidget {
  const UserAvatar({
    super.key,
    required this.url,
    this.name = '',
    this.size = 40,
    this.borderColor,
  });

  /// 头像 URL（可传空串/文件名，内部走 avatarUrl 智能拼接）
  final String url;
  final String name;
  final double size;

  /// 描边颜色（管理员环 / 头像框）：非空即渲染描边
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final resolved = avatarUrl(url);
    return AppAvatar(
      url: resolved.isEmpty ? null : resolved,
      size: size,
      name: name,
      ring: borderColor != null,
      ringColor: borderColor,
    );
  }
}
