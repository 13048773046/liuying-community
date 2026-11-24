/// 应用详情 · 分享面板
///
/// 分享应用不是直接把 API JSON 丢给朋友：这里统一走
/// `https://站点/community/app/<id>` 的 H5 落地页，里面有应用介绍、截图和
/// 安装入口。面板本身只负责“复制 / 系统分享 / 分享已下载的安装包”。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../design/components.dart';
import '../../design/system.dart';
import '../../models/app_market.dart';
import '../../services/app_download_manager.dart';
import 'app_widgets.dart';

class AppShareSheet extends StatefulWidget {
  const AppShareSheet({
    super.key,
    required this.app,
    required this.shareUrl,
    required this.onSystemShare,
    required this.onShareFriend,
    this.task,
    this.onShareFile,
  });

  final MarketApp app;
  final String shareUrl;
  final AppDownloadTask? task;
  final VoidCallback onSystemShare;
  final VoidCallback onShareFriend;
  final VoidCallback? onShareFile;

  @override
  State<AppShareSheet> createState() => _AppShareSheetState();
}

class _AppShareSheetState extends State<AppShareSheet> {
  bool _copied = false;

  String get _url => widget.shareUrl;

  Future<void> _copy() async {
    await AppClipboard.copy(_url);
    if (!mounted) return;
    setState(() => _copied = true);
    HapticFeedback.lightImpact();
    Future<void>.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final task = widget.task;
    final canShareFile =
        widget.onShareFile != null &&
        task != null &&
        task.status == AppDownloadStatus.completed &&
        task.filePath.isNotEmpty;
    return Container(
      decoration: const BoxDecoration(
        color: Color(AppColors.canvas),
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  AppIconTile(app: app, size: 54, radius: AppRadius.md),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          app.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppType.title.copyWith(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '${app.version.isEmpty ? '未填写版本' : 'v${app.version}'}'
                          ' · ${app.platformLabel} · ${app.packageLabel}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppType.micro.copyWith(
                            fontSize: 10.5,
                            color: const Color(AppColors.textTertiary),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(AppColors.accent)
                          .withValues(alpha: .08),
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                    ),
                    child: Text(
                      '应用分享',
                      style: AppType.micro.copyWith(
                        fontSize: 9.5,
                        color: const Color(AppColors.accent),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: _ShareAction(
                      icon: _copied ? Icons.check_rounded : Icons.link_rounded,
                      label: _copied ? '已复制' : '复制链接',
                      accent: _copied,
                      onTap: _copy,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _ShareAction(
                      icon: Icons.ios_share_rounded,
                      label: '系统分享',
                      onTap: widget.onSystemShare,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _ShareAction(
                      icon: Icons.insert_drive_file_outlined,
                      label: canShareFile ? '分享安装包' : '安装包',
                      sublabel: canShareFile ? null : '下载后可分享',
                      enabled: canShareFile,
                      onTap: canShareFile ? widget.onShareFile : null,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              PillButton(
                label: '分享给互关好友',
                size: PillSize.md,
                icon: Icons.forum_outlined,
                expand: true,
                onTap: widget.onShareFriend,
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
                decoration: BoxDecoration(
                  color: const Color(AppColors.card).withValues(alpha: .55),
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  border: Border.all(color: const Color(AppColors.border)),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.public_rounded,
                      size: 15,
                      color: Color(AppColors.textTertiary),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _url,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppType.micro.copyWith(
                          fontSize: 10.5,
                          color: const Color(AppColors.textSecondary),
                        ),
                      ),
                    ),
                    IconCircleButton(
                      icon: _copied
                          ? Icons.check_rounded
                          : Icons.content_copy_rounded,
                      size: 30,
                      iconSize: 14,
                      tooltip: '复制链接',
                      background: Colors.transparent,
                      color: _copied
                          ? const Color(AppColors.accent)
                          : const Color(AppColors.textTertiary),
                      onTap: _copy,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Text(
                '分享页会展示应用介绍、截图和下载 / 安装入口；对方用 iPhone 打开即可安装。',
                style: AppType.micro.copyWith(
                  fontSize: 9.5,
                  height: 1.55,
                  color: const Color(AppColors.textTertiary),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ShareAction extends StatelessWidget {
  const _ShareAction({
    required this.icon,
    required this.label,
    this.sublabel,
    this.enabled = true,
    this.accent = false,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final String? sublabel;
  final bool enabled;
  final bool accent;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final color = accent
        ? const Color(AppColors.accent)
        : enabled
        ? const Color(AppColors.textPrimary)
        : const Color(AppColors.textDisabled);
    return PressableScale(
      onTap: enabled ? onTap : null,
      scale: 0.96,
      child: Container(
        height: 92,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(
          color: const Color(AppColors.card).withValues(alpha: .62),
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(
            color: accent
                ? const Color(AppColors.accent).withValues(alpha: .35)
                : const Color(AppColors.border),
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: accent
                    ? const Color(AppColors.accent).withValues(alpha: .14)
                    : Colors.white.withValues(alpha: .055),
              ),
              child: Icon(icon, size: 18, color: color),
            ),
            const SizedBox(height: 8),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppType.micro.copyWith(
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
            if (sublabel != null) ...[
              const SizedBox(height: 2),
              Text(
                sublabel!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppType.micro.copyWith(
                  fontSize: 8.5,
                  color: const Color(AppColors.textDisabled),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
