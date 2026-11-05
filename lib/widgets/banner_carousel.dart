/// 首页运营位 Banner：全幅沉浸卡（图片 + 底部渐变 + 标题），自动翻页 + 手势滑动。
/// 空数据时回退「社区活动」引导卡（点击进任务中心）。
library;

import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../api/client.dart';
import '../config.dart';
import '../design/components.dart';
import '../pages/discover/topic_detail_page.dart';
import '../pages/mine/task_center_page.dart';
import '../pages/post/post_detail.dart';
import '../pages/user/user_profile.dart';

class BannerCarousel extends StatefulWidget {
  const BannerCarousel({super.key});

  @override
  State<BannerCarousel> createState() => _BannerCarouselState();
}

class _BannerCarouselState extends State<BannerCarousel> {
  static const double _h = 132;

  List<Map<String, dynamic>> _banners = [];
  bool _loaded = false;
  int _page = 0;
  Timer? _timer;
  PageController? _controller;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await ApiClient.banners();
      if (!mounted) return;
      setState(() {
        _banners = list;
        _loaded = true;
        if (list.isNotEmpty) {
          final n = list.length;
          _controller = PageController(initialPage: (10000 ~/ n) * n);
        }
      });
      _startTimer();
    } catch (_) {
      if (!mounted) return;
      setState(() => _loaded = true);
    }
  }

  void _startTimer() {
    _timer?.cancel();
    if (_banners.length <= 1) return;
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted || _controller == null || !_controller!.hasClients) return;
      final next = (_controller!.page ?? 0).round() + 1;
      _controller!.animateToPage(
        next,
        duration: const Duration(milliseconds: 460),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  void _open(Map<String, dynamic> b) {
    final linkType = (b['linkType'] ?? '') as String;
    final linkId = (b['linkId'] ?? '') as String;
    final nav = Navigator.of(context);
    switch (linkType) {
      case 'post':
        nav.push(MaterialPageRoute(
            builder: (_) => PostDetailPage(postId: linkId)));
      case 'topic':
        nav.push(MaterialPageRoute(
            builder: (_) => TopicDetailPage(topic: linkId)));
      case 'user':
        nav.push(MaterialPageRoute(builder: (_) => UserProfilePage(uid: linkId)));
      default:
        nav.push(MaterialPageRoute(builder: (_) => const TaskCenterPage()));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const SizedBox(
        height: _h,
        child: SkeletonBox(height: _h, radius: AppRadius.md),
      );
    }
    if (_banners.isEmpty) return _fallbackCard();

    final n = _banners.length;
    return SizedBox(
      height: _h,
      child: Stack(
        children: [
          PageView.builder(
            controller: _controller,
            onPageChanged: (i) => setState(() => _page = i % n),
            itemBuilder: (_, i) {
              final b = _banners[i % n];
              final img = (b['image'] ?? '') as String;
              final title = (b['title'] ?? '') as String;
              return PressableScale(
                onTap: () => _open(b),
                scale: 0.98,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (img.isEmpty)
                        const ImagePlaceholder(radius: 0)
                      else
                        CachedNetworkImage(
                          imageUrl: img.startsWith('http') ? img : mediaUrl(img),
                          fit: BoxFit.cover,
                          placeholder: (_, _) => const ImagePlaceholder(radius: 0),
                          errorWidget: (_, _, _) =>
                              const ImagePlaceholder(radius: 0),
                        ),
                      const DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.bottomCenter,
                            end: Alignment.topCenter,
                            colors: [Color(0xE6000000), Color(0x00000000)],
                            stops: [0, 0.75],
                          ),
                        ),
                      ),
                      if (title.isNotEmpty)
                        Positioned(
                          left: AppSpace.x4,
                          right: AppSpace.x4,
                          bottom: AppSpace.x3,
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppType.title.copyWith(
                              fontWeight: FontWeight.w700,
                              shadows: const [
                                Shadow(color: Color(0x99000000), blurRadius: 6)
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
          // 指示点（叠在右下角，不额外占高度）
          Positioned(
            right: AppSpace.x3,
            top: AppSpace.x3,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.35),
                borderRadius: AppRadius.rPill,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < n.clamp(0, 8); i++)
                    AnimatedContainer(
                      duration: AppMotion.fast,
                      margin: const EdgeInsets.symmetric(horizontal: 1.5),
                      width: i == _page ? 12 : 4,
                      height: 4,
                      decoration: BoxDecoration(
                        color: i == _page
                            ? Colors.white
                            : Colors.white.withValues(alpha: 0.45),
                        borderRadius: AppRadius.rPill,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _fallbackCard() {
    return PressableScale(
      onTap: () => _open(const {'linkType': '', 'linkId': ''}),
      scale: 0.98,
      child: Container(
        height: _h,
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.x4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: const Color(AppColors.border)),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              const Color(AppColors.accent).withValues(alpha: 0.22),
              const Color(AppColors.card),
            ],
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(AppColors.accent).withValues(alpha: 0.16),
              ),
              child: const Icon(Icons.local_fire_department_rounded,
                  color: Color(AppColors.accent), size: 22),
            ),
            const SizedBox(width: AppSpace.x3),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('社区活动进行中', style: AppType.title),
                  const SizedBox(height: 3),
                  Text('签到、发帖、互动都能涨经验，冲等级解锁装扮',
                      style: AppType.micro),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded,
                color: Color(AppColors.textTertiary)),
          ],
        ),
      ),
    );
  }
}
