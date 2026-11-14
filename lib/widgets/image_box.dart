/// 通用网络图片（沉浸黑：加载/失败统一用 [ImagePlaceholder]，布局不跳）
library;

import 'package:flutter/material.dart';

import '../design/components.dart';

class CachedNetworkImageCompat extends StatelessWidget {
  final String url;
  final double? width;
  final double? height;
  final BoxFit fit;
  final double borderRadius;

  const CachedNetworkImageCompat({
    super.key,
    required this.url,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.borderRadius = 0,
  });

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
          cacheWidth: ((width ?? MediaQuery.sizeOf(context).width) * 2).round(),
          loadingBuilder: (_, child, progress) => progress == null
              ? child
              : ImagePlaceholder(radius: borderRadius),
          errorBuilder: (_, _, _) => ImagePlaceholder(
            icon: Icons.broken_image_outlined,
            radius: borderRadius,
          ),
        ),
      ),
    );
  }
}
