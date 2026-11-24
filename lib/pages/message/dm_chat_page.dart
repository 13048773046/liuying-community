/// 私信聊天页（沉浸黑）：IM 气泡（我右/对方左）+ 贴底输入条 + WebSocket 实时收发
/// - 进入标记已读；WS onDm 实时追加对方消息并刷新未读
/// - 上滑加载历史（before 最早 created 分页）
/// - 消息类型：text / image / video / location / card
/// - 底栏：加号功能面板 / 表情面板内嵌（与键盘同区，微信抖音式互斥切换）
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show BlurStyle, ImageFilter, MaskFilter, Paint;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:image_picker/image_picker.dart';
import 'package:latlong2/latlong.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import '../../api/client.dart';
import '../../features/message/data/message_repository.dart';
import '../../config.dart';
import '../../design/components.dart';
import '../../features/emoji/text_emoji.dart';
import '../../models/feed_item.dart';
import '../../services/notify_bus.dart';
import '../../widgets/emoji_panel.dart';
import '../../widgets/image_box.dart';
import '../../widgets/input_panel_host.dart';
import '../apps/app_detail_page.dart';
import '../mine/login_page.dart';
import '../post/post_detail.dart';
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
  if (s.startsWith('/')) return '$kSiteBase$s';
  return mediaUrl(s);
}

/// 私信底栏面板：与键盘同一块空间，加号/表情互斥切换
enum _PanelMode { none, more, emoji }

/// 上传结果 → 消息里应存的相对路径（统一「存相对路径，渲染时 _fullUrl」）
String _uploadPath(Map<String, dynamic> j) {
  final raw = (j['url'] ?? j['name'] ?? '').toString().trim();
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
  final String peerFrameId;
  final bool peerVerified;
  final String peerVerifiedLabel;

  /// 仅官方 AI 会传 true：用于“正在输入”与 AI 专属的回复节奏。
  final bool peerIsAi;
  const DmChatPage({
    super.key,
    required this.peerId,
    required this.peerName,
    this.peerAvatar = '',
    this.peerFrameId = '',
    this.peerVerified = false,
    this.peerVerifiedLabel = '',
    this.peerIsAi = false,
  });

  @override
  State<DmChatPage> createState() => _DmChatPageState();
}

class _DmChatPageState extends State<DmChatPage> with TickerProviderStateMixin {
  final List<Map<String, dynamic>> _msgs = [];
  final TextEmojiEditingController _input = TextEmojiEditingController();
  final FocusNode _inputFocus = FocusNode();
  _PanelMode _panel = _PanelMode.none; // 底栏面板：更多功能 / 表情
  bool get _panelOpen => _panel != _PanelMode.none;

  final ScrollController _scroll = ScrollController();
  final GlobalKey _pageStackKey = GlobalKey();
  bool _loading = true;
  bool _loadError = false;
  bool _historyLoading = false;
  bool _sending = false;
  bool _hasMore = true;
  bool _typing = false;
  bool _followBottom = true;
  bool _voiceMode = false;
  bool _voiceHintVisible = false;
  bool _voiceListening = false;
  bool _voicePressing = false;
  bool _voiceCancel = false;
  bool _speechReady = false;
  String _voiceDraft = '';
  double _voiceStartDy = 0;
  final stt.SpeechToText _speech = stt.SpeechToText();
  String? _ghostText;
  String? _myId;
  StreamSubscription? _dmSub;
  StreamSubscription? _dmReadSub;
  Timer? _typingTimer;
  Timer? _streamTimer;
  Map<String, dynamic>? _streamMsg;
  AnimationController? _ghostAnim;
  AnimationController? _flyAnim;
  Map<String, dynamic>? _flying;
  final Set<String> _seenIds = {};
  final Set<String> _seenFallback = {};

  /// 当前用户 id。登录态恢复是异步的，进入私信页时 [ApiClient.userId]
  /// 可能还没回填；此时用 myProfile 兜底，仍取不到再由 [_isMine] 按会话关系判断。
  String? get _uid {
    // 登录态可能在本页打开后才回填：始终先读当前 ApiClient.userId，
    // 再退到 initState 缓存和 myProfile，避免空缓存盖住后来恢复的身份。
    final direct = (ApiClient.userId ?? '').trim();
    if (direct.isNotEmpty) return direct;
    final cached = (_myId ?? '').trim();
    if (cached.isNotEmpty) return cached;
    final profileId = (ApiClient.meProfile?['id'] ?? '').toString().trim();
    return profileId.isEmpty ? null : profileId;
  }

  /// 一对一私信里，发送者只可能是“我”或“对方”。优先用真实 uid 比较，
  /// 拿不到 uid 时：乐观消息按自己处理；服务端历史里非对方的发送者按自己处理。
  /// 这样冷启动/异步恢复登录态时，自己发的消息也不会跑到左侧变成对方气泡。
  bool _isMine(Map<String, dynamic> m) {
    if (m['_mine'] == true) return true;
    if (m['_mine'] == false) return false;
    final sender = (m['senderId'] ?? '').toString().trim();
    final me = _uid;
    if (me != null) return sender == me;
    if (m['_pending'] == true) return true;
    return sender.isNotEmpty && sender != widget.peerId;
  }

  @override
  void initState() {
    super.initState();
    _myId = ApiClient.userId ?? (ApiClient.meProfile?['id'] ?? '').toString();
    _inputFocus.addListener(_onFocusChanged);
    _scroll.addListener(_onScrollChanged);
    _ghostAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 150),
    );
    _loadHistory();
    // 实时接收对方消息 + 对方读取回执
    _dmSub = NotifyBus.shared.onDm.stream.listen(_onDm);
    _dmReadSub = NotifyBus.shared.onDmRead.stream.listen(_onDmRead);
    // 进入即标记已读（不再延迟，避免红点残留 300ms）
    unawaited(_markRead());
  }

  void _onFocusChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _dmSub?.cancel();
    _dmReadSub?.cancel();
    _inputFocus.removeListener(_onFocusChanged);
    _scroll.removeListener(_onScrollChanged);
    _typingTimer?.cancel();
    _streamTimer?.cancel();
    _streamMsg = null;
    _ghostAnim?.dispose();
    _flyAnim?.dispose();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  String _msgId(Map<String, dynamic> m) => (m['id'] ?? '').toString().trim();

  String _fallbackKey(Map<String, dynamic> m) {
    final sender = (m['senderId'] ?? '').toString();
    final content = (m['content'] ?? '').toString();
    final created = _tsOf(m['created']);
    // AI 可能在同一秒发出两条完全相同的内容；带 msgType 与内容长度，
    // 仍只作为“服务端没有 id”时的兜底，不能替代真实 id。
    return '$sender|$created|${m['msgType'] ?? 'text'}|${content.length}|$content';
  }

  bool _rememberMessage(Map<String, dynamic> m) {
    final id = _msgId(m);
    if (id.isNotEmpty) {
      if (_seenIds.contains(id)) return false;
      _seenIds.add(id);
      return true;
    }
    final fb = _fallbackKey(m);
    if (_seenFallback.contains(fb)) return false;
    _seenFallback.add(fb);
    return true;
  }

  void _onScrollChanged() {
    if (!_scroll.hasClients) return;
    final atBottom = _scroll.position.maxScrollExtent - _scroll.offset < 44;
    if (atBottom != _followBottom) _followBottom = atBottom;
  }

  void _armTypingTimer() {
    _typingTimer?.cancel();
    if (!widget.peerIsAi) return;
    _typingTimer = Timer(const Duration(seconds: 75), () {
      if (mounted && _typing) setState(() => _typing = false);
    });
  }

  void _onDm(Map<String, dynamic> dm) {
    final from = mapOf(dm['from']);
    if ((from['id'] ?? '') == widget.peerId) {
      if (!mounted) return;
      final m = <String, dynamic>{
        'id': (dm['id'] ?? '').toString(),
        'senderId': widget.peerId,
        'content': (dm['content'] ?? '').toString(),
        'msgType': (dm['msgType'] ?? 'text').toString(),
        'created': dm['created'] ?? 0,
        'isRead': 1,
        '_mine': false,
        '_key': GlobalKey(),
        '_fresh': true,
      };
      // 没有服务端 id 的旧推送：同发送者 + 同内容 + 2.5 秒内算同一条。
      if (_msgId(m).isEmpty) {
        final now = _tsOf(m['created']);
        final duplicate = _msgs.any((old) {
          if ((old['senderId'] ?? '') != (m['senderId'] ?? '')) return false;
          if ((old['content'] ?? '') != (m['content'] ?? '')) return false;
          return (_tsOf(old['created']) - now).abs() <= 2;
        });
        if (duplicate) return;
        _seenFallback.add(_fallbackKey(m));
      } else if (!_rememberMessage(m)) {
        return;
      }
      final shouldStream =
          widget.peerIsAi &&
          (m['msgType'] ?? 'text') == 'text' &&
          (m['content'] ?? '').toString().isNotEmpty;
      if (shouldStream) _finishAiStream();
      if (shouldStream) {
        // 第一帧先给 2 个字，避免先冒出一个只有光标的空泡。
        m['_stream'] = true;
        m['_shown'] = math.min(2, (m['content'] ?? '').toString().length);
      }
      setState(() {
        _typing = false;
        _typingTimer?.cancel();
        _msgs.add(m);
      });
      if (shouldStream) {
        _startAiStream(m, m['content'].toString());
      }
      _scrollToBottom();
      unawaited(_markRead());
    }
  }

  /// 官方 AI 专属：整段回复已到，但按 2~4 字逐段揭开，气泡随行数长高。
  /// 只对 peerIsAi 的文本消息生效，普通用户消息始终整段出现。
  void _startAiStream(Map<String, dynamic> m, String full) {
    _finishAiStream();
    if (full.isEmpty) return;
    _streamMsg = m;
    var tick = 0;
    _streamTimer = Timer.periodic(const Duration(milliseconds: 55), (timer) {
      if (!mounted || !identical(_streamMsg, m)) {
        timer.cancel();
        return;
      }
      tick++;
      // 2、4、3 字循环，避免机械等速；长回复也不会拖太久。
      final step = const [2, 4, 3][tick % 3];
      final shown = (intOf(m['_shown']) + step).clamp(0, full.length);
      setState(() => m['_shown'] = shown);
      _scrollToBottom();
      if (shown >= full.length) {
        timer.cancel();
        m['_stream'] = false;
        _streamMsg = null;
        setState(() {});
      }
    });
  }

  void _finishAiStream() {
    _streamTimer?.cancel();
    _streamTimer = null;
    final m = _streamMsg;
    if (m != null) {
      final full = (m['content'] ?? '').toString();
      m['_stream'] = false;
      m['_shown'] = full.length;
    }
    _streamMsg = null;
  }

  /// 对方在另一端读了我的消息后，服务端会推送 dm_read；把己方气泡改为已读。
  void _onDmRead(Map<String, dynamic> e) {
    final peer = (e['peer'] ?? e['reader'] ?? '').toString();
    if (peer.isNotEmpty && peer != widget.peerId) return;
    if (!mounted) return;
    var changed = false;
    for (final m in _msgs) {
      if (_isMine(m) &&
          m['_pending'] != true &&
          intOf(m['isRead']) != 1) {
        m['isRead'] = 1;
        changed = true;
      }
    }
    if (changed) setState(() {});
  }

  Future<void> _markRead() async {
    try {
      await MessageRepository.instance.dmRead(widget.peerId);
      await _refreshDmUnread();
    } catch (_) {}
  }

  Future<void> _refreshDmUnread() async {
    try {
      final j = await MessageRepository.instance.dmUnread();
      NotifyBus.shared.setDmUnread(intOf(j['unread'] ?? j['count']));
    } catch (_) {}
  }

  Future<void> _loadHistory() async {
    if (_historyLoading) return;
    _historyLoading = true;
    try {
      final before = _msgs.isEmpty
          ? 0.0
          : _tsOf(_msgs.first['created']).toDouble();
      final j = await MessageRepository.instance.dmMessages(
        peer: widget.peerId,
        before: before,
        limit: 30,
      );
      final rawList = ((j['list'] ?? []) as List)
          .whereType<Map<String, dynamic>>()
          .toList();
      final list = <Map<String, dynamic>>[];
      for (final raw in rawList) {
        final m = Map<String, dynamic>.from(raw);
        m['_key'] = GlobalKey();
        m['_fresh'] = false;
        if (!_rememberMessage(m)) continue;
        list.add(m);
      }
      _historyLoading = false;
      if (!mounted) return;
      setState(() {
        _msgs.insertAll(0, list);
        _hasMore = list.length >= 30;
        _loading = false;
        _loadError = false;
      });
      if (before == 0) {
        // 首次进入必须“已经在正确位置”，不能让用户看着列表滚一长段。
        _jumpToBottomAfterLayout();
      }
    } catch (_) {
      _historyLoading = false;
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
    final optimistic = <String, dynamic>{
      'senderId': _uid ?? '',
      'content': content,
      'msgType': 'text',
      'created': DateTime.now().millisecondsSinceEpoch / 1000,
      'isRead': 0,
      '_pending': true,
      '_fresh': true,
      '_mine': true,
      '_key': GlobalKey(),
    };
    setState(() {
      _sending = true;
      _msgs.add(optimistic);
      _ghostText = content;
      if (widget.peerIsAi) _typing = true;
    });
    _input.clear();
    _ghostAnim?.forward(from: 0);
    _armTypingTimer();
    _scrollToBottom(force: true);
    _pushSend('text', content, optimistic: optimistic);
  }

  /// 媒体消息：乐观插入 → 上传 → 发送（失败回滚 pending 并提示）
  Future<void> _sendMedia(
    String type,
    String payload, {
    bool flyFromKeyboard = false,
  }) async {
    if (_sending) return;
    final optimistic = <String, dynamic>{
      'senderId': _uid ?? '',
      'content': payload,
      'msgType': type,
      'created': DateTime.now().millisecondsSinceEpoch / 1000,
      'isRead': 0,
      '_pending': true,
      '_fresh': true,
      '_mine': true,
      '_key': GlobalKey(),
      '_flyDone': !flyFromKeyboard,
    };
    setState(() {
      _sending = true;
      _msgs.add(optimistic);
      if (widget.peerIsAi) _typing = true;
    });
    _armTypingTimer();
    _scrollToBottom(force: true);
    if (flyFromKeyboard) _startStickerFly(optimistic);
    _pushSend(type, payload, optimistic: optimistic);
  }

  Future<void> _pushSend(
    String type,
    String payload, {
    Map<String, dynamic>? optimistic,
  }) async {
    try {
      final j = await MessageRepository.instance.dmSend(
        widget.peerId,
        payload,
        type: type,
      );
      if (!mounted) return;
      final id = (j['id'] ?? '').toString();
      setState(() {
        _sending = false;
        final target = optimistic;
        if (target != null) {
          target.remove('_pending');
          if (id.isNotEmpty) {
            target['id'] = id;
            // 服务端回包 id 与 WS 同 id：若 WS 已先插入了同一条，
            // 用乐观消息合并，避免“一条消息两个气泡”。
            _msgs.removeWhere(
              (m) =>
                  m != target &&
                  _msgId(m) == id &&
                  (m['senderId'] ?? '') == (target['senderId'] ?? ''),
            );
            if (id.isNotEmpty) _seenIds.add(id);
          }
        } else {
          final last = _msgs.isNotEmpty ? _msgs.last : null;
          if (last != null) last.remove('_pending');
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _typing = false;
        // 只回滚本次发送的乐观气泡，不能把其他仍在等待回包的消息一起删掉。
        if (optimistic != null) {
          _msgs.remove(optimistic);
        } else {
          _msgs.removeWhere((m) => m['_pending'] == true);
        }
      });
      _typingTimer?.cancel();
      showAppToast(context, e is ApiException ? e.message : '发送失败');
    }
  }

  void _scrollToBottom({bool force = false}) {
    if (force) _followBottom = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients || !_followBottom) return;
      final target = _scroll.position.maxScrollExtent;
      if ((target - _scroll.offset).abs() < 1) return;
      _scroll.animateTo(
        target,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    });
  }

  void _jumpToBottomAfterLayout() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
      _followBottom = true;
    });
  }

  // ---------- 表情包飞入 ----------

  void _startStickerFly(Map<String, dynamic> message) {
    final previous = _flying;
    if (previous != null) previous['_flyDone'] = true;
    _flying = message;
    final oldController = _flyAnim;
    _flyAnim = null;
    final controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    );
    _flyAnim = controller;
    controller.addStatusListener((status) {
      if (status != AnimationStatus.completed || !mounted) return;
      setState(() {
        message['_flyDone'] = true;
        if (identical(_flying, message)) _flying = null;
      });
    });
    controller.forward();
    setState(() {});
    // 旧气泡的 AnimatedBuilder 还挂在旧 controller 上；等下一帧重建后
    // 再 dispose，避免在动画监听仍被使用时销毁 controller。
    if (oldController != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        oldController.dispose();
      });
    }
  }

  Widget _flyingStickerOverlay() {
    final message = _flying;
    final controller = _flyAnim;
    if (message == null || controller == null) return const SizedBox.shrink();
    final screen = MediaQuery.sizeOf(context);
    return Positioned.fill(
      key: const ValueKey('dm_flying_sticker'),
      child: IgnorePointer(
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            AnimatedBuilder(
              animation: controller,
              builder: (context, _) {
                final stackBox =
                    _pageStackKey.currentContext?.findRenderObject()
                        as RenderBox?;
                final targetBox =
                    (message['_key'] as GlobalKey?)?.currentContext
                            ?.findRenderObject()
                        as RenderBox?;
                // 乐观气泡可能尚未完成 sliver 布局，localToGlobal 在
                // “已挂载但尚未排版”的瞬间会抛空；此处兜底到列表中段，
                // 下一帧拿到有效几何再自然吸附到真实气泡位置。
                Rect? resolved;
                if (stackBox != null && targetBox != null) {
                  try {
                    final local = targetBox.localToGlobal(
                      Offset.zero,
                      ancestor: stackBox,
                    );
                    resolved = Rect.fromLTWH(
                      local.dx,
                      local.dy,
                      targetBox.size.width,
                      targetBox.size.height,
                    );
                  } catch (_) {}
                }
                final target =
                    resolved ??
                    Rect.fromLTWH(
                      screen.width / 2 - 90,
                      screen.height * 0.58,
                      180,
                      180,
                    );
                final start = Rect.fromLTWH(
                  screen.width / 2 - 38,
                  screen.height + 12,
                  76,
                  76,
                );
                final t = Curves.easeOutCubic.transform(
                  controller.value.clamp(0.0, 1.0),
                );
                final rect = Rect.lerp(start, target, t)!;
                final radius = 18 + 2 * t;
                final content = (message['content'] ?? '').toString();
                final renderPath = upgradeEmojiMediaPath(content);
                final isEmoji = _isLiuyingEmojiPath(renderPath);
                return Positioned(
                  key: const ValueKey('dm_flying_sticker_body'),
                  left: rect.left,
                  top: rect.top,
                  width: rect.width,
                  height: rect.height,
                  child: Opacity(
                    opacity: t < 0.18 ? t / 0.18 : 1,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(radius),
                      child: CachedNetworkImage(
                        imageUrl: _fullUrl(renderPath),
                        fit: isEmoji ? BoxFit.contain : BoxFit.cover,
                        errorWidget: (_, _, _) => isEmoji
                            ? const SizedBox.shrink()
                            : Container(
                                color: const Color(AppColors.card),
                                alignment: Alignment.center,
                                child: const Icon(
                                  Icons.image_not_supported_outlined,
                                ),
                              ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  // ---------- QQ 式占位面板（非弹窗：收起输入法，面板占住输入法位置） ----------

  /// 互斥切换面板（更多功能 / 表情），收起输入法让面板占住键盘位置
  void _switchPanel(_PanelMode mode) {
    if (_panel == mode) {
      _closePanel();
      return;
    }
    // 不强行抢焦点：键盘本来开着就保留，关着就只开面板，
    // 避免“键盘先弹一下再收起”的闪烁。面板收起时由 InputPanelHost
    // 仅在输入框仍持焦时唤回键盘。
    unawaited(SystemChannels.textInput.invokeMethod('TextInput.hide'));
    setState(() => _panel = mode);
    _scrollToBottom();
  }

  void _togglePanel() => _switchPanel(_PanelMode.more);

  void _toggleEmoji() => _switchPanel(_PanelMode.emoji);

  void _closePanel() {
    if (_panelOpen) {
      setState(() => _panel = _PanelMode.none);
    }
  }

  /// 点消息区/空白：收起键盘与面板（点输入框以外的地方）
  void _dismissInput() {
    if (_panelOpen) {
      setState(() => _panel = _PanelMode.none);
    }
    if (_inputFocus.hasFocus) {
      _inputFocus.unfocus();
    }
  }

  void _toggleVoiceMode() {
    HapticFeedback.selectionClick();
    if (_voiceMode) {
      _inputFocus.requestFocus();
      unawaited(SystemChannels.textInput.invokeMethod('TextInput.show'));
    } else {
      _inputFocus.unfocus();
      unawaited(SystemChannels.textInput.invokeMethod('TextInput.hide'));
    }
    setState(() => _voiceMode = !_voiceMode);
  }

  void _needLogin() {
    HapticFeedback.lightImpact();
    showAppToast(context, '请先登录（账号与流萤音乐互通）');
    unawaited(
      Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => const LoginPage())),
    );
  }

  void _onVoicePressStart(LongPressStartDetails details) {
    _voiceStartDy = details.globalPosition.dy;
    _voiceCancel = false;
    _voicePressing = true;
    _voiceDraft = '';
    unawaited(_startVoice());
  }

  Future<void> _startVoice() async {
    if (_voiceListening) return;
    if (ApiClient.token == null) {
      _voicePressing = false;
      _needLogin();
      return;
    }
    if (!_speechReady) {
      // 插件缺失（桌面/测试环境）或系统语音服务异常时 initialize 会抛异常，
      // 不能让它变成未捕获的异步错误，否则按住说话会静默失败、提示层也不收起。
      var ok = false;
      try {
        ok = await _speech.initialize();
      } catch (_) {
        ok = false;
      }
      if (!ok) {
        _voicePressing = false;
        if (mounted) showAppToast(context, '当前设备无法使用语音识别');
        return;
      }
      _speechReady = true;
    }
    if (!mounted || !_voicePressing) return;
    HapticFeedback.mediumImpact();
    setState(() {
      _voiceListening = true;
      _voiceHintVisible = true;
      _voiceCancel = false;
      _voiceDraft = '';
    });
    try {
      await _speech.listen(
        listenOptions: stt.SpeechListenOptions(
          localeId: 'zh_CN',
          listenFor: const Duration(seconds: 45),
          pauseFor: const Duration(seconds: 2),
        ),
        onResult: (r) {
          if (!mounted) return;
          final text = r.recognizedWords.trim();
          if (text.isEmpty || text == _voiceDraft) return;
          setState(() => _voiceDraft = text);
        },
      );
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _voiceListening = false;
        _voicePressing = false;
        _voiceHintVisible = false;
      });
      showAppToast(context, '语音识别启动失败');
    }
  }

  void _onVoiceMove(LongPressMoveUpdateDetails details) {
    if (!_voiceListening) return;
    final up = _voiceStartDy - details.globalPosition.dy;
    final cancel = up > 64;
    if (cancel != _voiceCancel) {
      HapticFeedback.selectionClick();
      setState(() => _voiceCancel = cancel);
    }
  }

  Future<void> _onVoicePressEnd(LongPressEndDetails details) async {
    _voicePressing = false;
    if (!_voiceListening) return;
    final canceled = _voiceCancel;
    final text = _voiceDraft.trim();
    await _stopVoice(send: !canceled ? text : null);
    if (!mounted) return;
    if (canceled) {
      showAppToast(context, '已取消');
    } else if (text.isEmpty) {
      showAppToast(context, '没听清，再说一次');
    }
  }

  void _onVoiceCancel() {
    _voicePressing = false;
    if (!_voiceListening) return;
    unawaited(_stopVoice(send: null));
    if (mounted) showAppToast(context, '已取消');
  }

  Future<void> _stopVoice({String? send}) async {
    try {
      await _speech.stop();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _voiceListening = false;
      _voicePressing = false;
      _voiceHintVisible = false;
      _voiceCancel = false;
    });
    final text = (send ?? '').trim();
    if (text.isNotEmpty && !_sending) _sendText(text);
  }

  /// 当前面板：表情内嵌（与键盘同区）或功能网格
  Widget _panelContent() {
    switch (_panel) {
      case _PanelMode.emoji:
        return Container(
          color: const Color(AppColors.bg),
          child: EmojiPanel(compact: true, onPick: _onPickEmoji),
        );
      case _PanelMode.more:
        return _morePanel();
      case _PanelMode.none:
        return const SizedBox.shrink();
    }
  }

  /// 选中表情即发（与图片消息同路径），面板保持打开可连发。
  /// 表情包会从键盘/面板下方沿一条连续路径飞入消息列表。
  void _onPickEmoji(Map<String, dynamic> e) {
    final code = (e['textCode'] ?? '').toString();
    if (code.isNotEmpty && kTextEmojiByCode.containsKey(code)) {
      HapticFeedback.lightImpact();
      _input.insertEmojiCode(code);
      setState(() {});
      return;
    }
    final img = (e['image'] ?? '').toString().trim();
    if (img.isEmpty) {
      showAppToast(context, '表情还在加载，请稍后再试');
      return;
    }
    HapticFeedback.lightImpact();
    _sendMedia('image', img, flyFromKeyboard: true);
  }

  Widget _morePanel() {
    final items = <(IconData, String, VoidCallback)>[
      (
        Icons.photo_library_rounded,
        '图片',
        () {
          _closePanel();
          _pickImage(ImageSource.gallery);
        },
      ),
      (
        Icons.photo_camera_rounded,
        '拍照',
        () {
          _closePanel();
          _pickImage(ImageSource.camera);
        },
      ),
      (
        Icons.videocam_rounded,
        '视频',
        () {
          _closePanel();
          _pickVideo();
        },
      ),
      (
        Icons.location_on_rounded,
        '位置',
        () {
          _closePanel();
          _sendLocation();
        },
      ),
      (Icons.emoji_emotions_rounded, '表情', _toggleEmoji),
      (
        Icons.badge_rounded,
        '名片',
        () {
          _closePanel();
          _sendCard();
        },
      ),
    ];
    return Container(
      decoration: const BoxDecoration(
        color: Color(AppColors.bg),
        border: Border(top: BorderSide(color: Color(AppColors.hairline))),
      ),
      padding: const EdgeInsets.fromLTRB(
        AppSpace.x4,
        AppSpace.x3,
        AppSpace.x4,
        AppSpace.x2,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: GridView.count(
              physics: const NeverScrollableScrollPhysics(),
              crossAxisCount: 3,
              mainAxisSpacing: AppSpace.x2,
              crossAxisSpacing: AppSpace.x3,
              childAspectRatio: 1.0,
              children: [
                for (final (icon, label, onTap) in items)
                  PressableScale(
                    onTap: onTap,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 56,
                          height: 56,
                          decoration: BoxDecoration(
                            color: const Color(AppColors.card),
                            borderRadius: AppRadius.rMd,
                            border: Border.all(
                              color: const Color(AppColors.border),
                            ),
                          ),
                          child: Icon(
                            icon,
                            size: 24,
                            color: const Color(AppColors.accent),
                          ),
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
        source: src,
        maxWidth: 2000,
        imageQuality: 85,
      );
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
    final myId = _uid ?? '';
    final payload = '{"id":"$myId","name":"$myName","avatar":"$myAvatar"}';
    await _sendMedia('card', payload);
  }

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    return ImmersivePage(
      // 键盘/面板都交给 InputPanelHost 统一占位：
      // 如果 Scaffold 先按键盘 inset 缩一次，面板再占一次，输入栏会被顶高一截。
      resizeToAvoidBottomInset: false,
      child: Stack(
        key: _pageStackKey,
        children: [
          Positioned.fill(
            child: Column(
              children: [
                Expanded(child: _messageList(top)),
                // 输入区：键盘态由 Scaffold 顶起；加号面板态平滑占住原输入法位置
                InputPanelHost(
                  absorbInsets: true,
                  surfaceColor: const Color(AppColors.bg),
                  fallbackHeight: 272,
                  inputBar: _inputBar(),
                  panel: _panelOpen ? _panelContent() : null,
                ),
              ],
            ),
          ),
          // 顶部：平面黑色标题栏（返回 + 头像 + 昵称），不做胶囊悬浮
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              height: top + 52,
              padding: EdgeInsets.only(
                top: top,
                left: AppSpace.x2,
                right: AppSpace.x3,
              ),
              color: const Color(AppColors.bg),
              child: Row(
                children: [
                  IconCircleButton(
                    icon: Icons.arrow_back_ios_new_rounded,
                    size: 36,
                    iconSize: 17,
                    onTap: () => Navigator.of(context).maybePop(),
                  ),
                  const SizedBox(width: AppSpace.x1),
                  PressableScale(
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => UserProfilePage(uid: widget.peerId),
                        ),
                      );
                    },
                    scale: 0.92,
                    child: AppAvatar(
                      url: widget.peerAvatar.isEmpty
                          ? avatarUrlOf(widget.peerId)
                          : avatarUrl(widget.peerAvatar),
                      name: widget.peerName,
                      size: 30,
                      verified:
                          widget.peerVerified ||
                          widget.peerVerifiedLabel.trim().isNotEmpty,
                      isAi:
                          widget.peerIsAi ||
                          widget.peerVerifiedLabel.trim().toUpperCase() == 'AI',
                      frameUrl: frameUrlOf(widget.peerFrameId),
                    ),
                  ),
                  const SizedBox(width: AppSpace.x3),
                  Expanded(
                    child: Text(
                      widget.peerName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.title.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          _voiceHoldHint(),
          if (_flying != null) _flyingStickerOverlay(),
        ],
      ),
    );
  }

  Widget _messageList(double topInset) {
    // 点消息区（含空态/错误态空白）收起键盘与面板
    return GestureDetector(
      key: const ValueKey('dm_message_area'),
      behavior: HitTestBehavior.opaque,
      onTap: _dismissInput,
      child: _messageListBody(topInset),
    );
  }

  Widget _messageListBody(double topInset) {
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
    if (_msgs.isEmpty) {
      return Center(
        child: EmptyState(
          compact: true,
          icon: Icons.waving_hand_rounded,
          title: '还没有聊天记录',
          message: '发个表情或说说近况，先打个招呼吧',
        ),
      );
    }
    return ListView.builder(
      controller: _scroll,
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      padding: EdgeInsets.fromLTRB(
        AppSpace.gutter,
        topInset + 72,
        AppSpace.gutter,
        AppSpace.x3,
      ),
      itemCount: _msgs.length + (_typing ? 1 : 0) + (_hasMore ? 1 : 0),
      itemBuilder: (_, i) {
        if (i == _msgs.length && _typing) return _typingBubble();
        if (i == _msgs.length + (_typing ? 1 : 0)) {
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
          children: [if (showTime) _timeDivider(ts), _bubble(m)],
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
    final mine = _isMine(m);
    final content = (m['content'] ?? '') as String;
    final type = (m['msgType'] ?? 'text') as String;
    final isRead = (m['isRead'] ?? 0) == 1;
    final pending = m['_pending'] == true;
    final bubble = Padding(
      key: ValueKey('dm_bubble_${_msgId(m)}_${mine ? 'out' : 'in'}'),
      padding: const EdgeInsets.symmetric(vertical: AppSpace.x1),
      child: Row(
        mainAxisAlignment: mine
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!mine) ...[
            AppAvatar(
              url: widget.peerAvatar.isEmpty
                  ? avatarUrlOf(widget.peerId)
                  : avatarUrl(widget.peerAvatar),
              name: widget.peerName,
              size: 32,
              verified:
                  widget.peerVerified ||
                  widget.peerVerifiedLabel.trim().isNotEmpty,
              isAi:
                  widget.peerIsAi ||
                  widget.peerVerifiedLabel.trim().toUpperCase() == 'AI',
              frameUrl: frameUrlOf(widget.peerFrameId),
            ),
            const SizedBox(width: AppSpace.x2),
          ],
          Flexible(
            child: Column(
              crossAxisAlignment: mine
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              children: [
                _bubbleBody(type, content, mine, m: m),
                const SizedBox(height: 3),
                if (mine)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        pending
                            ? Icons.schedule_rounded
                            : (isRead
                                  ? Icons.done_all_rounded
                                  : Icons.done_rounded),
                        size: 12,
                        color: const Color(AppColors.textTertiary),
                      ),
                      const SizedBox(width: 3),
                      Text(
                        pending ? '发送中…' : (isRead ? '已读' : '未读'),
                        style: AppType.micro.copyWith(
                          color: const Color(AppColors.textTertiary),
                          fontSize: 10.5,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    return _BubbleEntrance(
      key: ValueKey(
        'b_${m['id'] ?? ''}_${_tsOf(m['created'])}_${content.hashCode}',
      ),
      animate: m['_fresh'] == true,
      child: KeyedSubtree(
        key: m['_key'] as Key?,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onLongPressStart: (details) =>
              _showMessageMenu(m, details.globalPosition),
          child: Opacity(
            opacity: m['_flyDone'] == false ? 0 : 1,
            child: bubble,
          ),
        ),
      ),
    );
  }

  Widget _typingBubble() {
    return _BubbleEntrance(
      key: const ValueKey('dm_typing_bubble'),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpace.x1),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppAvatar(
              url: widget.peerAvatar.isEmpty
                  ? avatarUrlOf(widget.peerId)
                  : avatarUrl(widget.peerAvatar),
              name: widget.peerName,
              size: 32,
              verified:
                  widget.peerVerified ||
                  widget.peerVerifiedLabel.trim().isNotEmpty,
              isAi:
                  widget.peerIsAi ||
                  widget.peerVerifiedLabel.trim().toUpperCase() == 'AI',
              frameUrl: frameUrlOf(widget.peerFrameId),
            ),
            const SizedBox(width: AppSpace.x2),
            Container(
              height: 36,
              padding: const EdgeInsets.symmetric(horizontal: 13),
              decoration: BoxDecoration(
                color: const Color(AppColors.elevated),
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(AppRadius.xs),
                  topRight: const Radius.circular(AppRadius.md),
                  bottomLeft: const Radius.circular(AppRadius.md),
                  bottomRight: const Radius.circular(AppRadius.md),
                ),
              ),
              alignment: Alignment.center,
              child: const _TypewriterDots(),
            ),
          ],
        ),
      ),
    );
  }

  /// 流萤表情媒体路径（含 0.9.48 及以前发出的 128 PNG 历史路径）。
  bool _isLiuyingEmojiPath(String path) =>
      path.contains('emoji_official/liuying/ly') &&
      (path.endsWith('.webp') || path.endsWith('.png'));

  Widget _bubbleBody(
    String type,
    String content,
    bool mine, {
    Map<String, dynamic>? m,
  }) {
    final bg = mine
        ? const Color(AppColors.accent)
        : const Color(AppColors.elevated);
    final fg = mine
        ? const Color(AppColors.onAccent)
        : const Color(AppColors.textPrimary);
    switch (type) {
      case 'image':
        final renderPath = upgradeEmojiMediaPath(content);
        final isEmoji = _isLiuyingEmojiPath(renderPath);
        return ClipRRect(
          borderRadius: AppRadius.rMd,
          child: GestureDetector(
            onTap: () => _previewImage(_fullUrl(renderPath)),
            child: BlurUpImage(
              url: _fullUrl(renderPath),
              width: 180,
              height: 180,
              fit: isEmoji ? BoxFit.contain : BoxFit.cover,
              cacheWidth: 540,
              borderRadius: 14,
              transparentBackground: isEmoji,
              placeholder: isEmoji
                  ? const Center(
                      child: Icon(
                        Icons.broken_image_outlined,
                        color: Color(AppColors.textTertiary),
                        size: 20,
                      ),
                    )
                  : Container(
                      width: 180,
                      height: 180,
                      color: const Color(AppColors.card),
                      alignment: Alignment.center,
                      child: const Icon(
                        Icons.broken_image_outlined,
                        color: Color(AppColors.textTertiary),
                        size: 24,
                      ),
                    ),
            ),
          ),
        );
      case 'video':
        return GestureDetector(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => _DmVideoPlayer(url: _fullUrl(content)),
            ),
          ),
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
                  child: const Icon(
                    Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 28,
                  ),
                ),
                Positioned(
                  left: AppSpace.x3,
                  bottom: AppSpace.x3,
                  child: Row(
                    children: [
                      const Icon(
                        Icons.videocam_rounded,
                        size: 13,
                        color: Color(AppColors.textTertiary),
                      ),
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
            horizontal: AppSpace.x3 + 2,
            vertical: AppSpace.x3,
          ),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(mine ? AppRadius.md : AppRadius.xs),
              topRight: Radius.circular(mine ? AppRadius.xs : AppRadius.md),
              bottomLeft: const Radius.circular(AppRadius.md),
              bottomRight: const Radius.circular(AppRadius.md),
            ),
          ),
          child: m?['_stream'] == true
              ? KeyedSubtree(
                  key: ValueKey('dm_stream_${m?['id'] ?? ''}'),
                  child: _streamingText(content, intOf(m?['_shown']), fg),
                )
              : TextEmojiText(content, style: AppType.body.copyWith(color: fg)),
        );
    }
  }

  /// 流式文本：已揭开的正文 + 尾部 2 字 4px 模糊 + 尾光标。
  Widget _streamingText(String full, int shown, Color fg) {
    final n = shown.clamp(0, full.length);
    final tail = n >= 5 ? 2 : 0;
    final head = full.substring(0, n - tail);
    final tailText = full.substring(n - tail, n);
    return Text.rich(
      TextSpan(
        style: AppType.body.copyWith(color: fg),
        children: [
          TextSpan(text: head),
          if (tailText.isNotEmpty)
            TextSpan(
              text: tailText,
              style: TextStyle(
                foreground: (Paint()
                  ..color = fg
                  ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4)),
              ),
            ),
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: _StreamCaret(color: fg),
          ),
        ],
      ),
    );
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
                  AppSpace.x3,
                  AppSpace.x2,
                  AppSpace.x3,
                  AppSpace.x2 + 2,
                ),
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
        ? Uri.parse('https://maps.apple.com/?ll=$lat,$lng&q=$q')
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
    final kind = (card['kind'] ?? '').toString();
    if (kind == 'app') return _appCardBubble(card);
    if (kind == 'post') return _postCardBubble(card);
    final name = (card['name'] ?? '') as String;
    final avatar = (card['avatar'] ?? '') as String;
    final uid = (card['id'] ?? '') as String;
    return GestureDetector(
      onTap: () {
        if (uid.isNotEmpty) {
          Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => UserProfilePage(uid: uid)));
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
            AppAvatar(
              url: avatar.isEmpty ? avatarUrlOf(uid) : avatarUrl(avatar),
              name: name,
              size: 40,
              verified:
                  verifiedOf(card['verified']) ||
                  (card['verifiedLabel'] ?? '').toString().trim().isNotEmpty,
              isAi:
                  boolOf(card['isAi']) ||
                  (card['verifiedLabel'] ?? '')
                          .toString()
                          .trim()
                          .toUpperCase() ==
                      'AI',
            ),
            const SizedBox(width: AppSpace.x2 + 2),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(kind == 'user' ? '主页分享' : '推荐名片', style: AppType.micro),
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
                    style: AppType.micro.copyWith(
                      color: const Color(AppColors.accent),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _postCardBubble(Map<String, dynamic> card) {
    final postId = (card['postId'] ?? '').toString();
    final title = (card['title'] ?? '帖子').toString();
    final excerpt = (card['excerpt'] ?? '').toString();
    final cover = (card['cover'] ?? '').toString();
    final author = (card['authorName'] ?? '').toString();
    final note = (card['note'] ?? '').toString();
    return GestureDetector(
      onTap: () {
        if (postId.isNotEmpty) {
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => PostDetailPage(postId: postId)),
          );
        }
      },
      child: Container(
        width: 236,
        decoration: BoxDecoration(
          color: const Color(AppColors.elevated),
          borderRadius: AppRadius.rMd,
          border: Border.all(color: const Color(AppColors.border)),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (cover.isNotEmpty)
              SizedBox(
                height: 108,
                width: double.infinity,
                child: CachedNetworkImage(
                  imageUrl: _fullUrl(cover),
                  fit: BoxFit.cover,
                  errorWidget: (_, _, _) => Container(
                    color: const Color(AppColors.card),
                    child: const Icon(Icons.article_rounded, size: 26),
                  ),
                ),
              )
            else
              Container(
                height: 54,
                width: double.infinity,
                color: const Color(AppColors.card),
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: const Icon(Icons.article_rounded, size: 22),
              ),
            Padding(
              padding: const EdgeInsets.all(AppSpace.x3),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.tag_rounded,
                        size: 12,
                        color: Color(AppColors.accent),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '帖子分享',
                        style: AppType.micro.copyWith(
                          color: const Color(AppColors.accent),
                        ),
                      ),
                      if (author.isNotEmpty) ...[
                        const Spacer(),
                        Text(
                          author,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppType.micro.copyWith(fontSize: 9.5),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 5),
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.body.copyWith(
                      fontWeight: FontWeight.w700,
                      height: 1.35,
                    ),
                  ),
                  if (excerpt.isNotEmpty && excerpt != title) ...[
                    const SizedBox(height: 5),
                    Text(
                      excerpt,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.micro.copyWith(height: 1.45),
                    ),
                  ],
                  if (note.isNotEmpty) ...[
                    const SizedBox(height: 7),
                    Text(
                      note,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.micro.copyWith(
                        height: 1.4,
                        color: const Color(AppColors.textSecondary),
                      ),
                    ),
                  ],
                  const SizedBox(height: 7),
                  Text(
                    '点击查看帖子详情',
                    style: AppType.micro.copyWith(
                      color: const Color(AppColors.accent),
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _appCardBubble(Map<String, dynamic> card) {
    final appId = (card['appId'] ?? '').toString();
    final name = (card['name'] ?? '应用').toString();
    final icon = (card['icon'] ?? '').toString();
    final platform = (card['platform'] ?? '').toString();
    final pkg = (card['packageType'] ?? '').toString().toUpperCase();
    final version = (card['version'] ?? '').toString();
    final note = (card['note'] ?? '').toString();
    final platLabel =
        {
          'ios': 'iOS',
          'android': 'Android',
          'harmony': '鸿蒙',
          'windows': 'Windows',
        }[platform.toLowerCase()] ??
        platform;
    return GestureDetector(
      onTap: () {
        if (appId.isNotEmpty) {
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => AppDetailPage(appId: appId)),
          );
        }
      },
      child: Container(
        width: 230,
        padding: const EdgeInsets.all(AppSpace.x3),
        decoration: BoxDecoration(
          color: const Color(AppColors.elevated),
          borderRadius: AppRadius.rMd,
          border: Border.all(color: const Color(AppColors.border)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    color: const Color(AppColors.card),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: icon.isEmpty
                      ? const Icon(Icons.apps_rounded)
                      : CachedNetworkImage(
                          imageUrl: _fullUrl(icon),
                          fit: BoxFit.cover,
                          errorWidget: (_, _, _) =>
                              const Icon(Icons.apps_rounded),
                        ),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '应用分享',
                        style: AppType.micro.copyWith(
                          color: const Color(AppColors.accent),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppType.body.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 5,
              runSpacing: 4,
              children: [
                if (platLabel.isNotEmpty) _cardChip(platLabel),
                if (pkg.isNotEmpty) _cardChip(pkg),
                if (version.isNotEmpty) _cardChip('v$version'),
              ],
            ),
            if (note.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                note,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: AppType.micro.copyWith(height: 1.5),
              ),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(
                  Icons.touch_app_rounded,
                  size: 12,
                  color: Color(AppColors.accent),
                ),
                const SizedBox(width: 3),
                Text(
                  '点击查看应用详情',
                  style: AppType.micro.copyWith(
                    color: const Color(AppColors.accent),
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _cardChip(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(AppColors.card),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(AppColors.border)),
      ),
      child: Text(text, style: AppType.micro.copyWith(fontSize: 9.5)),
    );
  }

  /// 长按消息菜单：从手指落点浮出，背景半透，带一次轻微过冲。
  Future<void> _showMessageMenu(
    Map<String, dynamic> message,
    Offset origin,
  ) async {
    final content = (message['content'] ?? '').toString();
    if (content.isEmpty) return;
    HapticFeedback.mediumImpact();
    final overlayContext = Navigator.of(context).overlay?.context ?? context;
    final size = MediaQuery.sizeOf(overlayContext);
    final menuWidth = math.min(196.0, size.width - 24);
    final menuHeight = 108.0;
    final left = (origin.dx - menuWidth / 2).clamp(
      12.0,
      math.max(12.0, size.width - menuWidth - 12),
    );
    final top = origin.dy > size.height * 0.56
        ? (origin.dy - menuHeight - 12).clamp(
            80.0,
            math.max(80.0, size.height - menuHeight - 32),
          )
        : (origin.dy + 14).clamp(
            80.0,
            math.max(80.0, size.height - menuHeight - 32),
          );
    final align = Alignment(
      ((origin.dx / size.width) * 2 - 1).clamp(-1.0, 1.0),
      ((origin.dy / size.height) * 2 - 1).clamp(-1.0, 1.0),
    );
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '关闭消息菜单',
      barrierColor: Colors.black.withValues(alpha: 0.5),
      transitionDuration: const Duration(milliseconds: 240),
      pageBuilder: (ctx, _, _) {
        return Material(
          type: MaterialType.transparency,
          child: Stack(
            children: [
              Positioned(
                left: left.toDouble(),
                top: top.toDouble(),
                width: menuWidth,
                child: _MessageMenuCard(
                  onCopy: () async {
                    await Clipboard.setData(ClipboardData(text: content));
                    if (ctx.mounted) Navigator.of(ctx).pop();
                    if (mounted) showAppToast(context, '已复制');
                  },
                  onCancel: () {
                    if (ctx.mounted) Navigator.of(ctx).pop();
                  },
                ),
              ),
            ],
          ),
        );
      },
      transitionBuilder: (ctx, animation, _, child) {
        final scale = TweenSequence<double>([
          TweenSequenceItem(
            tween: Tween(
              begin: 0.84,
              end: 1.045,
            ).chain(CurveTween(curve: Curves.easeOutCubic)),
            weight: 58,
          ),
          TweenSequenceItem(
            tween: Tween(
              begin: 1.045,
              end: 1.0,
            ).chain(CurveTween(curve: Curves.easeOut)),
            weight: 42,
          ),
        ]).animate(animation);
        return FadeTransition(
          opacity: animation,
          child: ScaleTransition(scale: scale, alignment: align, child: child),
        );
      },
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
                child: Text(
                  '图片加载失败',
                  style: AppType.bodySm.copyWith(color: Colors.white),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 输入栏：胶囊输入框 + 加号（QQ 式面板）+ 薄荷发送钮。
  ///
  /// 语音模式不是整块替换：文字输入框本身收拢成圆形语音键，
  /// 表情和发送钮按先后顺序让位；切回文字时反向展开。
  Widget _inputBar() {
    final emojiOpen = _panel == _PanelMode.emoji;
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(
          AppSpace.x3,
          AppSpace.x2,
          AppSpace.x3,
          AppSpace.x2,
        ),
        decoration: const BoxDecoration(
          color: Color(AppColors.bg),
          border: Border(top: BorderSide(color: Color(AppColors.hairline))),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            const fixed =
                36 + AppSpace.x2 + (AppSpace.x1 + 36) + 36 + AppSpace.x1 + 36;
            final composerMax = math.max(72.0, constraints.maxWidth - fixed);
            final composerW = _voiceMode ? 36.0 : composerMax;
            return Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // 更多功能：打开时旋转成 ×
                PressableScale(
                  onTap: _togglePanel,
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: const Color(AppColors.elevated),
                      shape: BoxShape.circle,
                      border: Border.all(color: const Color(AppColors.border)),
                    ),
                    child: AnimatedRotation(
                      turns: _panel == _PanelMode.more ? 0.125 : 0,
                      duration: AppMotion.base,
                      curve: AppMotion.standard,
                      child: Icon(
                        Icons.add_rounded,
                        size: 20,
                        color: _panel == _PanelMode.more
                            ? const Color(AppColors.textPrimary)
                            : const Color(AppColors.accent),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: AppSpace.x2),
                // 输入框 / 语音圆钮是同一个容器，宽度和内容一起变形
                AnimatedContainer(
                  duration: const Duration(milliseconds: 280),
                  curve: Curves.easeOutCubic,
                  width: composerW,
                  height: _voiceMode ? 36 : null,
                  constraints: const BoxConstraints(minHeight: 36),
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: const Color(AppColors.elevated),
                    borderRadius: AppRadius.rPill,
                    border: Border.all(
                      color: _inputFocus.hasFocus && !_voiceMode
                          ? const Color(AppColors.accent)
                                .withValues(alpha: 0.32)
                          : const Color(AppColors.border),
                    ),
                  ),
                  child: Stack(
                    clipBehavior: Clip.hardEdge,
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpace.x4,
                          vertical: AppSpace.x2 + 1,
                        ),
                        child: IgnorePointer(
                          ignoring: _voiceMode,
                          child: Opacity(
                            opacity: _voiceMode ? 0 : 1,
                            child: TextField(
                              controller: _input,
                              focusNode: _inputFocus,
                              minLines: 1,
                              maxLines: _voiceMode ? 1 : 4,
                              cursorColor: const Color(AppColors.accent),
                              style: AppType.body,
                              decoration: InputDecoration(
                                hintText: '说点什么…',
                                hintStyle: AppType.body.copyWith(
                                  color: const Color(AppColors.textTertiary),
                                ),
                                filled: false,
                                isCollapsed: true,
                                contentPadding: EdgeInsets.zero,
                                border: InputBorder.none,
                                enabledBorder: InputBorder.none,
                                focusedBorder: InputBorder.none,
                              ),
                              onChanged: (_) => setState(() {}),
                              onTap: _closePanel,
                              onSubmitted: (_) => _send(),
                            ),
                          ),
                        ),
                      ),
                      // 发送时文字先向上收拢淡出，再真正从输入框消失
                      if (_ghostText != null && _ghostText!.isNotEmpty)
                        Positioned(
                          left: AppSpace.x4,
                          right: AppSpace.x4,
                          top: AppSpace.x2 + 1,
                          child: IgnorePointer(
                            child: AnimatedBuilder(
                              animation: _ghostAnim!,
                              builder: (_, child) {
                                final v = Curves.easeInCubic.transform(
                                  _ghostAnim!.value.clamp(0.0, 1.0),
                                );
                                return Transform.translate(
                                  offset: Offset(0, -11 * v),
                                  child: Transform.scale(
                                    scale: 1 - 0.07 * v,
                                    alignment: Alignment.bottomLeft,
                                    child: Opacity(
                                      opacity: (1 - v).clamp(0.0, 1.0),
                                      child: child,
                                    ),
                                  ),
                                );
                              },
                              child: Text(
                                _ghostText!,
                                maxLines: 4,
                                overflow: TextOverflow.ellipsis,
                                style: AppType.body,
                              ),
                            ),
                          ),
                        ),
                      if (_voiceMode)
                        Positioned.fill(
                          child: GestureDetector(
                            key: const ValueKey('dm_voice_hold'),
                            behavior: HitTestBehavior.opaque,
                            onLongPressStart: _onVoicePressStart,
                            onLongPressMoveUpdate: _onVoiceMove,
                            onLongPressEnd: _onVoicePressEnd,
                            onLongPressCancel: _onVoiceCancel,
                            child: const Center(
                              child: Icon(
                                Icons.mic_rounded,
                                size: 19,
                                color: Color(AppColors.accent),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                // 表情：先于发送钮让位，形成有先后的收拢
                AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOutCubic,
                  width: _voiceMode ? 0 : AppSpace.x1 + 36,
                  child: AnimatedOpacity(
                    opacity: _voiceMode ? 0 : 1,
                    duration: const Duration(milliseconds: 120),
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: SizedBox(
                        width: 36,
                        height: 36,
                        child: PressableScale(
                          onTap: _toggleEmoji,
                          child: Icon(
                            emojiOpen
                                ? Icons.keyboard_alt_outlined
                                : Icons.emoji_emotions_outlined,
                            size: 22,
                            color: emojiOpen
                                ? const Color(AppColors.accent)
                                : const Color(AppColors.textSecondary),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                if (_voiceMode) const Spacer(),
                // 语音/文字切换：文字态是麦克风，语音态是键盘
                PressableScale(
                  key: const ValueKey('dm_voice_toggle'),
                  onTap: _toggleVoiceMode,
                  child: SizedBox(
                    width: 36,
                    height: 36,
                    child: AnimatedSwitcher(
                      duration: AppMotion.fast,
                      child: Icon(
                        _voiceMode
                            ? Icons.keyboard_alt_outlined
                            : Icons.keyboard_voice_outlined,
                        key: ValueKey(_voiceMode),
                        size: 21,
                        color: _voiceMode
                            ? const Color(AppColors.accent)
                            : const Color(AppColors.textSecondary),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: AppSpace.x1),
                // 发送：有内容才亮起，语音态最后让位
                AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  width: _voiceMode ? 0 : 36,
                  child: AnimatedOpacity(
                    opacity: _voiceMode ? 0 : 1,
                    duration: const Duration(milliseconds: 140),
                    child: ValueListenableBuilder<TextEditingValue>(
                      valueListenable: _input,
                      builder: (_, v, child) {
                        final on = v.text.trim().isNotEmpty;
                        return PressableScale(
                          onTap: _send,
                          child: AnimatedContainer(
                            duration: AppMotion.base,
                            curve: AppMotion.standard,
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              color: on
                                  ? const Color(AppColors.accent)
                                  : const Color(AppColors.elevated),
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: on
                                    ? const Color(AppColors.accent)
                                    : const Color(AppColors.border),
                              ),
                              boxShadow: AppEffects.accentGlow(
                                opacity: on ? 0.28 : 0,
                              ),
                            ),
                            child: Icon(
                              Icons.send_rounded,
                              size: 17,
                              color: on
                                  ? const Color(AppColors.onAccent)
                                  : const Color(AppColors.textTertiary),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// 按住说话时从输入栏上方展开的提示，收起比展开略快。
  Widget _voiceHoldHint() {
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Positioned(
      left: AppSpace.gutter,
      right: AppSpace.gutter,
      bottom: bottom + 62,
      child: IgnorePointer(
        ignoring: !_voiceHintVisible,
        child: AnimatedSlide(
          offset: _voiceHintVisible ? Offset.zero : const Offset(0, 0.42),
          duration: _voiceHintVisible
              ? const Duration(milliseconds: 150)
              : const Duration(milliseconds: 95),
          curve: _voiceHintVisible ? Curves.easeOutCubic : Curves.easeInCubic,
          child: AnimatedOpacity(
            opacity: _voiceHintVisible ? 1 : 0,
            duration: _voiceHintVisible
                ? const Duration(milliseconds: 130)
                : const Duration(milliseconds: 80),
            child: Container(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
              decoration: BoxDecoration(
                color: const Color(AppColors.elevated).withValues(alpha: 0.94),
                borderRadius: BorderRadius.circular(AppRadius.lg),
                border: Border.all(color: const Color(AppColors.border)),
                boxShadow: AppEffects.overlay,
              ),
              child: Row(
                children: [
                  Icon(
                    _voiceCancel ? Icons.close_rounded : Icons.mic_rounded,
                    size: 18,
                    color: _voiceCancel
                        ? const Color(AppColors.heart)
                        : const Color(AppColors.accent),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _voiceCancel
                              ? '松开取消'
                              : (_voiceListening ? '松开发送' : '按住说话'),
                          style: AppType.bodySm.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          _voiceCancel
                              ? '上滑已触发取消'
                              : (_voiceDraft.isEmpty ? '正在听…' : _voiceDraft),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: AppType.micro.copyWith(
                            color: const Color(AppColors.textSecondary),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _voiceCancel ? '松手' : '上滑取消',
                    style: AppType.micro.copyWith(
                      color: const Color(AppColors.textTertiary),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 新消息气泡入场：从略小撑开，末端 1.8% 过冲后立刻停稳。
class _BubbleEntrance extends StatefulWidget {
  const _BubbleEntrance({super.key, required this.child, this.animate = true});

  final Widget child;
  final bool animate;

  @override
  State<_BubbleEntrance> createState() => _BubbleEntranceState();
}

class _BubbleEntranceState extends State<_BubbleEntrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 250),
    value: widget.animate ? 0 : 1,
  );
  late final Animation<double> _scale = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween(
        begin: 0.86,
        end: 1.018,
      ).chain(CurveTween(curve: Curves.easeOutCubic)),
      weight: 62,
    ),
    TweenSequenceItem(
      tween: Tween(
        begin: 1.018,
        end: 1.0,
      ).chain(CurveTween(curve: Curves.easeOut)),
      weight: 38,
    ),
  ]).animate(_c);
  late final Animation<double> _fade = CurvedAnimation(
    parent: _c,
    curve: Curves.easeOut,
  );
  late final Animation<double> _lift = Tween<double>(
    begin: 7,
    end: 0,
  ).animate(CurvedAnimation(parent: _c, curve: Curves.easeOutCubic));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!widget.animate) {
      _c.value = 1;
    } else if (MediaQuery.disableAnimationsOf(context)) {
      _c.value = 1;
    } else if (_c.value == 0) {
      _c.forward();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, child) => Opacity(
        opacity: _fade.value,
        child: Transform.translate(
          offset: Offset(0, _lift.value),
          child: Transform.scale(
            scale: _scale.value,
            alignment: Alignment.bottomCenter,
            child: child,
          ),
        ),
      ),
      child: widget.child,
    );
  }
}

/// “正在输入”的三点不是整体闪烁：同一时刻只亮一个点，按 0→1→2 硬切循环。
/// 流式尾光标：1 秒一亮的硬切，不做渐变呼吸。
class _StreamCaret extends StatefulWidget {
  final Color color;
  const _StreamCaret({required this.color});

  @override
  State<_StreamCaret> createState() => _StreamCaretState();
}

class _StreamCaretState extends State<_StreamCaret>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1000),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) => Opacity(
        opacity: _c.value < 0.55 ? 1 : 0,
        child: Text(
          '▍',
          style: TextStyle(
            color: widget.color,
            fontSize: 13,
            height: 1.15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _TypewriterDots extends StatefulWidget {
  const _TypewriterDots();

  @override
  State<_TypewriterDots> createState() => _TypewriterDotsState();
}

class _TypewriterDotsState extends State<_TypewriterDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1080),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) {
        final active = (_c.value * 3).floor().clamp(0, 2);
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < 3; i++) ...[
              if (i > 0) const SizedBox(width: 5),
              Opacity(
                // 只亮当前点；另外两个留极淡的槽位，保证“依次跳”的
                // 节奏同时不出现三点齐亮或整体呼吸。
                opacity: i == active ? 1 : 0.16,
                child: Container(
                  width: 5,
                  height: 5,
                  decoration: const BoxDecoration(
                    color: Color(AppColors.textSecondary),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

/// 长按菜单卡片：半透玻璃，下面列表仍隐约可见。
class _MessageMenuCard extends StatelessWidget {
  const _MessageMenuCard({required this.onCopy, required this.onCancel});

  final VoidCallback onCopy;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          decoration: BoxDecoration(
            color: const Color(AppColors.elevated).withValues(alpha: 0.86),
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: Border.all(color: const Color(AppColors.border)),
            boxShadow: AppEffects.overlay,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _menuRow(icon: Icons.copy_rounded, label: '复制', onTap: onCopy),
              const Divider(height: 1, color: Color(AppColors.hairline)),
              _menuRow(icon: Icons.close_rounded, label: '取消', onTap: onCancel),
            ],
          ),
        ),
      ),
    );
  }

  Widget _menuRow({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        height: 53,
        child: Row(
          children: [
            const SizedBox(width: 16),
            Icon(icon, size: 18, color: const Color(AppColors.textSecondary)),
            const SizedBox(width: 11),
            Text(
              label,
              style: AppType.body.copyWith(fontWeight: FontWeight.w500),
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
          flags: InteractiveFlag.none,
        ), // 纯展示，禁手势
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://webrd0{s}.is.autonavi.com/appmaptile?lang=zh_cn&size=1&scale=1&style=8&x={x}&y={y}&z={z}',
          subdomains: const ['1', '2', '3', '4'],
          userAgentPackageName: 'com.liuying.community',
        ),
        MarkerLayer(
          markers: [
            Marker(
              point: LatLng(lat, lng),
              width: 34,
              height: 34,
              child: const Icon(
                Icons.location_pin,
                color: Color(AppColors.heart),
                size: 34,
              ),
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
      ..initialize()
          .then((_) {
            if (!mounted) return;
            setState(() {});
            _vc?.play();
          })
          .catchError((e) {
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
      // 键盘/面板都交给 InputPanelHost 统一占位：
      // 如果 Scaffold 先按键盘 inset 缩一次，面板再占一次，输入栏会被顶高一截。
      resizeToAvoidBottomInset: false,
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
