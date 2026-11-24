/// 首页远程公告卡：内容、按钮、跳转链接、是否可关闭都由热更新后台控制。
library;

import 'package:flutter/material.dart';
import '../design/components.dart';
import '../services/secure_links.dart';
import '../services/hot_update.dart';

class HotAnnouncementCard extends StatefulWidget {
  const HotAnnouncementCard({super.key});

  @override
  State<HotAnnouncementCard> createState() => _HotAnnouncementCardState();
}

class _HotAnnouncementCardState extends State<HotAnnouncementCard> {
  String _id = '';
  bool _ready = false;
  bool _dismissed = false;

  @override
  void initState() {
    super.initState();
    HotUpdateService.instance.config.addListener(_sync);
    _sync();
  }

  @override
  void dispose() {
    HotUpdateService.instance.config.removeListener(_sync);
    super.dispose();
  }

  Future<void> _sync() async {
    final ann = HotUpdateService.instance.config.value.announcement;
    final id = ann == null ? '' : HotUpdateService.instance.config.value.announcementId;
    if (!mounted) return;
    if (id == _id && _ready) {
      setState(() {});
      return;
    }
    _id = id;
    final dismissed = id.isEmpty
        ? false
        : await HotUpdateService.instance.isAnnouncementDismissed(id);
    if (!mounted) return;
    setState(() {
      _dismissed = dismissed;
      _ready = true;
    });
  }

  Future<void> _open(String url) async {
    final ok = await SecureLinks.openExternal(url);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('链接不在安全域名内或无法打开'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _dismiss(String id) async {
    await HotUpdateService.instance.dismissAnnouncement(id);
    if (mounted) setState(() => _dismissed = true);
  }

  @override
  Widget build(BuildContext context) {
    final cfg = HotUpdateService.instance.config.value;
    final ann = cfg.announcement;
    if (ann == null || !_ready || _dismissed) return const SizedBox.shrink();

    final badge = (ann['badge'] ?? '').toString().trim();
    final title = (ann['title'] ?? '').toString().trim();
    final body = (ann['body'] ?? '').toString().trim();
    final actionText = (ann['actionText'] ?? '').toString().trim();
    final actionUrl = (ann['actionUrl'] ?? '').toString().trim();
    final dismissible = ann['dismissible'] != false;
    final hasAction = actionText.isNotEmpty && actionUrl.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: ClipRRect(
        borderRadius: AppRadius.rMd,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                const Color(AppColors.accentSoft).withValues(alpha: 0.95),
                const Color(AppColors.card).withValues(alpha: 0.96),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: AppRadius.rMd,
            border: Border.all(
              color: const Color(AppColors.accent).withValues(alpha: 0.22),
            ),
          ),
          child: Stack(
            children: [
              Positioned(
                right: -28,
                top: -42,
                child: Container(
                  width: 120,
                  height: 120,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        const Color(AppColors.accent).withValues(alpha: 0.14),
                        Colors.transparent,
                      ],
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(15, 14, 12, 13),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (badge.isNotEmpty) ...[
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(AppColors.accent)
                                  .withValues(alpha: 0.14),
                              borderRadius: AppRadius.rPill,
                              border: Border.all(
                                color: const Color(AppColors.accent)
                                    .withValues(alpha: 0.25),
                              ),
                            ),
                            child: Text(
                              badge,
                              style: AppType.micro.copyWith(
                                color: const Color(AppColors.accent),
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                        ],
                        Expanded(
                          child: Text(
                            title,
                            style: AppType.body.copyWith(
                              fontWeight: FontWeight.w700,
                              height: 1.35,
                            ),
                          ),
                        ),
                        if (dismissible)
                          InkResponse(
                            onTap: () => _dismiss(cfg.announcementId),
                            radius: 17,
                            child: const Padding(
                              padding: EdgeInsets.only(left: 8, bottom: 4),
                              child: Icon(
                                Icons.close_rounded,
                                size: 16,
                                color: Color(AppColors.textTertiary),
                              ),
                            ),
                          ),
                      ],
                    ),
                    if (body.isNotEmpty) ...[
                      const SizedBox(height: 7),
                      Text(
                        body,
                        style: AppType.caption.copyWith(
                          color: const Color(AppColors.textSecondary),
                          height: 1.6,
                        ),
                      ),
                    ],
                    if (hasAction) ...[
                      const SizedBox(height: 10),
                      InkWell(
                        onTap: () => _open(actionUrl),
                        borderRadius: AppRadius.rXs,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                actionText,
                                style: AppType.caption.copyWith(
                                  color: const Color(AppColors.accent),
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(width: 3),
                              const Icon(
                                Icons.arrow_forward_rounded,
                                size: 14,
                                color: Color(AppColors.accent),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
