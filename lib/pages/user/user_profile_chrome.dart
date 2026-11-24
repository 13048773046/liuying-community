/// 用户主页的新视觉语言：夜航档案。
///
/// 这里只放可复用的展示件：封面、身份统计带、下划线 tab、作品卡、应用卡、
/// 骨架与空态。页面负责请求、状态归属和导航。
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../config.dart';
import '../../design/components.dart';
import '../../features/emoji/text_emoji.dart';
import '../../models/app_market.dart';
import '../../models/feed_item.dart' show FeedItem, countText, timeAgo;
import '../apps/app_widgets.dart';

// ============================================================================
// 封面
// ============================================================================

/// 全幅身份封面。无背景图时使用固定的夜航光晕 + 萤火点，避免额外网络依赖。
class ProfileCover extends StatelessWidget {
  const ProfileCover({
    super.key,
    required this.imageUrl,
    this.height = 190,
    this.watermark = '',
  });

  final String imageUrl;
  final double height;
  final String watermark;

  @override
  Widget build(BuildContext context) {
    final decodeWidth =
        (MediaQuery.sizeOf(context).width *
                MediaQuery.devicePixelRatioOf(context))
            .ceil();
    return SizedBox(
      height: height,
      width: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: [
          const _AmbientCover(),
          if (imageUrl.isNotEmpty)
            CachedNetworkImage(
              imageUrl: imageUrl,
              fit: BoxFit.cover,
              memCacheWidth: decodeWidth,
              fadeInDuration: const Duration(milliseconds: 220),
              placeholder: (_, _) => const _AmbientCover(),
              errorWidget: (_, _, _) => const _AmbientCover(),
            ),
          // 保证顶栏在深色/浅色封面上都能读。
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: AppEffects.topScrim(height: 0.62),
            ),
          ),
          // 封面底部融进纯黑，身份区不再像一块贴上去的卡片。
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 150,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [
                    const Color(AppColors.bg),
                    const Color(AppColors.bg).withValues(alpha: 0.82),
                    const Color(AppColors.bg).withValues(alpha: 0),
                  ],
                  stops: const [0, 0.38, 1],
                ),
              ),
            ),
          ),
          // 无背景图时，用名字首字做超大暗纹，避免封面只剩一片空黑。
          if (imageUrl.isEmpty && watermark.isNotEmpty)
            Positioned(
              right: -10,
              top: 34,
              child: IgnorePointer(
                child: Text(
                  String.fromCharCode(watermark.runes.first),
                  style: TextStyle(
                    fontSize: 156,
                    height: 1,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -8,
                    color: Colors.white.withValues(alpha: 0.055),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _AmbientCover extends StatelessWidget {
  const _AmbientCover();

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color(0xFF07110F),
                Color(0xFF030807),
                Color(AppColors.bg),
              ],
              stops: [0, 0.56, 1],
            ),
          ),
        ),
        // 右上角的薄荷光晕，给纯黑封面一点空间深度。
        Positioned(
          right: -90,
          top: -120,
          child: Container(
            width: 320,
            height: 320,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  const Color(AppColors.accent).withValues(alpha: 0.18),
                  const Color(AppColors.accent).withValues(alpha: 0.04),
                  const Color(AppColors.accent).withValues(alpha: 0),
                ],
                stops: const [0, 0.46, 1],
              ),
            ),
          ),
        ),
        Positioned(
          left: -80,
          bottom: -150,
          child: Container(
            width: 300,
            height: 300,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  const Color(AppColors.info).withValues(alpha: 0.10),
                  const Color(AppColors.info).withValues(alpha: 0),
                ],
              ),
            ),
          ),
        ),
        const Positioned.fill(
          child: IgnorePointer(child: CustomPaint(painter: _FireflyPainter())),
        ),
      ],
    );
  }
}

/// 固定坐标的萤火点；不随机、不随时间变化，保证 golden 稳定。
class _FireflyPainter extends CustomPainter {
  const _FireflyPainter();

  static const List<Offset> _dots = [
    Offset(0.14, 0.30),
    Offset(0.26, 0.58),
    Offset(0.37, 0.21),
    Offset(0.48, 0.44),
    Offset(0.58, 0.72),
    Offset(0.67, 0.18),
    Offset(0.74, 0.49),
    Offset(0.83, 0.34),
    Offset(0.91, 0.64),
    Offset(0.21, 0.78),
    Offset(0.44, 0.86),
    Offset(0.79, 0.82),
    Offset(0.08, 0.52),
    Offset(0.55, 0.10),
    Offset(0.95, 0.20),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    for (var i = 0; i < _dots.length; i++) {
      final p = Offset(_dots[i].dx * size.width, _dots[i].dy * size.height);
      final r = i % 4 == 0 ? 2.2 : 1.2;
      final opacity = i % 3 == 0 ? 0.42 : 0.22;
      final paint = Paint()
        ..color = const Color(AppColors.accent).withValues(alpha: opacity);
      if (i % 5 == 0) {
        paint.maskFilter = const MaskFilter.blur(BlurStyle.normal, 5);
      }
      canvas.drawCircle(p, r, paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ============================================================================
// 身份统计带
// ============================================================================

/// 关注 / 粉丝 / 等级三栏，同一块玻璃带上完成关系与成长信息。
class ProfileStatBand extends StatelessWidget {
  const ProfileStatBand({
    super.key,
    required this.followers,
    required this.followings,
    required this.level,
    required this.exp,
    this.onFollowers,
    this.onFollowings,
  });

  final int followers;
  final int followings;
  final int level;
  final int exp;
  final VoidCallback? onFollowers;
  final VoidCallback? onFollowings;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 70,
      decoration: BoxDecoration(
        color: const Color(AppColors.card).withValues(alpha: 0.74),
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: const Color(AppColors.border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: _StatCell(
              value: countText(followings),
              label: '关注',
              onTap: onFollowings,
              semanticLabel: '查看关注列表，$followings 人',
            ),
          ),
          const _StatDivider(),
          Expanded(
            child: _StatCell(
              value: countText(followers),
              label: '粉丝',
              onTap: onFollowers,
              accent: true,
              semanticLabel: '查看粉丝列表，$followers 人',
            ),
          ),
          const _StatDivider(),
          Expanded(
            child: _StatCell(
              value: 'Lv.$level',
              label: exp <= 0 ? '经验值' : '${_expText(exp)} 经验',
              accent: true,
              semanticLabel: '社区等级 $level，$exp 经验',
            ),
          ),
        ],
      ),
    );
  }
}

String _expText(int exp) {
  if (exp < 10000) return '$exp';
  return '${(exp / 10000).toStringAsFixed(1)}w';
}

class _StatCell extends StatelessWidget {
  const _StatCell({
    required this.value,
    required this.label,
    this.onTap,
    this.accent = false,
    required this.semanticLabel,
  });

  final String value;
  final String label;
  final VoidCallback? onTap;
  final bool accent;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    final content = Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppType.h2.copyWith(
            fontSize: 21,
            letterSpacing: -0.3,
            color: accent
                ? const Color(AppColors.accent)
                : const Color(AppColors.textPrimary),
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(height: 3),
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppType.micro.copyWith(
            color: const Color(AppColors.textTertiary),
          ),
        ),
      ],
    );

    return Semantics(
      button: onTap != null,
      label: semanticLabel,
      child: PressableScale(
        onTap: onTap,
        scale: 0.97,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.x2),
          child: content,
        ),
      ),
    );
  }
}

class _StatDivider extends StatelessWidget {
  const _StatDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 0.5,
      height: 28,
      color: const Color(AppColors.border),
    );
  }
}

// ============================================================================
// 分段
// ============================================================================

/// 下划线分段：和全站的胶囊 tab 区分开，更像一份档案的章节。
class ProfileTabBar extends StatelessWidget {
  const ProfileTabBar({
    super.key,
    required this.labels,
    required this.index,
    required this.onChanged,
  });

  final List<String> labels;
  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 46,
      child: Row(
        children: [
          for (var i = 0; i < labels.length; i++)
            Expanded(
              child: Semantics(
                button: true,
                selected: i == index,
                label: labels[i],
                child: PressableScale(
                  onTap: () => onChanged(i),
                  scale: 0.97,
                  child: ExcludeSemantics(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        AnimatedDefaultTextStyle(
                          duration: AppMotion.base,
                          curve: AppMotion.standard,
                          style: AppType.title.copyWith(
                            fontFamily: DefaultTextStyle.of(context)
                                .style
                                .fontFamily,
                            fontSize: 15,
                            fontWeight: i == index
                                ? FontWeight.w700
                                : FontWeight.w500,
                            color: i == index
                                ? const Color(AppColors.textPrimary)
                                : const Color(AppColors.textTertiary),
                          ),
                          child: Text(labels[i]),
                        ),
                        const SizedBox(height: 6),
                        AnimatedContainer(
                          duration: AppMotion.base,
                          curve: AppMotion.emphasized,
                          width: i == index ? 22 : 0,
                          height: 2.5,
                          decoration: BoxDecoration(
                            color: const Color(AppColors.accent),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ============================================================================
// 作品卡
// ============================================================================

/// 两列档案式作品卡。个人主页不重复作者信息，把面积让给内容、封面与真实互动数据。
class ProfileWorkCard extends StatelessWidget {
  const ProfileWorkCard({
    super.key,
    required this.item,
    this.onTap,
    this.index = 0,
  });

  final FeedItem item;
  final VoidCallback? onTap;
  final int index;

  @override
  Widget build(BuildContext context) {
    final cover = item.isVideo
        ? item.cover.trim()
        : (item.images.isNotEmpty ? item.images.first.trim() : '');
    final label = item.isVideo ? '查看短视频' : '查看帖子';
    final body = _coverSurface(cover) ?? _textSurface(context);

    return Semantics(
      button: true,
      label: '$label：${item.content}',
      child: ExcludeSemantics(
        child: PressableScale(
          onTap: onTap,
          scale: 0.965,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.lg),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(AppColors.card),
                border: Border.all(color: const Color(AppColors.border)),
                borderRadius: BorderRadius.circular(AppRadius.lg),
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  body,
                  if (cover.isNotEmpty)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      height: 105,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.bottomCenter,
                            end: Alignment.topCenter,
                            colors: [
                              Colors.black.withValues(alpha: 0.88),
                              Colors.black.withValues(alpha: 0),
                            ],
                          ),
                        ),
                      ),
                    ),
                  if (cover.isNotEmpty)
                    Positioned(
                      left: AppSpace.x3,
                      right: AppSpace.x3,
                      bottom: AppSpace.x3,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (item.reason.trim().isNotEmpty) ...[
                            Row(
                              children: [
                                const Icon(
                                  Icons.auto_awesome_rounded,
                                  size: 10,
                                  color: Color(AppColors.accent),
                                ),
                                const SizedBox(width: 4),
                                Expanded(
                                  child: Text(
                                    item.reason,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 9,
                                      height: 1.15,
                                      color: Color(AppColors.accent),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                          ],
                          if (item.content.trim().isNotEmpty)
                            TextEmojiText(
                              item.content.trim(),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: AppType.caption.copyWith(
                                color: Colors.white,
                                height: 1.35,
                              ),
                            ),
                          const SizedBox(height: 6),
                          _WorkMeta(item: item, light: true),
                        ],
                      ),
                    ),
                  if (cover.isEmpty)
                    Positioned(
                      left: AppSpace.x3,
                      right: AppSpace.x3,
                      bottom: AppSpace.x3,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (item.reason.trim().isNotEmpty) ...[
                            Row(
                              children: [
                                const Icon(
                                  Icons.auto_awesome_rounded,
                                  size: 10,
                                  color: Color(AppColors.accent),
                                ),
                                const SizedBox(width: 4),
                                Expanded(
                                  child: Text(
                                    item.reason,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 9,
                                      height: 1.15,
                                      color: Color(AppColors.accent),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                          ],
                          _WorkMeta(item: item, light: false),
                        ],
                      ),
                    ),
                  Positioned(
                    top: AppSpace.x3,
                    left: AppSpace.x3,
                    child: _WorkKindBadge(item: item),
                  ),
                  if (item.isVideo) const Center(child: _PlayMark()),
                  if (!item.isVideo && item.images.length > 1)
                    Positioned(
                      top: AppSpace.x3,
                      right: AppSpace.x3,
                      child: _CountMark(
                        icon: Icons.filter_none_rounded,
                        text: '${item.images.length}',
                      ),
                    ),
                  if (item.isVideo && item.duration > 0)
                    Positioned(
                      right: AppSpace.x3,
                      top: AppSpace.x3,
                      child: _CountMark(
                        icon: Icons.schedule_rounded,
                        text: _durationText(item.duration),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget? _coverSurface(String cover) {
    if (cover.isEmpty) return null;
    return CachedNetworkImage(
      imageUrl: mediaUrl(cover),
      fit: BoxFit.cover,
      fadeInDuration: const Duration(milliseconds: 160),
      placeholder: (_, _) => const _ImageFallback(),
      errorWidget: (_, _, _) => const _ImageFallback(),
    );
  }

  Widget _textSurface(BuildContext context) {
    final tones = <List<Color>>[
      const [Color(0xFF111A17), Color(AppColors.card)],
      const [Color(0xFF151217), Color(AppColors.card)],
      const [Color(0xFF101619), Color(AppColors.card)],
    ];
    final tone = tones[index % tones.length];
    return Container(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.x3,
        AppSpace.x5 + 8,
        AppSpace.x3,
        46,
      ),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: tone,
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            right: -4,
            top: -14,
            child: Text(
              '“',
              style: TextStyle(
                fontSize: 52,
                height: 1,
                fontWeight: FontWeight.w800,
                color: Colors.white.withValues(alpha: 0.055),
              ),
            ),
          ),
          TextEmojiText(
            item.content.trim().isEmpty ? '无正文' : item.content.trim(),
            maxLines: 5,
            overflow: TextOverflow.ellipsis,
            style: AppType.bodySm.copyWith(
              color: const Color(AppColors.textSecondary),
              height: 1.55,
            ),
          ),
        ],
      ),
    );
  }
}

class _ImageFallback extends StatelessWidget {
  const _ImageFallback();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF121815), Color(AppColors.card)],
        ),
      ),
      child: Center(
        child: Icon(
          Icons.image_outlined,
          size: 24,
          color: Color(AppColors.textDisabled),
        ),
      ),
    );
  }
}

class _WorkMeta extends StatelessWidget {
  const _WorkMeta({required this.item, required this.light});

  final FeedItem item;
  final bool light;

  @override
  Widget build(BuildContext context) {
    final color = light
        ? Colors.white.withValues(alpha: 0.92)
        : const Color(AppColors.textTertiary);
    final secondary = light
        ? Colors.white.withValues(alpha: 0.62)
        : const Color(AppColors.textTertiary);
    return Row(
      children: [
        Icon(Icons.favorite_rounded, size: 12, color: secondary),
        const SizedBox(width: 4),
        Text(
          countText(item.likeCount),
          style: AppType.micro.copyWith(color: color),
        ),
        const SizedBox(width: 9),
        Icon(Icons.chat_bubble_outline_rounded, size: 12, color: secondary),
        const SizedBox(width: 4),
        Text(
          countText(item.commentCount),
          style: AppType.micro.copyWith(color: secondary),
        ),
        const Spacer(),
        Text(
          timeAgo(item.created),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppType.micro.copyWith(color: secondary, fontSize: 10),
        ),
      ],
    );
  }
}

class _WorkKindBadge extends StatelessWidget {
  const _WorkKindBadge({required this.item});

  final FeedItem item;

  @override
  Widget build(BuildContext context) {
    final video = item.isVideo;
    return Container(
      height: 23,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.58),
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            video ? Icons.play_arrow_rounded : Icons.notes_rounded,
            size: 12,
            color: video ? const Color(AppColors.accent) : Colors.white,
          ),
          const SizedBox(width: 3),
          Text(
            video ? '短视频' : '随笔',
            style: AppType.micro.copyWith(
              fontSize: 10,
              color: Colors.white,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _CountMark extends StatelessWidget {
  const _CountMark({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: 7),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: Colors.white70),
          const SizedBox(width: 3),
          Text(
            text,
            style: AppType.micro.copyWith(fontSize: 10, color: Colors.white),
          ),
        ],
      ),
    );
  }
}

class _PlayMark extends StatelessWidget {
  const _PlayMark();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.black.withValues(alpha: 0.5),
        border: Border.all(color: Colors.white.withValues(alpha: 0.22)),
      ),
      child: const Icon(
        Icons.play_arrow_rounded,
        size: 24,
        color: Colors.white,
      ),
    );
  }
}

String _durationText(int seconds) {
  final m = seconds ~/ 60;
  final s = seconds % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}

// ============================================================================
// 应用卡
// ============================================================================

/// 个人主页的应用投稿卡：只展示已上架应用，突出名称、平台、评分与下载。
class ProfileAppCard extends StatelessWidget {
  const ProfileAppCard({super.key, required this.app, this.onTap});

  final MarketApp app;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final desc = app.description.trim();
    return Semantics(
      button: true,
      label: '查看应用：${app.name}',
      child: ExcludeSemantics(
        child: PressableScale(
          onTap: onTap,
          scale: 0.985,
          child: Container(
            padding: const EdgeInsets.all(AppSpace.x3),
            decoration: BoxDecoration(
              color: const Color(AppColors.card).withValues(alpha: 0.66),
              borderRadius: BorderRadius.circular(AppRadius.lg),
              border: Border.all(color: const Color(AppColors.hairline)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppIconTile(app: app, size: 58),
                const SizedBox(width: AppSpace.x3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
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
                          if (app.featured)
                            const Padding(
                              padding: EdgeInsets.only(left: 6),
                              child: Icon(
                                Icons.star_rounded,
                                size: 15,
                                color: Color(AppColors.warning),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          PlatformBadge(app: app),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              app.category.isEmpty
                                  ? '社区应用'
                                  : '${app.category}${app.subCategory.isEmpty ? '' : ' / ${app.subCategory}'}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppType.micro.copyWith(fontSize: 10.5),
                            ),
                          ),
                        ],
                      ),
                      if (desc.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          desc,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: AppType.caption.copyWith(
                            color: const Color(AppColors.textSecondary),
                          ),
                        ),
                      ],
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          const Icon(
                            Icons.download_rounded,
                            size: 12,
                            color: Color(AppColors.textTertiary),
                          ),
                          const SizedBox(width: 3),
                          Text(
                            '${countText(app.downloadCount)} 次下载',
                            style: AppType.micro.copyWith(fontSize: 10.5),
                          ),
                          const SizedBox(width: 10),
                          Icon(
                            Icons.star_rounded,
                            size: 12,
                            color: app.ratingCount > 0
                                ? const Color(AppColors.warning)
                                : const Color(AppColors.textTertiary),
                          ),
                          const SizedBox(width: 3),
                          Text(
                            app.ratingText,
                            style: AppType.micro.copyWith(fontSize: 10.5),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// 加载骨架 / 空态
// ============================================================================

/// 首屏骨架严格沿用新主页的封面、身份区与两列作品墙比例。
class ProfileArchiveSkeleton extends StatelessWidget {
  const ProfileArchiveSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      children: [
        const SkeletonBox(width: double.infinity, height: 190, radius: 0),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpace.gutter,
            16,
            AppSpace.gutter,
            0,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SkeletonBox(width: 94, height: 94, radius: 47),
                  const SizedBox(width: AppSpace.x4),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 6),
                        const SkeletonBox(width: 130, height: 24),
                        const SizedBox(height: AppSpace.x2),
                        const SkeletonBox(width: 96, height: 18, radius: 9),
                        const SizedBox(height: AppSpace.x3),
                        Row(
                          children: const [
                            SkeletonBox(width: 54, height: 13),
                            SizedBox(width: 8),
                            SkeletonBox(width: 48, height: 13),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpace.x5),
              const SkeletonBox(width: 210, height: 14),
              const SizedBox(height: AppSpace.x2),
              const SkeletonBox(width: 156, height: 14),
              const SizedBox(height: AppSpace.x5),
              const SkeletonBox(
                width: double.infinity,
                height: 74,
                radius: AppRadius.lg,
              ),
              const SizedBox(height: AppSpace.x4),
              Row(
                children: const [
                  Expanded(
                    child: SkeletonBox(height: 48, radius: AppRadius.pill),
                  ),
                  SizedBox(width: AppSpace.x2),
                  Expanded(
                    child: SkeletonBox(height: 48, radius: AppRadius.pill),
                  ),
                ],
              ),
              const SizedBox(height: AppSpace.x6),
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  mainAxisSpacing: AppSpace.x2,
                  crossAxisSpacing: AppSpace.x2,
                  childAspectRatio: 0.79,
                ),
                itemCount: 4,
                itemBuilder: (_, _) => const SkeletonBox(radius: AppRadius.lg),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 档案内的空态：不做通用空插画，保持“这个人的档案目前留白”的语气。
class ProfileArchiveEmpty extends StatelessWidget {
  const ProfileArchiveEmpty({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.gutter,
        AppSpace.x3,
        AppSpace.gutter,
        AppSpace.x6,
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpace.x5,
          vertical: AppSpace.x7,
        ),
        decoration: BoxDecoration(
          color: const Color(AppColors.card).withValues(alpha: 0.42),
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(color: const Color(AppColors.hairline)),
        ),
        child: Column(
          children: [
            Container(
              width: 50,
              height: 50,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(AppColors.accent).withValues(alpha: 0.08),
                border: Border.all(
                  color: const Color(AppColors.accent).withValues(alpha: 0.18),
                ),
              ),
              child: Icon(
                icon,
                size: 22,
                color: const Color(AppColors.accent).withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(height: AppSpace.x3),
            Text(
              title,
              textAlign: TextAlign.center,
              style: AppType.title.copyWith(
                color: const Color(AppColors.textSecondary),
              ),
            ),
            const SizedBox(height: 5),
            Text(message, textAlign: TextAlign.center, style: AppType.caption),
          ],
        ),
      ),
    );
  }
}
