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
import '../../widgets/emoji_panel.dart';
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
  int _likeCount = 0;
  bool _loading = true;
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
        _likeCount = (pj['likeCount'] ?? 0) as int;
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
        _cHasMore = (j['hasMore'] ?? false) as bool;
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
      await ApiClient.toggleFav(_post!.id);
    } catch (_) {
      if (!mounted) return;
      setState(() => _faved = !_faved);
    }
  }

  Future<void> _sendComment() async {
    final text = _commentCtrl.text.trim();
    if (text.isEmpty && _commentImage == null) {
      _toast('评论内容不能为空');
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
              Text('Lv${a.level} · ${timeAgo(_post!.created)}',
                  style: const TextStyle(
                      color: Color(AppTheme.textTertiary), fontSize: 12)),
            ],
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
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: p.images
                .map((img) => ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: CachedNetworkImageCompat(
                        url: mediaUrl(img),
                        width: (MediaQuery.of(context).size.width - 40 - 16) /
                            (p.images.length == 1 ? 1 : 2),
                        height: 160,
                        fit: BoxFit.cover,
                      ),
                    ))
                .toList(),
          ),
        ],
        if (p.isVideo) ...[
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: CachedNetworkImageCompat(
              url: mediaUrl(p.cover == 'auto' ? '${p.video}.jpg' : p.cover),
              width: double.infinity,
              height: 300,
              fit: BoxFit.cover,
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
            _faved ? Icons.star_rounded : Icons.star_border_rounded,
            '收藏',
            _faved ? const Color(AppTheme.peach) : const Color(AppTheme.textSecondary),
            _toggleFav),
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
    final content = (c['content'] ?? '') as String;
    final images = (c['images'] ?? const []) as List;
    final sticker = (c['sticker'] ?? '') as String;
    final created = (c['created'] ?? 0) as int;
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
                Text(name,
                    style: const TextStyle(
                        color: Color(AppTheme.textSecondary), fontSize: 12)),
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
                Text(timeAgo(created),
                    style: const TextStyle(
                        color: Color(AppTheme.textTertiary), fontSize: 11)),
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
