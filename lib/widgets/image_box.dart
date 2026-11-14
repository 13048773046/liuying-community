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
    // 按目标尺寸解码：长列表里原图往往 1080p，全尺寸解码会吃满内存并掉帧。
    // 取目标宽 ×2 作为解码上限，肉眼看不出差别，内存能降一个量级。
    final targetW = width ?? MediaQuery.sizeOf(context).width;
    final cacheW = (targetW * 2).round();
    return SizedBox(
      width: width,
      height: height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: Image.network(
          url,
          fit: fit,
          cacheWidth: cacheW,
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
