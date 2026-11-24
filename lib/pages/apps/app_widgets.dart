/// 应用市场通用视觉组件：图标、平台徽标、评分星、应用行、精选卡。
///
/// 颜色、圆角、字阶全部取 [AppColors]/[AppType]/[AppRadius]；
/// 页面只组合这些原子件，不另造一套卡片语言。
library;

import 'package:flutter/material.dart';

import '../../api/app_market_api.dart';
import '../../design/components.dart';
import '../../design/shared_element.dart';
import '../../models/app_market.dart';
import '../../widgets/image_box.dart';

const Map<String, Color> kPlatformColors = {
  'android': Color(AppColors.accent),
  'ios': Color(AppColors.lilac),
  'harmony': Color(AppColors.peach),
  'windows': Color(AppColors.sky),
};

Color platformColor(String platform) =>
    kPlatformColors[platform] ?? const Color(AppColors.textTertiary);

String humanBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}

String humanSpeed(int bytesPerSecond) {
  if (bytesPerSecond <= 0) return '';
  if (bytesPerSecond < 1024) return '$bytesPerSecond B/s';
  if (bytesPerSecond < 1024 * 1024) {
    return '${(bytesPerSecond / 1024).toStringAsFixed(1)} KB/s';
  }
  return '${(bytesPerSecond / 1024 / 1024).toStringAsFixed(1)} MB/s';
}

String iconUrlOf(MarketApp app) => AppMarketApi.mediaPathToUrl(app.icon);

/// 应用图标：圆角方块 + 无图标时的品牌字母兜底。
class AppIconTile extends StatelessWidget {
  const AppIconTile({
    super.key,
    required this.app,
    this.size = 64,
    this.radius = AppRadius.md,
    this.heroTag,
  });

  final MarketApp app;
  final double size;
  final double radius;
  final String? heroTag;

  @override
  Widget build(BuildContext context) {
    final url = iconUrlOf(app);
    final tile = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        color: const Color(AppColors.elevated),
        border: Border.all(color: const Color(AppColors.border)),
      ),
      clipBehavior: Clip.antiAlias,
      child: url.isEmpty
          ? _fallback()
          : CachedNetworkImageCompat(
              url: url,
              fit: BoxFit.cover,
              width: size,
              height: size,
              memCacheWidth: (size * 2.5).round(),
              placeholder: _fallback(),
              errorWidget: _fallback(),
            ),
    );
    final tag = heroTag;
    return tag == null ? tile : AppHero(tag: tag, child: tile);
  }

  Widget _fallback() {
    final letter = app.name.trim().isEmpty
        ? 'A'
        : app.name.trim().substring(0, 1);
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            platformColor(app.platform).withValues(alpha: 0.32),
            const Color(AppColors.card),
          ],
        ),
      ),
      child: Center(
        child: Text(
          letter,
          style: TextStyle(
            color: const Color(AppColors.textPrimary),
            fontSize: size * 0.34,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}

/// 平台 / 包类型徽标。
class PlatformBadge extends StatelessWidget {
  const PlatformBadge({super.key, required this.app, this.compact = true});

  final MarketApp app;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final color = platformColor(app.platform);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 7 : 9,
        vertical: compact ? 2.5 : 3.5,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.xs),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        '${app.platformLabel} · ${app.packageLabel}',
        style: AppType.micro.copyWith(
          fontSize: compact ? 10 : 11,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}

/// 五颗星评分。传入 [onChanged] 时可点选 1–5。
class RatingStars extends StatelessWidget {
  const RatingStars({
    super.key,
    required this.value,
    this.size = 14,
    this.onChanged,
    this.activeColor = const Color(AppColors.warning),
  });

  final double value;
  final double size;
  final ValueChanged<int>? onChanged;
  final Color activeColor;

  @override
  Widget build(BuildContext context) {
    final filled = value.round();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(5, (i) {
        final star = Icon(
          i < filled ? Icons.star_rounded : Icons.star_outline_rounded,
          size: size,
          color: i < filled ? activeColor : const Color(AppColors.textDisabled),
        );
        if (onChanged == null) return star;
        return Semantics(
          button: true,
          label: '评 ${i + 1} 星',
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => onChanged!(i + 1),
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: size * 0.35),
              child: star,
            ),
          ),
        );
      }),
    );
  }
}

/// 应用列表行（首页、我的投稿、收藏共用）。
class AppListTile extends StatelessWidget {
  const AppListTile({
    super.key,
    required this.app,
    this.onTap,
    this.trailing,
    this.showStatus = false,
    this.showDescription = true,
  });

  final MarketApp app;
  final VoidCallback? onTap;
  final Widget? trailing;
  final bool showStatus;
  final bool showDescription;

  @override
  Widget build(BuildContext context) {
    final desc = app.description.trim();
    return PressableScale(
      onTap: onTap,
      scale: 0.985,
      child: Container(
        padding: const EdgeInsets.all(AppSpace.x3),
        decoration: BoxDecoration(
          color: const Color(AppColors.card).withValues(alpha: 0.58),
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(color: const Color(AppColors.hairline)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppIconTile(app: app, size: 62),
            const SizedBox(width: AppSpace.x3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (app.reason.trim().isNotEmpty) ...[
                    Row(
                      children: [
                        const Icon(
                          Icons.auto_awesome_rounded,
                          size: 12,
                          color: Color(AppColors.accent),
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            app.reason,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppType.micro.copyWith(
                              fontSize: 10,
                              color: const Color(AppColors.accent),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                  ],
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          app.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppType.title.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      if (app.featured) const _MiniFeatured(),
                      if (showStatus) ...[
                        const SizedBox(width: 6),
                        AppStatusBadge(
                          status: app.status,
                          label: app.statusText,
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 5),
                  Row(
                    children: [
                      PlatformBadge(app: app),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          app.category.isEmpty
                              ? '未分类'
                              : '${app.category} / ${app.subCategory}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppType.micro.copyWith(fontSize: 10.5),
                        ),
                      ),
                    ],
                  ),
                  if (showDescription && desc.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      desc,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.bodySm.copyWith(
                        fontSize: 12.5,
                        height: 1.4,
                        color: const Color(AppColors.textSecondary),
                      ),
                    ),
                  ],
                  const SizedBox(height: 7),
                  Row(
                    children: [
                      if (app.ratingCount > 0) ...[
                        RatingStars(value: app.rating, size: 12),
                        const SizedBox(width: 4),
                        Text(
                          app.rating.toStringAsFixed(1),
                          style: AppType.micro.copyWith(
                            fontSize: 10.5,
                            color: const Color(AppColors.warning),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 10),
                      ] else ...[
                        Text(
                          '暂无评分',
                          style: AppType.micro.copyWith(fontSize: 10.5),
                        ),
                        const SizedBox(width: 10),
                      ],
                      Icon(
                        Icons.download_rounded,
                        size: 12,
                        color: const Color(AppColors.textTertiary),
                      ),
                      const SizedBox(width: 3),
                      Text(
                        formatCount(app.downloadCount),
                        style: AppType.micro.copyWith(fontSize: 10.5),
                      ),
                      if (app.version.isNotEmpty) ...[
                        const SizedBox(width: 10),
                        Flexible(
                          child: Text(
                            'v${app.version}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppType.micro.copyWith(fontSize: 10.5),
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (showStatus && app.rejectReason.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      '驳回原因：${app.rejectReason}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.micro.copyWith(
                        color: const Color(AppColors.danger),
                        height: 1.35,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: AppSpace.x2),
              Padding(padding: const EdgeInsets.only(top: 2), child: trailing!),
            ],
          ],
        ),
      ),
    );
  }
}

class _MiniFeatured extends StatelessWidget {
  const _MiniFeatured();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
      decoration: BoxDecoration(
        color: const Color(AppColors.accent).withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        '精选',
        style: AppType.micro.copyWith(
          fontSize: 9,
          color: const Color(AppColors.accent),
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// 审核 / 上架状态徽标。
class AppStatusBadge extends StatelessWidget {
  const AppStatusBadge({super.key, required this.status, required this.label});

  final int status;
  final String label;

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      2 => const Color(AppColors.accent),
      1 => const Color(AppColors.warning),
      3 => const Color(AppColors.danger),
      4 => const Color(AppColors.textTertiary),
      _ => const Color(AppColors.sky),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.xs),
      ),
      child: Text(
        label.isEmpty ? '状态未知' : label,
        style: AppType.micro.copyWith(
          fontSize: 9.5,
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// 精选应用大卡：首页唯一的视觉焦点。
class FeaturedAppCard extends StatelessWidget {
  const FeaturedAppCard({super.key, required this.app, this.onTap});

  final MarketApp app;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final color = platformColor(app.platform);
    return PressableScale(
      onTap: onTap,
      scale: 0.985,
      child: Container(
        height: 158,
        padding: const EdgeInsets.all(AppSpace.x4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              color.withValues(alpha: 0.20),
              const Color(AppColors.card),
              const Color(AppColors.bg),
            ],
            stops: const [0, 0.55, 1],
          ),
          border: Border.all(color: color.withValues(alpha: 0.22)),
        ),
        child: Stack(
          children: [
            Positioned(
              right: -18,
              top: -32,
              child: Icon(
                Icons.apps_rounded,
                size: 132,
                color: color.withValues(alpha: 0.08),
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.auto_awesome_rounded, size: 14, color: color),
                    const SizedBox(width: 5),
                    Text(
                      '本周精选',
                      style: AppType.micro.copyWith(
                        color: color,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ],
                ),
                const Spacer(),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    AppIconTile(app: app, size: 58, radius: AppRadius.sm),
                    const SizedBox(width: AppSpace.x3),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            app.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppType.h2.copyWith(
                              fontWeight: FontWeight.w800,
                              fontSize: 19,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            app.description.isEmpty
                                ? '社区精选应用'
                                : app.description,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: AppType.bodySm.copyWith(
                              fontSize: 12.5,
                              height: 1.35,
                              color: const Color(AppColors.textSecondary),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: AppSpace.x2),
                    Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white.withValues(alpha: 0.06),
                        border: Border.all(
                          color: const Color(AppColors.border),
                        ),
                      ),
                      child: const Icon(
                        Icons.arrow_forward_rounded,
                        size: 18,
                        color: Color(AppColors.textSecondary),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 小节标题：应用市场内页统一使用，避免每个区块自己算间距。
class AppSectionTitle extends StatelessWidget {
  const AppSectionTitle({
    super.key,
    required this.title,
    this.subtitle,
    this.action,
    this.onAction,
    this.padding = const EdgeInsets.fromLTRB(
      AppSpace.gutter,
      AppSpace.x6,
      AppSpace.gutter,
      AppSpace.x3,
    ),
  });

  final String title;
  final String? subtitle;
  final String? action;
  final VoidCallback? onAction;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: AppType.title.copyWith(fontWeight: FontWeight.w700),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 3),
                  Text(subtitle!, style: AppType.caption),
                ],
              ],
            ),
          ),
          if (action != null)
            PressableScale(
              onTap: onAction,
              child: Row(
                children: [
                  Text(action!, style: AppType.caption),
                  const Icon(
                    Icons.chevron_right_rounded,
                    size: 16,
                    color: Color(AppColors.textTertiary),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// 空态使用现有 [EmptyState] 时需要的插图容器。
class AppEmptyIllustration extends StatelessWidget {
  const AppEmptyIllustration({super.key, this.icon = Icons.apps_rounded});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 82,
      height: 82,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(AppColors.card),
        border: Border.all(color: const Color(AppColors.border)),
      ),
      child: Icon(icon, size: 38, color: const Color(AppColors.accent)),
    );
  }
}

/// 应用市场顶部小标签。
class AppMarketStatPill extends StatelessWidget {
  const AppMarketStatPill({
    super.key,
    required this.icon,
    required this.label,
    this.color = const Color(AppColors.textSecondary),
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.045),
        borderRadius: AppRadius.rPill,
        border: Border.all(color: const Color(AppColors.hairline)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: AppType.micro.copyWith(fontSize: 10.5, color: color),
          ),
        ],
      ),
    );
  }
}
