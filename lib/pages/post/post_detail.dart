/// 帖子详情页（P0）：图文/视频帖详情 + 评论区
/// 评论区支持：文字评论、图片评论（≤1 图）、表情包（占位，官方素材到达后接入）
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../api/client.dart';
import '../../config.dart';
import '../../models/feed_item.dart';
import '../../widgets/image_box.dart';
import '../../widgets/poll_card.dart';
import '../../widgets/emoji_panel.dart';
import '../mine/login_page.dart';
import '../user/user_profile.dart';

class PostDetailPage extends StatefulWidget {
  final String postId;
  const PostDetailPage({super.key, required this.postId});

  @override
  State<PostDetailPage> createState() => _PostDetailPageState();
}

class _PostDetailPageState extends State<PostDetailPage> {
  FeedItem? _post;
  bool _liked = false;
  bool _faved = false;
  bool _latered = false;
  int _likeCount = 0;
  bool _loading = true;
  bool _following = false;
  bool _followBusy = false;
  List<Map<String, dynamic>> _comments = [];
  int _cPage = 1;
  bool _cHasMore = false;
  bool _cLoading = false;

  final _commentCtrl = TextEditingController();
  File? _commentImage;
  String? _commentSticker;
  final _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final j = await ApiClient.postDetail(widget.postId);
      if (!mounted) return;
      final pj = Map<String, dynamic>.from(j['post'] as Map);
      setState(() {
        _post = FeedItem.fromJson(pj);
        _liked = pj['liked'] ?? false;
        _faved = pj['faved'] ?? false;
        _latered = pj['later'] ?? false;
        _likeCount = ((pj['likeCount'] ?? 0) as num).toInt();
        _loading = false;
      });
      await _loadComments(refresh: true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _loadComments({bool refresh = false}) async {
    if (_cLoading || (!_cHasMore && !refresh)) return;
    setState(() => _cLoading = true);
    try {
      final j = await ApiClient.comments(widget.postId,
          page: refresh ? 1 : _cPage + 1, size: 20);
      if (!mounted) return;
      setState(() {
        final list = ((j['list'] ?? []) as List)
            .whereType<Map<String, dynamic>>()
            .toList();
        if (refresh) {
          _comments = list;
          _cPage = 1;
        } else {
          _comments.addAll(list);
          _cPage++;
        }
        _cHasMore = boolOf(j['hasMore']);
        _cLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _cLoading = false);
    }
  }

  Future<void> _toggleLike() async {
    if (_post == null) return;
    setState(() {
      _liked = !_liked;
      _likeCount += _liked ? 1 : -1;
    });
    try {
      await ApiClient.toggleLike(_post!.id);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _liked = !_liked;
        _likeCount += _liked ? 1 : -1;
      });
    }
  }

  Future<void> _toggleFav() async {
    if (_post == null) return;
    setState(() => _faved = !_faved);
    try {
      await ApiClient.toggleFav(_post!.id, faved: _faved);
    } catch (_) {
      if (!mounted) return;
      setState(() => _faved = !_faved);
    }
  }

  Future<void> _toggleLater() async {
    if (_post == null) return;
    setState(() => _latered = !_latered);
    try {
      await ApiClient.toggleFav(_post!.id, kind: 'later', faved: _latered);
    } catch (_) {
      if (!mounted) return;
      setState(() => _latered = !_latered);
    }
  }

  /// 举报弹窗（帖子/评论通用）
  Future<void> _report(String targetType, String targetId) async {
    if (ApiClient.token == null) {
      if (!mounted) return;
      Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const LoginPage()));
      return;
    }
    const reasons = ['垃圾广告', '色情低俗', '不实信息', '人身攻击', '违法违规', '其他'];
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(AppTheme.card),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 14),
            const Text('举报',
                style: TextStyle(
                    color: Color(AppTheme.textPrimary),
                    fontSize: 16,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            const Text('请选择举报原因，我们会尽快核实处理',
                style: TextStyle(
                    color: Color(AppTheme.textTertiary), fontSize: 12)),
            const SizedBox(height: 8),
            for (final r in reasons)
              ListTile(
                dense: true,
                title: Text(r,
                    style: const TextStyle(
                        color: Color(AppTheme.textPrimary),
                        fontSize: 13.5)),
                trailing: const Icon(Icons.chevron_right_rounded,
                    size: 18, color: Color(AppTheme.textTertiary)),
                onTap: () => Navigator.pop(ctx, r),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    try {
      await ApiClient.report(targetType, targetId, picked);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('已收到举报，我们会尽快处理'),
        backgroundColor: Color(AppTheme.card),
        behavior: SnackBarBehavior.floating,
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(e is ApiException ? e.message : '举报失败，请稍后再试'),
        backgroundColor: const Color(AppTheme.card),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  void _reportPost() {
    if (_post == null) return;
    _report('post', _post!.id);
  }

  /// 收藏按钮弹层：收藏 / 稍后看 二选一（概念稿：稍后看独立入口）
  Future<void> _showFavSheet() async {
    if (_post == null) return;
    await showModalBottomSheet(
      context: context,
      backgroundColor: const Color(AppTheme.card),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 14),
            const Text('收藏内容',
                style: TextStyle(
                    color: Color(AppTheme.textPrimary),
                    fontSize: 16,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            const Text('选择收藏方式',
                style: TextStyle(
                    color: Color(AppTheme.textTertiary), fontSize: 12)),
            const SizedBox(height: 12),
            _favOption(
              icon: _faved ? Icons.star_rounded : Icons.star_border_rounded,
              label: '收藏',
              sub: '在我的页「收藏」中查看',
              active: _faved,
              color: const Color(AppTheme.peach),
              onTap: () {
                Navigator.pop(ctx);
                _toggleFav();
              },
            ),
            _favOption(
              icon: _latered ? Icons.schedule_rounded : Icons.schedule_outlined,
              label: '稍后看',
              sub: '在我的页「稍后看」中查看',
              active: _latered,
              color: const Color(AppTheme.sky),
              onTap: () {
                Navigator.pop(ctx);
                _toggleLater();
              },
            ),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );
  }

  Widget _favOption(
      {required IconData icon,
      required String label,
      required String sub,
      required bool active,
      required Color color,
      required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        decoration: BoxDecoration(
          color: const Color(AppTheme.bg),
          borderRadius: BorderRadius.circular(AppTheme.radiusCard),
        ),
        child: Row(
          children: [
            Icon(icon, color: active ? color : const Color(AppTheme.textSecondary), size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: const TextStyle(
                          color: Color(AppTheme.textPrimary),
                          fontSize: 14,
                          fontWeight: FontWeight.w500)),
                  const SizedBox(height: 2),
                  Text(sub,
                      style: const TextStyle(
                          color: Color(AppTheme.textTertiary), fontSize: 11)),
                ],
              ),
            ),
            if (active)
              Icon(Icons.check_circle, color: color, size: 18),
          ],
        ),
      ),
    );
  }

  Future<void> _sendComment() async {
    final text = _commentCtrl.text.trim();
    if (text.isEmpty && _commentImage == null) {
      _toast('评论内容不能为空');
      return;
    }
    // 登录检查：未登录 → 提示并跳登录页（避免 401 生硬报错）
    if (ApiClient.token == null || ApiClient.token!.isEmpty) {
      _toast('请先登录后评论（账号与流萤音乐互通）');
      await Future<void>.delayed(const Duration(milliseconds: 600));
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const LoginPage()),
      );
      return;
    }
    List<String> imgs = [];
    try {
      if (_commentImage != null) {
        final j = await ApiClient.uploadImage(_commentImage!.path);
        imgs = [j['name'] as String];
      }
      await ApiClient.addComment(widget.postId, text,
          images: imgs, sticker: _commentSticker);
      if (!mounted) return;
      _commentCtrl.clear();
      setState(() {
        _commentImage = null;
        _commentSticker = null;
      });
      _toast('评论成功');
      await _loadComments(refresh: true);
    } catch (e) {
      _toast('评论失败：$e');
    }
  }

  void _toast(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(s), backgroundColor: const Color(AppTheme.card)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(AppTheme.bg),
      appBar: AppBar(
        backgroundColor: const Color(AppTheme.bg),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Color(AppTheme.textPrimary)),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(_post?.isVideo == true ? '视频详情' : '帖子详情',
            style: const TextStyle(
                color: Color(AppTheme.textPrimary),
                fontSize: 16,
                fontWeight: FontWeight.w600)),
        actions: [
          if (_post != null && _post!.author.id != ApiClient.userId)
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_horiz_rounded,
                  color: Color(AppTheme.textPrimary)),
              color: const Color(AppTheme.card),
              onSelected: (v) {
                if (v == 'report') _reportPost();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                    value: 'report',
                    child: Text('举报',
                        style: TextStyle(
                            color: Color(AppTheme.textPrimary),
                            fontSize: 13.5))),
              ],
            )
          else
            const SizedBox(width: 8),
        ],
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(
                  color: Color(AppTheme.accent), strokeWidth: 2.5))
          : _post == null
              ? const Center(
                  child: Text('内容不存在或已删除',
                      style: TextStyle(color: Color(AppTheme.textSecondary))))
              : Column(
                  children: [
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                        children: [
                          _authorRow(),
                          const SizedBox(height: 12),
                          _contentBlock(),
                          if (_post!.topic.isNotEmpty) ...[
                            const SizedBox(height: 10),
                            Wrap(
                              spacing: 6,
                              children: _post!.topic
                                  .map((t) => Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 10, vertical: 4),
                                        decoration: BoxDecoration(
                                          color: const Color(AppTheme.accentSoft),
                                          borderRadius: BorderRadius.circular(12),
                                        ),
                                        child: Text('#$t',
                                            style: const TextStyle(
                                                color: Color(AppTheme.accent),
                                                fontSize: 12)),
                                      ))
                                  .toList(),
                            ),
                          ],
                          if (_post!.poll != null) ...[
                            const SizedBox(height: 10),
                            PollCard(
                              postId: _post!.id,
                              poll: _post!.poll!,
                              onChanged: () {
                                if (!mounted) return;
                                setState(() {});
                              },
                            ),
                          ],
                          const SizedBox(height: 14),
                          _actionBar(),
                          const Divider(
                              color: Color(AppTheme.border), height: 28),
                          Row(
                            children: [
                              const Text('评论',
                                  style: TextStyle(
                                      color: Color(AppTheme.textPrimary),
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600)),
                              const SizedBox(width: 6),
                              Text('${_post!.commentCount}',
                                  style: const TextStyle(
                                      color: Color(AppTheme.textTertiary),
                                      fontSize: 13)),
                              const Spacer(),
                              if (_cHasMore)
                                GestureDetector(
                                  onTap: () => _loadComments(),
                                  child: const Text('加载更多',
                                      style: TextStyle(
                                          color: Color(AppTheme.textSecondary),
                                          fontSize: 12)),
                                ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          if (_comments.isEmpty)
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 24),
                              child: Center(
                                child: Text('还没有评论，来抢沙发',
                                    style: TextStyle(
                                        color: Color(AppTheme.textTertiary),
                                        fontSize: 13)),
                              ),
                            )
                          else
                            ..._comments.map((c) => _commentTile(c)),
                        ],
                      ),
                    ),
                    _commentInput(),
                  ],
                ),
    );
  }

  Widget _authorRow() {
    final a = _post!.author;
    return Row(
      children: [
        GestureDetector(
          onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => UserProfilePage(uid: a.id))),
          child: Container(
            padding: const EdgeInsets.all(1.5),
            decoration: a.frameId.isNotEmpty
                ? BoxDecoration(
                    border: Border.all(
                        color: const Color(AppTheme.accent), width: 2),
                    shape: BoxShape.circle,
                  )
                : null,
            child: CircleAvatar(
              radius: 20,
              backgroundColor: const Color(AppTheme.card),
              backgroundImage:
                  a.avatar.isNotEmpty ? NetworkImage(avatarUrl(a.avatar)) : null,
              child: a.avatar.isEmpty
                  ? const Icon(Icons.person, color: Color(AppTheme.textSecondary))
                  : null,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(a.name,
                      style: const TextStyle(
                          color: Color(AppTheme.textPrimary),
                          fontSize: 14,
                          fontWeight: FontWeight.w500)),
                  if (a.isAdmin) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(AppTheme.accentSoft),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(a.adminName.isEmpty ? '认证' : a.adminName,
                          style: const TextStyle(
                              color: Color(AppTheme.accent), fontSize: 10)),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 3),
              Text(
                'Lv${a.level} · ${timeAgo(_post!.created)}'
                '${_post!.tag.isNotEmpty ? ' · 来自${_post!.tag}' : ''}',
                style: const TextStyle(
                    color: Color(AppTheme.textTertiary), fontSize: 12),
              ),
            ],
          ),
        ),
        if (a.id != ApiClient.userId)
          Padding(
            padding: const EdgeInsets.only(left: 10),
            child: GestureDetector(
              onTap: _followBusy
                  ? null
                  : () async {
                      setState(() => _followBusy = true);
                      try {
                        await ApiClient.toggleFollow(a.id);
                        if (!mounted) return;
                        setState(() {
                          _following = !_following;
                          _followBusy = false;
                        });
                      } catch (_) {
                        if (!mounted) return;
                        setState(() => _followBusy = false);
                      }
                    },
              child: Container(
                width: 62,
                height: 30,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _following
                      ? Colors.transparent
                      : const Color(AppTheme.accent),
                  borderRadius: BorderRadius.circular(AppTheme.radiusPill),
                  border: _following
                      ? Border.all(color: const Color(AppTheme.border))
                      : null,
                ),
                child: _followBusy
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Color(AppTheme.accent)))
                    : Text(
                        _following ? '已关注' : '+ 关注',
                        style: TextStyle(
                            color: _following
                                ? const Color(AppTheme.textSecondary)
                                : Colors.black,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600),
                      ),
              ),
            ),
          ),
        if (_post!.sticky)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: const Color(AppTheme.sky).withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Text('置顶',
                style: TextStyle(color: Color(AppTheme.sky), fontSize: 11)),
          ),
      ],
    );
  }

  Widget _contentBlock() {
    final p = _post!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(p.content,
            style: const TextStyle(
                color: Color(AppTheme.textPrimary),
                fontSize: 16,
                height: 1.55)),
        if (p.images.isNotEmpty) ...[
          const SizedBox(height: 12),
          // 多图：按张数等宽网格，AspectRatio 自适应屏幕（不再写死高度）
          if (p.images.length == 1)
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: AspectRatio(
                aspectRatio: 4 / 3,
                child: CachedNetworkImageCompat(
                  url: mediaUrl(p.images[0]),
                  fit: BoxFit.cover,
                ),
              ),
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: p.images
                  .map((img) => ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: AspectRatio(
                          aspectRatio: 1,
                          child: CachedNetworkImageCompat(
                            url: mediaUrl(img),
                            fit: BoxFit.cover,
                          ),
                        ),
                      ))
                  .toList(),
            ),
        ],
        if (p.isVideo) ...[
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: CachedNetworkImageCompat(
                url: mediaUrl(p.cover == 'auto' ? '${p.video}.jpg' : p.cover),
                fit: BoxFit.cover,
              ),
            ),
          ),
          const SizedBox(height: 6),
          const Center(
            child: Text('完整视频请到「短视频」页观看',
                style: TextStyle(
                    color: Color(AppTheme.textTertiary), fontSize: 11)),
          ),
        ],
      ],
    );
  }

  Widget _actionBar() {
    final p = _post!;
    return Row(
      children: [
        _actionItem(Icons.thumb_up_alt_rounded, '${countText(_likeCount)}',
            _liked ? const Color(AppTheme.accent) : const Color(AppTheme.textSecondary),
            _toggleLike),
        const SizedBox(width: 20),
        _actionItem(Icons.comment_rounded, '${countText(p.commentCount)}',
            const Color(AppTheme.textSecondary), () {}),
        const SizedBox(width: 20),
        _actionItem(
            _faved || _latered ? Icons.star_rounded : Icons.star_border_rounded,
            '收藏',
            (_faved || _latered)
                ? const Color(AppTheme.peach)
                : const Color(AppTheme.textSecondary),
            _showFavSheet),
        const Spacer(),
        _actionItem(Icons.share_outlined, '分享',
            const Color(AppTheme.textSecondary), () {}),
      ],
    );
  }

  Widget _actionItem(IconData icon, String label, Color color, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Row(
        children: [
          Icon(icon, size: 22, color: color),
          const SizedBox(width: 4),
          Text(label,
              style: TextStyle(color: color, fontSize: 12)),
        ],
      ),
    );
  }

  Widget _commentTile(Map<String, dynamic> c) {
    final author = (c['author'] ?? const {}) as Map;
    final name = (author['name'] ?? '用户') as String;
    final avatar = (author['avatar'] ?? '') as String;
    final adminLevel = ((author['adminLevel'] ?? 0) as num).toInt();
    final adminName = (author['adminName'] ?? '') as String;
    final cid = (c['id'] ?? '') as String;
    final content = (c['content'] ?? '') as String;
    final images = (c['images'] ?? const []) as List;
    final sticker = (c['sticker'] ?? '') as String;
    final created = ((c['created'] ?? 0) as num).toInt();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 14,
            backgroundColor: const Color(AppTheme.card),
            backgroundImage: avatar.isNotEmpty
                ? NetworkImage(avatarUrl(avatar))
                : null,
            child: avatar.isEmpty
                ? const Icon(Icons.person,
                    size: 15, color: Color(AppTheme.textSecondary))
                : null,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(name,
                        style: const TextStyle(
                            color: Color(AppTheme.textSecondary),
                            fontSize: 12)),
                    if (adminLevel > 0) ...[
                      const SizedBox(width: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 1),
                        decoration: BoxDecoration(
                          color: const Color(AppTheme.accentSoft),
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: Text(adminName.isEmpty ? '认证' : adminName,
                            style: const TextStyle(
                                color: Color(AppTheme.accent),
                                fontSize: 9)),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                if (sticker.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: CachedNetworkImageCompat(
                        url: mediaUrl(sticker),
                        width: 56,
                        height: 56,
                        fit: BoxFit.contain),
                  )
                else if (content.isNotEmpty)
                  Text(content,
                      style: const TextStyle(
                          color: Color(AppTheme.textPrimary), fontSize: 14, height: 1.4)),
                if (images.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: CachedNetworkImageCompat(
                      url: mediaUrl(images.first.toString()),
                      width: 140,
                      height: 140,
                      fit: BoxFit.cover,
                    ),
                  ),
                ],
                const SizedBox(height: 4),
                Row(
                  children: [
                    Text(timeAgo(created),
                        style: const TextStyle(
                            color: Color(AppTheme.textTertiary),
                            fontSize: 11)),
                    const Spacer(),
                    GestureDetector(
                      onTap: () => _report('comment', cid),
                      child: const Text('举报',
                          style: TextStyle(
                              color: Color(AppTheme.textTertiary),
                              fontSize: 10.5)),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _commentInput() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      decoration: const BoxDecoration(
        color: Color(AppTheme.card),
        border: Border(top: BorderSide(color: Color(AppTheme.border), width: 0.5)),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            GestureDetector(
              onTap: () async {
                final v = await _picker.pickImage(source: ImageSource.gallery);
                if (v != null) {
                  setState(() => _commentImage = File(v.path));
                }
              },
              child: _commentImage != null
                  ? Stack(clipBehavior: Clip.none, children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: Image.file(_commentImage!,
                            width: 34, height: 34, fit: BoxFit.cover),
                      ),
                      Positioned(
                        right: -4,
                        top: -4,
                        child: GestureDetector(
                          onTap: () => setState(() => _commentImage = null),
                          child: Container(
                            padding: const EdgeInsets.all(2),
                            decoration: const BoxDecoration(
                              color: Colors.black54,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.close,
                                size: 10, color: Colors.white),
                          ),
                        ),
                      ),
                    ])
                  : const Icon(Icons.image_outlined,
                      color: Color(AppTheme.textSecondary), size: 24),
            ),
            const SizedBox(width: 4),
            // 表情包按钮（图片与表情互斥，与服务端校验一致）
            GestureDetector(
              onTap: () async {
                final e = await showEmojiPanel(context);
                if (e != null) {
                  setState(() {
                    _commentSticker = (e['image'] ?? '') as String;
                    _commentImage = null;
                  });
                }
              },
              child: _commentSticker != null
                  ? Stack(clipBehavior: Clip.none, children: [
                      CachedNetworkImageCompat(
                          url: mediaUrl(_commentSticker!),
                          width: 34,
                          height: 34,
                          fit: BoxFit.contain),
                      Positioned(
                        right: -4,
                        top: -4,
                        child: GestureDetector(
                          onTap: () => setState(() => _commentSticker = null),
                          child: Container(
                            padding: const EdgeInsets.all(2),
                            decoration: const BoxDecoration(
                              color: Colors.black54,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.close,
                                size: 10, color: Colors.white),
                          ),
                        ),
                      ),
                    ])
                  : const Icon(Icons.emoji_emotions_outlined,
                      color: Color(AppTheme.textSecondary), size: 24),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: const Color(AppTheme.bg),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: TextField(
                  controller: _commentCtrl,
                  maxLines: 3,
                  minLines: 1,
                  style: const TextStyle(
                      color: Color(AppTheme.textPrimary), fontSize: 14),
                  decoration: const InputDecoration(
                    hintText: '友善评论，理性发言',
                    hintStyle: TextStyle(color: Color(AppTheme.textTertiary)),
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(vertical: 10),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: _sendComment,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(AppTheme.accent),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: const Text('发送',
                    style: TextStyle(
                        color: Colors.black,
                        fontSize: 13,
                        fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
