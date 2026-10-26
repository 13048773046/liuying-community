/// 瀑布流卡片（首页/收藏页复用）：视频 / 图文 / 纯文 / 投票 四类
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'user_avatar.dart';

import '../config.dart';
import '../models/feed_item.dart';

class WaterfallCard extends StatelessWidget {
  final FeedItem item;
  final VoidCallback onTap;
  final VoidCallback? onAuthorTap;
  const WaterfallCard(
      {super.key, required this.item, required this.onTap, this.onAuthorTap});

  @override
  Widget build(BuildContext context) {
    final isVideo = item.type == 'video';
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        decoration: BoxDecoration(
          color: const Color(AppTheme.card),
          borderRadius: BorderRadius.circular(14),
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
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: _content(item.content, item.topic, item.type == 'text'),
              ),
            ],
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              child: _footerRow(isVideo),
            ),
          ],
        ),
      ),
    );
  }

  /// 视频卡：封面 3:4 + 播放角标 + 时长 + 作者条 + 互动
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
                  placeholder: (_, _) =>
                      Container(color: const Color(0xFF1C1C24)),
                  errorWidget: (_, _, _) => Container(
                    color: const Color(0xFF1C1C24),
                    child: const Icon(Icons.movie_outlined,
                        color: Color(AppTheme.textSecondary)),
                  ),
                )
              : Container(
                  color: const Color(0xFF1C1C24),
                  child: const Icon(Icons.movie_outlined,
                      color: Color(AppTheme.textSecondary)),
                ),
        ),
        // 时长角标（对齐抖音/小红书瀑布流：封面无播放按钮，仅右下角时长）
        if (dur > 0)
          Positioned(
            right: 6,
            bottom: 6,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(5),
              ),
              child: Text(_fmtDur(dur),
                  style: const TextStyle(
                      color: Colors.white, fontSize: 10.5)),
            ),
          ),
      ],
    );
  }

  /// 图文卡底部数据行：作者（左）+ 点赞/评论（右），对齐概念稿
  Widget _footerRow(bool isVideo) {
    final a = item.author;
    return Row(
      children: [
        if (onAuthorTap != null)
          GestureDetector(onTap: onAuthorTap, child: _miniAvatar(a.avatar, a.name))
        else
          _miniAvatar(a.avatar, a.name),
        const SizedBox(width: 6),
        Expanded(
          child: Row(
            children: [
              Flexible(
                child: Text(
                  a.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w600),
                ),
              ),
              if (a.isAdmin) ...[
                const SizedBox(width: 4),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                        colors: [
                          Color(AppTheme.accent),
                          Color(AppTheme.sky)
                        ]),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: const Text(
                    '管',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 8,
                        height: 1.3,
                        fontWeight: FontWeight.w600),
                  ),
                ),
              ],
              if (item.featured) ...[
                const SizedBox(width: 4),
                const Text('★',
                    style: TextStyle(
                        color: Color(0xFFFFB84D),
                        fontSize: 11,
                        fontWeight: FontWeight.bold)),
              ],
              if (item.sticky) ...[
                const SizedBox(width: 4),
                const Text('📌', style: TextStyle(fontSize: 10)),
              ],
              if (item.type == 'poll') ...[
                const SizedBox(width: 4),
                const Icon(Icons.how_to_vote_outlined,
                    size: 13, color: Color(AppTheme.lilac)),
              ],
            ],
          ),
        ),
        const SizedBox(width: 8),
        _miniAction(Icons.favorite_rounded, item.likeCount, item.liked),
        const SizedBox(width: 10),
        _miniAction(
            Icons.chat_bubble_outline_rounded, item.commentCount, false),
      ],
    );
  }

  Widget _miniAvatar(String url, String name) {
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white.withOpacity(0.25)),
      ),
      child: UserAvatar(url: url, name: name, size: 28),
    );
  }

  Widget _content(String text, List<String> topics, bool isText) {
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
            color: Color(AppTheme.lilac), fontWeight: FontWeight.w600),
      ));
      last = m.end;
    }
    if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
    return Text.rich(
      TextSpan(
        style: TextStyle(
            color: Colors.white,
            fontSize: isText ? 14 : 13.5,
            height: 1.45),
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
        placeholder: (_, _) => Container(color: const Color(0xFF1C1C24)),
        errorWidget: (_, _, _) => Container(
          color: const Color(0xFF1C1C24),
          child: const Icon(Icons.broken_image,
              color: Color(AppTheme.textSecondary)),
        ),
      ),
    );
  }

  Widget _miniAction(IconData icon, int count, bool active) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon,
            size: 15,
            color: active
                ? const Color(AppTheme.heart)
                : const Color(AppTheme.textSecondary)),
        const SizedBox(width: 2.5),
        Text(
          countText(count),
          style: const TextStyle(
              color: Color(AppTheme.textSecondary), fontSize: 11),
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
