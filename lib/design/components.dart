/// 流萤社区 · 沉浸黑设计系统 —— 通用组件
///
/// 所有页面统一从这里取组件，不要在页面里手写按钮/头像/空态/骨架。
library;

import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'tokens.dart';

export 'tokens.dart';

// ============================================================================
// 基础容器
// ============================================================================

/// 沉浸式页面骨架：纯黑画布 + 透明系统栏 + 可选顶/底渐变。
///
/// - [topScrim] / [bottomScrim]：内容全幅延伸到系统栏下方时，用它保证文字可读。
/// - 不自动加 SafeArea：全屏媒体页需要内容顶到状态栏，普通页面请自行用
///   [ImmersiveScroll] 或 `SafeArea(top: false)`。
class ImmersivePage extends StatelessWidget {
  const ImmersivePage({
    super.key,
    required this.child,
    this.background = const Color(AppColors.bg),
    this.topScrim = false,
    this.bottomScrim = false,
    this.resizeToAvoidBottomInset = true,
  });

  final Widget child;
  final Color background;
  final bool topScrim;
  final bool bottomScrim;
  final bool resizeToAvoidBottomInset;

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark.copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: background,
        systemNavigationBarIconBrightness: Brightness.dark,
      ),
      child: Scaffold(
        backgroundColor: background,
        resizeToAvoidBottomInset: resizeToAvoidBottomInset,
        body: Stack(
          children: [
            Positioned.fill(child: child),
            if (topScrim)
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                height: 140 + MediaQuery.paddingOf(context).top,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration:
                        BoxDecoration(gradient: AppEffects.topScrim()),
                  ),
                ),
              ),
            if (bottomScrim)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: 160,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration:
                        BoxDecoration(gradient: AppEffects.bottomScrim()),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 内容页滚动容器：统一底部留白（悬浮导航 + 安全区），少一处处手算。
class ImmersiveScroll extends StatelessWidget {
  const ImmersiveScroll({
    super.key,
    required this.children,
    this.controller,
    this.padding = const EdgeInsets.symmetric(horizontal: AppSpace.gutter),
    this.extraBottom = 0,
    this.physics,
  });

  final List<Widget> children;
  final ScrollController? controller;
  final EdgeInsets padding;
  final double extraBottom;
  final ScrollPhysics? physics;

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    return SingleChildScrollView(
      controller: controller,
      physics: physics ?? const BouncingScrollPhysics(),
      padding: padding.copyWith(
        top: padding.top + MediaQuery.paddingOf(context).top,
        bottom: padding.bottom + bottom + 28 + extraBottom,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}

// ============================================================================
// 顶部栏（玻璃浮层）
// ============================================================================

/// 玻璃顶栏：默认透明，滚动后（[solid]）加深并加毛玻璃。
class GlassTopBar extends StatelessWidget implements PreferredSizeWidget {
  const GlassTopBar({
    super.key,
    this.title,
    this.subtitle,
    this.leading,
    this.actions = const [],
    this.showBack = true,
    this.blur = true,
    this.floating = false,
    this.solid = false,
    this.onBack,
    this.height = 52,
  });

  final String? title;
  final String? subtitle;
  final Widget? leading;
  final List<Widget> actions;
  final bool showBack;
  final bool blur;

  /// 浮起样式：左右留白 + 圆角胶囊，用于内容页悬浮操作条。
  final bool floating;

  /// 实底（滚动后由调用方传入）。
  final bool solid;
  final VoidCallback? onBack;
  final double height;

  @override
  Size get preferredSize => Size.fromHeight(height + 24);

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    final row = Row(
      children: [
        if (showBack)
          IconCircleButton(
            icon: Icons.arrow_back_ios_new_rounded,
            size: 36,
            iconSize: 17,
            background: solid ? Colors.transparent : null,
            onTap: onBack ?? () => Navigator.of(context).maybePop(),
          ),
        ?leading,
        const SizedBox(width: AppSpace.x2),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (title != null)
                Text(
                  title!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: title == null
                      ? AppType.h2
                      : AppType.title.copyWith(fontWeight: FontWeight.w700),
                ),
              if (subtitle != null)
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Text(subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.micro),
                ),
            ],
          ),
        ),
        ...actions,
      ],
    );

    return Padding(
      padding: EdgeInsets.only(top: top),
      child: SizedBox(
        height: height,
        child: ClipRect(
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(
              sigmaX: blur && (solid || floating) ? 18 : 0.001,
              sigmaY: blur && (solid || floating) ? 18 : 0.001,
            ),
            child: Container(
              margin: floating
                  ? const EdgeInsets.symmetric(
                      horizontal: AppSpace.x4, vertical: AppSpace.x2)
                  : EdgeInsets.zero,
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.x3),
              decoration: BoxDecoration(
                color: solid
                    ? const Color(AppColors.glass)
                    : (floating
                        ? const Color(AppColors.glass)
                        : Colors.transparent),
                borderRadius:
                    floating ? AppRadius.rPill : BorderRadius.zero,
                border: floating
                    ? Border.all(color: const Color(AppColors.border))
                    : null,
              ),
              child: row,
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// 按钮
// ============================================================================

enum PillVariant { primary, tonal, ghost, danger }

enum PillSize { sm, md, lg }

/// 胶囊按钮：全站唯一的按钮形态（主色实心 / 深灰 tonal / 描边 ghost / 危险）。
class PillButton extends StatelessWidget {
  const PillButton({
    super.key,
    required this.label,
    this.onTap,
    this.variant = PillVariant.primary,
    this.size = PillSize.md,
    this.icon,
    this.trailingIcon,
    this.expand = false,
    this.loading = false,
    this.enabled = true,
    this.glow = false,
  });

  final String label;
  final VoidCallback? onTap;
  final PillVariant variant;
  final PillSize size;
  final IconData? icon;
  final IconData? trailingIcon;
  final bool expand;
  final bool loading;
  final bool enabled;
  final bool glow;

  double get _height => switch (size) {
        PillSize.sm => 30,
        PillSize.md => 40,
        PillSize.lg => 48,
      };

  EdgeInsets get _pad => switch (size) {
        PillSize.sm => const EdgeInsets.symmetric(horizontal: 12),
        PillSize.md => const EdgeInsets.symmetric(horizontal: 18),
        PillSize.lg => const EdgeInsets.symmetric(horizontal: 22),
      };

  TextStyle get _text => switch (size) {
        PillSize.sm => AppType.caption.copyWith(fontWeight: FontWeight.w600),
        PillSize.md => AppType.label,
        PillSize.lg => AppType.title.copyWith(fontWeight: FontWeight.w700),
      };

  @override
  Widget build(BuildContext context) {
    final (bg, fg, border) = _colors;
    final child = Row(
      mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (loading)
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 1.8, color: fg),
          )
        else if (icon != null)
          Icon(icon, size: _height * 0.42, color: fg),
        if (loading || icon != null) const SizedBox(width: 6),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: _text.copyWith(color: fg),
          ),
        ),
        if (trailingIcon != null) ...[
          const SizedBox(width: 4),
          Icon(trailingIcon, size: _height * 0.4, color: fg),
        ],
      ],
    );

    return Opacity(
      opacity: enabled ? 1 : 0.4,
      child: PressableScale(
        onTap: enabled && !loading ? onTap : null,
        child: Container(
          height: _height,
          padding: _pad,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: AppRadius.rPill,
            border: border == null ? null : Border.all(color: border),
            boxShadow: glow && variant == PillVariant.primary
                ? AppEffects.accentGlow()
                : null,
          ),
          child: child,
        ),
      ),
    );
  }

  (Color, Color, Color?) get _colors => switch (variant) {
        PillVariant.primary => (
            const Color(AppColors.accent),
            const Color(AppColors.onAccent),
            null
          ),
        PillVariant.tonal => (
            const Color(AppColors.canvas),
            const Color(AppColors.textPrimary),
            null
          ),
        PillVariant.ghost => (
            Colors.transparent,
            const Color(AppColors.textPrimary),
            const Color(AppColors.border)
          ),
        PillVariant.danger => (
            const Color(AppColors.danger).withValues(alpha: 0.16),
            const Color(AppColors.danger),
            null
          ),
      };
}

/// 圆形图标按钮（顶栏/悬浮操作通用）。
class IconCircleButton extends StatelessWidget {
  const IconCircleButton({
    super.key,
    required this.icon,
    this.onTap,
    this.size = 40,
    this.iconSize = 20,
    this.background,
    this.color,
    this.badge = 0,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final double size;
  final double iconSize;
  final Color? background;
  final Color? color;
  final int badge;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final fg = color ?? const Color(AppColors.textPrimary);
    Widget child = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: background ?? const Color(AppColors.canvas),
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Icon(icon, size: iconSize, color: fg),
    );
    if (badge > 0) {
      child = Stack(
        clipBehavior: Clip.none,
        children: [
          child,
          Positioned(
            right: -2,
            top: -2,
            child: CountBadge(count: badge),
          ),
        ],
      );
    }
    final tappable = PressableScale(onTap: onTap, child: child);
    return tooltip == null ? tappable : Tooltip(message: tooltip!, child: tappable);
  }
}

/// 数字角标（红点/计数）。
class CountBadge extends StatelessWidget {
  const CountBadge({super.key, required this.count, this.color, this.plain = false});

  final int count;
  final Color? color;
  final bool plain;

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return const SizedBox.shrink();
    final text = count > 99 ? '99+' : '$count';
    return Container(
      padding: plain
          ? const EdgeInsets.all(4)
          : const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      constraints: const BoxConstraints(minWidth: 16),
      decoration: BoxDecoration(
        color: color ?? const Color(AppColors.heart),
        borderRadius: AppRadius.rPill,
        border: Border.all(color: const Color(AppColors.bg), width: 1.5),
      ),
      alignment: Alignment.center,
      child: plain
          ? null
          : Text(
              text,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 9.5,
                height: 1.2,
                fontWeight: FontWeight.w700,
              ),
            ),
    );
  }
}

/// 按压缩放反馈（沉浸式交互的基础手感）。
class PressableScale extends StatefulWidget {
  const PressableScale({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.scale = 0.96,
    this.duration = AppMotion.fast,
    this.haptic = true,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double scale;
  final Duration duration;
  final bool haptic;

  @override
  State<PressableScale> createState() => _PressableScaleState();
}

class _PressableScaleState extends State<PressableScale> {
  bool _down = false;

  bool get _enabled => widget.onTap != null || widget.onLongPress != null;

  void _set(bool v) {
    if (!_enabled || _down == v) return;
    setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _set(true),
      onTapCancel: () => _set(false),
      onTapUp: (_) => _set(false),
      onTap: widget.onTap == null
          ? null
          : () {
              if (widget.haptic) HapticFeedback.selectionClick();
              widget.onTap!();
            },
      onLongPress: widget.onLongPress,
      child: AnimatedScale(
        scale: _down ? widget.scale : 1,
        duration: widget.duration,
        curve: AppMotion.standard,
        child: widget.child,
      ),
    );
  }
}

// ============================================================================
// 标签 / 分段
// ============================================================================

/// 话题/版块标签（可选中）。
class TagPill extends StatelessWidget {
  const TagPill({
    super.key,
    required this.label,
    this.onTap,
    this.active = false,
    this.icon,
    this.compact = false,
  });

  final String label;
  final VoidCallback? onTap;
  final bool active;
  final IconData? icon;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return PressableScale(
      onTap: onTap,
      child: AnimatedContainer(
        duration: AppMotion.base,
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 10 : 14,
          vertical: compact ? 6 : 8,
        ),
        decoration: BoxDecoration(
          color: active
              ? const Color(AppColors.accent).withValues(alpha: 0.16)
              : const Color(AppColors.canvas),
          borderRadius: AppRadius.rPill,
          border: Border.all(
            color: active
                ? const Color(AppColors.accent).withValues(alpha: 0.55)
                : Colors.transparent,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon,
                  size: compact ? 12 : 14,
                  color: active
                      ? const Color(AppColors.accent)
                      : const Color(AppColors.textSecondary)),
              const SizedBox(width: 4),
            ],
            Text(
              label,
              style: (compact ? AppType.caption : AppType.label).copyWith(
                color: active
                    ? const Color(AppColors.accent)
                    : const Color(AppColors.textSecondary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 横向滚动的标签行。
class TagRail extends StatelessWidget {
  const TagRail({
    super.key,
    required this.labels,
    this.index = 0,
    this.onChanged,
    this.padding = const EdgeInsets.symmetric(horizontal: AppSpace.gutter),
    this.gap = AppSpace.x2,
  });

  final List<String> labels;
  final int index;
  final ValueChanged<int>? onChanged;
  final EdgeInsets padding;
  final double gap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 34,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: padding,
        itemCount: labels.length,
        separatorBuilder: (_, _) => SizedBox(width: gap),
        itemBuilder: (_, i) => Center(
          child: TagPill(
            label: labels[i],
            active: i == index,
            onTap: onChanged == null ? null : () => onChanged!(i),
          ),
        ),
      ),
    );
  }
}

/// 大标题分段（关注 / 推荐）：文字下划线指示器。
class FeedTabs extends StatelessWidget {
  const FeedTabs({
    super.key,
    required this.labels,
    required this.index,
    required this.onChanged,
    this.onTrailing,
  });

  final List<String> labels;
  final int index;
  final ValueChanged<int> onChanged;
  final Widget? onTrailing;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 46,
      child: Row(
        children: [
          const SizedBox(width: AppSpace.x3),
          ...List.generate(labels.length, (i) {
            final active = i == index;
            return PressableScale(
              onTap: () => onChanged(i),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpace.x3),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Spacer(),
                    AnimatedDefaultTextStyle(
                      duration: AppMotion.base,
                      style: (active ? AppType.h2 : AppType.title).copyWith(
                        color: active
                            ? const Color(AppColors.textPrimary)
                            : const Color(AppColors.textTertiary),
                        fontWeight: active ? FontWeight.w800 : FontWeight.w500,
                      ),
                      child: Text(labels[i]),
                    ),
                    const SizedBox(height: 6),
                    AnimatedContainer(
                      duration: AppMotion.base,
                      curve: AppMotion.standard,
                      height: 3,
                      width: active ? 18 : 0,
                      decoration: BoxDecoration(
                        color: const Color(AppColors.accent),
                        borderRadius: AppRadius.rPill,
                        boxShadow: active
                            ? [
                                BoxShadow(
                                  color: const Color(AppColors.accent)
                                      .withValues(alpha: 0.5),
                                  blurRadius: 8,
                                )
                              ]
                            : null,
                      ),
                    ),
                    const SizedBox(height: 7),
                  ],
                ),
              ),
            );
          }),
          const Spacer(),
          ?onTrailing,
          const SizedBox(width: AppSpace.x2),
        ],
      ),
    );
  }
}

// ============================================================================
// 头像 / 图片占位
// ============================================================================

/// 统一头像：支持等级环、在线点、占位字。
class AppAvatar extends StatelessWidget {
  const AppAvatar({
    super.key,
    this.url,
    this.size = 40,
    this.name = '',
    this.onTap,
    this.ring = false,
    this.ringColor,
    this.badge,
  });

  final String? url;
  final double size;
  final String name;
  final VoidCallback? onTap;
  final bool ring;
  final Color? ringColor;
  final Widget? badge;

  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      color: const Color(AppColors.elevated),
      child: Text(
        name.isEmpty ? '?' : name.characters.first,
        style: TextStyle(
          color: const Color(AppColors.textSecondary),
          fontSize: size * 0.4,
          fontWeight: FontWeight.w700,
        ),
      ),
    );

    Widget image = ClipOval(
      child: SizedBox(
        width: size,
        height: size,
        child: (url == null || url!.isEmpty)
            ? fallback
            : CachedNetworkImage(
                imageUrl: url!,
                fit: BoxFit.cover,
                width: size,
                height: size,
                placeholder: (_, _) => fallback,
                errorWidget: (_, _, _) => fallback,
              ),
      ),
    );

    if (ring) {
      image = Container(
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: ringColor ?? const Color(AppColors.accent),
            width: 1.5,
          ),
        ),
        child: image,
      );
    }

    Widget child = badge == null
        ? image
        : Stack(clipBehavior: Clip.none, children: [
            image,
            Positioned(right: -2, bottom: -2, child: badge!),
          ]);

    return onTap == null
        ? child
        : PressableScale(onTap: onTap, scale: 0.92, child: child);
  }
}

/// 图片占位/失败态（黑底 + 图标），保证布局不跳。
class ImagePlaceholder extends StatelessWidget {
  const ImagePlaceholder({
    super.key,
    this.icon = Icons.image_outlined,
    this.radius = AppRadius.md,
  });

  final IconData icon;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(AppColors.elevated),
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Center(
        child: Icon(icon, size: 22, color: const Color(AppColors.textDisabled)),
      ),
    );
  }
}

// ============================================================================
// 骨架屏 / 空态 / 错误态
// ============================================================================

/// 呼吸式骨架块（黑底上不用渐变扫光，改用极淡的明暗呼吸，更克制）。
class SkeletonBox extends StatefulWidget {
  const SkeletonBox({
    super.key,
    this.width,
    this.height = 14,
    this.radius = AppRadius.xs,
  });

  final double? width;
  final double height;
  final double radius;

  @override
  State<SkeletonBox> createState() => _SkeletonBoxState();
}

class _SkeletonBoxState extends State<SkeletonBox>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) => Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          color: Color.lerp(
            const Color(AppColors.skeletonBase),
            const Color(AppColors.skeletonHighlight),
            _c.value * 0.7,
          ),
          borderRadius: BorderRadius.circular(widget.radius),
        ),
      ),
    );
  }
}

/// 信息流骨架（两条卡片）。
class FeedSkeleton extends StatelessWidget {
  const FeedSkeleton({super.key, this.count = 3});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: List.generate(
        count,
        (_) => Container(
          margin: const EdgeInsets.only(bottom: 1),
          padding: const EdgeInsets.fromLTRB(
              AppSpace.gutter, AppSpace.x4, AppSpace.gutter, AppSpace.x4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const SkeletonBox(width: 40, height: 40, radius: 20),
                  const SizedBox(width: AppSpace.x3),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SkeletonBox(width: 110, height: 12),
                        SizedBox(height: 8),
                        SkeletonBox(width: 64, height: 10),
                      ],
                    ),
                  ),
                  SkeletonBox(width: 54, height: 28, radius: 14),
                ],
              ),
              const SizedBox(height: AppSpace.x3),
              const SkeletonBox(height: 12),
              const SizedBox(height: 8),
              const SkeletonBox(width: 220, height: 12),
              const SizedBox(height: AppSpace.x3),
              const SkeletonBox(height: 180, radius: AppRadius.md),
            ],
          ),
        ),
      ),
    );
  }
}

/// 空态：图标 + 标题 + 说明 + 可选动作。
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    this.icon = Icons.inbox_outlined,
    required this.title,
    this.message,
    this.actionLabel,
    this.onAction,
    this.compact = false,
  });

  final IconData icon;
  final String title;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: AppSpace.x7,
        vertical: compact ? AppSpace.x8 : AppSpace.x8 * 1.6,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(AppColors.canvas),
            ),
            child: Icon(icon,
                size: 28, color: const Color(AppColors.textTertiary)),
          ),
          const SizedBox(height: AppSpace.x4),
          Text(title,
              textAlign: TextAlign.center,
              style: AppType.title.copyWith(color: const Color(AppColors.textSecondary))),
          if (message != null) ...[
            const SizedBox(height: AppSpace.x2),
            Text(message!,
                textAlign: TextAlign.center, style: AppType.caption),
          ],
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: AppSpace.x5),
            PillButton(
              label: actionLabel!,
              onTap: onAction,
              variant: PillVariant.ghost,
              size: PillSize.sm,
            ),
          ],
        ],
      ),
    );
  }
}

/// 错误态（与空态区分：给重试）。
class ErrorState extends StatelessWidget {
  const ErrorState({
    super.key,
    required this.message,
    this.onRetry,
    this.title = '加载失败',
  });

  final String message;
  final VoidCallback? onRetry;
  final String title;

  @override
  Widget build(BuildContext context) {
    return EmptyState(
      icon: Icons.wifi_off_rounded,
      title: title,
      message: message,
      actionLabel: onRetry == null ? null : '重试',
      onAction: onRetry,
    );
  }
}

/// 列表底部加载更多。
class LoadMoreFooter extends StatelessWidget {
  const LoadMoreFooter({
    super.key,
    this.loading = false,
    this.hasMore = true,
    this.onTap,
    this.endLabel = '已经到底了',
  });

  final bool loading;
  final bool hasMore;
  final VoidCallback? onTap;
  final String endLabel;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: AppSpace.x5),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (!hasMore) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpace.x6),
        child: Center(
          child: Text(endLabel,
              style: AppType.micro.copyWith(letterSpacing: 0.5)),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpace.x4),
      child: Center(
        child: PressableScale(
          onTap: onTap,
          child: Text('加载更多',
              style: AppType.caption.copyWith(color: const Color(AppColors.accent))),
        ),
      ),
    );
  }
}

// ============================================================================
// 底部弹层
// ============================================================================

/// 统一的底部弹层外形：24 圆角 + 抓手 + 标题行 + 内容。
///
/// 用法：
/// ```dart
/// showModalBottomSheet(
///   context: context,
///   isScrollControlled: true,
///   backgroundColor: Colors.transparent,
///   builder: (_) => SheetShell(title: '评论', child: ...),
/// );
/// ```
class SheetShell extends StatelessWidget {
  const SheetShell({
    super.key,
    this.title,
    this.subtitle,
    required this.child,
    this.actions = const [],
    this.heightFactor,
    this.showGrabber = true,
    this.padding =
        const EdgeInsets.symmetric(horizontal: AppSpace.gutter),
  });

  final String? title;
  final String? subtitle;
  final Widget child;
  final List<Widget> actions;
  final double? heightFactor;
  final bool showGrabber;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final maxH = MediaQuery.sizeOf(context).height;
    final content = Container(
      constraints: BoxConstraints(
        maxHeight: heightFactor == null ? maxH * 0.88 : maxH * heightFactor!,
        minHeight: heightFactor == null ? 0 : maxH * heightFactor!,
      ),
      decoration: const BoxDecoration(
        color: Color(AppColors.canvas),
        borderRadius: AppRadius.sheetTop,
        border: Border(
          top: BorderSide(color: Color(AppColors.border)),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showGrabber)
            Container(
              margin: const EdgeInsets.only(top: 10, bottom: 6),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: const Color(AppColors.textDisabled),
                borderRadius: AppRadius.rPill,
              ),
            ),
          if (title != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpace.x4, AppSpace.x1, AppSpace.x3, AppSpace.x3),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(title!, style: AppType.h2),
                        if (subtitle != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(subtitle!, style: AppType.caption),
                          ),
                      ],
                    ),
                  ),
                  ...actions,
                  IconCircleButton(
                    icon: Icons.close_rounded,
                    size: 30,
                    iconSize: 16,
                    background: const Color(AppColors.canvas),
                    onTap: () => Navigator.of(context).maybePop(),
                  ),
                ],
              ),
            ),
          Flexible(
            child: Padding(
              padding: title == null
                  ? padding.copyWith(top: AppSpace.x3)
                  : padding,
              child: child,
            ),
          ),
        ],
      ),
    );
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: content,
    );
  }
}

// ============================================================================
// 其它原子件
// ============================================================================

/// 小节标题：左标题 + 右动作。
class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.actionLabel,
    this.onAction,
    this.padding =
        const EdgeInsets.fromLTRB(AppSpace.gutter, AppSpace.x5, AppSpace.gutter, AppSpace.x3),
  });

  final String title;
  final String? subtitle;
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
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title, style: AppType.h2),
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(subtitle!, style: AppType.caption),
                  ),
              ],
            ),
          ),
          if (actionLabel != null)
            PressableScale(
              onTap: onAction,
              child: Row(
                children: [
                  Text(actionLabel!,
                      style: AppType.caption
                          .copyWith(color: const Color(AppColors.textSecondary))),
                  const Icon(Icons.chevron_right_rounded,
                      size: 16, color: Color(AppColors.textTertiary)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// 搜索胶囊（点击进入搜索页，不直接输入）。
class SearchPill extends StatelessWidget {
  const SearchPill({
    super.key,
    this.hint = '搜索帖子、视频、用户',
    this.onTap,
    this.trailing,
  });

  final String hint;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return PressableScale(
      onTap: onTap,
      child: Container(
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.x3),
        decoration: BoxDecoration(
          color: const Color(AppColors.canvas),
          borderRadius: AppRadius.rPill,
          border: Border.all(color: const Color(AppColors.border)),
        ),
        child: Row(
          children: [
            const Icon(Icons.search_rounded,
                size: 18, color: Color(AppColors.textTertiary)),
            const SizedBox(width: AppSpace.x2),
            Expanded(
              child: Text(
                hint,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppType.bodySm
                    .copyWith(color: const Color(AppColors.textTertiary)),
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );
  }
}

/// 统计格（数字在上、标签在下）。
class StatTile extends StatelessWidget {
  const StatTile({
    super.key,
    required this.value,
    required this.label,
    this.onTap,
    this.highlight = false,
  });

  final String value;
  final String label;
  final VoidCallback? onTap;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    return PressableScale(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            value,
            style: AppType.h2.copyWith(
              fontSize: 19,
              color: highlight
                  ? const Color(AppColors.accent)
                  : const Color(AppColors.textPrimary),
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 2),
          Text(label, style: AppType.micro),
        ],
      ),
    );
  }
}

/// 细分隔线（全宽，透明度极低）。
class Hairline extends StatelessWidget {
  const Hairline({super.key, this.indent = 0});

  final double indent;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(left: indent),
      child: Container(height: 0.5, color: const Color(AppColors.hairline)),
    );
  }
}

/// 列表行（设置/我的/消息通用）：左图标或头像 + 标题/副标题 + 右侧。
class ListRow extends StatelessWidget {
  const ListRow({
    super.key,
    this.leading,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.showChevron = true,
    this.padding =
        const EdgeInsets.symmetric(horizontal: AppSpace.gutter, vertical: AppSpace.x3),
  });

  final Widget? leading;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool showChevron;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      splashColor: Colors.transparent,
      highlightColor: const Color(0x08000000),
      child: Padding(
        padding: padding,
        child: Row(
          children: [
            if (leading != null) ...[leading!, const SizedBox(width: AppSpace.x3)],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title, style: AppType.body),
                  if (subtitle != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppType.caption),
                    ),
                ],
              ),
            ),
            ?trailing,
            if (trailing == null && showChevron)
              const Icon(Icons.chevron_right_rounded,
                  size: 20, color: Color(AppColors.textTertiary)),
          ],
        ),
      ),
    );
  }
}

/// 空对话/空列表用的虚线描边卡（引导动作）。
class DashedActionCard extends StatelessWidget {
  const DashedActionCard({
    super.key,
    required this.label,
    this.icon = Icons.add_rounded,
    this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return PressableScale(
      onTap: onTap,
      child: Container(
        height: 92,
        decoration: BoxDecoration(
          color: const Color(AppColors.canvas),
          borderRadius: AppRadius.rMd,
          border: Border.all(color: const Color(AppColors.border)),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: const Color(AppColors.textTertiary), size: 22),
            const SizedBox(height: 6),
            Text(label, style: AppType.caption),
          ],
        ),
      ),
    );
  }
}

/// 轻提示（统一深色胶囊 + 底部偏移）。
void showAppToast(BuildContext context, String message) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message,
            style: AppType.bodySm.copyWith(color: const Color(0xFFFAF8F4))),
        duration: const Duration(milliseconds: 1800),
        backgroundColor: const Color(AppColors.textPrimary),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(48, 0, 48, 28),
        shape: const RoundedRectangleBorder(borderRadius: AppRadius.rPill),
      ),
    );
}

/// 数字缩写：1234 → 1234；12345 → 1.2万。
String formatCount(num n) {
  final v = n.toInt();
  if (v < 10000) return '$v';
  final w = v / 10000;
  return '${w.toStringAsFixed(w >= 100 ? 0 : 1)}万';
}
