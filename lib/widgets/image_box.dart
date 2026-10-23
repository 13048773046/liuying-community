/// 通用网络图片（深色主题下加载/错误占位统一风格）
library;

import 'package:flutter/material.dart';

import '../config.dart';

class CachedNetworkImageCompat extends StatelessWidget {
  final String url;
  final double? width;
  final double? height;
  final BoxFit fit;
  final double borderRadius;
  const CachedNetworkImageCompat(
      {super.key,
      required this.url,
      this.width,
      this.height,
      this.fit = BoxFit.cover,
      this.borderRadius = 0});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: Image.network(
          url,
          fit: fit,
          errorBuilder: (_, __, ___) => Container(
            color: const Color(AppTheme.card),
            child: const Icon(Icons.broken_image,
                color: Color(AppTheme.textTertiary), size: 28),
          ),
          loadingBuilder: (_, child, prog) =>
              prog == null ? child : Container(color: const Color(AppTheme.card)),
        ),
      ),
    );
  }
}
