/// 我的页 · 会员状态 + 四快捷入口
///
/// 不做「五块独立卡片」：会员收成一条轻量状态带，四个入口做成一条无边框
/// 快捷轨，直接落在画布上。这样既在首屏看得见，也不会把个人主页切成设置页。
library;

import 'package:flutter/material.dart';

import '../../design/components.dart';

class MineEntrySection extends StatelessWidget {
  const MineEntrySection({
    super.key,
    required this.member,
    required this.onMember,
    required this.onDownloads,
    required this.onWorks,
    required this.onFeedback,
    required this.onAbout,
  });

  /// `/member/status` 返回体；未开通时为空 Map。
  final Map<String, dynamic> member;
  final VoidCallback onMember;
  final VoidCallback onDownloads;
  final VoidCallback onWorks;
  final VoidCallback onFeedback;
  final VoidCallback onAbout;

  @override
  Widget build(BuildContext context) {
    final level = (member['level'] ?? '') as String;
    final active = level.isNotEmpty;
    final label = (member['label'] ?? '') as String;
    final days = ((member['daysLeft'] ?? 0) as num).toInt();
    final expiring = member['expiring'] == true;
    final title = active ? (label.isEmpty ? '会员中心' : '$label 会员') : '会员中心';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PressableScale(
          onTap: onMember,
          scale: 0.99,
          child: Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [
                  const Color(AppColors.accent)
                      .withValues(alpha: active ? 0.11 : 0.055),
                  const Color(AppColors.accent).withValues(alpha: 0.02),
                ],
              ),
              borderRadius: BorderRadius.circular(AppRadius.sm),
              border: Border.all(
                color: const Color(AppColors.accent)
                    .withValues(alpha: active ? 0.18 : 0.12),
              ),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.workspace_premium_rounded,
                  size: 15,
                  color: Color(AppColors.accent),
                ),
                const SizedBox(width: 7),
                Flexible(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.label.copyWith(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: const Color(AppColors.textPrimary),
                    ),
                  ),
                ),
                if (active) ...[
                  const SizedBox(width: 7),
                  _MemberDays(days: days, expiring: expiring),
                ] else ...[
                  const SizedBox(width: 8),
                  const Flexible(
                    child: Text(
                      '头像框 · 表情 · Agent 额度',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10.5,
                        color: Color(AppColors.textTertiary),
                      ),
                    ),
                  ),
                ],
                const SizedBox(width: 6),
                Text(
                  active ? '管理' : '开通',
                  style: AppType.caption.copyWith(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: const Color(AppColors.accent),
                  ),
                ),
                const Icon(
                  Icons.chevron_right_rounded,
                  size: 15,
                  color: Color(AppColors.textTertiary),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        SizedBox(
          height: 68,
          child: Row(
            children: [
              Expanded(
                child: _QuickEntry(
                  icon: Icons.download_for_offline_outlined,
                  label: '下载列表',
                  color: const Color(AppColors.accent),
                  onTap: onDownloads,
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: _QuickEntry(
                  icon: Icons.grid_view_rounded,
                  label: '我的作品',
                  color: const Color(AppColors.lilac),
                  onTap: onWorks,
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: _QuickEntry(
                  icon: Icons.chat_bubble_outline_rounded,
                  label: '意见反馈',
                  color: const Color(AppColors.sky),
                  onTap: onFeedback,
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: _QuickEntry(
                  icon: Icons.info_outline_rounded,
                  label: '关于社区',
                  color: const Color(AppColors.peach),
                  onTap: onAbout,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MemberDays extends StatelessWidget {
  const _MemberDays({required this.days, required this.expiring});

  final int days;
  final bool expiring;

  @override
  Widget build(BuildContext context) {
    final color = expiring
        ? const Color(AppColors.warning)
        : const Color(AppColors.accent);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppRadius.xs),
      ),
      child: Text(
        '剩 $days 天',
        style: AppType.micro.copyWith(
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

class _QuickEntry extends StatelessWidget {
  const _QuickEntry({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: PressableScale(
        onTap: onTap,
        scale: 0.97,
        child: Container(
          height: 68,
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 9),
          decoration: BoxDecoration(
            color: const Color(AppColors.card).withValues(alpha: 0.62),
            borderRadius: BorderRadius.circular(AppRadius.sm),
            border: Border.all(color: const Color(AppColors.border)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.north_east_rounded,
                    size: 13,
                    color: Color(AppColors.textTertiary),
                  ),
                  const Spacer(),
                  Icon(icon, size: 19, color: color),
                ],
              ),
              const Spacer(),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppType.caption.copyWith(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: const Color(AppColors.textPrimary),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
