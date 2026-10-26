/// 通用用户头像组件
/// - 有 URL → CachedNetworkImage（失败回退默认头像）
/// - 无 URL（未设置头像/解析失败）→ 渐变底 + 名字首字默认头像
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../config.dart';

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
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final resolved = avatarUrl(url);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: borderColor != null
            ? Border.all(color: borderColor!, width: 1.5)
            : null,
      ),
      child: ClipOval(
        child: resolved.isNotEmpty
            ? CachedNetworkImage(
                imageUrl: resolved,
                fit: BoxFit.cover,
                errorWidget: (_, _, _) => _default(),
              )
            : _default(),
      ),
    );
  }

  /// 默认头像：薄荷绿渐变 + 名字首字（无名字时用占位图标）
  Widget _default() {
    final char = name.trim().isNotEmpty ? name.trim().characters.first : '?';
    return Container(
      color: const Color(AppTheme.accentSoft),
      alignment: Alignment.center,
      child: Text(
        char,
        style: TextStyle(
          color: const Color(AppTheme.accent),
          fontSize: size * 0.42,
          fontWeight: FontWeight.bold,
          height: 1,
        ),
      ),
    );
  }
}
