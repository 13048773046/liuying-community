/// 沉浸式内容卡片：全站信息流统一形态。
///
/// 形态（抖音式）：全幅媒体 + 底部渐变叠加（作者/正文/话题）+ 右侧竖排操作栏；
/// 纯文字帖退化为黑底卡片（无媒体区）。短视频只展示封面与时长，播放交给详情页。
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../api/client.dart';
import '../config.dart';
import '../design/components.dart';
import '../models/feed_item.dart';
import '../utils/share_util.dart';
import '../pages/mine/login_page.dart';

/// 缩略图加载（统一占位与失败态，避免布局跳动）。
class _PostImage extends StatelessWidget {
  const _PostImage({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    return CachedNetworkImage(
      imageUrl: url,
      fit: BoxFit.cover,
      width: double.infinity,
      height: double.infinity,
      placeholder: (_, _) =>
          const ImagePlaceholder(icon: Icons.image_outlined, radius: 0),
      errorWidget: (_, _, _) =>
          const ImagePlaceholder(icon: Icons.broken_image_outlined, radius: 0),
    );
  }
}

class PostCard extends StatefulWidget {
  const PostCard({
    super.key,
    required this.item,
    this.onTap,
    this.onAuthorTap,
    this.onLike,
    this.onFav,
    this.onShare,
    this.onComment,
    this.showAuthor = true,
    this.mediaHeight,
    this.rounded = true,
  });

  final FeedItem item;
  final VoidCallback? onTap;
  final VoidCallback? onAuthorTap;
  final VoidCallback? onLike;

  /// 收藏切换后会回调**新的状态**（true=已收藏），调用方据此决定 POST/DELETE。
  final void Function(bool faved)? onFav;
  final VoidCallback? onShare;
  final VoidCallback? onComment;

  /// 详情页内嵌/特殊场景可隐藏作者行。
  final bool showAuthor;

  /// 覆盖媒体高度（默认按屏宽 1.12 倍，最高 520）。
  final double? mediaHeight;
  final bool rounded;

  @override
  State<PostCard> createState() => _PostCardState();
}

class _PostCardState extends State<PostCard> {
  late bool _liked = widget.item.liked;
  late bool _faved = widget.item.faved;
  late int _likeCount = widget.item.likeCount;
  int _imgIndex = 0;

  @override
  void didUpdateWidget(covariant PostCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.id != widget.item.id) {
      _liked = widget.item.liked;
      _faved = widget.item.faved;
      _likeCount = widget.item.likeCount;
      _imgIndex = 0;
    }
  }

  /// 未登录就跳登录页并返回 false
  bool _ensureLogin() {
    if (ApiClient.token != null) return true;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const LoginPage()),
    );
    return false;
  }

  /// 点赞：有外部回调就交给调用方，否则卡片自己调接口（乐观更新 + 失败回滚）
  Future<void> _toggleLike() async {
    final next = !_liked;
    setState(() {
      _liked = next;
      _likeCount += next ? 1 : -1;
    });
    if (widget.onLike != null) {
      widget.onLike!();
      return;
    }
    if (!_ensureLogin()) {
      setState(() {
        _liked = !next;
        _likeCount += next ? -1 : 1;
      });
      return;
    }
    try {
      final r = await ApiClient.setPostLike(widget.item.id, liked: next);
      if (!mounted) return;
      setState(() {
        _liked = boolOf(r['liked'], next);
        _likeCount = ((r['likeCount'] ?? _likeCount) as num).toInt();
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _liked = !next;
        _likeCount += next ? -1 : 1;
      });
    }
  }

  /// 收藏：同点赞，faved 传的是「切换后的新状态」
  Future<void> _toggleFav() async {
    final next = !_faved;
    setState(() => _faved = next);
    if (widget.onFav != null) {
      widget.onFav!(next);
      return;
    }
    if (!_ensureLogin()) {
      setState(() => _faved = !next);
      return;
    }
    try {
      await ApiClient.toggleFav(widget.item.id, faved: !next);
    } catch (e) {
      if (!mounted) return;
      setState(() => _faved = !next);
      showAppToast(context, '操作失败：$e');
    }
  }

  /// 分享：上报计数 + 调系统分享
  Future<void> _share() async {
    if (widget.onShare != null) {
      widget.onShare!();
      return;
    }
    if (_ensureLogin()) {
      try {
        await ApiClient.reportShare(widget.item.id);
      } catch (_) {}
    }
    await sharePostLink(widget.item.content, widget.item.id);
  }

  bool get _hasMedia =>
      widget.item.isVideo || widget.item.images.isNotEmpty;


  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final radius = widget.rounded ? 16.0 : 0.0;

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: PressableScale(
        onTap: widget.onTap,
        scale: 0.985,
        haptic: false,
        child: Container(
          decoration: BoxDecoration(
            color: const Color(AppColors.card),
            borderRadius: BorderRadius.circular(radius),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_hasMedia) _mediaBlock(item),
              Padding(
                padding: EdgeInsets.fromLTRB(16, _hasMedia ? 15 : 17, 16, 0),
                child: _textBlock(item),
              ),
              if (widget.showAuthor)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                  child: _authorRow(item.author, item.created),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 13, 16, 14),
                child: _actsRow(item),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ 媒体块
  Widget _mediaBlock(FeedItem item) {
    final h = widget.mediaHeight ?? 206.0;
    return SizedBox(
      height: h,
      child: Stack(
        fit: StackFit.expand,
        children: [
          _media(item),
          Positioned(
            left: 12,
            top: 12,
            child: Row(
              children: [
                if (item.sticky)
                  _Badge(label: '置顶', color: const Color(AppColors.accent)),
                if (item.sticky) const SizedBox(width: 6),
                if (item.featured)
                  _Badge(label: '精华', color: const Color(AppColors.warning)),
                if (!item.sticky &&
                    !item.featured &&
                    item.topic.isNotEmpty)
                  _Badge(
                    label: item.topic.first,
                    color: const Color(0x99000000),
                  ),
              ],
            ),
          ),
          if (item.isVideo)
            Positioned(
              right: 12,
              bottom: 12,
              child: _DurationChip(seconds: item.duration),
            ),
          if (!item.isVideo && item.images.length > 1)
            Positioned(
              left: 0,
              right: 0,
              bottom: 10,
              child: Center(
                child: _Dots(count: item.images.length, index: _imgIndex),
              ),
            ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ 文字块
  Widget _textBlock(FeedItem item) {
    final c = item.content.trim();
    if (c.isEmpty) return const SizedBox.shrink();
    final title = _titleOf(c);
    final rest = c.length > title.length
        ? c
            .substring(title.length)
            .replaceFirst(RegExp(r'^[。，、\n\s]+'), '')
            .trim()
        : '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 16.5,
            height: 1.45,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.25,
            color: Color(AppColors.textPrimary),
          ),
        ),
        if (rest.isNotEmpty) ...[
          const SizedBox(height: 7),
          Text(
            rest,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 13,
              height: 1.7,
              color: Color(AppColors.textSecondary),
            ),
          ),
        ],
      ],
    );
  }

  /// 取首句作标题：优先换行，其次句号，最多 30 字
  String _titleOf(String c) {
    final nl = c.indexOf('\n');
    final dot = c.indexOf('。');
    var cut = -1;
    if (nl > 0 && nl <= 30) cut = nl;
    if (dot > 0 && dot <= 30 && (cut < 0 || dot < cut)) cut = dot + 1;
    if (cut > 0) return c.substring(0, cut);
    if (c.length <= 30) return c;
    return c.substring(0, 30);
  }

  // ------------------------------------------------------------------ 作者行
  Widget _authorRow(Author a, int created) {
    return GestureDetector(
      onTap: widget.onAuthorTap,
      behavior: HitTestBehavior.opaque,
      child: Row(
        children: [
          AppAvatar(
            url: avatarUrlOf(a.id),
            size: 24,
            name: a.name,
            ring: a.isAdmin,
          ),
          const SizedBox(width: 9),
          Flexible(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    a.name.isEmpty ? '匿名用户' : a.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: Color(AppColors.textSecondary),
                    ),
                  ),
                ),
                if (a.isAdmin || a.level > 0) ...[
                  const SizedBox(width: 6),
                  _LevelChip(
                    level: a.level,
                    adminName: a.isAdmin ? a.adminName : null,
                  ),
                ],
              ],
            ),
          ),
          const Spacer(),
          Text(
            _ago(created),
            style: const TextStyle(
              fontSize: 10.5,
              color: Color(AppColors.textTertiary),
            ),
          ),
        ],
      ),
    );
  }

  String _ago(int sec) {
    if (sec <= 0) return '';
    final t = DateTime.fromMillisecondsSinceEpoch(sec * 1000);
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return '刚刚';
    if (d.inMinutes < 60) return '${d.inMinutes} 分钟前';
    if (d.inHours < 24) return '${d.inHours} 小时前';
    if (d.inDays < 30) return '${d.inDays} 天前';
    final mm = t.month.toString().padLeft(2, '0');
    final dd = t.day.toString().padLeft(2, '0');
    return '${t.year}-$mm-$dd';
  }

  // ------------------------------------------------------------------ 互动行
  Widget _actsRow(FeedItem item) {
    return Row(
      children: [
        _InlineAction(
          icon: _liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
          active: _liked,
          activeColor: const Color(AppColors.heart),
          label: formatCount(_likeCount),
          onTap: _toggleLike,
        ),
        _InlineAction(
          icon: Icons.mode_comment_outlined,
          label: formatCount(item.commentCount),
          onTap: widget.onComment ?? widget.onTap,
        ),
        _InlineAction(
          icon: _faved ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
          active: _faved,
          activeColor: const Color(AppColors.accent),
          label: '',
          onTap: _toggleFav,
        ),
        const Spacer(),
        _InlineAction(
          icon: Icons.ios_share_rounded,
          label: '',
          onTap: _share,
        ),
      ],
    );
  }


  // ---------------------------------------------------------------- 媒体卡
  Widget _media(FeedItem item) {
    if (item.isVideo) {
      final cover = item.cover.isNotEmpty ? item.cover : '';
      return Stack(
        fit: StackFit.expand,
        children: [
          if (cover.isNotEmpty)
            _PostImage(url: mediaUrl(cover))
          else
            const ImagePlaceholder(icon: Icons.movie_outlined, radius: 0),
          // 中心播放键
          Center(
            child: Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.black.withValues(alpha: 0.35),
                border: Border.all(color: Colors.white.withValues(alpha: 0.75), width: 1.4),
              ),
              child: const Icon(Icons.play_arrow_rounded,
                  color: Colors.white, size: 32),
            ),
          ),
        ],
      );
    }
    if (item.images.length == 1) {
      return _PostImage(url: mediaUrl(item.images.first));
    }
    return PageView.builder(
      itemCount: item.images.length,
      onPageChanged: (i) => setState(() => _imgIndex = i),
      itemBuilder: (_, i) => _PostImage(url: mediaUrl(item.images[i])),
    );
  }
}

class _InlineAction extends StatelessWidget {
  const _InlineAction({
    required this.icon,
    required this.label,
    this.onTap,
    this.active = false,
    this.activeColor,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool active;
  final Color? activeColor;

  @override
  Widget build(BuildContext context) {
    final color = active
        ? (activeColor ?? const Color(AppColors.accent))
        : const Color(AppColors.textSecondary);
    return PressableScale(
      onTap: onTap,
      scale: 0.9,
      child: Padding(
        padding: const EdgeInsets.only(right: 20),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            BounceOnChange(
              trigger: active,
              child: Icon(icon, size: 18, color: color),
            ),
            if (label.isNotEmpty) ...[
              const SizedBox(width: 5),
              RollingText(
                text: label,
                style: TextStyle(fontSize: 11.5, color: color),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color,
        borderRadius: AppRadius.rXs,
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 10,
          height: 1.1,
          fontWeight: FontWeight.w800,
          color: Color(AppColors.onAccent),
        ),
      ),
    );
  }
}

class _DurationChip extends StatelessWidget {
  const _DurationChip({required this.seconds});

  final int seconds;

  @override
  Widget build(BuildContext context) {
    if (seconds <= 0) return const SizedBox.shrink();
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: AppRadius.rXs,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.play_arrow_rounded, size: 11, color: Colors.white),
          const SizedBox(width: 2),
          Text('$m:$s',
              style: const TextStyle(
                fontSize: 10.5,
                height: 1.1,
                fontWeight: FontWeight.w600,
                color: Colors.white,
                fontFeatures: [FontFeature.tabularFigures()],
              )),
        ],
      ),
    );
  }
}

class _Dots extends StatelessWidget {
  const _Dots({required this.count, required this.index});

  final int count;
  final int index;

  @override
  Widget build(BuildContext context) {
    final shown = count.clamp(0, 6).toInt();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.35),
        borderRadius: AppRadius.rPill,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(shown, (i) {
          final active = i == index.clamp(0, shown - 1).toInt();
          return AnimatedContainer(
            duration: AppMotion.fast,
            margin: const EdgeInsets.symmetric(horizontal: 1.5),
            width: active ? 12 : 4,
            height: 4,
            decoration: BoxDecoration(
              color: active ? Colors.white : Colors.white.withValues(alpha: 0.5),
              borderRadius: AppRadius.rPill,
            ),
          );
        }),
      ),
    );
  }
}

class _LevelChip extends StatelessWidget {
  const _LevelChip({required this.level, this.adminName});

  final int level;
  final String? adminName;

  @override
  Widget build(BuildContext context) {
    final isAdmin = adminName != null && adminName!.isNotEmpty;
    final label = isAdmin
        ? (adminName!.length > 6 ? '管理员' : adminName!)
        : 'Lv.$level';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
      decoration: BoxDecoration(
        color: isAdmin
            ? const Color(AppColors.accent).withValues(alpha: 0.22)
            : Colors.white.withValues(alpha: 0.14),
        borderRadius: AppRadius.rXs,
        border: Border.all(
          color: isAdmin
              ? const Color(AppColors.accent).withValues(alpha: 0.55)
              : Colors.transparent,
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 9.5,
          height: 1.2,
          fontWeight: FontWeight.w700,
          color: isAdmin ? const Color(AppColors.accent) : Colors.white,
        ),
      ),
    );
  }
}

// ============================================================================
// 网格小卡（我的作品 / 收藏 / 话题聚合用）
// ============================================================================

class PostGridTile extends StatelessWidget {
  const PostGridTile({
    super.key,
    required this.item,
    this.onTap,
    this.onAuthorTap,
  });

  final FeedItem item;
  final VoidCallback? onTap;

  /// 左下角作者角标点击（进作者主页）；不传则整卡只走 [onTap]。
  final VoidCallback? onAuthorTap;

  @override
  Widget build(BuildContext context) {
    final cover = item.isVideo
        ? item.cover
        : (item.images.isNotEmpty ? item.images.first : '');
    return PressableScale(
      onTap: onTap,
      scale: 0.95,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (cover.isNotEmpty)
              _PostImage(url: mediaUrl(cover))
            else
              Container(
                color: const Color(AppColors.card),
                padding: const EdgeInsets.all(AppSpace.x3),
                child: Text(
                  item.content.trim(),
                  maxLines: 5,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.caption.copyWith(color: const Color(AppColors.textSecondary)),
                ),
              ),
            if (item.isVideo && onAuthorTap != null)
              const Positioned(
                left: 6,
                top: 6,
                child: Icon(Icons.play_arrow_rounded,
                    size: 13, color: Colors.white),
              ),
            Positioned(
              left: 6,
              bottom: 6,
              right: 6,
              child: Row(
                children: [
                  if (onAuthorTap != null)
                    Flexible(
                      flex: 3,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: onAuthorTap,
                        child: Container(
                          padding: const EdgeInsets.fromLTRB(2, 2, 6, 2),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.45),
                            borderRadius: AppRadius.rPill,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              AppAvatar(
                                url: item.author.avatar.isEmpty
                                    ? null
                                    : avatarUrl(item.author.avatar),
                                size: 15,
                                name: item.author.name,
                              ),
                              const SizedBox(width: 4),
                              Flexible(
                                child: Text(
                                  item.author.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 10,
                                      height: 1.1,
                                      color: Colors.white),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    )
                  else if (item.isVideo)
                    const Icon(Icons.play_arrow_rounded,
                        size: 13, color: Colors.white),
                  const Spacer(),
                  const Icon(Icons.favorite_rounded,
                      size: 11, color: Colors.white),
                  const SizedBox(width: 3),
                  Text('${item.likeCount}',
                      style: const TextStyle(
                          fontSize: 10, color: Colors.white, height: 1.1)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
