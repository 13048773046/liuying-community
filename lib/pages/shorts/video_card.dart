/// 短视频单页卡片：全屏沉浸式
/// 复刻音乐 iOS PlayerCard 结构：全屏媒体 + 底部作者行 + 右侧互动列
/// - 播放器懒初始化：进入页面才创建（PageView.builder 天然懒构建）
/// - isActive 切换：当前页 play / 离屏页 pause（高频状态隔离，等效音乐端 isCurrent 优化）
/// - 封面兜底：视频初始化期间展示封面/海报，缓冲时显示加载圈
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:video_player/video_player.dart';

import '../../api/client.dart';
import '../../config.dart';
import '../../models/feed_item.dart';
import '../mine/login_page.dart';
import '../user/user_profile.dart';
import '../../widgets/comment_sheet.dart';

class VideoCard extends StatefulWidget {
  final FeedItem item;
  final bool isActive;

  const VideoCard({super.key, required this.item, required this.isActive});

  @override
  State<VideoCard> createState() => _VideoCardState();
}

class _VideoCardState extends State<VideoCard> {
  VideoPlayerController? _video;
  bool _failed = false;
  bool _liked = false;
  int _likeCount = 0;
  bool _faved = false;
  int _commentCount = 0;
  int _shareCount = 0;
  bool _followed = false;
  bool _muted = false;
  @override
  void initState() {
    super.initState();
    _liked = widget.item.liked;
    _likeCount = widget.item.likeCount;
    _faved = widget.item.faved;
    _commentCount = widget.item.commentCount;
    _shareCount = widget.item.shareCount;
    if (widget.item.video.isNotEmpty) {
      _initVideo();
    }
  }

  Future<void> _initVideo() async {
    setState(() {
      _failed = false;
    });
    try {
      final c = VideoPlayerController.networkUrl(
        Uri.parse(mediaUrl(widget.item.video)),
        videoPlayerOptions: VideoPlayerOptions(
          // 移动端混合模式：视频覆盖层避免系统播放器
          mixWithOthers: true,
        ),
      );
      await c.initialize();
      if (!mounted) {
        c.dispose();
        return;
      }
      setState(() {
        _video = c;
      });
      if (widget.isActive) {
        c.setLooping(true);
        c.play();
        c.setVolume(_muted ? 0 : 1);
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _failed = true);
    }
  }

  @override
  void didUpdateWidget(covariant VideoCard old) {
    super.didUpdateWidget(old);
    if (old.isActive != widget.isActive) {
      _syncPlayback();
    }
  }

  /// 播放状态同步：当前页播、离屏页暂停（等效音乐端 isCurrent 高频状态隔离）
  void _syncPlayback() {
    final v = _video;
    if (v == null || !v.value.isInitialized) return;
    if (widget.isActive) {
      v.setLooping(true);
      v.setVolume(_muted ? 0 : 1);
      v.play();
    } else {
      v.pause();
    }
  }

  @override
  void dispose() {
    _video?.dispose();
    super.dispose();
  }

  // ---------- 互动 ----------

  Future<void> _toggleLike() async {
    if (ApiClient.token == null) {
      _needLogin();
      return;
    }
    try {
      final r = await ApiClient.toggleLike(widget.item.id);
      if (!mounted) return;
      setState(() {
        _liked = r['liked'] == true;
        // 服务端返回 likeCount（此前误读 count 导致点赞计数永不更新）
        _likeCount = ((r['likeCount'] ?? _likeCount) as num).toInt();
      });
    } catch (_) {}
  }

  Future<void> _toggleFav() async {
    if (ApiClient.token == null) {
      _needLogin();
      return;
    }
    try {
      final r = await ApiClient.toggleFav(widget.item.id);
      if (!mounted) return;
      setState(() => _faved = r['faved'] == true);
    } catch (_) {}
  }

  Future<void> _toggleFollow() async {
    if (ApiClient.token == null) {
      _needLogin();
      return;
    }
    try {
      final r = await ApiClient.toggleFollow(widget.item.author.id);
      if (!mounted) return;
      setState(() => _followed = boolOf(r['following'], !_followed));
    } catch (_) {}
  }

  Future<void> _share() async {
    try {
      final r = await ApiClient.reportShare(widget.item.id);
      if (!mounted) return;
      // 服务端返回 shareCount（此前误读 count 导致分享计数永不更新）
      setState(() => _shareCount =
          ((r['shareCount'] ?? _shareCount + 1) as num).toInt());
    } catch (_) {}
    // 系统分享（Android/iOS 平台通道）
    // TODO: 接入 share_plus 后打开系统分享面板
  }

  /// 打开评论：抖音式完整弹窗（评论列表 + 输入栏）；
  /// 评论数为 0 时，同时叠一个纯输入弹窗并唤起输入法，直接发第一条
  Future<void> _openComments() async {
    final needInput = _commentCount <= 0;
    final full = showCommentSheet(
      context,
      postId: widget.item.id,
      onChanged: (n) {
        if (!mounted) return;
        setState(() => _commentCount = n);
      },
    );
    if (needInput) {
      await showCommentSheet(context,
          postId: widget.item.id, pureInput: true);
    }
    await full;
  }

  /// 未登录：弹提示并跳转登录页（登录后自动恢复）
  void _needLogin() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('请先登录（账号与流萤音乐互通）'),
        duration: Duration(seconds: 2),
      ),
    );
    Future<void>.delayed(const Duration(milliseconds: 600), () {
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const LoginPage()),
      );
    });
  }

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        final v = _video;
        if (v != null && v.value.isInitialized) {
          setState(() {
            if (v.value.isPlaying) {
              v.pause();
            } else {
              v.play();
            }
          });
        }
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 全屏媒体：视频 / 封面兜底
          _buildMedia(),
          // 底部渐变压暗，保证文字可读
          const _BottomGradient(),
          // 底部：作者行 + 文案
          _buildBottomInfo(),
          // 右侧互动列
          _buildActionRail(),
        ],
      ),
    );
  }

  Widget _buildMedia() {
    final v = _video;
    if (v != null && v.value.isInitialized && !_failed) {
      return FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: v.value.size.width,
          height: v.value.size.height,
          child: VideoPlayer(v),
        ),
      );
    }
    // 封面兜底（视频初始化中 / 加载失败）
    // cover=auto 时使用转码自动生成的首帧封面（community_video_*.jpg）
    if (widget.item.cover.isNotEmpty && !_failed) {
      final cover = widget.item.cover == 'auto'
          ? '${widget.item.video}.jpg'
          : widget.item.cover;
      return CachedNetworkImage(
        imageUrl: mediaUrl(cover),
        fit: BoxFit.cover,
        placeholder: (_, __) => const _MediaLoading(),
        errorWidget: (_, __, ___) => const _MediaLoading(),
      );
    }
    // 加载失败：显示重试
    if (_failed) {
      return GestureDetector(
        onTap: _initVideo,
        child: Container(
          color: const Color(0xFF14141B),
          child: const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.refresh, color: Color(AppTheme.textSecondary), size: 34),
                SizedBox(height: 8),
                Text('视频加载失败，点击重试',
                    style: TextStyle(color: Color(AppTheme.textSecondary), fontSize: 12)),
              ],
            ),
          ),
        ),
      );
    }
    return const _MediaLoading();
  }

  Widget _buildBottomInfo() {
    final a = widget.item.author;
    final f = widget.item;
    return Positioned(
      left: 0,
      right: 64,
      bottom: 0,
      child: SafeArea(
        child: Padding(
          // 底部避让透明导航栏：54(导航栏本体) + 底部安全区 + 12 间距
          padding: EdgeInsets.fromLTRB(
              14, 0, 8, 12 + _navBarHeight(context)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // 作者行：昵称 + 认证LOGO（关注入口在右侧操作栏头像上）
              Row(
                children: [
                  Flexible(
                    child: Text(
                      a.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (a.isAdmin) ...[
                    const SizedBox(width: 5),
                    const _VerifiedBadge(name: '管理员'),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              // 文案：话题高亮 + @提及高亮
              if (f.content.isNotEmpty)
                _ContentText(
                  text: f.content,
                  topics: f.topic,
                  mentions: f.mentions,
                ),
              const SizedBox(height: 6),
              // 话题 tag 行
              if (f.topic.isNotEmpty)
                Wrap(
                  spacing: 8,
                  children: [
                    for (final t in f.topic)
                      Text(
                        '#$t',
                        style: const TextStyle(
                          color: Color(AppTheme.lilac),
                          fontSize: 13,
                        ),
                      ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildActionRail() {
    final a = widget.item.author;
    return Positioned(
      right: 10,
      bottom: 20 + _navBarHeight(context),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 抖音式：作者头像 + 关注加号叠在头像正下方水平居中（上缘遮住头像一点）
            Stack(
              clipBehavior: Clip.none,
              children: [
                _RailAvatar(
                  avatar: a.avatar,
                  size: 48,
                  onTap: a.id.isEmpty
                      ? null
                      : () => Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) => UserProfilePage(uid: a.id)),
                          ),
                ),
                if (!_followed && a.id.isNotEmpty)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: -8,
                    child: Center(
                      child: GestureDetector(
                        onTap: _toggleFollow,
                        child: Container(
                          width: 22,
                          height: 22,
                          decoration: BoxDecoration(
                            color: const Color(0xFFFF4D6D),
                            shape: BoxShape.circle,
                            border:
                                Border.all(color: Colors.white, width: 1.5),
                          ),
                          child: const Icon(Icons.add,
                              size: 14, color: Colors.white),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            _RailAction(
              asset: 'assets/icons/heart.svg',
              color: _liked ? const Color(0xFFFF4D6D) : Colors.white,
              count: _likeCount,
              onTap: _toggleLike,
            ),
            _RailAction(
              asset: 'assets/icons/chatbubble-ellipses.svg',
              count: _commentCount,
              onTap: _openComments,
            ),
            _RailAction(
              asset: 'assets/icons/arrow-redo.svg',
              count: _shareCount,
              onTap: _share,
            ),
            _RailAction(
              asset: 'assets/icons/star.svg',
              color: _faved ? const Color(0xFFFFB84D) : Colors.white,
              count: 0,
              onTap: _toggleFav,
            ),
          ],
        ),
      ),
    );
  }
}

// ---------- 子组件 ----------

/// 短视频 tab 透明导航栏高度（本体 54 = 6+22+2+14+6+4 与 _AppTabBar 布局同步）
/// 内容需整体避让，背景（视频画面）可延伸到导航栏区域
double _navBarHeight(BuildContext c) =>
    54 + MediaQuery.viewPaddingOf(c).bottom;

class _BottomGradient extends StatelessWidget {
  const _BottomGradient();
  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      height: MediaQuery.of(context).size.height * 0.42,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [
              Colors.black.withOpacity(0.72),
              Colors.black.withOpacity(0.30),
              Colors.transparent,
            ],
          ),
        ),
      ),
    );
  }
}

class _MediaLoading extends StatelessWidget {
  const _MediaLoading();
  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF14141B),
      child: const Center(
        child: SizedBox(
          width: 30,
          height: 30,
          child: CircularProgressIndicator(
            strokeWidth: 2.5,
            color: Color(AppTheme.accent),
          ),
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  final dynamic a;
  final double size;
  const _Avatar({required this.a, required this.size});

  @override
  Widget build(BuildContext context) {
    final url = a.avatar;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white.withOpacity(0.35), width: 1),
      ),
      child: ClipOval(
        child: url != null && url.toString().isNotEmpty
            ? CachedNetworkImage(
                imageUrl: url.toString(),
                fit: BoxFit.cover,
                errorWidget: (_, __, ___) => const _AvatarFallback(),
              )
            : const _AvatarFallback(),
      ),
    );
  }
}

/// 操作栏作者头像（抖音式）：白描边圆环 + 可点击进主页
class _RailAvatar extends StatelessWidget {
  final String? avatar;
  final double size;
  final VoidCallback? onTap;
  const _RailAvatar(
      {required this.avatar, required this.size, this.onTap});

  @override
  Widget build(BuildContext context) {
    final child = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white.withOpacity(0.6), width: 1.5),
      ),
      child: ClipOval(
        child: avatar != null && avatar!.isNotEmpty
            ? CachedNetworkImage(
                imageUrl: avatar!,
                fit: BoxFit.cover,
                errorWidget: (_, __, ___) => const _AvatarFallback(),
              )
            : const _AvatarFallback(),
      ),
    );
    if (onTap == null) return child;
    return GestureDetector(onTap: onTap, child: child);
  }
}

class _AvatarFallback extends StatelessWidget {
  const _AvatarFallback();
  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF3A3A46),
      child: const Icon(Icons.person, color: Color(AppTheme.textSecondary), size: 18),
    );
  }
}

class _VerifiedBadge extends StatelessWidget {
  final String name;
  const _VerifiedBadge({required this.name});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(AppTheme.accent), Color(AppTheme.sky)],
        ),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Text(
        name,
        style: const TextStyle(color: Colors.white, fontSize: 9, height: 1.3),
      ),
    );
  }
}

class _FollowButton extends StatelessWidget {
  final bool followed;
  final bool self;
  final VoidCallback onTap;
  const _FollowButton(
      {required this.followed, required this.self, required this.onTap});

  @override
  Widget build(BuildContext context) {
    if (self) return const SizedBox.shrink();
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: followed ? Colors.white.withOpacity(0.16) : const Color(AppTheme.accent),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          followed ? '已关注' : '关注',
          style: TextStyle(
            color: followed ? Colors.white.withOpacity(0.85) : Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

/// 文案：话题与 @提及 高亮（富文本简化渲染）
class _ContentText extends StatelessWidget {
  final String text;
  final List<String> topics;
  final List<String> mentions;
  const _ContentText(
      {required this.text, required this.topics, required this.mentions});

  @override
  Widget build(BuildContext context) {
    final spans = <TextSpan>[];
    // 简化：按话题/提及切分高亮
    final RegExp kw = RegExp(
        '(#(?:${topics.map(RegExp.escape).join('|')}))|(@(?:${mentions.map(RegExp.escape).join('|')}))');
    if (topics.isEmpty && mentions.isEmpty) {
      spans.add(TextSpan(text: text));
    } else {
      var last = 0;
      for (final m in kw.allMatches(text)) {
        if (m.start > last) {
          spans.add(TextSpan(text: text.substring(last, m.start)));
        }
        final isTopic = m.group(1) != null;
        spans.add(TextSpan(
          text: m.group(0),
          style: TextStyle(
            color: isTopic
                ? const Color(AppTheme.lilac)
                : const Color(AppTheme.sky),
            fontWeight: FontWeight.w600,
          ),
        ));
        last = m.end;
      }
      if (last < text.length) {
        spans.add(TextSpan(text: text.substring(last)));
      }
    }
    return Text.rich(
      TextSpan(
        style: const TextStyle(
            color: Colors.white, fontSize: 13.5, height: 1.45),
        children: spans,
      ),
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
    );
  }
}

class _RailAction extends StatelessWidget {
  final String asset; // assets/icons/*.svg（网上下载的开源实心图标）
  final Color color;
  final int count;
  final VoidCallback onTap;
  const _RailAction({
    required this.asset,
    required this.count,
    required this.onTap,
    this.color = Colors.white,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 20),
        child: Column(
          children: [
            // 无圆形卡片背景：网上下载的开源实心图标（抖音式操作栏）
            SvgPicture.asset(
              asset,
              width: 36,
              height: 36,
              colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
            ),
            if (count > 0)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(
                  countText(count),
                  style: const TextStyle(
                      color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
