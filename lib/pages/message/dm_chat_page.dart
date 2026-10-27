/// 私信聊天页：IM 气泡（我右/对方左）+ 输入框 + WebSocket 实时收发
/// - 进入标记已读；WS onDm 实时追加对方消息并刷新未读
/// - 上滑加载历史（before 最早 created 分页）
/// - 消息类型：text / image / video / location / card
/// - 输入框方形 + 加号弹出 QQ 式发送面板（相册/拍照/视频/位置/名片）
library;

import 'dart:async';
import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../../widgets/emoji_panel.dart';
import 'package:video_player/video_player.dart';

import '../../api/client.dart';
import '../../config.dart';
import '../../services/notify_bus.dart';
import '../../widgets/user_avatar.dart';
import '../user/user_profile.dart';

/// 媒体/相对路径 → 完整 URL（content 存的是 /community/api/media/xxx）
String _fullUrl(String content) => 'https://www.dbmt999.asia$content';

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
  final FocusNode _inputFocus = FocusNode();
  bool _panelOpen = false; // QQ 式占位面板（收起输入法后占住输入法位置）
  bool _emojiMode = false; // 面板当前是否为表情网格

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
          'msgType': dm['msgType'] ?? 'text',
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
    _sendText(content);
  }

  void _sendText(String content) {
    setState(() {
      _sending = true;
      _msgs.add({
        'senderId': _myId ?? '',
        'content': content,
        'msgType': 'text',
        'created': DateTime.now().millisecondsSinceEpoch / 1000,
        'isRead': 0,
        '_pending': true,
      });
    });
    _input.clear();
    _scrollToBottom();
    _pushSend('text', content);
  }

  /// 媒体消息：乐观插入 → 上传 → 发送（失败回滚 pending 并提示）
  Future<void> _sendMedia(String type, String payload) async {
    if (_sending) return;
    setState(() {
      _sending = true;
      _msgs.add({
        'senderId': _myId ?? '',
        'content': payload,
        'msgType': type,
        'created': DateTime.now().millisecondsSinceEpoch / 1000,
        'isRead': 0,
        '_pending': true,
      });
    });
    _scrollToBottom();
    _pushSend(type, payload);
  }

  Future<void> _pushSend(String type, String payload) async {
    try {
      await ApiClient.dmSend(widget.peerId, payload, type: type);
      if (!mounted) return;
      setState(() {
        _sending = false;
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

  // ---------- QQ 式占位面板（非弹窗：收起输入法，面板占住输入法位置） ----------

  void _togglePanel() {
    setState(() {
      if (_panelOpen) {
        _panelOpen = false;
        _emojiMode = false;
      } else {
        FocusScope.of(context).unfocus();
        _panelOpen = true;
        _emojiMode = false;
      }
    });
  }

  void _closePanel() {
    if (_panelOpen) {
      setState(() {
        _panelOpen = false;
        _emojiMode = false;
      });
    }
  }

  /// 占位面板（QQ 式：相册/拍照/视频/位置/名片 + 表情入口）
  Widget _sendPanel() {
    if (!_panelOpen) return const SizedBox.shrink();
    if (_emojiMode) {
      return Container(
        height: 224,
        color: const Color(AppTheme.bg),
        child: EmojiPanel(
          initialFav: true,
          onPick: (e) async {
            final img = (e['image'] ?? '') as String;
            if (img.isEmpty) return;
            _closePanel();
            try {
              await _sendMedia('image', mediaUrl(img));
            } catch (err) {
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text('表情发送失败'),
                backgroundColor: const Color(AppTheme.card),
              ));
            }
          },
        ),
      );
    }
    final items = <(IconData, String, VoidCallback)>[
      (Icons.photo_library_rounded, '相册', () {
        _closePanel();
        _pickImage(ImageSource.gallery);
      }),
      (Icons.photo_camera_rounded, '拍照', () {
        _closePanel();
        _pickImage(ImageSource.camera);
      }),
      (Icons.videocam_rounded, '视频', () {
        _closePanel();
        _pickVideo();
      }),
      (Icons.location_on_rounded, '位置', () {
        _closePanel();
        _sendLocation();
      }),
      (Icons.person_rounded, '名片', () {
        _closePanel();
        _sendCard();
      }),
      (Icons.emoji_emotions_outlined, '表情', () {
        setState(() => _emojiMode = true);
      }),
    ];
    return Container(
      height: 224,
      color: const Color(AppTheme.bg),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('发送',
              style: TextStyle(
                  color: Color(AppTheme.textPrimary),
                  fontSize: 13,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 10),
          Expanded(
            child: GridView.count(
              physics: const NeverScrollableScrollPhysics(),
              crossAxisCount: 4,
              mainAxisSpacing: 12,
              crossAxisSpacing: 10,
              childAspectRatio: 0.9,
              children: [
                for (final (icon, label, act) in items)
                  GestureDetector(
                    onTap: act,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 56,
                          height: 56,
                          decoration: BoxDecoration(
                            color: const Color(AppTheme.card),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          alignment: Alignment.center,
                          child: Icon(icon,
                              color: const Color(AppTheme.accent),
                              size: 26),
                        ),
                        const SizedBox(height: 6),
                        Text(label,
                            style: const TextStyle(
                                color: Color(AppTheme.textSecondary),
                                fontSize: 11)),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickImage(ImageSource src) async {
    try {
      final img = await ImagePicker().pickImage(
          source: src, maxWidth: 2000, imageQuality: 85);
      if (img == null) return;
      final j = await ApiClient.uploadImage(img.path);
      final url = (j['url'] ?? '') as String;
      if (url.isEmpty) throw ApiException(400, '上传失败');
      await _sendMedia('image', url);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(e is ApiException ? e.message : '图片发送失败'),
        backgroundColor: const Color(AppTheme.card),
      ));
    }
  }

  Future<void> _pickVideo() async {
    try {
      final vid = await ImagePicker().pickVideo(source: ImageSource.gallery);
      if (vid == null) return;
      final j = await ApiClient.uploadVideo(vid.path);
      final name = (j['name'] ?? '') as String;
      if (name.isEmpty) throw ApiException(400, '上传失败');
      await _sendMedia('video', mediaUrl(name));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(e is ApiException ? e.message : '视频发送失败'),
        backgroundColor: const Color(AppTheme.card),
      ));
    }
  }

  Future<void> _sendLocation() async {
    // 轻量实现：发送“我的位置”文本（坐标）。后续可接地图选点。
    await _sendMedia('location', '31.2990,120.5853（我的位置）');
  }

  Future<void> _sendCard() async {
    var myName = '我';
    var myAvatar = '';
    try {
      final j = await ApiClient.myProfile();
      final u = (j['user'] ?? {}) as Map<String, dynamic>;
      myName = (u['name'] ?? '我') as String;
      myAvatar = (u['avatar'] ?? '') as String;
    } catch (_) {}
    final myId = _myId ?? '';
    final payload =
        '{"id":"$myId","name":"$myName","avatar":"$myAvatar"}';
    await _sendMedia('card', payload);
  }

  // ---------- UI ----------

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
          _sendPanel(),
          _inputBar(),
        ],
      ),
    );
  }

  Widget _bubble(Map<String, dynamic> m) {
    final mine = (m['senderId'] ?? '') == _myId;
    final content = (m['content'] ?? '') as String;
    final type = (m['msgType'] ?? 'text') as String;
    final isRead = (m['isRead'] ?? 0) == 1;
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
                _bubbleBody(type, content, mine),
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

  Widget _bubbleBody(String type, String content, bool mine) {
    final textColor = mine
        ? Colors.black
        : const Color(AppTheme.textPrimary);
    final bg = mine
        ? const Color(AppTheme.accent)
        : const Color(AppTheme.card);
    switch (type) {
      case 'image':
        return ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: GestureDetector(
            onTap: () => _previewImage(_fullUrl(content)),
            child: CachedNetworkImage(
              imageUrl: _fullUrl(content),
              width: 180,
              height: 180,
              fit: BoxFit.cover,
              placeholder: (_, __) => Container(
                width: 180,
                height: 180,
                color: const Color(AppTheme.elevated),
                child: const Center(
                    child: CircularProgressIndicator(
                        color: Color(AppTheme.accent), strokeWidth: 2)),
              ),
              errorWidget: (_, __, ___) => Container(
                width: 180,
                height: 120,
                color: const Color(AppTheme.elevated),
                alignment: Alignment.center,
                child: const Text('图片加载失败',
                    style: TextStyle(
                        color: Color(AppTheme.textTertiary), fontSize: 12)),
              ),
            ),
          ),
        );
      case 'video':
        return GestureDetector(
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => _DmVideoPlayer(url: _fullUrl(content)))),
          child: Container(
            width: 180,
            height: 110,
            decoration: BoxDecoration(
              color: const Color(AppTheme.elevated),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.play_arrow_rounded,
                      color: Colors.white, size: 28),
                ),
              ],
            ),
          ),
        );
      case 'location':
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.location_on_rounded,
                  color: Color(0xFF4CD9A5), size: 18),
              const SizedBox(width: 6),
              Flexible(
                child: Text(content,
                    style: TextStyle(
                        color: textColor,
                        fontSize: 13,
                        height: 1.3)),
              ),
            ],
          ),
        );
      case 'card':
        return _cardBubble(content, mine);
      default:
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(mine ? 12 : 4),
              topRight: Radius.circular(mine ? 4 : 12),
              bottomLeft: const Radius.circular(12),
              bottomRight: const Radius.circular(12),
            ),
          ),
          child: Text(content,
              style: TextStyle(
                  color: textColor, fontSize: 14, height: 1.35)),
        );
    }
  }

  /// 名片消息：头像+昵称卡片，点击查看对方主页
  Widget _cardBubble(String payload, bool mine) {
    Map<String, dynamic> card = {};
    try {
      final j = jsonDecode(payload);
      if (j is Map<String, dynamic>) card = j;
    } catch (_) {}
    final name = (card['name'] ?? '') as String;
    final avatar = (card['avatar'] ?? '') as String;
    final uid = (card['id'] ?? '') as String;
    return GestureDetector(
      onTap: () {
        if (uid.isNotEmpty) {
          Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => UserProfilePage(uid: uid)));
        }
      },
      child: Container(
        width: 200,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(AppTheme.elevated),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            UserAvatar(url: avatar, name: name, size: 40),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('推荐名片',
                      style: TextStyle(
                          color: Color(AppTheme.textTertiary),
                          fontSize: 10)),
                  const SizedBox(height: 2),
                  Text(name.isEmpty ? '用户' : name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Color(AppTheme.textPrimary),
                          fontSize: 14,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  const Text('点击查看资料',
                      style: TextStyle(
                          color: Color(AppTheme.accent), fontSize: 11)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _previewImage(String url) {
    showDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.9),
      builder: (_) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: EdgeInsets.zero,
        child: GestureDetector(
          onTap: () => Navigator.of(context).pop(),
          child: InteractiveViewer(
            child: CachedNetworkImage(
              imageUrl: url,
              fit: BoxFit.contain,
              placeholder: (_, __) => const Center(
                  child: CircularProgressIndicator(
                      color: Color(AppTheme.accent))),
              errorWidget: (_, __, ___) => const Center(
                  child: Text('图片加载失败',
                      style: TextStyle(color: Colors.white))),
            ),
          ),
        ),
      ),
    );
  }

  /// 输入栏：方形输入框 + 加号（QQ 式面板）+ 发送
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
                  // 方形输入框（小圆角）
                  borderRadius: BorderRadius.circular(6),
                ),
                child: TextField(
                  controller: _input,
                  focusNode: _inputFocus,
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
                  onTap: _closePanel,
                  onSubmitted: (_) => _send(),
                ),
              ),
            ),
            const SizedBox(width: 6),
            // 加号：弹出 QQ 式发送面板
            GestureDetector(
              onTap: _togglePanel,
              child: Container(
                width: 38,
                height: 38,
                decoration: const BoxDecoration(
                  color: Color(AppTheme.bg),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.add_rounded,
                    color: Color(AppTheme.accent), size: 24),
              ),
            ),
            const SizedBox(width: 6),
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

/// 视频消息播放页（全屏黑底，video_player）
class _DmVideoPlayer extends StatefulWidget {
  final String url;
  const _DmVideoPlayer({required this.url});

  @override
  State<_DmVideoPlayer> createState() => _DmVideoPlayerState();
}

class _DmVideoPlayerState extends State<_DmVideoPlayer> {
  VideoPlayerController? _vc;

  @override
  void initState() {
    super.initState();
    _vc = VideoPlayerController.networkUrl(Uri.parse(widget.url))
      ..initialize().then((_) {
        if (!mounted) return;
        setState(() {});
        _vc?.play();
      }).catchError((e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('视频加载失败')));
      });
  }

  @override
  void dispose() {
    _vc?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vc = _vc;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: Center(
        child: vc == null || !vc.value.isInitialized
            ? const CircularProgressIndicator(color: Colors.white)
            : GestureDetector(
                onTap: () => setState(() {
                  if (vc.value.isPlaying) {
                    vc.pause();
                  } else {
                    vc.play();
                  }
                }),
                child: AspectRatio(
                  aspectRatio: vc.value.aspectRatio,
                  child: VideoPlayer(vc),
                ),
              ),
      ),
    );
  }
}
