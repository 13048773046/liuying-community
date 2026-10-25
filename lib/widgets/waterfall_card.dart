/// 瀑布流卡片（首页/收藏页复用）：视频 / 图文 / 纯文 / 投票 四类
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

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
            if (isVideo)
              _videoCover()
            else
              _authorRow(),
            if (!isVideo && item.content.isNotEmpty) ...[
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: _content(item.content, item.topic, item.type == 'text'),
              ),
            ],
            if (!isVideo && item.images.isNotEmpty) ...[
              const SizedBox(height: 8),
              _images(item.images),
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
        // 中央播放钮
        Center(
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.45),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white.withOpacity(0.5)),
            ),
            child: const Icon(Icons.play_arrow_rounded,
                color: Colors.white, size: 26),
          ),
        ),
        // 时长角标
        if (dur > 0)
          Positioned(
            right: 6,
            bottom: 6,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.6),
                borderRadius: BorderRadius.circular(5),
              ),
              child: Text(_fmtDur(dur),
                  style: const TextStyle(
                      color: Colors.white, fontSize: 10.5)),
            ),
          ),
        // 作者条（封面底部）
        Positioned(
          left: 8,
          right: 8,
          bottom: 34,
          child: Row(
            children: [
              _miniAvatar(item.author.avatar),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  item.author.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      shadows: [Shadow(color: Colors.black54, blurRadius: 4)]),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _authorRow() {
    final a = item.author;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 0),
      child: Row(
        children: [
          if (onAuthorTap != null)
            GestureDetector(onTap: onAuthorTap, child: _miniAvatar(a.avatar))
          else
            _miniAvatar(a.avatar),
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
                        fontSize: 12.5,
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
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _miniAvatar(String url) {
    return Container(
      width: 26,
      height: 26,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white.withOpacity(0.25)),
      ),
      child: ClipOval(
        child: url.isNotEmpty
            ? CachedNetworkImage(
                imageUrl: url,
                fit: BoxFit.cover,
                errorWidget: (_, _, _) => const Icon(Icons.person,
                    size: 14, color: Color(AppTheme.textSecondary)),
              )
            : const Icon(Icons.person,
                size: 14, color: Color(AppTheme.textSecondary)),
      ),
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
    final n = images.length;
    if (n == 1) {
      return AspectRatio(
        aspectRatio: 4 / 3,
        child: CachedNetworkImage(
          imageUrl: mediaUrl(images[0]),
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
    // 2~3 张：两列等方小图
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(child: _sqImg(images[0], n > 2 ? 5 : 3)),
              if (n > 1) ...[
                const SizedBox(width: 3),
                Expanded(child: _sqImg(images[1], n > 2 ? 5 : 3)),
              ],
            ],
          ),
          if (n > 2) ...[
            const SizedBox(height: 3),
            Row(
              children: [
                Expanded(child: _sqImg(images[2], 5)),
                const SizedBox(width: 3),
                const Expanded(child: SizedBox()),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _sqImg(String url, double radius) {
    return AspectRatio(
      aspectRatio: 1,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: CachedNetworkImage(
          imageUrl: mediaUrl(url),
          fit: BoxFit.cover,
          placeholder: (_, _) => Container(color: const Color(0xFF1C1C24)),
          errorWidget: (_, _, _) => Container(
            color: const Color(0xFF1C1C24),
            child: const Icon(Icons.broken_image,
                color: Color(AppTheme.textSecondary), size: 20),
          ),
        ),
      ),
    );
  }

  Widget _footerRow(bool isVideo) {
    return Row(
      children: [
        _miniAction(Icons.favorite_rounded, item.likeCount, item.liked),
        const SizedBox(width: 14),
        _miniAction(
            Icons.chat_bubble_outline_rounded, item.commentCount, false),
        const SizedBox(width: 14),
        _miniAction(Icons.arrow_upward_rounded, item.shareCount, false),
        const Spacer(),
        if (item.featured)
          const Text('★',
              style: TextStyle(
                  color: Color(0xFFFFB84D),
                  fontSize: 12,
                  fontWeight: FontWeight.bold)),
        if (item.sticky) ...[
          const SizedBox(width: 6),
          const Text('📌', style: TextStyle(fontSize: 11)),
        ],
        if (item.type == 'poll')
          const Padding(
            padding: EdgeInsets.only(left: 6),
            child: Icon(Icons.how_to_vote_outlined,
                size: 14, color: Color(AppTheme.lilac)),
          ),
      ],
    );
  }

  Widget _miniAction(IconData icon, int count, bool active) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon,
            size: 15,
            color: active
                ? const Color(0xFFFF6B81)
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
