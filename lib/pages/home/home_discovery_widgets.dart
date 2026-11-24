/// 首页混合流里的应用发现模块。
///
/// 只负责呈现：精选应用大卡、分类筛选、横向应用滑轨、竖向编辑清单、
/// 社区话题横滑卡。导航与数据加载留在 [HomePage]，避免组件偷偷发请求。
library;

import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../api/app_market_api.dart';
import '../../design/components.dart';
import '../../models/app_market.dart';
import '../apps/app_widgets.dart';

/// 首页话题卡的数据结构。接口只给 name / count，不编造热度文案。
class HomeTopic {
  const HomeTopic({required this.name, required this.count, this.reason = ''});

  final String name;
  final int count;
  final String reason;

  factory HomeTopic.fromJson(Map<String, dynamic> json) => HomeTopic(
    name: (json['name'] ?? '').toString(),
    count:
        (json['count'] as num?)?.toInt() ??
        (json['post_count'] as num?)?.toInt() ??
        0,
    reason: (json['reason'] ?? '').toString(),
  );
}

/// 小节标题：左侧冷灰小标 + 主标题，右侧可选胶囊入口。
class HomeSectionHeader extends StatelessWidget {
  const HomeSectionHeader({
    super.key,
    required this.kicker,
    required this.title,
    this.actionLabel,
    this.onAction,
    this.padding = EdgeInsets.zero,
  });

  final String kicker;
  final String title;
  final String? actionLabel;
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
                  kicker,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 9.5,
                    height: 1.2,
                    letterSpacing: 1.1,
                    fontWeight: FontWeight.w600,
                    color: Color(AppColors.textTertiary),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 16,
                    height: 1.2,
                    letterSpacing: -0.4,
                    fontWeight: FontWeight.w700,
                    color: Color(AppColors.textPrimary),
                  ),
                ),
              ],
            ),
          ),
          if (actionLabel != null) ...[
            const SizedBox(width: 10),
            PressableScale(
              onTap: onAction,
              scale: 0.96,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: const Color(AppColors.hairline)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      actionLabel!,
                      style: const TextStyle(
                        fontSize: 9.5,
                        height: 1.2,
                        fontWeight: FontWeight.w500,
                        color: Color(AppColors.textSecondary),
                      ),
                    ),
                    const SizedBox(width: 3),
                    const Icon(
                      Icons.arrow_forward_rounded,
                      size: 11,
                      color: Color(AppColors.accent),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ============================================================================
// 精选应用大卡
// ============================================================================

/// H5 里的首屏焦点：截图做背景、图标+文案压在左下、右上斜放手机截图。
class HomeFeaturedAppCard extends StatelessWidget {
  const HomeFeaturedAppCard({
    super.key,
    required this.app,
    this.screenshotUrl = '',
    this.onTap,
  });

  final MarketApp app;

  /// 应用详情里的第一张截图；为空时退回品牌渐变，不伪造截图。
  final String screenshotUrl;
  final VoidCallback? onTap;

  static const double _height = 224;

  @override
  Widget build(BuildContext context) {
    final category = [
      app.category,
      app.subCategory,
    ].where((e) => e.trim().isNotEmpty).join(' / ');
    final version = app.version.trim();
    final subline = [
      if (version.isNotEmpty) 'v$version',
      if (category.isNotEmpty) category,
    ].join(' · ');
    final desc = app.description.trim().isEmpty
        ? app.shareReason.trim()
        : app.description.trim();

    return PressableScale(
      onTap: onTap,
      scale: 0.985,
      child: Container(
        height: _height,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: const Color(AppColors.accent).withValues(alpha: 0.16),
          ),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF10241F), Color(0xFF0B1210), Color(0xFF09090A)],
            stops: [0, 0.45, 1],
          ),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            _background(),
            Positioned(
              left: 16,
              right: 16,
              top: 14,
              child: Row(
                children: [
                  _Kicker(label: app.featured ? '编辑精选' : '社区应用'),
                  const Spacer(),
                  Text(
                    '应用 / ${app.packageLabel.toUpperCase()}',
                    style: const TextStyle(
                      fontSize: 9,
                      height: 1.2,
                      letterSpacing: 1.2,
                      color: Color(0x8FFFFFFF),
                    ),
                  ),
                ],
              ),
            ),
            if (screenshotUrl.isNotEmpty)
              Positioned(
                right: 14,
                top: 46,
                child: Transform.rotate(
                  angle: 0.061,
                  child: Container(
                    width: 82,
                    height: 104,
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      color: const Color(AppColors.elevated),
                      borderRadius: BorderRadius.circular(9),
                      border: Border.all(color: const Color(0x26FFFFFF)),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x59000000),
                          blurRadius: 22,
                          offset: Offset(0, 10),
                        ),
                      ],
                    ),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        CachedNetworkImage(
                          imageUrl: screenshotUrl,
                          fit: BoxFit.cover,
                          alignment: Alignment.topCenter,
                          placeholder: (_, _) =>
                              const ImagePlaceholder(radius: 0),
                          errorWidget: (_, _, _) =>
                              const ImagePlaceholder(radius: 0),
                        ),
                        const DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.bottomCenter,
                              end: Alignment.topCenter,
                              colors: [Color(0x70000000), Color(0x00000000)],
                              stops: [0, 0.45],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            Positioned(
              left: 16,
              right: 110,
              bottom: 16,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      AppIconTile(app: app, size: 52, radius: 13),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              app.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 19,
                                height: 1.15,
                                letterSpacing: -0.6,
                                fontWeight: FontWeight.w800,
                                color: Color(AppColors.textPrimary),
                              ),
                            ),
                            if (subline.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text(
                                subline,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 11,
                                  height: 1.3,
                                  color: Color(AppColors.textSecondary),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (desc.isNotEmpty) ...[
                    const SizedBox(height: 9),
                    Text(
                      desc,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11.5,
                        height: 1.58,
                        color: Color(0x9FFFFFFF),
                      ),
                    ),
                  ],
                  const SizedBox(height: 9),
                  _MetaLine(app: app),
                ],
              ),
            ),
            Positioned(
              right: 14,
              bottom: 16,
              child: Container(
                height: 29,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: const Color(AppColors.accent),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '查看',
                      style: TextStyle(
                        fontSize: 10.5,
                        height: 1.2,
                        fontWeight: FontWeight.w700,
                        color: Color(AppColors.onAccent),
                      ),
                    ),
                    SizedBox(width: 3),
                    Icon(
                      Icons.arrow_forward_rounded,
                      size: 12,
                      color: Color(AppColors.onAccent),
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

  Widget _background() {
    final fallback = DecoratedBox(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: const Alignment(0.86, -0.72),
          radius: 0.9,
          colors: [
            const Color(AppColors.accent).withValues(alpha: 0.17),
            Colors.transparent,
          ],
        ),
      ),
    );
    if (screenshotUrl.isEmpty) return fallback;
    return Stack(
      fit: StackFit.expand,
      children: [
        ImageFiltered(
          imageFilter: ui.ImageFilter.blur(sigmaX: 9, sigmaY: 9),
          child: Transform.scale(
            scale: 1.12,
            child: CachedNetworkImage(
              imageUrl: screenshotUrl,
              fit: BoxFit.cover,
              alignment: Alignment.topCenter,
              placeholder: (_, _) => const ImagePlaceholder(radius: 0),
              errorWidget: (_, _, _) => fallback,
            ),
          ),
        ),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [Color(0xF7050606), Color(0xD9050606), Color(0x52050606)],
              stops: [0, 0.52, 1],
            ),
          ),
        ),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [Color(0xF5050606), Color(0x00050606)],
              stops: [0, 0.64],
            ),
          ),
        ),
      ],
    );
  }
}

class _Kicker extends StatelessWidget {
  const _Kicker({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 20,
      padding: const EdgeInsets.symmetric(horizontal: 7),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: const Color(AppColors.accent).withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(
          color: const Color(AppColors.accent).withValues(alpha: 0.32),
        ),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 9,
          height: 1.2,
          letterSpacing: 0.8,
          fontWeight: FontWeight.w700,
          color: Color(AppColors.accent),
        ),
      ),
    );
  }
}

class _MetaLine extends StatelessWidget {
  const _MetaLine({required this.app});

  final MarketApp app;

  @override
  Widget build(BuildContext context) {
    final parts = <String>[
      '已上架 · ${app.packageLabel}',
      if (app.osVersion.trim().isNotEmpty) app.osVersion.trim(),
      '${formatCount(app.downloadCount)} 次下载',
    ];
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 7,
      runSpacing: 4,
      children: [
        for (var i = 0; i < parts.length; i++) ...[
          if (i > 0)
            Container(width: 1, height: 8, color: const Color(0x29FFFFFF)),
          Text(
            parts[i],
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 9.5,
              height: 1.2,
              color: Color(AppColors.textTertiary),
            ),
          ),
        ],
      ],
    );
  }
}

// ============================================================================
// 分类 chips
// ============================================================================

class HomeCategoryChips extends StatelessWidget {
  const HomeCategoryChips({
    super.key,
    required this.categories,
    required this.selectedId,
    required this.onSelected,
  });

  final List<AppCategory> categories;
  final String selectedId;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final entries = <(String, String)>[('', '全部')];
    for (final c in categories) {
      entries.add((c.id, c.name));
    }
    return SizedBox(
      height: 28,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.zero,
        physics: const BouncingScrollPhysics(),
        itemCount: entries.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (_, i) {
          final entry = entries[i];
          final active = entry.$1 == selectedId;
          return PressableScale(
            onTap: () => onSelected(entry.$1),
            scale: 0.97,
            child: AnimatedContainer(
              duration: AppMotion.fast,
              height: 26,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: AppRadius.rPill,
                border: Border.all(
                  color: active
                      ? const Color(AppColors.accent).withValues(alpha: 0.3)
                      : const Color(AppColors.hairline),
                ),
                color: active
                    ? const Color(AppColors.accent).withValues(alpha: 0.11)
                    : Colors.white.withValues(alpha: 0.03),
              ),
              child: Text(
                entry.$2,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10,
                  height: 1.2,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                  color: active
                      ? const Color(AppColors.accent)
                      : const Color(AppColors.textTertiary),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

// ============================================================================
// 横向应用滑轨
// ============================================================================

class HomeAppsRail extends StatelessWidget {
  const HomeAppsRail({
    super.key,
    required this.apps,
    required this.onOpen,
    this.onSeeAll,
    this.actionLabel,
    this.showHeader = true,
    this.kicker,
    this.title,
  });

  final List<MarketApp> apps;
  final ValueChanged<MarketApp> onOpen;
  final VoidCallback? onSeeAll;
  final String? actionLabel;

  /// 板块页等外部页面可只复用滑轨本身，标题与分类由外层组织。
  final bool showHeader;
  final String? kicker;
  final String? title;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showHeader) ...[
          HomeSectionHeader(
            kicker: kicker ?? '横向滑轨 / ${apps.length} 款',
            title: title ?? '这周大家都在装',
            actionLabel: onSeeAll == null
                ? null
                : (actionLabel ?? '全部 ${apps.length} 款'),
            onAction: onSeeAll,
          ),
          const SizedBox(height: 9),
        ],
        SizedBox(
          height: 128,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(0, 1, 0, 2),
            itemCount: apps.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (_, i) {
              final app = apps[i];
              return SizedBox(
                width: 112,
                child: _MiniAppCard(app: app, onTap: () => onOpen(app)),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _MiniAppCard extends StatelessWidget {
  const _MiniAppCard({required this.app, required this.onTap});

  final MarketApp app;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final category = app.category.trim();
    return PressableScale(
      onTap: onTap,
      scale: 0.975,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: const Color(AppColors.card),
          borderRadius: BorderRadius.circular(13),
          border: Border.all(color: const Color(AppColors.hairline)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppIconTile(app: app, size: 38, radius: 10),
            const SizedBox(height: 8),
            Text(
              app.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12,
                height: 1.25,
                fontWeight: FontWeight.w700,
                color: Color(AppColors.textPrimary),
              ),
            ),
            const SizedBox(height: 3),
            Text(
              [
                if (category.isNotEmpty) category,
                if (app.version.trim().isNotEmpty) app.version.trim(),
              ].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 9,
                height: 1.25,
                color: Color(AppColors.textTertiary),
              ),
            ),
            const SizedBox(height: 7),
            Row(
              children: [
                if (app.featured)
                  const _MiniTag(label: '精选', accent: true)
                else
                  _MiniTag(
                    label: app.subCategory.trim().isEmpty
                        ? '已上架'
                        : app.subCategory.trim(),
                  ),
                if (app.ratingCount > 0) ...[
                  const SizedBox(width: 4),
                  const Icon(
                    Icons.star_rounded,
                    size: 10,
                    color: Color(AppColors.warning),
                  ),
                  const SizedBox(width: 2),
                  Text(
                    app.rating.toStringAsFixed(1),
                    style: const TextStyle(
                      fontSize: 8,
                      height: 1.2,
                      color: Color(AppColors.warning),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniTag extends StatelessWidget {
  const _MiniTag({required this.label, this.accent = false});

  final String label;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      decoration: BoxDecoration(
        color: accent
            ? const Color(AppColors.accent).withValues(alpha: 0.12)
            : Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 8,
          height: 1.2,
          color: accent
              ? const Color(AppColors.accent)
              : const Color(AppColors.textSecondary),
        ),
      ),
    );
  }
}

// ============================================================================
// 竖向应用清单
// ============================================================================

class HomeAppListCard extends StatelessWidget {
  const HomeAppListCard({
    super.key,
    required this.apps,
    required this.onOpen,
    this.onSeeAll,
    this.actionLabel,
  });

  final List<MarketApp> apps;
  final ValueChanged<MarketApp> onOpen;
  final VoidCallback? onSeeAll;
  final String? actionLabel;

  @override
  Widget build(BuildContext context) {
    final shown = apps.take(3).toList();
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 4),
      decoration: BoxDecoration(
        color: const Color(AppColors.card),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(AppColors.hairline)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HomeSectionHeader(
            kicker: '编辑清单 / ${shown.length.toString().padLeft(2, '0')} 款',
            title: '这周装什么',
            actionLabel: onSeeAll == null
                ? null
                : (actionLabel ?? '全部 ${apps.length} 款'),
            onAction: onSeeAll,
          ),
          const SizedBox(height: 8),
          for (var i = 0; i < shown.length; i++)
            _AppListRow(
              app: shown[i],
              index: i,
              showDivider: i > 0,
              onTap: () => onOpen(shown[i]),
            ),
        ],
      ),
    );
  }
}

class _AppListRow extends StatelessWidget {
  const _AppListRow({
    required this.app,
    required this.index,
    required this.showDivider,
    required this.onTap,
  });

  final MarketApp app;
  final int index;
  final bool showDivider;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final sub = app.shareReason.trim().isNotEmpty
        ? app.shareReason.trim()
        : app.description.trim();
    final rightLabel = [
      app.category,
      app.subCategory,
    ].where((e) => e.trim().isNotEmpty).join(' / ');
    return PressableScale(
      onTap: onTap,
      scale: 0.985,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 9),
        decoration: BoxDecoration(
          border: showDivider
              ? const Border(top: BorderSide(color: Color(AppColors.hairline)))
              : null,
        ),
        child: Row(
          children: [
            SizedBox(
              width: 19,
              child: Text(
                '${index + 1}'.padLeft(2, '0'),
                style: const TextStyle(
                  fontSize: 9,
                  height: 1.2,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.4,
                  color: Color(AppColors.accent),
                ),
              ),
            ),
            const SizedBox(width: 5),
            AppIconTile(app: app, size: 38, radius: 10),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          app.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12.5,
                            height: 1.3,
                            fontWeight: FontWeight.w600,
                            color: Color(AppColors.textPrimary),
                          ),
                        ),
                      ),
                      if (app.featured) ...[
                        const SizedBox(width: 5),
                        const _MiniTag(label: '精选', accent: true),
                      ],
                    ],
                  ),
                  if (sub.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      sub,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 9.5,
                        height: 1.3,
                        color: Color(AppColors.textTertiary),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 6),
            SizedBox(
              width: 84,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Flexible(
                    child: Text(
                      rightLabel,
                      maxLines: 2,
                      textAlign: TextAlign.right,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 9,
                        height: 1.3,
                        color: Color(AppColors.textTertiary),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(
                    Icons.chevron_right_rounded,
                    size: 14,
                    color: Color(AppColors.textTertiary),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// 话题横滑
// ============================================================================

class HomeTopicRail extends StatelessWidget {
  const HomeTopicRail({
    super.key,
    required this.topics,
    required this.onOpen,
    this.onMore,
  });

  final List<HomeTopic> topics;
  final ValueChanged<HomeTopic> onOpen;
  final VoidCallback? onMore;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        HomeSectionHeader(
          kicker: '社区热榜 / 横向滑轨',
          title: '正在热议',
          actionLabel: onMore == null ? null : '更多话题',
          onAction: onMore,
        ),
        const SizedBox(height: 9),
        SizedBox(
          height: 104,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(0, 1, 0, 2),
            itemCount: topics.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (_, i) {
              final topic = topics[i];
              return SizedBox(
                width: 146,
                child: _TopicCard(
                  topic: topic,
                  index: i,
                  onTap: () => onOpen(topic),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _TopicCard extends StatelessWidget {
  const _TopicCard({
    required this.topic,
    required this.index,
    required this.onTap,
  });

  final HomeTopic topic;
  final int index;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tint = switch (index % 3) {
      0 => const Color(AppColors.accent),
      1 => const Color(AppColors.info),
      _ => const Color(AppColors.warning),
    };
    return PressableScale(
      onTap: onTap,
      scale: 0.98,
      child: Container(
        padding: const EdgeInsets.fromLTRB(11, 10, 11, 9),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(13),
          border: Border.all(color: const Color(AppColors.hairline)),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [tint.withValues(alpha: 0.12), const Color(0xFF0A0B0C)],
            stops: const [0, 0.72],
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  '${index + 1}'.padLeft(2, '0'),
                  style: const TextStyle(
                    fontSize: 9,
                    height: 1.2,
                    letterSpacing: 0.9,
                    color: Color(AppColors.textTertiary),
                  ),
                ),
                const Spacer(),
                Text(
                  '${formatCount(topic.count)} 讨论',
                  maxLines: 1,
                  style: const TextStyle(
                    fontSize: 8,
                    height: 1.2,
                    color: Color(AppColors.textTertiary),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '# ${topic.name}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 14,
                height: 1.2,
                letterSpacing: -0.4,
                fontWeight: FontWeight.w800,
                color: Color(AppColors.textPrimary),
              ),
            ),
            const SizedBox(height: 5),
            const Text(
              '点开看看大家都在聊什么',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 9,
                height: 1.45,
                color: Color(AppColors.textTertiary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// 加载 / 空态
// ============================================================================

class HomeFeaturedSkeleton extends StatelessWidget {
  const HomeFeaturedSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return const SkeletonBox(height: HomeFeaturedAppCard._height, radius: 16);
  }
}

class HomeAppsRailSkeleton extends StatelessWidget {
  const HomeAppsRailSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Row(
          children: [
            Expanded(child: SkeletonBox(height: 16, width: 132)),
            SkeletonBox(height: 22, width: 58, radius: 6),
          ],
        ),
        const SizedBox(height: 9),
        SizedBox(
          height: 128,
          child: Row(
            children: [
              for (var i = 0; i < 3; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                const Expanded(child: SkeletonBox(height: 128, radius: 13)),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class HomeDiscoveryNotice extends StatelessWidget {
  const HomeDiscoveryNotice({super.key, required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 15, 14, 15),
      decoration: BoxDecoration(
        color: const Color(AppColors.card),
        borderRadius: BorderRadius.circular(16),
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
              Icons.apps_rounded,
              size: 19,
              color: Color(AppColors.accent),
            ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '应用区暂时没连上',
                  style: TextStyle(
                    fontSize: 13.5,
                    height: 1.3,
                    fontWeight: FontWeight.w600,
                    color: Color(AppColors.textPrimary),
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  message,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 10,
                    height: 1.45,
                    color: Color(AppColors.textTertiary),
                  ),
                ),
              ],
            ),
          ),
          if (onRetry != null) ...[
            const SizedBox(width: 8),
            PressableScale(
              onTap: onRetry,
              scale: 0.95,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(7),
                  border: Border.all(
                    color: const Color(AppColors.accent)
                        .withValues(alpha: 0.25),
                  ),
                ),
                child: const Text(
                  '重试',
                  style: TextStyle(
                    fontSize: 10,
                    height: 1.2,
                    fontWeight: FontWeight.w600,
                    color: Color(AppColors.accent),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 应用分类与当前应用目录的交叉过滤：只保留真正有应用的分类。
List<AppCategory> categoriesWithApps(
  List<AppCategory> categories,
  List<MarketApp> apps,
) {
  final ids = apps.map((e) => e.categoryId).toSet();
  return categories.where((c) => ids.contains(c.id)).toList();
}

/// 首页模块统一取图标 URL，避免各卡自己拼路径。
String appIconUrl(MarketApp app) => AppMarketApi.mediaPathToUrl(app.icon);
