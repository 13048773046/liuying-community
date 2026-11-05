/// 瀑布流卡片（首页/收藏页复用）：视频 / 图文 / 纯文 / 投票 四类
///
/// 沉浸黑：黑底无边框 + 14 圆角 + 白色文字；字段、构造参数与回调语义保持不变。
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../config.dart';
import '../design/components.dart';
import '../models/feed_item.dart';
import 'poll_card.dart';
import 'user_avatar.dart';

class WaterfallCard extends StatelessWidget {
  final FeedItem item;
  final VoidCallback onTap;
  final VoidCallback? onAuthorTap;
  const WaterfallCard(
      {super.key, required this.item, required this.onTap, this.onAuthorTap});

  @override
  Widget build(BuildContext context) {
    final isVideo = item.type == 'video';
    return PressableScale(
      onTap: onTap,
      scale: 0.97,
      haptic: false,
      child: Container(
        decoration: const BoxDecoration(
          color: Color(AppColors.card),
          borderRadius: BorderRadius.all(Radius.circular(14)),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 概念稿卡片结构：图 → 正文 → 底部作者+互动数据行
            if (isVideo)
              _videoCover()
            else if (item.images.isNotEmpty)
              _images(item.images),
            if (!isVideo && item.content.isNotEmpty) ...[
              const SizedBox(height: AppSpace.x2),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpace.x3),
                child: _content(item.content, item.type == 'text'),
              ),
            ],
            if (item.poll != null) ...[
              const SizedBox(height: AppSpace.x2),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpace.x3),
                child: PollCard(
                  postId: item.id,
                  poll: item.poll!,
                ),
              ),
            ],
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpace.x3, AppSpace.x2, AppSpace.x3, AppSpace.x3),
              child: _footerRow(),
            ),
          ],
        ),
      ),
    );
  }

  /// 视频卡：封面 3:4 + 时长 + 底部作者条 + 互动
  Widget _videoCover() {
    final cover = item.cover == 'auto' ? '${item.video}.jpg' : item.cover;
    final dur = item.duration;
    return Stack(
      children: [
        AspectRatio(
          aspectRatio: 3 / 4,
          child: cover.isNotEmpty
              ? CachedNetworkImage(
                  imageUrl: mediaUrl(cover),
                  fit: BoxFit.cover,
                  placeholder: (_, _) => const ImagePlaceholder(radius: 0),
                  errorWidget: (_, _, _) => const ImagePlaceholder(
                    icon: Icons.movie_outlined,
                    radius: 0,
                  ),
                )
              : const ImagePlaceholder(icon: Icons.movie_outlined, radius: 0),
        ),
        // 时长角标（封面无播放按钮，仅右下角时长）
        if (dur > 0)
          Positioned(
            right: AppSpace.x2,
            bottom: AppSpace.x2,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.6),
                borderRadius: AppRadius.rXs,
              ),
              child: Text(
                _fmtDur(dur),
                style: AppType.micro.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// 底部数据行：作者（左）+ 点赞/评论（右）
  Widget _footerRow() {
    final a = item.author;
    final avatar = _miniAvatar(a.avatar, a.name);
    return Row(
      children: [
        if (onAuthorTap != null)
          GestureDetector(onTap: onAuthorTap, child: avatar)
        else
          avatar,
        const SizedBox(width: AppSpace.x2),
        Expanded(
          child: Row(
            children: [
              Flexible(
                child: Text(
                  a.name.isEmpty ? '匿名用户' : a.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.label.copyWith(
                    color: Colors.white,
                    shadows: const [
                      Shadow(color: Color(0x99000000), blurRadius: 4)
                    ],
                  ),
                ),
              ),
              if (a.isAdmin) ...[
                const SizedBox(width: AppSpace.x1),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    color: const Color(AppColors.accent).withValues(alpha: 0.22),
                    borderRadius: AppRadius.rXs,
                    border: Border.all(
                      color:
                          const Color(AppColors.accent).withValues(alpha: 0.55),
                    ),
                  ),
                  child: Text(
                    '管',
                    style: AppType.micro.copyWith(
                      color: const Color(AppColors.accent),
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
              if (item.featured) ...[
                const SizedBox(width: AppSpace.x1),
                const Icon(Icons.star_rounded,
                    size: 12, color: Color(AppColors.warning)),
              ],
              if (item.sticky) ...[
                const SizedBox(width: AppSpace.x1),
                const Icon(Icons.push_pin_rounded,
                    size: 11, color: Color(AppColors.textTertiary)),
              ],
              if (item.type == 'poll') ...[
                const SizedBox(width: AppSpace.x1),
                const Icon(Icons.how_to_vote_outlined,
                    size: 12, color: Color(AppColors.textTertiary)),
              ],
            ],
          ),
        ),
        const SizedBox(width: AppSpace.x2),
        _miniAction(Icons.favorite_rounded, item.likeCount, item.liked),
        const SizedBox(width: AppSpace.x2),
        _miniAction(
            Icons.chat_bubble_outline_rounded, item.commentCount, false),
      ],
    );
  }

  Widget _miniAvatar(String url, String name) {
    return UserAvatar(
      url: url,
      name: name,
      size: 26,
      borderColor: Colors.white.withValues(alpha: 0.18),
    );
  }

  Widget _content(String text, bool isText) {
    final spans = <TextSpan>[];
    final kw = RegExp('(#[^\\s#]+)');
    var last = 0;
    for (final m in kw.allMatches(text)) {
      if (m.start > last) {
        spans.add(TextSpan(text: text.substring(last, m.start)));
      }
      spans.add(TextSpan(
        text: m.group(0),
        style: const TextStyle(
            color: Color(AppColors.accent), fontWeight: FontWeight.w600),
      ));
      last = m.end;
    }
    if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
    return Text.rich(
      TextSpan(
        style: AppType.body.copyWith(
          fontSize: isText ? 14 : 13.5,
          height: 1.45,
          color: Colors.white,
        ),
        children: spans,
      ),
      maxLines: isText ? 6 : 3,
      overflow: TextOverflow.ellipsis,
    );
  }

  Widget _images(List<String> images) {
    // 无论帖子有多少张图，瀑布流卡统一只显示第一张（图在上、文字在下）
    if (images.isEmpty) return const SizedBox.shrink();
    return AspectRatio(
      aspectRatio: 4 / 3,
      child: CachedNetworkImage(
        imageUrl: mediaUrl(images.first),
        fit: BoxFit.cover,
        placeholder: (_, _) => const ImagePlaceholder(radius: 0),
        errorWidget: (_, _, _) => const ImagePlaceholder(
          icon: Icons.broken_image_outlined,
          radius: 0,
        ),
      ),
    );
  }

  Widget _miniAction(IconData icon, int count, bool active) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: 14,
          color: active
              ? const Color(AppColors.heart)
              : const Color(AppColors.textTertiary),
        ),
        const SizedBox(width: 3),
        Text(
          formatCount(count),
          style: AppType.micro.copyWith(
            color: const Color(AppColors.textSecondary),
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }

  static String _fmtDur(int s) {
    final m = s ~/ 60;
    final sec = s % 60;
    return '$m:${sec.toString().padLeft(2, '0')}';
  }
}
