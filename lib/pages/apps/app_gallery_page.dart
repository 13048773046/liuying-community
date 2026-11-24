/// 应用截图全屏查看：沿用社区已有 photo_view 手势，不另造图片查看器。
library;

import 'package:flutter/material.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';

import '../../api/app_market_api.dart';
import '../../design/components.dart';
import '../../widgets/image_box.dart';

class AppGalleryPage extends StatefulWidget {
  const AppGalleryPage({
    super.key,
    required this.images,
    required this.title,
    this.initialIndex = 0,
  });

  final List<String> images;
  final String title;
  final int initialIndex;

  @override
  State<AppGalleryPage> createState() => _AppGalleryPageState();
}

class _AppGalleryPageState extends State<AppGalleryPage> {
  late final PageController _controller = PageController(
    initialPage: widget.initialIndex.clamp(0, widget.images.length - 1),
  );
  late int _index = widget.initialIndex.clamp(0, widget.images.length - 1);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ImmersivePage(
      background: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          PhotoViewGallery.builder(
            scrollPhysics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics(),
            ),
            itemCount: widget.images.length,
            pageController: _controller,
            backgroundDecoration: const BoxDecoration(color: Colors.black),
            onPageChanged: (i) => setState(() => _index = i),
            builder: (context, i) => PhotoViewGalleryPageOptions(
              imageProvider: cachedImageProvider(
                AppMarketApi.mediaPathToUrl(widget.images[i]),
              ),
              initialScale: PhotoViewComputedScale.contained,
              minScale: PhotoViewComputedScale.contained * 0.8,
              maxScale: PhotoViewComputedScale.covered * 2.2,
              errorBuilder: (_, _, _) =>
                  const ImagePlaceholder(icon: Icons.broken_image_outlined),
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: GlassTopBar(
              title: widget.title,
              subtitle: '${_index + 1} / ${widget.images.length}',
              solid: true,
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: MediaQuery.paddingOf(context).bottom + 18,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: AppRadius.rPill,
                  border: Border.all(color: const Color(AppColors.border)),
                ),
                child: Text(
                  '${_index + 1} / ${widget.images.length}',
                  style: AppType.micro.copyWith(
                    color: const Color(AppColors.textSecondary),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
