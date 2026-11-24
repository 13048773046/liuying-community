/// 应用详情内的下载面板：按钮、进度、暂停/恢复、完成后的安装/分享。
///
/// 它只订阅 [AppDownloadManager] 的任务状态；真正的网络、文件写入和
/// 断点续传都在服务层，页面被返回或切换 tab 时下载不会中断。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../design/components.dart';
import '../../models/app_market.dart';
import '../../services/app_download_manager.dart';
import '../../services/app_install_service.dart';
import 'app_ios_install_sheet.dart';
import 'app_widgets.dart';

class AppDownloadPanel extends StatelessWidget {
  const AppDownloadPanel({
    super.key,
    required this.app,
    required this.notifier,
  });

  final MarketApp app;
  final ValueNotifier<AppDownloadTask> notifier;

  String get _openLabel =>
      app.packageType.toLowerCase() == 'apk' ? '安装应用' : '打开文件';

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AppDownloadTask>(
      valueListenable: notifier,
      builder: (context, task, _) {
        final active =
            task.status == AppDownloadStatus.downloading ||
            task.status == AppDownloadStatus.resolving;
        final percent = task.totalBytes > 0
            ? '${(task.progress * 100).round()}%'
            : humanBytes(task.receivedBytes);
        return Container(
          padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.lg),
            color: const Color(AppColors.card).withValues(alpha: 0.64),
            border: Border.all(
              color: task.status == AppDownloadStatus.failed
                  ? const Color(AppColors.danger).withValues(alpha: 0.25)
                  : const Color(AppColors.border),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    task.status == AppDownloadStatus.completed
                        ? Icons.check_circle_rounded
                        : task.status == AppDownloadStatus.failed
                        ? Icons.error_outline_rounded
                        : Icons.download_for_offline_outlined,
                    size: 18,
                    color: task.status == AppDownloadStatus.failed
                        ? const Color(AppColors.danger)
                        : task.status == AppDownloadStatus.completed
                        ? const Color(AppColors.accent)
                        : const Color(AppColors.textSecondary),
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      task.status == AppDownloadStatus.idle
                          ? '下载安装包'
                          : task.statusLabel,
                      style: AppType.label.copyWith(
                        fontWeight: FontWeight.w700,
                        color: task.status == AppDownloadStatus.failed
                            ? const Color(AppColors.danger)
                            : const Color(AppColors.textPrimary),
                      ),
                    ),
                  ),
                  Text(
                    task.status == AppDownloadStatus.completed
                        ? humanBytes(task.receivedBytes)
                        : active || task.receivedBytes > 0
                        ? percent
                        : app.packageLabel,
                    style: AppType.micro.copyWith(
                      color: const Color(AppColors.textSecondary),
                      fontSize: 10.5,
                    ),
                  ),
                ],
              ),
              if (task.status == AppDownloadStatus.downloading ||
                  task.status == AppDownloadStatus.paused ||
                  task.status == AppDownloadStatus.resolving ||
                  task.status == AppDownloadStatus.completed) ...[
                const SizedBox(height: 9),
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                  child: LinearProgressIndicator(
                    minHeight: 3,
                    value: task.totalBytes > 0 ? task.progress : null,
                    backgroundColor: Colors.white.withValues(alpha: 0.07),
                    valueColor: AlwaysStoppedAnimation(
                      task.status == AppDownloadStatus.completed
                          ? const Color(AppColors.accent)
                          : const Color(AppColors.accent),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        task.status == AppDownloadStatus.completed
                            ? '已保存到应用目录，可在系统文件管理器中找到'
                            : task.status == AppDownloadStatus.paused
                            ? '${humanBytes(task.receivedBytes)} 已缓存，可继续下载'
                            : task.status == AppDownloadStatus.resolving
                            ? '正在解析下载地址，不会预解析其他应用'
                            : task.totalBytes > 0
                            ? '${humanBytes(task.receivedBytes)} / ${humanBytes(task.totalBytes)}'
                            : humanBytes(task.receivedBytes),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppType.micro.copyWith(
                          fontSize: 10.5,
                          color: const Color(AppColors.textTertiary),
                        ),
                      ),
                    ),
                    if (task.status == AppDownloadStatus.downloading &&
                        task.speedBytesPerSecond > 0) ...[
                      const SizedBox(width: 8),
                      Text(
                        humanSpeed(task.speedBytesPerSecond),
                        style: AppType.micro.copyWith(
                          color: const Color(AppColors.accent),
                          fontSize: 10.5,
                        ),
                      ),
                    ],
                  ],
                ),
              ],
              if (task.error.isNotEmpty &&
                  task.status == AppDownloadStatus.failed) ...[
                const SizedBox(height: 8),
                Text(
                  task.error,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.micro.copyWith(
                    color: const Color(AppColors.danger),
                    height: 1.4,
                  ),
                ),
              ],
              const SizedBox(height: 11),
              _actions(context, task),
            ],
          ),
        );
      },
    );
  }

  Widget _actions(BuildContext context, AppDownloadTask task) {
    switch (task.status) {
      case AppDownloadStatus.idle:
        if (AppInstallService.canOtaInstall(app)) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PillButton(
                label: '安装应用',
                size: PillSize.lg,
                icon: Icons.system_update_alt_rounded,
                expand: true,
                glow: true,
                onTap: () async {
                  final outcome = await showAppIosInstallSheet(context, app);
                  if (outcome == AppIosInstallOutcome.installed) {
                    AppDownloadManager.I.markInstalling(app);
                  } else if (outcome == AppIosInstallOutcome.download) {
                    unawaited(AppDownloadManager.I.start(app));
                  }
                },
              ),
              const SizedBox(height: 6),
              Text(
                '由 iOS 系统接管安装 · 需要已签名的 IPA',
                textAlign: TextAlign.center,
                style: AppType.micro.copyWith(fontSize: 10),
              ),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PillButton(
              label: '下载安装包',
              size: PillSize.lg,
              icon: Icons.download_rounded,
              expand: true,
              glow: true,
              onTap: () => unawaited(AppDownloadManager.I.start(app)),
            ),
            const SizedBox(height: 6),
            Text(
              '点击后才解析下载链接 · 支持断点续传',
              textAlign: TextAlign.center,
              style: AppType.micro.copyWith(fontSize: 10),
            ),
          ],
        );
      case AppDownloadStatus.resolving:
        return const Align(
          alignment: Alignment.centerLeft,
          child: Text('请稍候，正在向下载服务申请临时入口…', style: AppType.micro),
        );
      case AppDownloadStatus.downloading:
        return Row(
          children: [
            Expanded(
              child: PillButton(
                label: '暂停下载',
                size: PillSize.md,
                icon: Icons.pause_rounded,
                variant: PillVariant.ghost,
                onTap: () => AppDownloadManager.I.pause(app.id),
              ),
            ),
            const SizedBox(width: 8),
            IconCircleButton(
              icon: Icons.close_rounded,
              size: 40,
              iconSize: 18,
              tooltip: '取消下载',
              onTap: () => _cancel(context),
            ),
          ],
        );
      case AppDownloadStatus.paused:
        return Row(
          children: [
            Expanded(
              child: PillButton(
                label: '继续下载',
                size: PillSize.md,
                icon: Icons.play_arrow_rounded,
                onTap: () => unawaited(AppDownloadManager.I.start(app)),
              ),
            ),
            const SizedBox(width: 8),
            IconCircleButton(
              icon: Icons.delete_outline_rounded,
              size: 40,
              iconSize: 18,
              tooltip: '删除缓存',
              onTap: () => _cancel(context),
            ),
          ],
        );
      case AppDownloadStatus.completed:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PillButton(
              label: _openLabel,
              size: PillSize.lg,
              icon: Icons.open_in_new_rounded,
              expand: true,
              onTap: () => unawaited(_open(context, task)),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: PillButton(
                    label: '分享文件',
                    size: PillSize.sm,
                    icon: Icons.ios_share_rounded,
                    variant: PillVariant.ghost,
                    onTap: () =>
                        unawaited(AppDownloadManager.I.shareFile(task)),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: PillButton(
                    label: '重新下载',
                    size: PillSize.sm,
                    icon: Icons.refresh_rounded,
                    variant: PillVariant.ghost,
                    onTap: () async {
                      await AppDownloadManager.I.cancel(app.id);
                      unawaited(AppDownloadManager.I.start(app));
                    },
                  ),
                ),
              ],
            ),
          ],
        );
      case AppDownloadStatus.installing:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PillButton(
              label: '重新安装',
              size: PillSize.lg,
              icon: Icons.system_update_alt_rounded,
              expand: true,
              enabled: AppInstallService.canOtaInstall(app),
              onTap: () async {
                final outcome = await showAppIosInstallSheet(context, app);
                if (outcome == AppIosInstallOutcome.installed) {
                  AppDownloadManager.I.markInstalling(app);
                } else if (outcome == AppIosInstallOutcome.download) {
                  unawaited(AppDownloadManager.I.start(app));
                }
              },
            ),
            const SizedBox(height: 6),
            Text(
              '安装请求已交给 iOS；请回到桌面查看进度',
              textAlign: TextAlign.center,
              style: AppType.micro.copyWith(fontSize: 10),
            ),
          ],
        );
      case AppDownloadStatus.failed:
        return Row(
          children: [
            Expanded(
              child: PillButton(
                label: '重试下载',
                size: PillSize.md,
                icon: Icons.refresh_rounded,
                onTap: () => unawaited(AppDownloadManager.I.start(app)),
              ),
            ),
            const SizedBox(width: 8),
            IconCircleButton(
              icon: Icons.delete_outline_rounded,
              size: 40,
              iconSize: 18,
              tooltip: '清除缓存',
              onTap: () => _cancel(context),
            ),
          ],
        );
    }
  }

  Future<void> _open(BuildContext context, AppDownloadTask task) async {
    final message = await AppDownloadManager.I.openFile(task);
    if (message != null && context.mounted) showAppToast(context, message);
  }

  Future<void> _cancel(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(AppColors.card),
        title: const Text('删除下载缓存？', style: AppType.title),
        content: Text('已下载的临时文件会被删除，之后需要重新开始。', style: AppType.bodySm),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('保留'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text(
              '删除',
              style: TextStyle(color: Color(AppColors.danger)),
            ),
          ),
        ],
      ),
    );
    if (confirmed == true) await AppDownloadManager.I.cancel(app.id);
  }
}
