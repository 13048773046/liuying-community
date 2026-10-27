/// 首页运营位 Banner 无限轮播：/banners 列表，自动翻页 + 手势滑动 + 无限续接
/// 空数据时回退「社区活动」默认卡（可点击进任务中心）
library;

import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../api/client.dart';
import '../config.dart';
import '../pages/mine/task_center_page.dart';
import '../pages/post/post_detail.dart';
import '../pages/user/user_profile.dart';
import '../pages/discover/topic_detail_page.dart';

class BannerCarousel extends StatefulWidget {
  const BannerCarousel({super.key});

  @override
  State<BannerCarousel> createState() => _BannerCarouselState();
}

class _BannerCarouselState extends State<BannerCarousel> {
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
        // 无限续接：初始页取「对长度取整的大数」，保证 index % length == 0
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
    _timer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (!mounted || _controller == null || !_controller!.hasClients) return;
      final next = _controller!.page!.round() + 1;
      _controller!.animateToPage(
        next,
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeInOut,
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
    final target = Navigator.of(context);
    switch (linkType) {
      case 'post':
        target.push(MaterialPageRoute(
            builder: (_) => PostDetailPage(postId: linkId)));
      case 'topic':
        target.push(MaterialPageRoute(
            builder: (_) => TopicDetailPage(topic: linkId)));
      case 'user':
        target.push(MaterialPageRoute(
            builder: (_) => UserProfilePage(uid: linkId)));
      default:
        target.push(
            MaterialPageRoute(builder: (_) => const TaskCenterPage()));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return Container(
        height: 104,
        decoration: BoxDecoration(
          color: const Color(AppTheme.card),
          borderRadius: BorderRadius.circular(14),
        ),
      );
    }
    if (_banners.isEmpty) {
      return GestureDetector(
        onTap: () => _open(const {'linkType': '', 'linkId': ''}),
        child: Container(
          height: 104,
          width: double.infinity,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(AppTheme.accent), Color(AppTheme.lilac)]),
            borderRadius: BorderRadius.circular(14),
          ),
          padding: const EdgeInsets.all(14),
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('🔥 社区活动',
                  style: TextStyle(
                      color: Colors.black,
                      fontSize: 16,
                      fontWeight: FontWeight.bold)),
              SizedBox(height: 6),
              Text('参与签到与任务，赢取经验提升等级',
                  style: TextStyle(color: Colors.black54, fontSize: 12)),
            ],
          ),
        ),
      );
    }
    final n = _banners.length;
    return Column(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: SizedBox(
            height: 104,
            width: double.infinity,
            child: PageView.builder(
              controller: _controller,
              onPageChanged: (i) => setState(() => _page = i % n),
              itemBuilder: (_, i) {
                final b = _banners[i % n];
                final img = (b['image'] ?? '') as String;
                return GestureDetector(
                  onTap: () => _open(b),
                  child: img.isEmpty
                      ? Container(
                          color: const Color(AppTheme.card),
                          child: const Center(
                              child: Icon(Icons.image_outlined,
                                  color: Color(AppTheme.textTertiary))),
                        )
                      : CachedNetworkImage(
                          imageUrl:
                              img.startsWith('http') ? img : mediaUrl(img),
                          fit: BoxFit.cover,
                          placeholder: (_, _) =>
                              Container(color: const Color(AppTheme.card)),
                          errorWidget: (_, _, _) =>
                              const Icon(Icons.image_outlined,
                                  color: Color(AppTheme.textTertiary)),
                        ),
                );
              },
            ),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < n; i++)
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                margin: const EdgeInsets.symmetric(horizontal: 2.5),
                width: i == _page ? 14 : 5,
                height: 4,
                decoration: BoxDecoration(
                  color: i == _page
                      ? const Color(AppTheme.accent)
                      : const Color(AppTheme.textTertiary)
                          .withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
          ],
        ),
      ],
    );
  }
}
