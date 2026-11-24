/// 首页运营位 Banner：全幅沉浸卡（图片 + 左下角运营文案），自动翻页 + 手势滑动。
///
/// 数据来自 `/banners`：`list` 为启用 Banner；`fallback` 仅在没有启用 Banner
/// 时作为空态运营卡显示。真实 Banner 的图片加载失败不会再退化成活动卡。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/secure_links.dart';

import '../api/client.dart';
import '../config.dart';
import '../design/components.dart';
import '../pages/apps/app_detail_page.dart';
import '../pages/discover/topic_detail_page.dart';
import '../pages/mine/task_center_page.dart';
import '../pages/post/post_detail.dart';
import '../pages/user/user_profile.dart';
import 'image_box.dart';

class BannerCarousel extends StatefulWidget {
  const BannerCarousel({super.key});

  @override
  State<BannerCarousel> createState() => _BannerCarouselState();
}

class _BannerCarouselState extends State<BannerCarousel>
    with WidgetsBindingObserver {
  static const double _h = 132;

  List<Map<String, dynamic>> _banners = const [];
  Map<String, dynamic>? _fallback;
  bool _loaded = false;
  bool _loading = false;
  int _page = 0;
  Timer? _timer;
  bool _userDragging = false;
  PageController? _controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 后台运营改完后，App 回前台立即重新拉一次，不要求杀进程。
    if (state == AppLifecycleState.resumed) _load(silent: true);
  }

  Future<void> _load({bool silent = false}) async {
    if (_loading) return;
    _loading = true;
    try {
      final payload = await ApiClient.banners();
      if (!mounted) return;
      final list = ((payload['list'] ?? const []) as List)
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList(growable: false);
      final fbRaw = payload['fallback'];
      final fallback = fbRaw is Map
          ? Map<String, dynamic>.from(fbRaw)
          : <String, dynamic>{'enabled': false};
      setState(() {
        _banners = list;
        _fallback = fallback;
        _loaded = true;
        if (list.isEmpty) {
          _page = 0;
        } else if (_page >= list.length) {
          _page = 0;
        }
        if (_controller == null && list.isNotEmpty) {
          final n = list.length;
          _controller = PageController(initialPage: (10000 ~/ n) * n);
        }
      });
      _startTimer();
    } catch (_) {
      if (!mounted) return;
      setState(() => _loaded = true);
    } finally {
      _loading = false;
    }
  }

  void _startTimer() {
    _timer?.cancel();
    if (_banners.length <= 1) return;
    _timer = Timer.periodic(const Duration(milliseconds: 4200), (_) {
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
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _open(Map<String, dynamic> b) async {
    final linkType = (b['linkType'] ?? '').toString().trim().toLowerCase();
    final linkId = (b['linkId'] ?? '').toString().trim();
    final nav = Navigator.of(context);
    switch (linkType) {
      case 'post':
        if (linkId.isEmpty) {
          _toast('这条运营位还没有配置帖子');
          return;
        }
        nav.push(
          MaterialPageRoute(builder: (_) => PostDetailPage(postId: linkId)),
        );
        return;
      case 'topic':
        if (linkId.isEmpty) {
          _toast('这条运营位还没有配置话题');
          return;
        }
        nav.push(
          MaterialPageRoute(builder: (_) => TopicDetailPage(topic: linkId)),
        );
        return;
      case 'user':
        if (linkId.isEmpty) {
          _toast('这条运营位还没有配置用户');
          return;
        }
        nav.push(
          MaterialPageRoute(builder: (_) => UserProfilePage(uid: linkId)),
        );
        return;
      case 'app':
        if (linkId.isEmpty) {
          _toast('这条运营位还没有配置应用');
          return;
        }
        nav.push(
          MaterialPageRoute(builder: (_) => AppDetailPage(appId: linkId)),
        );
        return;
      case 'task':
        nav.push(MaterialPageRoute(builder: (_) => const TaskCenterPage()));
        return;
      case 'none':
      case '':
        return;
      case 'url':
      default:
        // 运营位允许「只放图、不配跳转」：空链接是合法状态，安静地不响应。
        if (linkId.isEmpty) return;
        final uri = SecureLinks.httpsUri(linkId);
        if (uri == null) {
          _toast('这条运营位只允许 HTTPS 安全链接');
          return;
        }
        final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
        if (!ok) _toast('没有找到可以打开这个链接的应用');
        return;
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
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
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: Stack(
          children: [
            NotificationListener<ScrollNotification>(
              onNotification: (n) {
                // 手动滑动后重置自动翻页计时：从用户松手重新计 4.2 秒，
                // 避免“刚滑完立刻又被自动翻走”。
                if (n is ScrollStartNotification && n.dragDetails != null) {
                  _userDragging = true;
                  _timer?.cancel();
                } else if (n is ScrollEndNotification && _userDragging) {
                  _userDragging = false;
                  _startTimer();
                }
                return false;
              },
              child: PageView.builder(
                controller: _controller,
                itemCount: 100000,
                onPageChanged: (i) => setState(() => _page = i % n),
                itemBuilder: (_, i) {
                  final b = _banners[i % n];
                  final img = (b['image'] ?? '').toString();
                  final title = (b['title'] ?? '').toString().trim();
                  return PressableScale(
                    onTap: () => _open(b),
                    scale: 0.98,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        const _BannerCanvas(),
                        if (img.isNotEmpty)
                          BlurUpImage(
                            url: img.startsWith('http') ? img : mediaUrl(img),
                            fit: BoxFit.cover,
                            cacheWidth: 1200,
                            placeholder: const _BannerCanvas(),
                          ),
                        if (title.isNotEmpty) ...[
                          const DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.bottomCenter,
                                end: Alignment.topCenter,
                                colors: [Color(0xD9000000), Color(0x00000000)],
                                stops: [0, 0.55],
                              ),
                            ),
                          ),
                          Positioned(
                            left: AppSpace.x4,
                            right: n > 1 ? 54 : AppSpace.x4,
                            bottom: AppSpace.x3,
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppType.title.copyWith(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                shadows: const [
                                  Shadow(
                                    color: Color(0x99000000),
                                    blurRadius: 8,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  );
                },
              ),
            ),
            if (n > 1)
              Positioned(
                right: AppSpace.x3,
                bottom: AppSpace.x3,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 4,
                  ),
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
                                ? const Color(AppColors.accent)
                                : Colors.white.withValues(alpha: 0.38),
                            borderRadius: AppRadius.rPill,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _fallbackCard() {
    final fb = _fallback;
    if (fb == null || fb['enabled'] != true) return const SizedBox.shrink();
    final title = (fb['title'] ?? '').toString().trim();
    final subtitle = (fb['subtitle'] ?? '').toString().trim();
    if (title.isEmpty && subtitle.isEmpty) return const SizedBox.shrink();
    return PressableScale(
      onTap: () => _open(fb),
      scale: 0.98,
      child: Container(
        height: _h,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: const Color(AppColors.border)),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF12251F), Color(0xFF0D1513), Color(0xFF09090A)],
            stops: [0, 0.52, 1],
          ),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Positioned(
              right: -26,
              top: -42,
              child: Container(
                width: 150,
                height: 150,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(AppColors.accent).withValues(alpha: 0.12),
                ),
              ),
            ),
            Positioned(
              right: 24,
              top: 24,
              child: Icon(
                Icons.auto_awesome_rounded,
                size: 44,
                color: const Color(AppColors.accent).withValues(alpha: 0.62),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 70, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text(
                    '流萤社区 / 今日推荐',
                    style: TextStyle(
                      fontSize: 9,
                      height: 1.2,
                      letterSpacing: 1.2,
                      fontWeight: FontWeight.w700,
                      color: Color(AppColors.accent),
                    ),
                  ),
                  if (title.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.title.copyWith(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                  if (subtitle.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.micro.copyWith(
                        fontSize: 11.5,
                        height: 1.35,
                        color: const Color(AppColors.textTertiary),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 真实 Banner 图片加载前/失败后的底：只做夜色渐变，不显示任何默认运营文案。
class _BannerCanvas extends StatelessWidget {
  const _BannerCanvas();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF12251F), Color(0xFF0D1513), Color(0xFF09090A)],
          stops: [0, 0.52, 1],
        ),
      ),
    );
  }
}
