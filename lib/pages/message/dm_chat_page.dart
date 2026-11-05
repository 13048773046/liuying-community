/// 私信聊天页（沉浸黑）：IM 气泡（我右/对方左）+ 贴底输入条 + WebSocket 实时收发
/// - 进入标记已读；WS onDm 实时追加对方消息并刷新未读
/// - 上滑加载历史（before 最早 created 分页）
/// - 消息类型：text / image / video / location / card
/// - 输入框胶囊 + 加号弹出 QQ 式发送面板（相册/拍照/位置）
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:image_picker/image_picker.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import '../../api/client.dart';
import '../../config.dart';
import '../../design/components.dart';
import '../../models/feed_item.dart';
import '../../services/notify_bus.dart';
import '../../widgets/input_panel_host.dart';
import '../user/user_profile.dart';
import 'location_picker_page.dart';

/// 媒体/相对路径 → 完整 URL（content 存的是 /community/api/media/xxx）
/// - 已是完整 http(s) URL：原样返回（兼容历史消息）
/// - 以 `/` 开头：拼社区域名
/// - 纯文件名：按 mediaUrl 拼接
String _fullUrl(String content) {
  final s = content.trim();
  if (s.isEmpty) return s;
  if (s.startsWith('http://') || s.startsWith('https://')) return s;
  if (s.startsWith('/')) return 'https://www.dbmt999.asia$s';
  return mediaUrl(s);
}

/// 上传结果 → 消息里应存的相对路径（统一「存相对路径，渲染时 _fullUrl」）
String _uploadPath(Map<String, dynamic> j) {
  final raw = ((j['url'] ?? j['name'] ?? '') as String).trim();
  if (raw.isEmpty) return '';
  if (raw.startsWith('http://') || raw.startsWith('https://')) {
    // 服务端若返回绝对 URL，剥掉域名只留 /community/api/media/xxx
    final i = raw.indexOf('/community/api/media/');
    return i >= 0 ? raw.substring(i) : raw;
  }
  if (raw.startsWith('/')) return raw;
  return '/community/api/media/$raw';
}

/// created 兼容 num / String / null（后端为 REAL 时间戳，单位秒）
int _tsOf(dynamic v) {
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}

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
      showAppToast(context, e is ApiException ? e.message : '发送失败');
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
      } else {
        // 收起输入法：面板平滑占据原输入法位置
        FocusScope.of(context).unfocus();
        _panelOpen = true;
      }
    });
  }

  void _closePanel() {
    if (_panelOpen) {
      setState(() => _panelOpen = false);
    }
  }

  /// 占位面板（加号 → 收起输入法，面板占住原输入法位置，丝滑切换）
  Widget _sendPanel() {
    if (!_panelOpen) return const SizedBox.shrink();
    final items = <(IconData, String, VoidCallback)>[
      (Icons.photo_library_rounded, '图片', () {
        _closePanel();
        _pickImage(ImageSource.gallery);
      }),
      (Icons.photo_camera_rounded, '拍照', () {
        _closePanel();
        _pickImage(ImageSource.camera);
      }),
      (Icons.location_on_rounded, '发送定位', () {
        _closePanel();
        _sendLocation();
      }),
    ];
    return Container(
      color: const Color(AppColors.bg),
      padding: const EdgeInsets.fromLTRB(
          AppSpace.x4, AppSpace.x3, AppSpace.x4, AppSpace.x2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('发送', style: AppType.caption),
          const SizedBox(height: AppSpace.x3),
          Expanded(
            child: GridView.count(
              physics: const NeverScrollableScrollPhysics(),
              crossAxisCount: 3,
              mainAxisSpacing: AppSpace.x3,
              crossAxisSpacing: AppSpace.x2,
              childAspectRatio: 1.1,
              children: [
                for (final (icon, label, onTap) in items)
                  PressableScale(
                    onTap: onTap,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 52,
                          height: 52,
                          decoration: BoxDecoration(
                            color: const Color(AppColors.card),
                            borderRadius: AppRadius.rMd,
                            border: Border.all(
                                color: const Color(AppColors.border)),
                          ),
                          child: Icon(icon,
                              size: 23, color: const Color(AppColors.accent)),
                        ),
                        const SizedBox(height: AppSpace.x2),
                        Text(label, style: AppType.micro),
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
      final path = _uploadPath(j);
      if (path.isEmpty) throw ApiException(400, '上传失败');
      await _sendMedia('image', path);
    } catch (e) {
      if (!mounted) return;
      showAppToast(context, e is ApiException ? e.message : '图片发送失败');
    }
  }

  // ignore: unused_element
  Future<void> _pickVideo() async {
    try {
      final vid = await ImagePicker().pickVideo(source: ImageSource.gallery);
      if (vid == null) return;
      final j = await ApiClient.uploadVideo(vid.path);
      final path = _uploadPath(j);
      if (path.isEmpty) throw ApiException(400, '上传失败');
      await _sendMedia('video', path);
    } catch (e) {
      if (!mounted) return;
      showAppToast(context, e is ApiException ? e.message : '视频发送失败');
    }
  }

  Future<void> _sendLocation() async {
    final loc = await showLocationPicker(context);
    if (loc == null || !mounted) return;
    await _sendMedia('location', jsonEncode(loc));
  }

  // ignore: unused_element
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
    final top = MediaQuery.paddingOf(context).top;
    return ImmersivePage(
      child: Stack(
        children: [
          Positioned.fill(
            child: Column(
              children: [
                Expanded(child: _messageList(top)),
                // 输入区：键盘态由 Scaffold 顶起；加号面板态平滑占住原输入法位置
                InputPanelHost(
                  absorbInsets: false,
                  surfaceColor: const Color(AppColors.bg),
                  fallbackHeight: 232,
                  inputBar: _inputBar(),
                  panel: _panelOpen ? _sendPanel() : null,
                ),
              ],
            ),
          ),
          // 悬浮顶栏：标题 + 返回
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: GlassTopBar(title: widget.peerName, floating: true),
          ),
        ],
      ),
    );
  }

  Widget _messageList(double topInset) {
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2.2),
        ),
      );
    }
    if (_loadError && _msgs.isEmpty) {
      return Center(
        child: ErrorState(
          message: '聊天记录加载失败',
          onRetry: () {
            _loadHistory();
          },
        ),
      );
    }
    return ListView.builder(
      controller: _scroll,
      physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics()),
      padding: EdgeInsets.fromLTRB(
          AppSpace.gutter, topInset + 72, AppSpace.gutter, AppSpace.x3),
      itemCount: _msgs.length + (_hasMore ? 1 : 0),
      itemBuilder: (_, i) {
        if (i == _msgs.length) {
          return LoadMoreFooter(
            hasMore: true,
            onTap: () {
              _loadHistory();
            },
          );
        }
        final m = _msgs[i];
        final ts = _tsOf(m['created']);
        final prevTs = i > 0 ? _tsOf(_msgs[i - 1]['created']) : 0;
        final showTime = i == 0 || (ts - prevTs).abs() > 300;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (showTime) _timeDivider(ts),
            _bubble(m),
          ],
        );
      },
    );
  }

  /// 时间分组：超过 5 分钟或首条前显示一次
  Widget _timeDivider(int ts) {
    if (ts <= 0) return const SizedBox(height: AppSpace.x2);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpace.x2),
      child: Center(child: Text(timeAgo(ts), style: AppType.micro)),
    );
  }

  Widget _bubble(Map<String, dynamic> m) {
    final mine = (m['senderId'] ?? '') == _myId;
    final content = (m['content'] ?? '') as String;
    final type = (m['msgType'] ?? 'text') as String;
    final isRead = (m['isRead'] ?? 0) == 1;
    final pending = m['_pending'] == true;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpace.x1),
      child: Row(
        mainAxisAlignment:
            mine ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!mine) ...[
            AppAvatar(
              url: avatarUrl(widget.peerAvatar),
              name: widget.peerName,
              size: 32,
            ),
            const SizedBox(width: AppSpace.x2),
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
                    style: AppType.micro,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _bubbleBody(String type, String content, bool mine) {
    final bg = mine
        ? const Color(AppColors.accent)
        : const Color(AppColors.elevated);
    final fg = mine
        ? const Color(AppColors.onAccent)
        : const Color(AppColors.textPrimary);
    switch (type) {
      case 'image':
        return ClipRRect(
          borderRadius: AppRadius.rMd,
          child: GestureDetector(
            onTap: () => _previewImage(_fullUrl(content)),
            child: CachedNetworkImage(
              imageUrl: _fullUrl(content),
              width: 180,
              height: 180,
              fit: BoxFit.cover,
              placeholder: (_, _) => Container(
                width: 180,
                height: 180,
                color: const Color(AppColors.card),
                child: const Center(
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
              errorWidget: (_, _, _) => Container(
                width: 180,
                height: 120,
                color: const Color(AppColors.card),
                alignment: Alignment.center,
                child: Text('图片加载失败', style: AppType.caption),
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
              color: const Color(AppColors.card),
              borderRadius: AppRadius.rMd,
              border: Border.all(color: const Color(AppColors.border)),
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
                Positioned(
                  left: AppSpace.x3,
                  bottom: AppSpace.x3,
                  child: Row(
                    children: [
                      const Icon(Icons.videocam_rounded,
                          size: 13, color: Color(AppColors.textTertiary)),
                      const SizedBox(width: 3),
                      Text('视频', style: AppType.micro),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      case 'location':
        return _locationBubble(content, mine);
      case 'card':
        return _cardBubble(content, mine);
      default:
        return Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width * 0.68,
          ),
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpace.x3 + 2, vertical: AppSpace.x3),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(mine ? AppRadius.md : AppRadius.xs),
              topRight: Radius.circular(mine ? AppRadius.xs : AppRadius.md),
              bottomLeft: const Radius.circular(AppRadius.md),
              bottomRight: const Radius.circular(AppRadius.md),
            ),
          ),
          child: Text(content, style: AppType.body.copyWith(color: fg)),
        );
    }
  }

  /// 位置卡片：小地图缩略图 + 地点名 + 地址（微信式），点击跳外部地图 App
  Widget _locationBubble(String payload, bool mine) {
    Map<String, dynamic> loc = {};
    try {
      final j = jsonDecode(payload);
      if (j is Map<String, dynamic>) loc = j;
    } catch (_) {}
    final lat = ((loc['lat'] ?? 0) as num).toDouble();
    final lng = ((loc['lng'] ?? 0) as num).toDouble();
    final name = (loc['name'] ?? '我的位置') as String;
    final address = (loc['address'] ?? '') as String;
    return GestureDetector(
      onTap: () => _openExternalMap(lat, lng, name),
      child: ClipRRect(
        borderRadius: AppRadius.rMd,
        child: Container(
          width: 220,
          decoration: const BoxDecoration(color: Color(AppColors.elevated)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 小地图缩略图（只读）
              SizedBox(
                height: 100,
                width: double.infinity,
                child: _LocationMapThumb(lat: lat, lng: lng),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    AppSpace.x3, AppSpace.x2, AppSpace.x3, AppSpace.x2 + 2),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.label,
                    ),
                    if (address.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        address,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppType.micro,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 跳转外部地图 App（iOS 苹果地图 / Android 系统地图选择器）
  Future<void> _openExternalMap(double lat, double lng, String name) async {
    final q = Uri.encodeComponent(name);
    final uri = Platform.isIOS
        ? Uri.parse('http://maps.apple.com/?ll=$lat,$lng&q=$q')
        : Uri.parse('geo:$lat,$lng?q=$lat,$lng($q)');
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
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
        padding: const EdgeInsets.all(AppSpace.x3),
        decoration: BoxDecoration(
          color: const Color(AppColors.elevated),
          borderRadius: AppRadius.rMd,
          border: Border.all(color: const Color(AppColors.border)),
        ),
        child: Row(
          children: [
            AppAvatar(url: avatarUrl(avatar), name: name, size: 40),
            const SizedBox(width: AppSpace.x2 + 2),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('推荐名片', style: AppType.micro),
                  const SizedBox(height: 2),
                  Text(
                    name.isEmpty ? '用户' : name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.body.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '点击查看资料',
                    style: AppType.micro
                        .copyWith(color: const Color(AppColors.accent)),
                  ),
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
      barrierColor: Colors.black.withValues(alpha: 0.92),
      builder: (_) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: EdgeInsets.zero,
        child: GestureDetector(
          onTap: () => Navigator.of(context).pop(),
          child: InteractiveViewer(
            child: CachedNetworkImage(
              imageUrl: url,
              fit: BoxFit.contain,
              placeholder: (_, _) => const Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2.2),
                ),
              ),
              errorWidget: (_, _, _) => Center(
                child: Text('图片加载失败',
                    style: AppType.bodySm.copyWith(color: Colors.white)),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 输入栏：胶囊输入框 + 加号（QQ 式面板）+ 薄荷发送钮
  Widget _inputBar() {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(
            AppSpace.x3, AppSpace.x2, AppSpace.x3, AppSpace.x2),
        decoration: const BoxDecoration(
          color: Color(AppColors.bg),
          border: Border(top: BorderSide(color: Color(AppColors.hairline))),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // 加号：弹出 QQ 式发送面板
            PressableScale(
              onTap: _togglePanel,
              child: Container(
                width: 38,
                height: 38,
                decoration: const BoxDecoration(
                  color: Color(AppColors.elevated),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.add_rounded,
                    color: Color(AppColors.accent), size: 22),
              ),
            ),
            const SizedBox(width: AppSpace.x2),
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: AppSpace.x4, vertical: AppSpace.x2),
                decoration: BoxDecoration(
                  color: const Color(AppColors.elevated),
                  borderRadius: AppRadius.rPill,
                  border: Border.all(color: const Color(AppColors.border)),
                ),
                child: TextField(
                  controller: _input,
                  focusNode: _inputFocus,
                  minLines: 1,
                  maxLines: 4,
                  cursorColor: const Color(AppColors.accent),
                  style: AppType.body,
                  decoration: InputDecoration(
                    hintText: '说点什么…',
                    hintStyle: AppType.body
                        .copyWith(color: const Color(AppColors.textTertiary)),
                    filled: false,
                    isCollapsed: true,
                    contentPadding: EdgeInsets.zero,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                  ),
                  onTap: _closePanel,
                  onSubmitted: (_) => _send(),
                ),
              ),
            ),
            const SizedBox(width: AppSpace.x2),
            PressableScale(
              onTap: _send,
              child: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: const Color(AppColors.accent),
                  shape: BoxShape.circle,
                  boxShadow: AppEffects.accentGlow(opacity: 0.3),
                ),
                child: const Icon(Icons.send_rounded,
                    color: Color(AppColors.onAccent), size: 18),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 位置卡片内嵌的小地图缩略图（只读，高德瓦片）
class _LocationMapThumb extends StatelessWidget {
  final double lat;
  final double lng;
  const _LocationMapThumb({required this.lat, required this.lng});

  @override
  Widget build(BuildContext context) {
    return FlutterMap(
      options: MapOptions(
        initialCenter: LatLng(lat, lng),
        initialZoom: 15,
        interactionOptions: const InteractionOptions(
            flags: InteractiveFlag.none), // 纯展示，禁手势
      ),
      children: [
        TileLayer(
          urlTemplate:
              'https://webrd0{s}.is.autonavi.com/appmaptile?lang=zh_cn&size=1&scale=1&style=8&x={x}&y={y}&z={z}',
          subdomains: const ['1', '2', '3', '4'],
          userAgentPackageName: 'com.liuying.community',
        ),
        MarkerLayer(
          markers: [
            Marker(
              point: LatLng(lat, lng),
              width: 34,
              height: 34,
              child: const Icon(Icons.location_pin,
                  color: Color(AppColors.heart), size: 34),
            ),
          ],
        ),
      ],
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
        showAppToast(context, '视频加载失败');
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
    return ImmersivePage(
      child: Stack(
        children: [
          Positioned.fill(
            child: Center(
              child: vc == null || !vc.value.isInitialized
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2.4),
                    )
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
          ),
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: GlassTopBar(title: '视频', floating: true),
          ),
        ],
      ),
    );
  }
}
