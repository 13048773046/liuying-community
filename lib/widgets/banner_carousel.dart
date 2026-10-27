/// 首页运营位 Banner 轮播：/banners 列表，自动轮播 + 圆点指示
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
      });
      if (list.length > 1) {
        _timer = Timer.periodic(const Duration(seconds: 4), (_) {
          if (!mounted || _banners.isEmpty) return;
          setState(() => _page = (_page + 1) % _banners.length);
        });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _loaded = true);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
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
    final banners = _banners.isEmpty
        ? [
            {
              'image': '',
              'linkType': '',
              'linkId': '',
              'fallback': true,
            }
          ]
        : _banners;
    return Column(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: SizedBox(
            height: 104,
            width: double.infinity,
            child: PageView.builder(
              onPageChanged: (i) {
                if (_banners.length > 1) setState(() => _page = i);
              },
              itemCount: banners.length,
              itemBuilder: (_, i) {
                final b = banners[i];
                final img = (b['image'] ?? '') as String;
                if (b['fallback'] == true || img.isEmpty) {
                  return GestureDetector(
                    onTap: () => _open(b),
                    child: Container(
                      width: double.infinity,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              Color(AppTheme.accent),
                              Color(AppTheme.lilac)
                            ]),
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
                              style: TextStyle(
                                  color: Colors.black54, fontSize: 12)),
                        ],
                      ),
                    ),
                  );
                }
                return GestureDetector(
                  onTap: () => _open(b),
                  child: CachedNetworkImage(
                    imageUrl: img.startsWith('http')
                        ? img
                        : mediaUrl(img),
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
        if (banners.length > 1) ...[
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < banners.length; i++)
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
      ],
    );
  }
}
