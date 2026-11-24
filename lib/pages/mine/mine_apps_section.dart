/// 我的页 · 应用投稿状态区
///
/// 把「我的投稿」从二级页提到个人主页首屏：待审核 / 未通过用整行状态带提醒，
/// 横滑卡片继续显示每一款应用的真实审核状态与驳回原因，点任意一款进入投稿管理。
library;

import 'package:flutter/material.dart';

import '../../design/components.dart';
import '../../models/app_market.dart';
import '../apps/app_widgets.dart';

class MineAppsSection extends StatelessWidget {
  const MineAppsSection({
    super.key,
    required this.apps,
    required this.loading,
    required this.error,
    required this.onManage,
    required this.onSubmit,
    required this.onRetry,
    required this.onOpen,
  });

  final List<MarketApp> apps;
  final bool loading;
  final String? error;
  final VoidCallback onManage;
  final VoidCallback onSubmit;
  final VoidCallback onRetry;
  final ValueChanged<MarketApp> onOpen;

  int get _pending => apps.where((e) => e.status == 1).length;
  int get _rejected => apps.where((e) => e.status == 3).length;
  int get _published => apps.where((e) => e.status == 2).length;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.gutter,
        AppSpace.x5,
        AppSpace.gutter,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'MY APPS / 投稿',
                      maxLines: 1,
                      style: AppType.micro.copyWith(
                        fontSize: 9.5,
                        letterSpacing: 1.1,
                        fontWeight: FontWeight.w600,
                        color: const Color(AppColors.textTertiary),
                      ),
                    ),
                    const SizedBox(height: 3),
                    const Text(
                      '我的应用投稿',
                      style: TextStyle(
                        fontSize: 17,
                        height: 1.2,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.4,
                        color: Color(AppColors.textPrimary),
                      ),
                    ),
                  ],
                ),
              ),
              _MiniAction(
                icon: Icons.add_rounded,
                label: '投稿',
                onTap: onSubmit,
              ),
              if (apps.isNotEmpty) ...[
                const SizedBox(width: 6),
                _MiniAction(
                  icon: Icons.chevron_right_rounded,
                  label: '全部 ${apps.length}',
                  trailingIcon: true,
                  onTap: onManage,
                ),
              ],
            ],
          ),
          if (_pending > 0 || _rejected > 0) ...[
            const SizedBox(height: 10),
            _AuditNotice(
              pending: _pending,
              rejected: _rejected,
              published: _published,
              onTap: onManage,
            ),
          ],
          const SizedBox(height: 10),
          if (loading && apps.isEmpty)
            const SizedBox(
              height: 108,
              child: Row(
                children: [
                  Expanded(child: SkeletonBox(height: 108, radius: 14)),
                  SizedBox(width: 8),
                  Expanded(child: SkeletonBox(height: 108, radius: 14)),
                ],
              ),
            )
          else if (error != null && apps.isEmpty)
            _ErrorRow(message: error!, onRetry: onRetry)
          else if (apps.isEmpty)
            _EmptySubmission(onTap: onSubmit)
          else
            SizedBox(
              height: 112,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(0, 1, 0, 2),
                itemCount: apps.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (_, i) {
                  final app = apps[i];
                  return SizedBox(
                    width: 166,
                    child: _SubmissionCard(app: app, onTap: () => onOpen(app)),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _MiniAction extends StatelessWidget {
  const _MiniAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.trailingIcon = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool trailingIcon;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[
      if (!trailingIcon)
        Icon(icon, size: 13, color: const Color(AppColors.accent)),
      if (!trailingIcon) const SizedBox(width: 3),
      Text(
        label,
        style: AppType.micro.copyWith(
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          color: const Color(AppColors.accent),
        ),
      ),
      if (trailingIcon)
        Icon(icon, size: 14, color: const Color(AppColors.accent)),
    ];
    return PressableScale(
      onTap: onTap,
      scale: 0.96,
      child: Container(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: const Color(AppColors.accent).withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(7),
          border: Border.all(
            color: const Color(AppColors.accent).withValues(alpha: 0.18),
          ),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: children),
      ),
    );
  }
}

class _AuditNotice extends StatelessWidget {
  const _AuditNotice({
    required this.pending,
    required this.rejected,
    required this.published,
    required this.onTap,
  });

  final int pending;
  final int rejected;
  final int published;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final hasRejected = rejected > 0;
    final color = hasRejected
        ? const Color(AppColors.danger)
        : const Color(AppColors.warning);
    final parts = <String>[
      if (pending > 0) '$pending 款审核中',
      if (rejected > 0) '$rejected 款未通过',
      if (published > 0) '$published 款已上架',
    ];
    final hint = hasRejected
        ? '未通过的应用可修改后重新提交，审核原因见卡片'
        : '人工审核通常很快完成，通过后会出现在应用市场';
    return PressableScale(
      onTap: onTap,
      scale: 0.99,
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 9, 10, 9),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [
              color.withValues(alpha: 0.11),
              color.withValues(alpha: 0.025),
            ],
          ),
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(color: color.withValues(alpha: 0.22)),
        ),
        child: Row(
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                hasRejected
                    ? Icons.error_outline_rounded
                    : Icons.hourglass_top_rounded,
                size: 16,
                color: color,
              ),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    parts.join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.caption.copyWith(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: color,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    hint,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 10.5,
                      height: 1.3,
                      color: Color(AppColors.textTertiary),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '去处理',
                  style: AppType.micro.copyWith(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    color: color,
                  ),
                ),
                Icon(Icons.chevron_right_rounded, size: 14, color: color),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SubmissionCard extends StatelessWidget {
  const _SubmissionCard({required this.app, required this.onTap});

  final MarketApp app;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final status = switch (app.status) {
      1 => const Color(AppColors.warning),
      2 => const Color(AppColors.accent),
      3 => const Color(AppColors.danger),
      4 => const Color(AppColors.textTertiary),
      _ => const Color(AppColors.sky),
    };
    final line = switch (app.status) {
      0 => '草稿未提交，点此继续填写',
      1 => '已提交审核，等待人工处理',
      2 => '已上架市场 · ${app.downloadCount} 次下载',
      3 =>
        app.rejectReason.trim().isEmpty
            ? '未通过审核，可修改后重新提交'
            : '未通过：${app.rejectReason.trim()}',
      4 => '已下架，暂不可展示',
      _ => app.statusText.isEmpty ? '状态未知' : app.statusText,
    };
    return PressableScale(
      onTap: onTap,
      scale: 0.975,
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 9, 9, 8),
        decoration: BoxDecoration(
          color: const Color(AppColors.card).withValues(alpha: 0.72),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: status.withValues(alpha: 0.28)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                AppIconTile(app: app, size: 36, radius: 10),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        app.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12.5,
                          height: 1.2,
                          fontWeight: FontWeight.w700,
                          color: Color(AppColors.textPrimary),
                        ),
                      ),
                      const SizedBox(height: 4),
                      AppStatusBadge(status: app.status, label: app.statusText),
                    ],
                  ),
                ),
              ],
            ),
            const Spacer(),
            Text(
              line,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10.5,
                height: 1.35,
                color: app.status == 3
                    ? const Color(AppColors.danger)
                    : const Color(AppColors.textTertiary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptySubmission extends StatelessWidget {
  const _EmptySubmission({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return PressableScale(
      onTap: onTap,
      scale: 0.985,
      child: Container(
        height: 78,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: const Color(AppColors.card).withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(AppColors.hairline)),
        ),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: const Color(AppColors.accent).withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(
                Icons.upload_file_rounded,
                size: 19,
                color: Color(AppColors.accent),
              ),
            ),
            const SizedBox(width: 10),
            const Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '分享你的第一个应用',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: Color(AppColors.textPrimary),
                    ),
                  ),
                  SizedBox(height: 3),
                  Text(
                    '审核通过后会出现在应用市场与社区首页',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10.5,
                      color: Color(AppColors.textTertiary),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: Color(AppColors.accent),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorRow extends StatelessWidget {
  const _ErrorRow({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
      decoration: BoxDecoration(
        color: const Color(AppColors.card).withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(AppColors.hairline)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.cloud_off_rounded,
            size: 16,
            color: Color(AppColors.textTertiary),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 11,
                color: Color(AppColors.textTertiary),
              ),
            ),
          ),
          TextButton(
            onPressed: onRetry,
            style: TextButton.styleFrom(
              minimumSize: const Size(48, 28),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('重试', style: TextStyle(fontSize: 11)),
          ),
        ],
      ),
    );
  }
}
