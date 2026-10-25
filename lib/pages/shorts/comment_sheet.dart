/// 短视频评论面板：底部弹层
/// - 打开即加载评论列表（接口无需登录，游客可浏览）
/// - 发送评论需登录：未登录点击发送 → 提示并跳转登录页
/// - 发送成功刷新列表，并把新评论数回传调用方
library;

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../config.dart';
import '../../models/feed_item.dart';
import '../../widgets/image_box.dart';
import '../mine/login_page.dart';

class CommentSheet extends StatefulWidget {
  final String postId;
  final int initialCount;

  const CommentSheet({
    super.key,
    required this.postId,
    required this.initialCount,
  });

  @override
  State<CommentSheet> createState() => _CommentSheetState();
}

class _CommentSheetState extends State<CommentSheet> {
  List<Map<String, dynamic>> _comments = [];
  int _cPage = 1;
  bool _cHasMore = false;
  bool _cLoading = false;
  bool _sending = false;
  int _count = 0;
  int _added = 0; // 本次会话新增评论数，关闭时回传调用方

  final _ctrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _count = widget.initialCount;
    _load(refresh: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _load({bool refresh = false}) async {
    if (_cLoading || (!_cHasMore && !refresh)) return;
    setState(() => _cLoading = true);
    try {
      final j = await ApiClient.comments(widget.postId,
          page: refresh ? 1 : _cPage + 1, size: 20);
      if (!mounted) return;
      setState(() {
        final list = ((j['list'] ?? const []) as List)
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

  /// 发送评论：未登录 → 提示并跳登录页；成功 → 刷新列表 + 计数+1
  Future<void> _send() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty) {
      _toast('评论内容不能为空');
      return;
    }
    if (_sending) return;
    // 登录检查：游客点发送 → 提示 + 跳登录页（登录后回来自动定位输入框）
    if (ApiClient.token == null || ApiClient.token!.isEmpty) {
      _toast('请先登录后评论（账号与流萤音乐互通）');
      await Future<void>.delayed(const Duration(milliseconds: 600));
      if (!mounted) return;
      Navigator.of(context).pop();
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const LoginPage()),
      );
      return;
    }
    setState(() => _sending = true);
    try {
      await ApiClient.addComment(widget.postId, text);
      if (!mounted) return;
      _ctrl.clear();
      setState(() {
        _count++;
        _added++;
        _sending = false;
      });
      _toast('评论成功');
      await _load(refresh: true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      _toast(e.toString(), error: true);
    }
  }

  void _toast(String s, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(s),
      backgroundColor: error ? const Color(0xFFB3261E) : null,
      duration: const Duration(seconds: 2),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return AnimatedPadding(
      duration: const Duration(milliseconds: 200),
      padding: EdgeInsets.only(bottom: bottom),
      child: Container(
        height: MediaQuery.of(context).size.height * 0.62,
        decoration: const BoxDecoration(
          color: Color(AppTheme.bg),
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: Column(
          children: [
            // 顶栏
            Container(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 10),
              child: Row(
                children: [
                  Text('评论',
                      style: const TextStyle(
                          color: Color(AppTheme.textPrimary),
                          fontSize: 15,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(width: 6),
                  Text('$_count',
                      style: const TextStyle(
                          color: Color(AppTheme.textTertiary), fontSize: 13)),
                  const Spacer(),
                  GestureDetector(
                    onTap: () => Navigator.of(context).pop(_added),
                    child: const Padding(
                      padding: EdgeInsets.all(6),
                      child: Icon(Icons.close_rounded,
                          size: 22, color: Color(AppTheme.textSecondary)),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(
                height: 1, color: Color(AppTheme.border), thickness: 0.5),
            // 列表
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                itemCount: _comments.length + (_cHasMore ? 1 : 0),
                itemBuilder: (context, i) {
                  if (i == _comments.length) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: GestureDetector(
                        onTap: () => _load(),
                        child: const Center(
                          child: Text('加载更多…',
                              style: TextStyle(
                                  color: Color(AppTheme.textSecondary),
                                  fontSize: 12)),
                        ),
                      ),
                    );
                  }
                  return _tile(_comments[i]);
                },
              ),
            ),
            // 输入栏
            Container(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
              decoration: const BoxDecoration(
                color: Color(AppTheme.card),
                border: Border(
                    top: BorderSide(color: Color(AppTheme.border), width: 0.5)),
              ),
              child: SafeArea(
                top: false,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                          color: const Color(AppTheme.bg),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: TextField(
                          controller: _ctrl,
                          maxLines: 3,
                          minLines: 1,
                          style: const TextStyle(
                              color: Color(AppTheme.textPrimary), fontSize: 14),
                          decoration: const InputDecoration(
                            hintText: '友善评论，理性发言',
                            hintStyle:
                                TextStyle(color: Color(AppTheme.textTertiary)),
                            border: InputBorder.none,
                            isDense: true,
                            contentPadding:
                                EdgeInsets.symmetric(vertical: 10),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: _send,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 8),
                        decoration: BoxDecoration(
                          color: const Color(AppTheme.accent),
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: _sending
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.black),
                              )
                            : const Text('发送',
                                style: TextStyle(
                                    color: Colors.black,
                                    fontSize: 13,
                                    fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tile(Map<String, dynamic> c) {
    final author = (c['author'] ?? const {}) as Map;
    final name = (author['name'] ?? '用户') as String;
    final avatar = (author['avatar'] ?? '') as String;
    final content = (c['content'] ?? '') as String;
    final sticker = (c['sticker'] ?? '') as String;
    final images = (c['images'] ?? const []) as List;
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
}
