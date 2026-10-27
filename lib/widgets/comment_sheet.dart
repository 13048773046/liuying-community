/// 抖音式评论弹窗（P0）：评论列表 + 底部输入栏
///
/// 交互参考抖音评论：
///  - 点击表情/图片图标 → 收起输入法，面板占住输入法原位置（互斥切换）
///  - 表情包（图片/GIF）与图片评论二选一（后端强制 images/sticker 互斥）
///  - 表情选择后进入待发预览区，可删除；图片同理
///  - @ 好友：弹层选择关注列表，插入「@昵称 」文本
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../api/client.dart';
import '../config.dart';
import '../models/feed_item.dart' show timeAgo;
import '../pages/mine/login_page.dart';
import 'emoji_panel.dart';
import 'image_box.dart';

enum _PanelMode { none, emoji, image }

/// 打开评论弹窗；[onChanged] 评论数变化回调
Future<void> showCommentSheet(
  BuildContext context, {
  required String postId,
  ValueChanged<int>? onChanged,
  bool light = false,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(AppTheme.bg),
    useSafeArea: true,
    builder: (_) => CommentSheet(
        postId: postId, onChanged: onChanged, light: light),
  );
}

class CommentSheet extends StatefulWidget {
  const CommentSheet(
      {super.key,
      required this.postId,
      this.onChanged,
      this.light = false});

  final String postId;
  final ValueChanged<int>? onChanged;

  /// light=true：仅评论列表弹窗（短视频详情用），
  /// 底部「说点什么…」点击后关闭本弹窗并打开完整抖音式评论弹窗
  final bool light;

  @override
  State<CommentSheet> createState() => _CommentSheetState();
}

class _CommentSheetState extends State<CommentSheet> {
  final _ctrl = TextEditingController();
  List<Map<String, dynamic>> _comments = [];
  int _page = 1;
  bool _hasMore = false;
  bool _loading = true;
  bool _sending = false;

  _PanelMode _panel = _PanelMode.none;
  File? _img;
  String? _sticker; // 表情文件名（媒体 URL）

  @override
  void initState() {
    super.initState();
    _load(refresh: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _load({bool refresh = false}) async {
    if (refresh) {
      setState(() {
        _page = 1;
        _loading = true;
      });
    } else {
      _page += 1;
    }
    try {
      final j = await ApiClient.comments(widget.postId, page: _page, size: 20);
      final list = ((j['list'] ?? []) as List)
          .whereType<Map<String, dynamic>>()
          .toList();
      final hasMore = (j['hasMore'] ?? false) == true;
      if (!mounted) return;
      setState(() {
        _comments = refresh ? list : [..._comments, ...list];
        _hasMore = hasMore;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  /// 收起键盘/面板
  void _collapse() {
    FocusScope.of(context).unfocus();
    setState(() => _panel = _PanelMode.none);
  }

  void _showPanel(_PanelMode m) {
    FocusScope.of(context).unfocus();
    setState(() => _panel = _panel == m ? _PanelMode.none : m);
  }

  Future<void> _pickImage() async {
    final p = await ImagePicker()
        .pickImage(source: ImageSource.gallery, maxWidth: 1600);
    if (p == null || !mounted) return;
    setState(() {
      _img = File(p.path);
      _sticker = null; // 互斥：选图片时清掉表情
      _panel = _PanelMode.none;
    });
  }

  void _pickSticker(Map<String, dynamic> e) {
    setState(() {
      _sticker = (e['image'] ?? '') as String;
      _img = null; // 互斥：选表情时清掉图片
      _panel = _PanelMode.none;
    });
  }

  Future<void> _atFriend() async {
    _collapse();
    if (ApiClient.token == null || ApiClient.token!.isEmpty) {
      _needLogin();
      return;
    }
    try {
      final j = await ApiClient.userList(ApiClient.userId ?? '',
          kind: 'followings', page: 1, size: 50);
      final list = ((j['list'] ?? []) as List)
          .whereType<Map<String, dynamic>>()
          .toList();
      if (!mounted || list.isEmpty) return;
      final sel = await showModalBottomSheet<Map<String, dynamic>>(
        context: context,
        backgroundColor: const Color(AppTheme.card),
        builder: (_) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.all(14),
                child: Text('@好友',
                    style: TextStyle(
                        color: Color(AppTheme.textPrimary),
                        fontSize: 15,
                        fontWeight: FontWeight.w600)),
              ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: list.length,
                  itemBuilder: (_, i) {
                    final u = list[i];
                    final name = (u['name'] ?? '用户') as String;
                    return ListTile(
                      dense: true,
                      leading: CircleAvatar(
                        radius: 16,
                        backgroundColor: const Color(AppTheme.elevated),
                        backgroundImage: ((u['avatar'] ?? '') as String)
                                .isNotEmpty
                            ? NetworkImage(avatarUrl((u['avatar'] ?? '') as String))
                            : null,
                        child: ((u['avatar'] ?? '') as String).isEmpty
                            ? const Icon(Icons.person, size: 16)
                            : null,
                      ),
                      title: Text(name,
                          style: const TextStyle(
                              color: Color(AppTheme.textPrimary),
                              fontSize: 14)),
                      onTap: () => Navigator.of(context).pop(u),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      );
      if (sel != null && mounted) {
        final at = _ctrl.text;
        _ctrl.text = at.isEmpty ? '@${sel['name']} ' : '\$at @${sel['name']} ';
        _ctrl.selection = TextSelection.collapsed(offset: _ctrl.text.length);
        setState(() {});
      }
    } catch (_) {}
  }

  void _needLogin() {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('请先登录后评论（账号与流萤音乐互通）'),
        backgroundColor: Color(AppTheme.bg)));
    Navigator.of(context).pop();
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const LoginPage()),
    );
  }

  Future<void> _send() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty && _img == null && _sticker == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('评论内容不能为空'),
          backgroundColor: Color(AppTheme.bg)));
      return;
    }
    if (ApiClient.token == null || ApiClient.token!.isEmpty) {
      _needLogin();
      return;
    }
    if (_sending) return;
    setState(() => _sending = true);
    try {
      List<String> imgs = [];
      if (_img != null) {
        final j = await ApiClient.uploadImage(_img!.path);
        imgs = [j['name'] as String];
      }
      await ApiClient.addComment(widget.postId, text,
          images: imgs, sticker: _sticker);
      if (!mounted) return;
      setState(() {
        _ctrl.clear();
        _img = null;
        _sticker = null;
        _sending = false;
      });
      await _load(refresh: true);
      widget.onChanged?.call(_comments.length);
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('评论失败：$e'),
          backgroundColor: const Color(AppTheme.bg)));
    }
  }

  void _report(String type, String id) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('举报已提交，管理员将尽快处理'),
        backgroundColor: Color(AppTheme.bg)));
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.92,
        child: Column(
          children: [
            // 拖拽条
            Container(
              margin: const EdgeInsets.only(top: 8),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: const Color(AppTheme.border),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // 标题
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 8, 6),
              child: Row(
                children: [
                  Text('评论 ${_comments.length}',
                      style: const TextStyle(
                          color: Color(AppTheme.textPrimary),
                          fontSize: 15,
                          fontWeight: FontWeight.w600)),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close,
                        color: Color(AppTheme.textSecondary), size: 20),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(color: Color(AppTheme.border), height: 1),
            // 评论列表
            Expanded(
              child: _loading && _comments.isEmpty
                  ? const Center(
                      child: CircularProgressIndicator(
                          color: Color(AppTheme.accent), strokeWidth: 2))
                  : ListView(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 6),
                      children: [
                        if (_comments.isEmpty)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 40),
                            child: Center(
                              child: Text('还没有评论，来抢沙发',
                                  style: TextStyle(
                                      color: Color(AppTheme.textTertiary),
                                      fontSize: 13)),
                            ),
                          )
                        else ...[
                          ..._comments.map((c) => _commentTile(c)),
                          if (_hasMore)
                            Center(
                              child: TextButton(
                                onPressed: () => _load(),
                                child: const Text('加载更多',
                                    style: TextStyle(
                                        color: Color(AppTheme.textSecondary),
                                        fontSize: 12)),
                              ),
                            ),
                        ],
                      ],
                    ),
            ),
            const Divider(color: Color(AppTheme.border), height: 1),
            // 待发预览（表情包/图片，二选一；light 模式无）
            if (!widget.light && (_sticker != null || _img != null))
              Container(
                height: 76,
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
                child: Row(
                  children: [
                    Stack(
                      children: [
                        Container(
                          width: 60,
                          height: 60,
                          decoration: BoxDecoration(
                            color: const Color(AppTheme.card),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: _img != null
                              ? Image.file(_img!, fit: BoxFit.cover)
                              : CachedNetworkImageCompat(url: mediaUrl(_sticker ?? ''),
                                  fit: BoxFit.cover),
                        ),
                        Positioned(
                          right: -4,
                          top: -4,
                          child: GestureDetector(
                            onTap: () => setState(() {
                              _img = null;
                              _sticker = null;
                            }),
                            child: Container(
                              decoration: const BoxDecoration(
                                  color: Colors.black54, shape: BoxShape.circle),
                              padding: const EdgeInsets.all(2),
                              child: const Icon(Icons.close,
                                  size: 14, color: Colors.white),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(width: 10),
                    Text(_img != null ? '图片' : '表情包',
                        style: const TextStyle(
                            color: Color(AppTheme.textSecondary),
                            fontSize: 12)),
                  ],
                ),
              ),
            // 输入栏（light：仅「说点什么…」入口，点击打开完整评论弹窗）
            if (widget.light)
              GestureDetector(
                onTap: () {
                  Navigator.of(context).pop();
                  showCommentSheet(context,
                      postId: widget.postId, onChanged: widget.onChanged);
                },
                behavior: HitTestBehavior.opaque,
                child: Container(
                  color: const Color(AppTheme.card),
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  child: Row(
                    children: [
                      const CircleAvatar(
                        radius: 14,
                        backgroundColor: Color(AppTheme.elevated),
                        child: Icon(Icons.person,
                            size: 15, color: Color(AppTheme.textSecondary)),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          child: const Text('说点什么...',
                              style: TextStyle(
                                  color: Color(AppTheme.textTertiary),
                                  fontSize: 14)),
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Icon(Icons.emoji_emotions_outlined,
                          color: Color(AppTheme.textTertiary), size: 20),
                      const SizedBox(width: 14),
                      const Icon(Icons.image_outlined,
                          color: Color(AppTheme.textTertiary), size: 20),
                    ],
                  ),
                ),
              )
            else
              Container(
              color: const Color(AppTheme.card),
              padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Container(
                      constraints: const BoxConstraints(minHeight: 38),
                      decoration: BoxDecoration(
                        color: const Color(AppTheme.bg),
                        borderRadius: BorderRadius.circular(19),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: TextField(
                        controller: _ctrl,
                        focusNode: _focusNode,
                        onTap: () {
                          // 键盘占位：收起面板
                          if (_panel != _PanelMode.none) {
                            setState(() => _panel = _PanelMode.none);
                          }
                        },
                        style: const TextStyle(
                            color: Color(AppTheme.textPrimary),
                            fontSize: 14,
                            height: 1.4),
                        decoration: const InputDecoration(
                          hintText: '说点什么...',
                          hintStyle: TextStyle(
                              color: Color(AppTheme.textTertiary),
                              fontSize: 14),
                          border: InputBorder.none,
                          isDense: true,
                          contentPadding:
                              EdgeInsets.symmetric(vertical: 10),
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.alternate_email,
                        color: Color(AppTheme.textSecondary), size: 20),
                    onPressed: _atFriend,
                  ),
                  IconButton(
                    icon: Icon(Icons.emoji_emotions_outlined,
                        color: _panel == _PanelMode.emoji
                            ? const Color(AppTheme.accent)
                            : const Color(AppTheme.textSecondary),
                        size: 22),
                    onPressed: () => _showPanel(_PanelMode.emoji),
                  ),
                  IconButton(
                    icon: Icon(Icons.image_outlined,
                        color: _panel == _PanelMode.image
                            ? const Color(AppTheme.accent)
                            : const Color(AppTheme.textSecondary),
                        size: 22),
                    onPressed: () => _showPanel(_PanelMode.image),
                  ),
                  _sending
                      ? const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 10),
                          child: SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Color(AppTheme.accent))),
                        )
                      : IconButton(
                          onPressed: _send,
                          icon: const Icon(Icons.send,
                              color: Color(AppTheme.accent), size: 22),
                        ),
                ],
              ),
            ),
            // 面板（表情/图片，占输入法位置；light 模式无）
            if (widget.light)
              const SizedBox.shrink()
            else
              AnimatedSize(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              child: _panel == _PanelMode.none
                  ? const SizedBox(width: double.infinity)
                  : Container(
                      height: 240,
                      color: const Color(AppTheme.card),
                      child: _panel == _PanelMode.emoji
                          ? EmojiPanel(
                              initialFav: true, onPick: _pickSticker)
                          : _imagePanel(),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  final FocusNode _focusNode = FocusNode();

  Widget _imagePanel() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        GestureDetector(
          onTap: _pickImage,
          child: Container(
            width: 84,
            height: 84,
            decoration: BoxDecoration(
              color: const Color(AppTheme.elevated),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(Icons.add_photo_alternate_outlined,
                color: Color(AppTheme.textSecondary), size: 30),
          ),
        ),
        const SizedBox(height: 10),
        const Text('选择图片（评论支持 1 张图片，与表情包二选一）',
            style: TextStyle(
                color: Color(AppTheme.textTertiary), fontSize: 12)),
      ],
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
            backgroundImage:
                avatar.isNotEmpty ? NetworkImage(avatarUrl(avatar)) : null,
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
                                color: Color(AppTheme.accent), fontSize: 9)),
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
                        width: 64,
                        height: 64,
                        fit: BoxFit.contain),
                  )
                else if (content.isNotEmpty)
                  Text(content,
                      style: const TextStyle(
                          color: Color(AppTheme.textPrimary),
                          fontSize: 14,
                          height: 1.4)),
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
}
