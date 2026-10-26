/// 私信聊天页：IM 气泡（我右/对方左）+ 输入框 + WebSocket 实时收发
/// - 进入标记已读；WS onDm 实时追加对方消息并刷新未读
/// - 上滑加载历史（before 最早 created 分页）
/// - 我发出的消息显示"已读"状态（对方已读后）
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../config.dart';
import '../../models/feed_item.dart';
import '../../services/notify_bus.dart';
import '../../widgets/user_avatar.dart';

class DmChatPage extends StatefulWidget {
  final String peerId;
  final String peerName;
  final String peerAvatar;
  const DmChatPage(
      {super.key,
      required this.peerId,
      required this.peerName,
      this.peerAvatar = ''});

  @override
  State<DmChatPage> createState() => _DmChatPageState();
}

class _DmChatPageState extends State<DmChatPage> {
  final List<Map<String, dynamic>> _msgs = [];
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  bool _loading = true;
  bool _loadError = false;
  bool _sending = false;
  bool _hasMore = true;
  String? _myId;
  StreamSubscription? _dmSub;

  @override
  void initState() {
    super.initState();
    _myId = ApiClient.userId;
    _loadHistory();
    // 实时接收对方消息
    _dmSub = NotifyBus.shared.onDm.stream.listen(_onDm);
    // 进入即标记已读
    Future.delayed(const Duration(milliseconds: 300), () {
      try {
        ApiClient.dmRead(widget.peerId);
      } catch (_) {}
    });
  }

  @override
  void dispose() {
    _dmSub?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onDm(Map<String, dynamic> dm) {
    final from = (dm['from'] ?? {}) as Map<String, dynamic>;
    if ((from['id'] ?? '') == widget.peerId) {
      if (!mounted) return;
      setState(() {
        _msgs.add({
          'senderId': widget.peerId,
          'content': dm['content'] ?? '',
          'created': dm['created'] ?? 0,
          'isRead': 1,
        });
      });
      _scrollToBottom();
      try {
        ApiClient.dmRead(widget.peerId);
      } catch (_) {}
      // 通知未读清零（全局）
      NotifyBus.shared.dmUnread.value = 0;
    }
  }

  Future<void> _loadHistory() async {
    try {
      final before = _msgs.isEmpty
          ? 0.0
          : ((_msgs.first['created'] ?? 0) as num).toDouble();
      final j = await ApiClient.dmMessages(
          peer: widget.peerId, before: before, limit: 30);
      final list = ((j['list'] ?? []) as List)
          .whereType<Map<String, dynamic>>()
          .toList();
      if (!mounted) return;
      setState(() {
        _msgs.insertAll(0, list);
        _hasMore = list.length >= 30;
        _loading = false;
        _loadError = false;
      });
      if (before == 0) _scrollToBottom();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = true;
      });
    }
  }

  Future<void> _send() async {
    final content = _input.text.trim();
    if (content.isEmpty || _sending) return;
    setState(() {
      _sending = true;
      _msgs.add({
        'senderId': _myId ?? '',
        'content': content,
        'created': DateTime.now().millisecondsSinceEpoch / 1000,
        'isRead': 0,
        '_pending': true,
      });
    });
    _input.clear();
    _scrollToBottom();
    try {
      await ApiClient.dmSend(widget.peerId, content);
      if (!mounted) return;
      setState(() {
        _sending = false;
        // 更新 pending 消息为已发送（保持展示）
        final last = _msgs.isNotEmpty ? _msgs.last : null;
        if (last != null) last.remove('_pending');
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _msgs.removeWhere((m) => m['_pending'] == true);
      });
      final msg = e is ApiException ? e.message : '发送失败';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(msg),
        backgroundColor: const Color(AppTheme.card),
      ));
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(AppTheme.bg),
      appBar: AppBar(
        backgroundColor: const Color(AppTheme.bg),
        elevation: 0,
        centerTitle: true,
        title: Text(widget.peerName,
            style: const TextStyle(
                color: Color(AppTheme.textPrimary),
                fontSize: 16,
                fontWeight: FontWeight.w600)),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded,
              color: Colors.white, size: 18),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: _loading
                ? const Center(
                    child: CircularProgressIndicator(
                        color: Color(AppTheme.accent), strokeWidth: 2.5))
                : _loadError && _msgs.isEmpty
                    ? Center(
                        child: OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: const Color(AppTheme.accent),
                            side: const BorderSide(
                                color: Color(AppTheme.accent)),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(20)),
                          ),
                          onPressed: _loadHistory,
                          child: const Text('重新加载'),
                        ),
                      )
                    : ListView.builder(
                        controller: _scroll,
                        padding:
                            const EdgeInsets.symmetric(horizontal: 12),
                        itemCount: _msgs.length + (_hasMore ? 1 : 0),
                        itemBuilder: (_, i) {
                          if (i == _msgs.length) {
                            return GestureDetector(
                              onTap: _loadHistory,
                              behavior: HitTestBehavior.opaque,
                              child: const Padding(
                                padding: EdgeInsets.symmetric(vertical: 12),
                                child: Center(
                                  child: Text('加载更多历史',
                                      style: TextStyle(
                                          color:
                                              Color(AppTheme.textTertiary),
                                          fontSize: 12)),
                                ),
                              ),
                            );
                          }
                          return _bubble(_msgs[i]);
                        },
                      ),
          ),
          _inputBar(),
        ],
      ),
    );
  }

  Widget _bubble(Map<String, dynamic> m) {
    final mine = (m['senderId'] ?? '') == _myId;
    final content = (m['content'] ?? '') as String;
    final isRead = boolOf(m['isRead']);
    final pending = m['_pending'] == true;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        mainAxisAlignment:
            mine ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!mine) ...[
            UserAvatar(url: widget.peerAvatar, name: widget.peerName, size: 32),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Column(
              crossAxisAlignment:
                  mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: mine
                        ? const Color(AppTheme.accent)
                        : const Color(AppTheme.card),
                    borderRadius: BorderRadius.only(
                      topLeft: Radius.circular(mine ? 16 : 4),
                      topRight: Radius.circular(mine ? 4 : 16),
                      bottomLeft: const Radius.circular(16),
                      bottomRight: const Radius.circular(16),
                    ),
                  ),
                  child: Text(content,
                      style: TextStyle(
                          color: mine
                              ? Colors.black
                              : const Color(AppTheme.textPrimary),
                          fontSize: 14,
                          height: 1.35)),
                ),
                const SizedBox(height: 3),
                if (mine)
                  Text(
                    pending
                        ? '发送中…'
                        : (isRead ? '已读' : ''),
                    style: const TextStyle(
                        color: Color(AppTheme.textTertiary), fontSize: 10),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _inputBar() {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        decoration: const BoxDecoration(
          color: Color(AppTheme.elevated),
          border: Border(top: BorderSide(color: Color(AppTheme.border))),
        ),
        child: Row(
          children: [
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: const Color(AppTheme.bg),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: TextField(
                  controller: _input,
                  minLines: 1,
                  maxLines: 4,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  decoration: const InputDecoration(
                    hintText: '说点什么…',
                    hintStyle: TextStyle(
                        color: Color(AppTheme.textTertiary), fontSize: 14),
                    border: InputBorder.none,
                    isCollapsed: true,
                    contentPadding: EdgeInsets.symmetric(vertical: 10),
                  ),
                  onSubmitted: (_) => _send(),
                ),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: _send,
              child: Container(
                width: 40,
                height: 40,
                decoration: const BoxDecoration(
                  color: Color(AppTheme.accent),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.send_rounded,
                    color: Colors.black, size: 18),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
