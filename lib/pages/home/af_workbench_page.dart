import 'dart:async';

import 'package:characters/characters.dart';

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'dart:typed_data';

import 'package:flutter/gestures.dart';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:http/http.dart' as http;

import '../../api/client.dart';
import '../../widgets/image_box.dart';
import 'af_effort_card.dart';
import 'af_palette.dart';
import 'af_providers.dart';

import 'package:image_picker/image_picker.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../config.dart';
import '../../widgets/ai_avatar.dart';
import '../../widgets/input_panel_host.dart';
import 'af_billing_page.dart';
import 'af_memory_page.dart';
import '../../design/components.dart';
import '../../services/secure_store.dart';
import '../../services/local_tools.dart';
import '../../services/secure_screen.dart';
import '../../services/secure_links.dart';

/// 二楼 · 小萤 Agent。
///
/// Agent 不是聊天皮肤：给目标，先拆步骤，再连续调工具，最后交付产物。
///
/// 本机轻执行（文件/网络/文本）直接跑，重任务走云沙箱。
/// 额度按豆包双窗口计：5 小时 / 7 天 / 月，三档同时扣取最小。
/// 贴底跟随判定：只有「用户手势」滚动才改状态；程序滚动（动画/追加）保持原值。
/// 距底部 <= 56px 视为贴在最新位置。
bool afStickAfterScroll({
  required double maxExtent,
  required double pixels,
  required bool userScrolling,
  required bool current,
}) {
  if (!userScrolling) return current;
  return (maxExtent - pixels) <= 56;
}

class AfWorkbenchPage extends StatefulWidget {
  const AfWorkbenchPage({super.key, this.client});

  /// 仅用于渲染验证时注入；正式运行不传，用默认 client。
  final http.Client? client;

  @override
  State<AfWorkbenchPage> createState() => _AfWorkbenchPageState();
}

/// 一次最多发 9 张图 + 9 个文件
const int kAfMaxImgs = 9;
const int kAfMaxFiles = 9;

class _Attach {
  _Attach({
    required this.name,
    required this.size,
    this.url,
    this.local,
    this.mime,
  });
  bool get isImg => (mime ?? '').startsWith('image/');
  final String name;
  final int size;
  String? url; // 上传成功后的地址
  Uint8List? local; // 本地预览字节
  String? mime;
  bool uploading = false;
}

String _mimeFromName(String name) {
  final ext = name.split('.').last.toLowerCase();
  switch (ext) {
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'png':
      return 'image/png';
    case 'webp':
      return 'image/webp';
    case 'gif':
      return 'image/gif';
    case 'bmp':
      return 'image/bmp';
    case 'heic':
    case 'heif':
      return 'image/heic';
    case 'pdf':
      return 'application/pdf';
    case 'txt':
    case 'md':
    case 'json':
    case 'csv':
    case 'log':
      return 'text/plain';
  }
  return 'application/octet-stream';
}

bool _isJpegBytes(Uint8List b) => b.length > 2 && b[0] == 0xFF && b[1] == 0xD8;

bool _isHeicBytes(Uint8List b) {
  if (b.length < 12) return false;
  // ISO BMFF: ....ftypheic / heix / mif1
  if (b[4] != 0x66 || b[5] != 0x74 || b[6] != 0x79 || b[7] != 0x70) {
    return false;
  }
  final brand = String.fromCharCodes(b.sublist(8, 12)).toLowerCase();
  return brand == 'heic' ||
      brand == 'heix' ||
      brand == 'heif' ||
      brand == 'mif1' ||
      brand == 'msf1';
}

/// 附件图片名规范化：图片扩展名统一小写，无扩展名的 JPEG 补 .jpg。
String afImageName(String name, Uint8List bytes) {
  final low = name.toLowerCase();
  if (RegExp(r'\.(jpg|jpeg|png|webp|gif)$').hasMatch(low)) {
    // 服务端按扩展名给 Content-Type；IMG_0001.JPG 这种大写会让模型收到
    // application/octet-stream，统一成小写，避免被当成“格式不支持”。
    return name.replaceFirstMapped(
      RegExp(r'\.(JPG|JPEG|PNG|WEBP|GIF)$', caseSensitive: false),
      (m) => m.group(0)!.toLowerCase(),
    );
  }
  if (_isJpegBytes(bytes)) return '$name.jpg';
  return name;
}

String _sizeLabel(int bytes) {
  if (bytes >= 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '$bytes B';
}

Map<String, dynamic> _deliveryMap(dynamic v) {
  if (v is Map<String, dynamic>) return v;
  if (v is Map) return Map<String, dynamic>.from(v);
  return <String, dynamic>{};
}

/// done.files 对账：把本轮已发布、但客户端没收到 tool 事件的文件
/// 补成 publish_file 工具卡。按 URL 去重，避免和已有文件卡重复。
List<Map<String, dynamic>> afDeliveryFileTools(
  dynamic raw,
  Iterable<String> knownUrls,
) {
  final out = <Map<String, dynamic>>[];
  final have = <String>{...knownUrls.where((e) => e.isNotEmpty)};
  if (raw is! List) return out;
  for (final x in raw) {
    final f = _deliveryMap(x);
    final u = (f['url'] ?? '').toString();
    if (u.isEmpty || have.contains(u)) continue;
    have.add(u);
    out.add(<String, dynamic>{
      'id': 'auto_${DateTime.now().microsecondsSinceEpoch}_${out.length}',
      'name': 'publish_file',
      'args': {'path': f['file'] ?? ''},
      'status': 'ok',
      'detail': f,
    });
  }
  return out;
}

({String text, List<_Attach> atts}) _splitUserAtts(String raw) {
  var start = raw.indexOf('\n\n[用户发来附件]');
  if (start < 0) start = raw.indexOf('[用户发来附件]');
  if (start < 0) return (text: raw, atts: const <_Attach>[]);
  final clean = raw.substring(0, start).trim();
  final block = raw.substring(start);
  final atts = <_Attach>[];
  final re = RegExp(r'- \[(图片|文件)\] ([^\n]+?)（(\d+)B）(?:\n\s+(\S+))?');
  for (final m in re.allMatches(block)) {
    final name = (m.group(2) ?? '').trim();
    if (name.isEmpty) continue;
    final url = (m.group(4) ?? '').trim();
    final isImg = m.group(1) == '图片';
    atts.add(
      _Attach(
        name: name,
        size: int.tryParse(m.group(3) ?? '') ?? 0,
        url: url.isEmpty ? null : url,
        mime: isImg ? _mimeFromName(name) : 'application/octet-stream',
      ),
    );
  }
  return (text: clean, atts: atts);
}

class _Msg {
  _Msg({
    required this.role,
    required this.text,
    this.tool,
    this.reasoning = '',
    this.streaming = false,
    this.id = '',
    this.expanded = false,
    this.ms = 0,
    this.created = 0,
    this.atts = const [],
  });
  final String role; // user / ai / tool
  String text;

  /// 用户发出的附件：图片缩略图 / 文件卡在气泡里直接展示
  final List<_Attach> atts;
  String reasoning = '';
  String costText = '';
  int ms;

  /// 服务端 created（秒级时间戳），历史消息用来兜底推算处理时长。
  double created;
  Map<String, dynamic>? tool;

  /// 后端还在生成（切后台/退出后重进，需要续播）
  bool streaming;

  /// 「完整过程」是否展开
  bool expanded;

  /// 思考过程是否展开。默认折叠，只留一行入口；每个会话重新进入也保持折叠。
  bool reasoningOpen = false;

  /// 单个任务阶段是否展开原始参数。
  bool stepOpen = false;

  /// 用户对这条回复的反馈：1 赞 / -1 踩 / 0 未选。
  int feedback = 0;

  /// 工具调用在客户端出现/完成的时间，用来给每一步一个人类可读耗时。
  DateTime? toolStartedAt;
  DateTime? toolEndedAt;

  /// 历史消息 id（用于记住展开状态；流式时由 meta 事件回填）
  String id;
}

/// 一轮对话：AI 消息 + 它期间产生的工具卡（文件卡）
class _Turn {
  _Turn(this.msg);
  final _Msg msg;
  final List<_Msg> tools = [];

  List<_Msg> get files => tools
      .where(
        (t) =>
            (t.tool?['name'] == 'publish_file') && (t.tool?['status'] == 'ok'),
      )
      .toList();
}

/// 模型写在正文末尾的 [[AF_SUMMARY]]…[[/AF_SUMMARY]] 拆分
class AfSummaryParts {
  const AfSummaryParts(this.summary, this.body);
  final String summary;
  final String body;
}

AfSummaryParts afSplitSummary(String text) {
  const open = '[[AF_SUMMARY]]';
  const close = '[[/AF_SUMMARY]]';
  final i = text.indexOf(open);
  if (i < 0) return AfSummaryParts('', text);
  final j = text.indexOf(close, i + open.length);
  final body =
      (text.substring(0, i) + (j >= 0 ? text.substring(j + close.length) : ''))
          .trim();
  final sum = text.substring(i + open.length, j >= 0 ? j : text.length).trim();
  return AfSummaryParts(sum, body);
}

/// 模型没写总结块时的兜底摘要：取第一段结论性文字（跳过列表/代码），最多 140 字
String afFallbackSummary(String body) {
  final t = body.trim();
  if (t.isEmpty) return '';
  final paras = t
      .split(RegExp(r'\n\s*\n'))
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();
  var pick = '';
  for (final p in paras) {
    final firstLine = p.split('\n').first.trim();
    final isList = RegExp(r'^([-*+]|\d+[.)])\s').hasMatch(firstLine);
    if (!isList && !p.startsWith('```')) {
      pick = p;
      break;
    }
  }
  if (pick.isEmpty) pick = paras.isEmpty ? t : paras.first;
  pick = pick.replaceAll(RegExp(r'^#+\s*'), '').replaceAll('**', '');
  if (pick.length > 140) pick = pick.substring(0, 140) + '…';
  return pick;
}

class _AfWorkbenchPageState extends State<AfWorkbenchPage>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin, SecureScreenMixin<AfWorkbenchPage> {
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _micReady = false;
  bool _micOn = false;
  final _input = TextEditingController();
  final _scroll = ScrollController();

  /// 是否贴底跟随最新（用户上滑看历史时置 false，滑回底部自动恢复）
  bool _stick = true;

  /// 手指正按在列表上（拖拽/惯性中），此时绝不做任何程序滚动
  bool _touching = false;

  /// 是否处于用户发起的滚动（含惯性），由 UserScrollNotification 维护；
  /// 程序自己的 animateTo/jumpTo 不会触发，避免误判
  bool _userScrolling = false;

  /// 当前正在流式输出的 AI 消息
  _Msg? _activeAi;

  /// 断线续播：轮询后端已落库的内容，本地用打字机追平
  Timer? _resumePoll;
  Timer? _typer;
  String _targetText = '';
  String _targetReason = '';
  bool _resumeDone = false;
  final _msgs = <_Msg>[];
  bool _busy = false;

  /// 哪个会话正在生成（SSE 或轮询续播都算）
  String? _streamConvId;

  /// SSE 断了但后端还在跑：交给轮询续播
  bool _resumeAfterSend = false;

  /// 打字机追平的目标消息（末条可能是工具卡，不能盲目取最后一条）
  _Msg? _typerTarget;
  final _atts = <_Attach>[];

  Map<String, dynamic>? _quota;
  http.Client? _client;
  final FocusNode _inputFocus = FocusNode();
  bool _focused = false;
  bool _attachOpen = false;
  bool _aborted = false;
  String? _token;
  String? _convId;
  int _avatarEpoch = 0;
  String _mode = 'chat'; // chat | work
  String _model = 'deepseek-flash'; // flash | pro
  String _effort = 'medium'; // low|medium|high|xhigh|ultra
  late final http.Client _http = widget.client ?? http.Client();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  /// 抽屉柜式侧滑：抽屉从左侧出来时，主界面整体被推到右边（不是盖上去）
  static const double _drawerW = 318;
  late final AnimationController _drawerCtrl;
  bool get _drawerOpen => _drawerCtrl.value > 0.001;

  void _openDrawer() {
    _loadConvs();
    _drawerCtrl.forward();
  }

  void _closeDrawer() {
    if (_drawerCtrl.value > 0) _drawerCtrl.reverse();
  }

  List<Map<String, dynamic>> _convs = const [];
  String _plan = 'free';
  int _left = 0;

  @override
  void initState() {
    super.initState();
    _drawerCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    );
    _scroll.addListener(_onScroll);
    _inputFocus.addListener(() {
      if (_focused != _inputFocus.hasFocus)
        setState(() => _focused = _inputFocus.hasFocus);
    });
    WidgetsBinding.instance.addObserver(this);
    _boot();
  }

  Future<void> _boot() async {
    final sp = await SharedPreferences.getInstance();
    _token = ApiClient.token;
    final cached = await SecureStore.read(SecureStore.tokenKey);
    if ((_token == null || _token!.isEmpty) &&
        cached != null &&
        cached.isNotEmpty) {
      _token = cached;
      ApiClient.token = cached;
    }
    final savedMode = sp.getString('af_mode');
    final savedModel = sp.getString('af_model');
    final savedEffort = sp.getString('af_effort');
    if (mounted) {
      setState(() {
        if (savedMode == 'chat' || savedMode == 'work') _mode = savedMode!;
        if (savedModel != null && savedModel.trim().isNotEmpty)
          _model = savedModel.trim();
        if (savedEffort != null &&
            AfEffort.all.any((e) => e.key == savedEffort))
          _effort = savedEffort;
      });
    }
    // 三步并行，任何一步慢或失败都不拖住其它
    unawaited(_loadQuota());
    unawaited(_loadHistory());
    unawaited(_loadConvs());
    unawaited(_validateSavedModel());
  }

  /// 自定义模型被删/被停用后，回到内置「快速」，避免选中一个不存在的模型
  Future<void> _validateSavedModel() async {
    if (!afIsByok(_model)) return;
    final parts = _model.split(':');
    var ok = false;
    if (parts.length >= 3) {
      final list = await loadAfProviders();
      ok = list.any(
        (p) =>
            p.id == parts[1] &&
            p.models.any((m) => m.model == parts[2] && m.enabled),
      );
    }
    if (ok || !mounted) return;
    setState(() => _model = 'deepseek-flash');
    final sp = await SharedPreferences.getInstance();
    await sp.setString('af_model', 'deepseek-flash');
  }

  /// 拉最近一次会话的消息，实现「退出再进能看到记录」
  Future<void> _loadHistory() async {
    if (_token == null) return;
    try {
      final r = await _http
          .get(
            Uri.parse('$kApiBase/af/conversations'),
            headers: {'Authorization': 'Bearer $_token'},
          )
          .timeout(const Duration(seconds: 15));
      final j = _asMap(jsonDecode(r.body));
      final list = (j['list'] as List?) ?? const [];
      if (list.isEmpty) return;
      // 上次停留的会话优先；没有则回到最早创建的主对话
      final sp = await SharedPreferences.getInstance();
      final saved = sp.getString('af_conv_id');
      String cid = (saved ?? '').toString();
      if (cid.isEmpty) {
        var oldest = _asMap(list.last);
        for (final e in list) {
          final m = _asMap(e);
          final c1 = _asDouble(m['created']);
          final c0 = _asDouble(oldest['created']);
          if (c1 > 0 && (c0 == 0 || c1 < c0)) oldest = m;
        }
        cid = (oldest['id'] ?? '').toString();
      }
      _convId = cid.isEmpty ? null : cid;
      if (cid.isEmpty) return;
      await _loadChat(cid);
    } catch (_) {}
  }

  /// 某个会话的消息 + 工具卡/文件卡 + 展开状态 + 续播，全走这一套。
  /// 进 App、切换会话都用它，保证前端展示与后端落库完全一致。
  Future<void> _loadChat(String cid) async {
    if (_token == null || cid.isEmpty) return;
    try {
      final expMap = <String, dynamic>{};
      try {
        final sp2 = await SharedPreferences.getInstance();
        final raw = sp2.getString('af_expanded') ?? '{}';
        final j2 = jsonDecode(raw);
        if (j2 is Map) {
          j2.forEach((k, v) => expMap[k.toString()] = v);
        }
      } catch (_) {}
      final rm = await _http
          .get(
            Uri.parse('$kApiBase/af/messages?conv_id=$cid'),
            headers: {'Authorization': 'Bearer $_token'},
          )
          .timeout(const Duration(seconds: 15));
      final jm = _asMap(jsonDecode(rm.body));
      final rows = (jm['list'] as List?) ?? const [];
      final items = (jm['items'] as List?) ?? const [];
      if (rows.isEmpty && items.isEmpty) return;
      final restored = <_Msg>[];
      // 卡片（工具卡/文件卡）按落库时间插回原位，重进后与当时看到的一致
      final pend = <Map<String, dynamic>>[];
      for (final e in items) {
        final it = _asMap(e);
        final p = _asMap(it['payload']);
        if (p.isEmpty) continue;
        pend.add({'t': _asDouble(it['created']), 'p': p});
      }
      pend.sort((a, b) => _asDouble(a['t']).compareTo(_asDouble(b['t'])));
      void drain(double until) {
        while (pend.isNotEmpty && _asDouble(pend.first['t']) <= until) {
          final it = pend.removeAt(0);
          restored.add(_Msg(role: 'tool', text: '', tool: _asMap(it['p'])));
        }
      }

      var lastUserAt = 0.0;
      for (final e in rows) {
        final m = _asMap(e);
        final role = (m['role'] ?? '').toString();
        final text = (m['content'] ?? '').toString();
        final rsn = (m['reasoning'] ?? '').toString();
        final createdAt = _asDouble(m['created']);
        drain(createdAt);
        if (text.isEmpty && rsn.isEmpty) continue;
        final mid2 = (m['id'] ?? '').toString();
        final userParts = role == 'user'
            ? _splitUserAtts(text)
            : (text: text, atts: const <_Attach>[]);
        final computedMs = (role != 'user' && lastUserAt > 0 && createdAt > 0)
            ? ((createdAt - lastUserAt) * 1000).round()
            : 0;
        restored.add(
          _Msg(
            role: role == 'user' ? 'user' : 'ai',
            text: userParts.text,
            atts: userParts.atts,
            reasoning: rsn,
            streaming: (m['status'] ?? '') == 'streaming',
            id: mid2,
            ms: (m['ms'] as num?)?.toInt() ?? computedMs,
            created: createdAt,
            expanded: expMap[mid2] == 1,
          ),
        );
        if (role == 'user') lastUserAt = createdAt;
      }
      drain(1e18);
      if (restored.isEmpty) return;
      setState(() {
        _msgs
          ..clear()
          ..addAll(restored);
      });
      _scrollBottom(force: true);
      // 上次退出时这条还在生成：后端一直在跑并落库，这里用打字机接着播
      _Msg? lastAi;
      for (final m in restored) {
        if (m.role == 'ai') lastAi = m;
      }
      if (lastAi != null && lastAi.streaming) {
        _targetText = lastAi.text;
        _targetReason = lastAi.reasoning;
        _typerTarget = lastAi;
        _startResume();
      }
    } catch (_) {}
  }

  /// 断线续播：后端把生成中的内容持续落库，前端轮询 + 本地打字机追平
  void _startResume() {
    if (_resumePoll != null) return;
    _resumeDone = false;
    _streamConvId = _convId;
    if (mounted) setState(() => _busy = true);
    _ensureTyper();
    _pollResume();
    _resumePoll = Timer.periodic(
      const Duration(milliseconds: 1200),
      (_) => _pollResume(),
    );
  }

  Future<void> _pollResume() async {
    final cid = _convId;
    if (cid == null || _token == null) return;
    try {
      final r = await _http
          .get(
            Uri.parse('$kApiBase/af/messages?conv_id=$cid'),
            headers: {'Authorization': 'Bearer $_token'},
          )
          .timeout(const Duration(seconds: 10));
      final j = _asMap(jsonDecode(r.body));
      final rows = (j['list'] as List?) ?? const [];
      Map<String, dynamic>? lastAi;
      for (final e in rows) {
        final m = _asMap(e);
        if (m['role'] == 'assistant') lastAi = m;
      }
      if (lastAi == null) return;
      _targetText = (lastAi['content'] ?? '').toString();
      _targetReason = (lastAi['reasoning'] ?? '').toString();
      _resumeDone = (lastAi['status'] ?? 'done') != 'streaming';
      final aid = (lastAi['id'] ?? '').toString();
      var idx = aid.isEmpty
          ? -1
          : _msgs.lastIndexWhere((m) => m.role == 'ai' && m.id == aid);
      if (idx >= 0) {
        _typerTarget = _msgs[idx];
        _msgs[idx].streaming = true;
      } else if (aid.isEmpty && _msgs.isNotEmpty && _msgs.last.role == 'ai') {
        _typerTarget = _msgs.last;
        _msgs.last.streaming = true;
      } else {
        final nm = _Msg(
          role: 'ai',
          text: '',
          reasoning: '',
          streaming: true,
          id: aid,
        );
        _typerTarget = nm;
        setState(() => _msgs.add(nm));
      }
      _ensureTyper();
    } catch (_) {}
  }

  void _ensureTyper() {
    if (_typer != null) return;
    _typer = Timer.periodic(const Duration(milliseconds: 24), (_) {
      if (!mounted || _msgs.isEmpty) return;
      final m = _typerTarget ?? _msgs.last;
      if (m.role != 'ai') return;
      var changed = false;
      final totalT = _targetText.characters.length;
      final curT = m.text.characters.length;
      if (curT < totalT) {
        m.text = _targetText.characters
            .take((curT + 3).clamp(0, totalT))
            .toString();
        changed = true;
      }
      final totalR = _targetReason.characters.length;
      final curR = m.reasoning.characters.length;
      if (curR < totalR) {
        m.reasoning = _targetReason.characters
            .take((curR + 6).clamp(0, totalR))
            .toString();
        changed = true;
      }
      if (changed) {
        setState(() {});
        _scrollBottom();
      } else if (_resumeDone) {
        _finishResume();
      }
    });
  }

  void _finishResume() {
    _resumePoll?.cancel();
    _resumePoll = null;
    _typer?.cancel();
    _typer = null;
    for (final m in _msgs) {
      if (m.role == 'ai') m.streaming = false;
    }
    _typerTarget = null;
    _streamConvId = null;
    _busy = false;
    _targetText = '';
    _targetReason = '';
    _resumeDone = false;
    if (mounted) setState(() {});
    _loadQuota();
  }

  static Map<String, dynamic> _asMap(dynamic v) {
    if (v is Map<String, dynamic>) return v;
    if (v is Map) {
      final out = <String, dynamic>{};
      v.forEach((k, val) => out[k.toString()] = val);
      return out;
    }
    return <String, dynamic>{};
  }

  static int _asInt(dynamic v) {
    if (v is int) return v;
    if (v is double) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }

  static double _asDouble(dynamic v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? 0;
    return 0;
  }

  Future<void> _loadConvs() async {
    if (_token == null) return;
    try {
      final r = await _http.get(
        Uri.parse('$kApiBase/af/conversations'),
        headers: {'Authorization': 'Bearer $_token'},
      );
      final j = _asMap(jsonDecode(r.body));
      final list = (j['list'] as List?) ?? const [];
      if (!mounted) return;
      setState(() => _convs = list.map(_asMap).toList());
    } catch (_) {}
  }

  void _newConv() {
    _detachStream();
    _resumePoll?.cancel();
    _resumePoll = null;
    _typer?.cancel();
    _typer = null;
    _resumeDone = false;
    setState(() {
      _convId = null;
      _avatarEpoch++;
      _msgs.clear();
    });
    SharedPreferences.getInstance().then((sp) => sp.remove('af_conv_id'));
    _closeDrawer();
  }

  /// 长按会话：改名 / 置顶 / 删除
  Future<void> _convActions(String id, String title, bool pinned) async {
    final act = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(AfPalette.card),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    color: Color(AfPalette.text2),
                  ),
                ),
              ),
            ),
            _actRow(
              ctx,
              Icons.edit_outlined,
              '修改名称',
              () => Navigator.pop(ctx, 'rename'),
            ),
            _actRow(
              ctx,
              Icons.push_pin_outlined,
              pinned ? '取消置顶' : '置顶',
              () => Navigator.pop(ctx, 'pin'),
            ),
            _actRow(
              ctx,
              Icons.delete_outline,
              '删除会话',
              () => Navigator.pop(ctx, 'del'),
              danger: true,
            ),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );
    if (!mounted || act == null) return;
    if (act == 'rename') {
      await _renameConv(id, title);
    } else if (act == 'pin') {
      await _convPut({'id': id, 'pinned': !pinned});
      await _loadConvs();
    } else if (act == 'del') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(AfPalette.card),
          title: const Text(
            '删除这个会话？',
            style: TextStyle(fontSize: 15, color: Color(AfPalette.text)),
          ),
          content: const Text(
            '聊天记录、文件卡片会一起删掉，不能恢复。',
            style: TextStyle(fontSize: 12.5, color: Color(AfPalette.text2)),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text(
                '删除',
                style: TextStyle(color: Color(0xFFFF7A7A)),
              ),
            ),
          ],
        ),
      );
      if (ok != true) return;
      try {
        await _http.delete(
          Uri.parse('$kApiBase/af/conversations?id=$id'),
          headers: {'Authorization': 'Bearer $_token'},
        );
      } catch (_) {}
      if (id == _convId) {
        _newConv();
      } else {
        await _loadConvs();
      }
    }
  }

  Widget _actRow(
    BuildContext ctx,
    IconData icon,
    String label,
    VoidCallback onTap, {
    bool danger = false,
  }) {
    final color = danger
        ? const Color(0xFFFF7A7A)
        : const Color(AfPalette.text);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
        child: Row(
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 12),
            Text(label, style: TextStyle(fontSize: 14, color: color)),
          ],
        ),
      ),
    );
  }

  Future<void> _convPut(Map<String, dynamic> body) async {
    if (_token == null) return;
    try {
      await _http.put(
        Uri.parse('$kApiBase/af/conversations'),
        headers: {
          'Authorization': 'Bearer $_token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(body),
      );
    } catch (_) {}
  }

  Future<void> _renameConv(String id, String old) async {
    final ctrl = TextEditingController(text: old);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(AfPalette.card),
        title: const Text(
          '修改名称',
          style: TextStyle(fontSize: 15, color: Color(AfPalette.text)),
        ),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 30,
          style: const TextStyle(fontSize: 14, color: Color(AfPalette.text)),
          decoration: const InputDecoration(
            hintText: '给这个话题起个名字',
            counterText: '',
            hintStyle: TextStyle(fontSize: 13, color: Color(AfPalette.text3)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty || name == old) return;
    await _convPut({'id': id, 'title': name});
    await _loadConvs();
  }

  Future<void> _switchConv(String id) async {
    // 旧会话转后台：断开前端连接（后端继续跑并落库），切回来按 status 续播
    _detachStream();
    _resumePoll?.cancel();
    _resumePoll = null;
    _typer?.cancel();
    _typer = null;
    _resumeDone = false;
    setState(() {
      _convId = id;
      _msgs.clear();
    });
    SharedPreferences.getInstance().then(
      (sp) => sp.setString('af_conv_id', id),
    );
    _closeDrawer();
    // 与进 App 同一套加载：工具卡/文件卡/展开态/续播都会还原
    await _loadChat(id);
  }

  Widget _convDrawer() {
    return SizedBox(
      width: _drawerW,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF0C0F15), Color(0xFF090B0F)],
          ),
          border: Border(right: BorderSide(color: Color(AfPalette.line))),
        ),
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 12, 12, 4),
                child: Row(
                  children: [
                    const Text(
                      '会话',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        letterSpacing: .3,
                        color: Color(AfPalette.text),
                      ),
                    ),
                    const Spacer(),
                    PressableScale(
                      onTap: _closeDrawer,
                      child: Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: const Color(AfPalette.card),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: const Color(AfPalette.line),
                          ),
                        ),
                        child: const Icon(
                          Icons.close_rounded,
                          size: 16,
                          color: Color(AfPalette.text2),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 10),
                child: Text(
                  '最近 30 天 · ${_convs.length} 个会话',
                  style: const TextStyle(
                    fontSize: 10.5,
                    letterSpacing: .2,
                    color: Color(AfPalette.text3),
                  ),
                ),
              ),
              Expanded(
                child: _convs.isEmpty
                    ? Center(
                        child: Text(
                          '还没有会话',
                          style: const TextStyle(
                            fontSize: 11,
                            color: Color(AfPalette.text3),
                          ),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
                        itemCount: _convs.length,
                        itemBuilder: (_, i) {
                          final c = _convs[i];
                          final id = (c['id'] ?? '').toString();
                          final title = (c['title'] ?? '新对话').toString();
                          final active = id == _convId;
                          final pinned =
                              (c['pinned'] ?? 0) == 1 || c['pinned'] == true;
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: PressableScale(
                              onTap: () => _switchConv(id),
                              onLongPress: () =>
                                  _convActions(id, title, pinned),
                              child: Container(
                                padding: const EdgeInsets.fromLTRB(
                                  12,
                                  11,
                                  11,
                                  11,
                                ),
                                decoration: BoxDecoration(
                                  color: active
                                      ? const Color(0x133AC9F5)
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: active
                                        ? const Color(AfPalette.accentLine)
                                        : Colors.transparent,
                                  ),
                                ),
                                child: Stack(
                                  children: [
                                    if (active)
                                      Positioned(
                                        left: 0,
                                        top: 2,
                                        bottom: 2,
                                        child: Container(
                                          width: 2,
                                          decoration: BoxDecoration(
                                            color: const Color(
                                              AfPalette.accent,
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              2,
                                            ),
                                          ),
                                        ),
                                      ),
                                    Padding(
                                      padding: const EdgeInsets.only(left: 6),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            title,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 12.5,
                                              fontWeight: FontWeight.w600,
                                              color: active
                                                  ? const Color(
                                                      AfPalette.accent,
                                                    )
                                                  : const Color(AfPalette.text),
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            active ? '当前会话' : '点开继续',
                                            style: const TextStyle(
                                              fontSize: 10,
                                              letterSpacing: .2,
                                              color: Color(AfPalette.text3),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 4),
                child: PressableScale(
                  onTap: () {
                    Navigator.of(context).pop();
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const AfMemoryPage()),
                    );
                  },
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                    child: Row(
                      children: const [
                        Icon(
                          Icons.psychology_alt_outlined,
                          size: 16,
                          color: Color(AfPalette.text2),
                        ),
                        SizedBox(width: 8),
                        Text(
                          '记忆与偏好',
                          style: TextStyle(
                            fontSize: 12,
                            color: Color(AfPalette.text2),
                          ),
                        ),
                        Spacer(),
                        Icon(
                          Icons.chevron_right_rounded,
                          size: 16,
                          color: Color(AfPalette.text3),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                child: PressableScale(
                  onTap: _newConv,
                  child: Container(
                    height: 42,
                    decoration: BoxDecoration(
                      color: const Color(0x0F3AC9F5),
                      borderRadius: BorderRadius.circular(13),
                      border: Border.all(
                        color: const Color(AfPalette.accentLine),
                      ),
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.add_rounded,
                          size: 14,
                          color: Color(AfPalette.accent),
                        ),
                        SizedBox(width: 6),
                        Text(
                          '新建对话',
                          style: TextStyle(
                            fontSize: 12.5,
                            color: Color(AfPalette.accent),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _loadQuota() async {
    // 启动早期 ApiClient.token 可能还没恢复，这里再兜一次
    if (_token == null || _token!.isEmpty) {
      try {
        final t = await SecureStore.read(SecureStore.tokenKey);
        if (t != null && t.isNotEmpty) {
          _token = t;
          ApiClient.token = t;
        }
      } catch (_) {}
    }
    if (_token == null || _token!.isEmpty) return;
    try {
      final r = await _http
          .get(
            Uri.parse('$kApiBase/af/quota'),
            headers: {'Authorization': 'Bearer $_token'},
          )
          .timeout(const Duration(seconds: 15));
      final j = _asMap(jsonDecode(r.body));
      if (j['ok'] == true) {
        setState(() {
          _quota = j;
          _plan = (j['plan'] ?? 'free').toString();
          _left = _asInt(j['left']);
        });
      }
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      // 切后台：只断开前端连接，后端继续做；轮询接上，回前台再按 status 校准
      final wasStreaming = _busy;
      _detachStream();
      if (wasStreaming && _convId != null) _startResume();
    } else if (state == AppLifecycleState.resumed) {
      // 回前台：额度与当前会话都重拉一遍，保证界面和服务器一致
      _loadQuota();
      final cid = _convId;
      if (cid != null) {
        _loadChat(cid);
      } else {
        _loadHistory();
      }
    }
  }

  /// 只断开前端连接，不动后端任务：服务器会继续生成并把内容落库。
  /// 切会话、新建对话、切后台都走这里，回来看 status 续播即可。
  void _detachStream() {
    _aborted = true;
    try {
      _client?.close();
    } catch (_) {}
    _client = null;
    _activeAi = null;
    _resumeAfterSend = false;
    _busy = false;
  }

  /// 用户点「中断」：先让服务器停止生成，再断开连接（内容保留到已收到的部分）
  void _abort() {
    if (!_busy) return;
    final cid = _streamConvId ?? _convId;
    if (cid != null && _token != null) {
      try {
        _http
            .post(
              Uri.parse('$kApiBase/af/cancel'),
              headers: {
                'Authorization': 'Bearer $_token',
                'Content-Type': 'application/json',
              },
              body: jsonEncode({'conv_id': cid}),
            )
            .timeout(const Duration(seconds: 4))
            .catchError((_) => http.Response('', 200));
      } catch (_) {}
    }
    _detachStream();
    _resumePoll?.cancel();
    _resumePoll = null;
    _typer?.cancel();
    _typer = null;
    _typerTarget = null;
    _resumeDone = false;
    _streamConvId = null;
    if (mounted) {
      setState(() {
        if (_msgs.isNotEmpty && _msgs.last.role == 'ai') {
          if (_msgs.last.text.isEmpty) _msgs.last.text = '（已停止）';
          _msgs.last.streaming = false;
        }
      });
    }
  }

  @override
  void dispose() {
    _resumePoll?.cancel();
    _typer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    for (final t in _taps) {
      t.dispose();
    }
    _inputFocus.dispose();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// 距底部 56px 以内算「贴底」，恢复自动跟随
  void _onScroll() {
    if (!_scroll.hasClients) return;
    final p = _scroll.position;
    final near = afStickAfterScroll(
      maxExtent: p.maxScrollExtent,
      pixels: p.pixels,
      userScrolling: _userScrolling,
      current: _stick,
    );
    if (near != _stick) setState(() => _stick = near);
  }

  /// 「回到最新」：用户主动点击，立刻执行，不等帧末回调
  void _jumpToLatest() {
    _touching = false;
    if (!_scroll.hasClients) return;
    final target = _scroll.position.maxScrollExtent;
    _scroll
        .animateTo(
          target,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
        )
        .then((_) {
          if (!mounted || !_scroll.hasClients) return;
          if ((_scroll.position.maxScrollExtent - _scroll.position.pixels)
                  .abs() <=
              56) {
            setState(() => _stick = true);
          }
        });
  }

  /// [force] 用于进会话 / 自己发消息：无论当前在哪都拉到底部
  void _scrollBottom({bool force = false}) {
    // 手指按着/拖拽中：一律不碰滚动条，避免"AI 在跟我抢"
    if (_touching) return;
    if (!force && !_stick) return; // 用户正在上翻看历史，不打扰
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients || _touching) return;
      if (!force && !_stick) return;
      final target = _scroll.position.maxScrollExtent;
      if (force) {
        // 用户主动行为（发消息 / 回到最新）：一次短动画
        _scroll
            .animateTo(
              target,
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
            )
            .then((_) {
              if (!mounted || !_scroll.hasClients) return;
              final p = _scroll.position;
              if ((p.maxScrollExtent - p.pixels) <= 56 && !_stick) {
                setState(() => _stick = true); // 回到最新位置，恢复自动跟随
              }
            });
      } else {
        // 流式追加：短动画跟随，让气泡增长时页面平滑下移。
        // 每次 delta 都重启 140ms 的动画，目标持续增长时会自然跟在底部。
        if ((_scroll.position.pixels - target).abs() > 0.5) {
          _scroll.animateTo(
            target,
            duration: const Duration(milliseconds: 140),
            curve: Curves.easeOutCubic,
          );
        }
      }
    });
  }

  int get _imgCount => _atts.where((a) => a.isImg).length;
  int get _fileCount => _atts.where((a) => !a.isImg).length;

  void _tipLimit(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<Uint8List?> _toJpeg(Uint8List bytes) async {
    try {
      return await FlutterImageCompress.compressWithList(
        bytes,
        quality: 88,
        format: CompressFormat.jpeg,
      );
    } catch (_) {
      return null;
    }
  }

  /// 统一把 iPhone 的 HEIC/HEIF 转成 JPEG，避免模型/媒体接口不认格式。
  Future<_Attach?> _makeImageAttach(String rawName, Uint8List raw) async {
    var bytes = raw;
    var name = afImageName(rawName, bytes);
    var mime = _mimeFromName(name);
    if (_isHeicBytes(bytes) || mime == 'image/heic' || mime == 'image/bmp') {
      final jpg = await _toJpeg(bytes);
      if (jpg == null) {
        _tipLimit('这张照片格式暂不支持，换一张 JPG/PNG 试试');
        return null;
      }
      bytes = jpg;
      name = name.replaceFirst(
        RegExp(r'\.(heic|heif|bmp)$', caseSensitive: false),
        '.jpg',
      );
      if (!name.toLowerCase().endsWith('.jpg')) name = '$name.jpg';
      mime = 'image/jpeg';
    } else if (mime == 'application/octet-stream') {
      // ImagePicker 有时不给扩展名，但内容已经是 JPEG
      mime = _isJpegBytes(bytes) ? 'image/jpeg' : 'application/octet-stream';
    }
    return _Attach(name: name, size: bytes.length, local: bytes, mime: mime);
  }

  Future<_Attach?> _readPickedImage(XFile x) async {
    final bytes = await x.readAsBytes();
    return _makeImageAttach(x.name, bytes);
  }

  Future<void> _pickImage() async {
    final room = kAfMaxImgs - _imgCount;
    if (room <= 0) {
      _tipLimit('图片最多 $kAfMaxImgs 张，先删掉几张再加');
      return;
    }
    final p = ImagePicker();
    final list = await p.pickMultiImage(maxWidth: 2048, imageQuality: 88);
    if (list.isEmpty) return;
    final picked = list.length > room ? list.sublist(0, room) : list;
    if (list.length > room) _tipLimit('图片最多 $kAfMaxImgs 张，已加入前 $room 张');
    for (final x in picked) {
      final a = await _readPickedImage(x);
      if (a != null && mounted) setState(() => _atts.add(a));
    }
  }

  Future<void> _pickCamera() async {
    if (_imgCount >= kAfMaxImgs) {
      _tipLimit('图片最多 $kAfMaxImgs 张，先删掉几张再拍');
      return;
    }
    final x = await ImagePicker().pickImage(
      source: ImageSource.camera,
      maxWidth: 2048,
      imageQuality: 88,
    );
    if (x == null) return;
    final a = await _readPickedImage(x);
    if (a != null && mounted) setState(() => _atts.add(a));
  }

  Future<void> _pickFile() async {
    final r = await FilePicker.platform.pickFiles(
      withData: true,
      allowMultiple: true,
    );
    if (r == null || r.files.isEmpty) return;
    for (final f in r.files) {
      final bytes = f.bytes;
      if (bytes == null) continue;
      final mime = _mimeFromName(f.name);
      if (mime.startsWith('image/') || _isHeicBytes(bytes)) {
        if (_imgCount >= kAfMaxImgs) {
          _tipLimit('图片最多 $kAfMaxImgs 张，先删掉几张再加');
          continue;
        }
        final a = await _makeImageAttach(f.name, bytes);
        if (a != null && mounted) setState(() => _atts.add(a));
        continue;
      }
      if (_fileCount >= kAfMaxFiles) {
        _tipLimit('文件最多 $kAfMaxFiles 个，先删掉几个再加');
        break;
      }
      if (bytes.length > 20 * 1024 * 1024) continue;
      if (mounted) {
        setState(
          () => _atts.add(
            _Attach(name: f.name, size: bytes.length, local: bytes, mime: mime),
          ),
        );
      }
    }
  }

  Future<bool> _uploadAll(List<_Attach> list) async {
    var ok = true;
    for (final a in list) {
      if (a.url != null) continue;
      a.uploading = true;
      setState(() {});
      try {
        final r = await http
            .post(
              Uri.parse('$kApiBase/af/upload'),
              headers: {
                'Authorization': 'Bearer $_token',
                'Content-Type': 'application/json',
              },
              body: jsonEncode({
                'name': a.name,
                'mime': a.mime ?? '',
                'b64': base64Encode(a.local ?? Uint8List(0)),
              }),
            )
            .timeout(const Duration(seconds: 60));
        final j = _asMap(jsonDecode(r.body));
        if (j['ok'] == true) {
          a.url = j['url'] as String?;
        } else {
          ok = false;
          a.uploading = false;
          setState(() {});
          return false;
        }
      } catch (_) {
        ok = false;
        a.uploading = false;
        setState(() {});
        return false;
      }
      a.uploading = false;
    }
    setState(() {});
    return ok;
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    // 只发图片/文件、不写字也能发
    if ((text.isEmpty && _atts.isEmpty) || _busy || _token == null) return;
    _input.clear();
    if (_attachOpen) setState(() => _attachOpen = false);
    final atts = List<_Attach>.from(_atts);
    _aborted = false;
    setState(() {
      // 先把本地缩略图挂到气泡上，不等上传完成也能看到自己发了什么
      _msgs.add(_Msg(role: 'user', text: text, atts: atts));
      _atts.clear();
      _busy = true;
    });
    _scrollBottom(force: true);
    if (atts.isNotEmpty) {
      final upOk = await _uploadAll(atts);
      setState(() {});
      if (!upOk) {
        setState(() {
          _msgs.add(_Msg(role: 'ai', text: '附件没传上去，检查下网络再发一次。'));
          _busy = false;
        });
        return;
      }
    }
    final ai = _Msg(role: 'ai', text: '', streaming: true);
    _activeAi = ai;
    setState(() => _msgs.add(ai));
    _scrollBottom(force: true);
    // 纯文本的「强力」模型看不了图：带图这一轮自动切到带视觉的「快速」。
    // 否则上游会返回 Unsupported Image，和图片扩展名/压缩无关。
    final turnModel = afModelForTurn(
      _model,
      hasImage: atts.any((a) => a.isImg),
    );
    try {
      final req = http.Request('POST', Uri.parse('$kApiBase/af/chat'));
      req.headers['Authorization'] = 'Bearer $_token';
      req.headers['Content-Type'] = 'application/json';
      req.headers['Accept'] = 'text/event-stream';
      req.body = jsonEncode({
        'message': text,
        'conv_id': _convId ?? '',
        'model': turnModel,
        'mode': _mode,
        'effort': _effort,
        'attachments': atts
            .map(
              (a) => {
                'name': a.name,
                'url': a.url,
                'mime': a.mime,
                'size': a.size,
              },
            )
            .toList(),
        'local_tools': LocalTools.specs.map((e) => e['name']).toList(),
      });
      final client = widget.client ?? http.Client();
      _client = client;
      final resp = await client.send(req).timeout(const Duration(seconds: 30));
      if (resp.statusCode != 200) {
        final body = await resp.stream.bytesToString();
        setState(() {
          if (resp.statusCode == 403) {
            ai.text = 'Agent 模式是会员专属。开通 VIP 或 SVIP 后，我就能开沙箱连续执行并交付成品。';
          } else {
            ai.text =
                '请求失败（${resp.statusCode}）\n${body.length > 300 ? body.substring(0, 300) : body}';
          }
          _busy = false;
        });
        return;
      }
      final buf = StringBuffer();
      final think = StringBuffer();
      final t0 = DateTime.now();
      var evt = '';
      var finished = false;
      // SSE 按行解析：网络分块可能把一行切成两半，必须先攒行再解析，
      // 否则被切断的 data 行会 jsonDecode 失败被丢弃，表现为“输出着就断了”
      var pending = '';
      await for (final chunk in resp.stream.transform(utf8.decoder)) {
        pending += chunk;
        final lines = pending.split('\n');
        pending = lines.removeLast();
        for (final line in lines) {
          final raw = line.trimRight();
          if (raw.startsWith('event:')) {
            evt = raw.substring(6).trim();
            continue;
          }
          if (!raw.startsWith('data:')) continue;
          final data = raw.substring(5).trim();
          if (data.isEmpty || data == '[DONE]') continue;
          Map<String, dynamic> j;
          try {
            j = _asMap(jsonDecode(data));
          } catch (_) {
            continue;
          }
          if (evt == 'done') {
            // 交付对账：即使发布事件在流式传输里丢了，done 里仍带着本轮
            // 已发布的文件；按 URL 去重后补成文件卡，避免只剩“已完成”文字。
            final fs = j['files'];
            if (fs is List && fs.isNotEmpty) {
              final known = <String>[];
              for (final m in _msgs) {
                if (m.role != 'tool' || m.tool?['name'] != 'publish_file') {
                  continue;
                }
                final d = _asMap(m.tool?['detail'] ?? const {});
                final u = (d['url'] ?? '').toString();
                if (u.isNotEmpty) known.add(u);
              }
              final add = <_Msg>[];
              for (final t in afDeliveryFileTools(fs, known)) {
                final now = DateTime.now();
                add.add(
                  _Msg(role: 'tool', text: '', tool: t)
                    ..toolStartedAt = now
                    ..toolEndedAt = now,
                );
              }
              if (add.isNotEmpty) setState(() => _msgs.addAll(add));
            }
            finished = true;
            break;
          }
          if (evt == 'meta') {
            final mid = (j['mid'] ?? '').toString();
            if (mid.isNotEmpty) ai.id = mid;
            final cid = (j['conv_id'] ?? '').toString();
            if (cid.isNotEmpty && _convId != cid) {
              _convId = cid;
              SharedPreferences.getInstance().then(
                (sp) => sp.setString('af_conv_id', cid),
              );
              _loadConvs();
            }
          } else if (evt == 'reasoning' || j['reasoning'] != null) {
            think.write((j['t'] ?? j['reasoning'] ?? '').toString());
            setState(() => ai.reasoning = think.toString());
            _scrollBottom();
          } else if (evt == 'delta' || j['delta'] != null || j['t'] != null) {
            buf.write((j['delta'] ?? j['t'] ?? '').toString());
            setState(() => ai.text = buf.toString());
            _scrollBottom();
          } else if (evt == 'tool' || j['tool'] != null) {
            final tm = _asMap(j['tool'] ?? j);
            final tid = (tm['id'] ?? '').toString();
            final now = DateTime.now();
            setState(() {
              // 同一个工具调用会先发 running 再发 ok：按 id 原地更新，
              // 不能追加两条，否则执行时间线会把一步画成两步。
              if (tid.isNotEmpty) {
                for (final old in _msgs) {
                  if (old.role == 'tool' && (old.tool?['id'] ?? '') == tid) {
                    old.tool = tm;
                    old.toolStartedAt ??= now;
                    if ((tm['status'] ?? '') != 'running') {
                      old.toolEndedAt ??= now;
                    }
                    return;
                  }
                }
              }
              final nm = _Msg(role: 'tool', text: '', tool: tm)
                ..toolStartedAt = now;
              if ((tm['status'] ?? '') != 'running') {
                nm.toolEndedAt = now;
              }
              _msgs.add(nm);
            });
            _scrollBottom();
          } else if (evt == 'usage') {
            final u = _asMap(j);
            final byok = u['byok'] == true;
            final tin = _asDouble(u['tokens_in']) + _asDouble(u['tokens_out']);
            final gift = _asDouble(u['gift']);
            final fen = _asDouble(u['fen']);
            setState(() {
              // 自建 API：用户自己的 key，不显示 token、不扣官方额度
              if (byok) {
                ai.costText = '自建 API · 不计费';
              } else {
                ai.costText =
                    '本轮 ${tin.toInt()} token · '
                    '${gift > 0 ? "扣赠送 ${gift.toInt()}" : (fen > 0 ? "扣余额 ¥${(fen / 100).toStringAsFixed(2)}" : "未计费")}';
              }
            });
            if (mounted) _loadQuota();
          } else if (evt == 'error') {
            setState(() => ai.text = '出错了：${j['msg'] ?? ''}');
          }
        }
        if (finished) break;
      }
      ai.ms = DateTime.now().difference(t0).inMilliseconds;
      if (buf.isEmpty && ai.text.isEmpty) {
        ai.text = '（没有返回内容）';
      }
    } catch (e) {
      if (_aborted) {
        // 用户停止 / 切会话 / 切后台：保留已收到的内容，不报错
      } else if (_msgs.isNotEmpty && identical(_msgs.last, ai)) {
        // 连接断了但后端还在跑：不覆盖已有内容，交给轮询续播接上
        if (ai.text.isEmpty && ai.reasoning.isEmpty) {
          setState(() => ai.text = '连接断了，后台还在做，正在接上…');
        }
        _resumeAfterSend = true;
      } else {
        setState(() => ai.text = '出错了：${e.toString()}');
      }
    } finally {
      try {
        _client?.close();
      } catch (_) {}
      _client = null;
      _activeAi = null;
      if (_resumeAfterSend && _msgs.isNotEmpty && identical(_msgs.last, ai)) {
        _resumeAfterSend = false;
        ai.streaming = true;
        setState(() => _busy = true);
        _typerTarget = ai;
        _startResume();
      } else {
        _resumeAfterSend = false;
        setState(() {
          _busy = false;
          ai.streaming = false;
        });
      }
      _loadQuota();
      _scrollBottom();
    }
  }

  @override
  Widget build(BuildContext context) {
    // Agent 整页使用内置中文字体，避免手机系统/第三方字体自带的装饰线
    final base = Theme.of(context);
    return Theme(
      data: base.copyWith(
        textTheme: base.textTheme.apply(
          fontFamily: 'NotoSansSC',
          fontFamilyFallback: const ['PingFang SC', 'Heiti SC'],
        ),
      ),
      child: DefaultTextStyle.merge(
        style: const TextStyle(
          fontFamily: 'NotoSansSC',
          fontFamilyFallback: ['PingFang SC', 'Heiti SC'],
          color: Color(AfPalette.text),
          decoration: TextDecoration.none,
        ),
        child: PopScope(
          canPop: !_drawerOpen,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _closeDrawer();
          },
          child: AnimatedBuilder(
            animation: _drawerCtrl,
            builder: (_, __) {
              final t = _drawerCtrl.value;
              return Stack(
                children: [
                  // 抽屉在底层，从左侧滑出（收起时整个移出树，避免隐形控件响应/重复）
                  if (t > 0.001 || _drawerCtrl.isAnimating)
                    Positioned(
                      left: 0,
                      top: 0,
                      bottom: 0,
                      child: Transform.translate(
                        offset: Offset(-_drawerW * (1 - t), 0),
                        child: _convDrawer(),
                      ),
                    ),
                  // 主界面被推到右边（抽屉柜式）：卡片化，左侧圆角 + 投影，边界清楚
                  Transform.translate(
                    offset: Offset(_drawerW * t, 0),
                    child: IgnorePointer(
                      ignoring: t > 0.001,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          boxShadow: t <= 0.001
                              ? const []
                              : [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.45 * t),
                                    blurRadius: 28 * t,
                                    offset: Offset(-10 * t, 0),
                                  ),
                                ],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.horizontal(
                            left: Radius.circular(20 * t),
                          ),
                          child: _mainScaffold(),
                        ),
                      ),
                    ),
                  ),
                  // 点主界面右侧空白处收回抽屉
                  if (t > 0.001)
                    Positioned(
                      left: _drawerW,
                      top: 0,
                      right: 0,
                      bottom: 0,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _closeDrawer,
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _mainScaffold() {
    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: const Color(AfPalette.bg),
      body: SafeArea(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            _closeAttachPanel();
            if (_inputFocus.hasFocus) _inputFocus.unfocus();
            if (_micOn) _stopListening();
          },
          child: Column(
            children: [
              _header(),
              _quotaBar(),
              Expanded(child: _msgs.isEmpty ? _welcome() : _list()),
              _composer(),
            ],
          ),
        ),
      ),
    );
  }

  String get _convTitle {
    for (final c in _convs) {
      if ((c['id'] ?? '').toString() == _convId) {
        final t = (c['title'] ?? '').toString();
        if (t.isNotEmpty) return t;
      }
    }
    return '主对话';
  }

  Widget _headBtn(IconData icon, VoidCallback onTap, {bool dim = false}) {
    return PressableScale(
      onTap: onTap,
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: const Color(AfPalette.card),
          borderRadius: BorderRadius.circular(11),
          border: Border.all(color: const Color(AfPalette.line)),
        ),
        child: Icon(
          icon,
          size: 17,
          color: dim
              ? const Color(AfPalette.text3)
              : const Color(AfPalette.text2),
        ),
      ),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpace.gutter, 6, 14, 10),
      child: Row(
        children: [
          _headBtn(Icons.segment_rounded, _openDrawer),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '小萤 Agent',
                  style: TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w700,
                    letterSpacing: .3,
                    height: 1.2,
                    color: Color(AfPalette.text),
                  ),
                ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        _convTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          letterSpacing: .2,
                          color: Color(AfPalette.text3),
                        ),
                      ),
                    ),
                    const Icon(
                      Icons.expand_more_rounded,
                      size: 12,
                      color: Color(AfPalette.text3),
                    ),
                  ],
                ),
              ],
            ),
          ),
          _headBtn(
            Icons.account_balance_wallet_outlined,
            () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const AfBillingPage()),
            ),
            dim: true,
          ),
          const SizedBox(width: 8),
          _headBtn(Icons.close_rounded, () {
            final nav = Navigator.of(context);
            if (nav.canPop()) {
              nav.pop();
            } else {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('已回到 Agent 主界面'),
                  duration: Duration(milliseconds: 1400),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            }
          }),
        ],
      ),
    );
  }

  Widget _pill(
    String label,
    IconData icon,
    VoidCallback onTap, {
    bool highlight = false,
  }) {
    final c = highlight
        ? const Color(AfPalette.accent)
        : const Color(AfPalette.text2);
    return PressableScale(
      onTap: _busy ? null : onTap,
      child: Container(
        height: 27,
        padding: const EdgeInsets.symmetric(horizontal: 11),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: highlight ? const Color(0x143AC9F5) : const Color(0x08FFFFFF),
          border: Border.all(
            color: highlight
                ? const Color(AfPalette.accentLineStrong)
                : const Color(AfPalette.line),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: c),
            const SizedBox(width: 5),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              transitionBuilder: (ch, a) =>
                  FadeTransition(opacity: a, child: ch),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 150),
                child: Text(
                  label,
                  key: ValueKey(label),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.2,
                    fontWeight: FontWeight.w500,
                    color: c,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _modeBar() {
    final isWork = _mode == 'work';
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        children: [
          Expanded(
            child: Wrap(
              spacing: 7,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _pill(
                  isWork ? 'Agent 模式' : '聊天模式',
                  isWork
                      ? Icons.work_outline_rounded
                      : Icons.chat_bubble_outline_rounded,
                  _pickMode,
                  highlight: isWork,
                ),
                _pill(
                  afModelLabel(_model),
                  Icons.bolt_rounded,
                  _pickModel,
                  highlight: afIsByok(_model) || _model == 'deepseek-v4-pro',
                ),
                _pill(
                  AfEffort.of(_effort).label,
                  Icons.tune_rounded,
                  _pickEffort,
                  highlight: true,
                ),
                if (isWork) _sandboxPill(),
              ],
            ),
          ),
          if (isWork && _plan == 'free')
            const Padding(
              padding: EdgeInsets.only(left: 6),
              child: Text(
                '会员专属',
                style: TextStyle(fontSize: 11, color: Color(AfPalette.text3)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _sandboxPill() {
    return Container(
      height: 27,
      padding: const EdgeInsets.symmetric(horizontal: 11),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: const Color(0x08FFFFFF),
        border: Border.all(color: const Color(AfPalette.line)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.cloud_outlined,
            size: 12,
            color: Color(AfPalette.text2),
          ),
          const SizedBox(width: 5),
          const Text(
            '云沙箱',
            style: TextStyle(fontSize: 11.5, color: Color(AfPalette.text2)),
          ),
          const SizedBox(width: 4),
          Container(
            width: 4,
            height: 4,
            decoration: const BoxDecoration(
              color: Color(AfPalette.warm),
              shape: BoxShape.circle,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickEffort() async {
    await showAfEffortCard(
      context,
      mode: _mode,
      model: _model,
      effort: _effort,
      onMode: (v) async {
        setState(() => _mode = v);
        final sp = await SharedPreferences.getInstance();
        await sp.setString('af_mode', v);
      },
      onModel: (v) async {
        setState(() => _model = v);
        final sp = await SharedPreferences.getInstance();
        await sp.setString('af_model', v);
      },
      onEffort: (v) async {
        setState(() => _effort = v);
        final sp = await SharedPreferences.getInstance();
        await sp.setString('af_effort', v);
      },
    );
  }

  Future<void> _pickMode() async {
    final isMember = _plan != 'free';
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(AppColors.card),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => Theme(
        data: Theme.of(context).copyWith(
          textTheme: Theme.of(context).textTheme.apply(
            fontFamily: 'NotoSansSC',
            fontFamilyFallback: const ['LAT', 'CJK', 'PingFang SC', 'Heiti SC'],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('小萤怎么帮你', style: AppType.title),
                const SizedBox(height: 12),
                _modeCard(
                  ctx,
                  key: 'chat',
                  title: '聊天模式',
                  lines: ['问一句答一句', '轻量写作、看图、解释', '额度消耗慢'],
                  icon: Icons.chat_bubble_outline_rounded,
                ),
                const SizedBox(height: 10),
                _modeCard(
                  ctx,
                  key: 'work',
                  title: 'Agent 模式',
                  lines: ['先拆步骤，再连续执行', '读写文件、跑命令、交付成品', '额度消耗快'],
                  icon: Icons.work_outline_rounded,
                  locked: !isMember,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _modeCard(
    BuildContext ctx, {
    required String key,
    required String title,
    required List<String> lines,
    required IconData icon,
    bool locked = false,
  }) {
    final on = _mode == key;
    return PressableScale(
      onTap: () {
        if (locked) {
          Navigator.of(ctx).pop();
          Navigator.of(context)
              .push(MaterialPageRoute(builder: (_) => const AfBillingPage()));
          return;
        }
        setState(() => _mode = key);
        Navigator.of(ctx).pop();
      },
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: const Color(AppColors.elevated),
          border: Border.all(
            color: on
                ? const Color(AppColors.accent)
                : const Color(AppColors.hairline),
          ),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 20,
              color: on
                  ? const Color(AppColors.accent)
                  : const Color(AppColors.textSecondary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        title,
                        style: AppType.body.copyWith(
                          fontFamily: 'NotoSansSC',
                          fontFamilyFallback: const ['CJK'],
                        ),
                      ),
                      if (locked) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(4),
                            color: const Color(0x22FFFFFF),
                          ),
                          child: Text(
                            '会员专属',
                            style: AppType.micro.copyWith(
                              color: const Color(AppColors.textTertiary),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  for (final l in lines)
                    Text(
                      l,
                      style: AppType.micro.copyWith(
                        color: const Color(AppColors.textTertiary),
                      ),
                    ),
                ],
              ),
            ),
            if (on)
              const Icon(
                Icons.check_rounded,
                size: 18,
                color: Color(AppColors.accent),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickModel() async {
    final providers = await loadAfProviders();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(AppColors.card),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => AfModelPickerSheet(
        current: _model,
        initialProviders: providers,
        onPick: (v) async {
          setState(() => _model = v);
          final sp = await SharedPreferences.getInstance();
          await sp.setString('af_model', v);
        },
      ),
    );
  }

  String _fmtTokens(double v) {
    if (v >= 100000000) return '${(v / 100000000).toStringAsFixed(1)} 亿';
    if (v >= 10000) return '${(v / 10000).toStringAsFixed(1)} 万';
    return v.toInt().toString();
  }

  Widget _quotaBar() {
    final loaded = _quota != null;
    final gift = _asDouble(_quota?['gift_left']);
    final balYuan = _asDouble(_quota?['balance_yuan']);
    final limitRaw = _asDouble(_quota?['limit_w5h']);
    final limit = limitRaw > 0
        ? limitRaw
        : (_plan == 'free' ? 30000.0 : 1000000.0);
    final pct = gift > 0 ? (gift / limit).clamp(0.0, 1.0) : 0.0;
    final low = loaded && pct <= 0.12;
    final blocked = loaded && gift <= 0 && balYuan <= 0;
    return GestureDetector(
      onTap: _loadQuota,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  loaded
                      ? '剩余 ${_fmtTokens(gift)} / ${_fmtTokens(limit)}'
                      : '同步额度中…',
                  style: TextStyle(
                    fontSize: 10.5,
                    letterSpacing: .2,
                    color: blocked
                        ? const Color(AfPalette.danger)
                        : const Color(AfPalette.text3),
                  ),
                ),
                const Spacer(),
                Text(
                  loaded
                      ? '${_plan.toUpperCase()} · 余额 ¥${balYuan.toStringAsFixed(2)}'
                      : '',
                  style: const TextStyle(
                    fontSize: 10.5,
                    letterSpacing: .2,
                    color: Color(AfPalette.text3),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: pct),
                duration: const Duration(milliseconds: 520),
                curve: Curves.easeOutCubic,
                builder: (_, v, __) => LinearProgressIndicator(
                  value: loaded ? v : null,
                  minHeight: 3,
                  backgroundColor: const Color(AfPalette.line),
                  valueColor: AlwaysStoppedAnimation(
                    blocked
                        ? const Color(AfPalette.danger)
                        : (low
                              ? const Color(AfPalette.warm)
                              : const Color(AfPalette.accent)),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _agentStep(String num, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          num,
          style: AppType.micro.copyWith(
            fontSize: 9.5,
            letterSpacing: .8,
            color: const Color(AfPalette.accent),
          ),
        ),
        const SizedBox(width: 5),
        Text(
          label,
          style: AppType.micro.copyWith(
            fontSize: 11.5,
            color: const Color(AfPalette.text2),
          ),
        ),
      ],
    );
  }

  Widget _welcome() {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.gutter),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 14),
          Row(
            children: [
              const AiAvatar(size: 30, animate: false),
              const SizedBox(width: 10),
              Text(
                '小萤',
                style: AppType.body.copyWith(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: const Color(AfPalette.text2),
                ),
              ),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  border: Border.all(color: const Color(AfPalette.accentLine)),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  'AGENT',
                  style: AppType.micro.copyWith(
                    fontSize: 9.5,
                    color: const Color(AfPalette.accent),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Center(
            child: AiAvatar(
              key: ValueKey('ai-avatar-$_avatarEpoch'),
              size: 112,
              replay: _avatarEpoch,
            ),
          ),
          const SizedBox(height: 18),
          Text(
            '给我一个目标。\n我拆步骤，做完交给你。',
            style: AppType.h1.copyWith(
              fontSize: 24,
              height: 1.3,
              color: const Color(AfPalette.text),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '会规划、会调工具、会交付成品。\n轻活在本机做；重活自动进云沙箱，不占你手机。',
            style: AppType.body.copyWith(
              fontSize: 13,
              height: 1.75,
              color: const Color(AfPalette.text2),
            ),
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              _agentStep('01', '拆步骤'),
              const SizedBox(width: 14),
              _agentStep('02', '调工具'),
              const SizedBox(width: 14),
              _agentStep('03', '交成品'),
            ],
          ),
          const SizedBox(height: AppSpace.x6),
          Text(
            '试一句',
            style: AppType.micro.copyWith(
              fontSize: 12,
              color: const Color(AfPalette.text3),
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: ['帮我整理下载文件夹', '把这个网页的正文抓下来', '写一份周报', '读一下这个 CSV 并统计']
                .map(
                  (t) => PressableScale(
                    onTap: () {
                      _input.text = t;
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(AfPalette.card),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(AfPalette.line)),
                      ),
                      child: Text(
                        t,
                        style: AppType.body.copyWith(
                          fontSize: 12.5,
                          color: const Color(AfPalette.text2),
                        ),
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
        ],
      ),
    );
  }

  Widget _list() {
    // 把工具卡并进它所属的那一轮 AI 回复：正文里只留一行过程状态，
    // 完成后该行变成「总结 + 产物」卡，不再拉一长串工具卡。
    final turns = <_Turn>[];
    final pending = <_Msg>[];
    for (final m in _msgs) {
      if (m.role == 'tool') {
        if (turns.isNotEmpty && turns.last.msg.role == 'ai') {
          turns.last.tools.add(m);
        } else {
          // 旧数据里工具卡的时间戳可能早于 AI 消息，先存着，挂到随后的这条 AI 上
          pending.add(m);
        }
        continue;
      }
      final t = _Turn(m);
      if (pending.isNotEmpty) {
        t.tools.addAll(pending);
        pending.clear();
      }
      turns.add(t);
    }
    if (pending.isNotEmpty) {
      for (final m in pending) {
        for (var i = turns.length - 1; i >= 0; i--) {
          if (turns[i].msg.role == 'ai') {
            turns[i].tools.add(m);
            break;
          }
        }
      }
    }
    return Stack(
      children: [
        NotificationListener<ScrollNotification>(
          onNotification: (n) {
            if (n is UserScrollNotification) {
              _userScrolling = n.direction != ScrollDirection.idle;
            }
            return false;
          },
          child: Listener(
            onPointerDown: (_) => _touching = true,
            onPointerUp: (_) => _touching = false,
            onPointerCancel: (_) => _touching = false,
            child: ListView.builder(
              controller: _scroll,
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: const EdgeInsets.fromLTRB(
                AppSpace.gutter,
                0,
                AppSpace.gutter,
                16,
              ),
              itemCount: turns.length,
              itemBuilder: (_, i) {
                final t = turns[i];
                if (t.msg.role == 'ai') return _aiTurn(t);
                return _bubble(t.msg);
              },
            ),
          ),
        ),
        if (!_stick)
          Positioned(
            right: 12,
            bottom: 12,
            child: GestureDetector(
              onTap: () {
                // 按钮在列表的 Listener 里，点击会先被记成"手指按着"，
                // 这里显式放开，否则这次主动回底会被自己的防抢逻辑吞掉
                _jumpToLatest();
              },
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 11,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: const Color(AfPalette.card2),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: const Color(AfPalette.accentLine)),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.south_rounded,
                      size: 12,
                      color: Color(AfPalette.accent),
                    ),
                    SizedBox(width: 4),
                    Text(
                      '回到最新',
                      style: TextStyle(
                        fontSize: 11,
                        color: Color(AfPalette.accent),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  final _taps = <TapGestureRecognizer>[];

  /// 轻量富文本：代码块（带复制）、行内代码、加粗、标题、列表、链接。
  Widget _richBody(String text) {
    if (text.isEmpty) return const SizedBox.shrink();
    final blocks = <Widget>[];
    final lines = text.split('\n');
    var i = 0;
    while (i < lines.length) {
      final line = lines[i];
      final t = line.trimLeft();
      if (t.startsWith('```')) {
        final lang = t.substring(3).trim();
        final buf = StringBuffer();
        i++;
        while (i < lines.length && !lines[i].trimLeft().startsWith('```')) {
          buf.writeln(lines[i]);
          i++;
        }
        i++;
        blocks.add(_codeCard(lang, buf.toString().trimRight()));
        continue;
      }
      if (t.isEmpty) {
        blocks.add(const SizedBox(height: 6));
        i++;
        continue;
      }
      var hash = 0;
      while (hash < t.length && t[hash] == '#') {
        hash++;
      }
      if (hash >= 1 && hash <= 4 && t.length > hash && t[hash] == ' ') {
        blocks.add(
          Padding(
            padding: EdgeInsets.only(top: blocks.isEmpty ? 0 : 5, bottom: 2),
            child: Text(
              t.substring(hash + 1),
              style: AppType.body.copyWith(
                fontSize: hash <= 2 ? 16 : 15,
                fontWeight: FontWeight.w700,
                height: 1.5,
              ),
            ),
          ),
        );
        i++;
        continue;
      }
      final imgRe = RegExp(r'!\[[^\]]*\]\((https?://[^)\s]+)\)');
      if (imgRe.hasMatch(line)) {
        var lastEnd = 0;
        final row = <Widget>[];
        for (final m in imgRe.allMatches(line)) {
          final txt = line.substring(lastEnd, m.start).trim();
          if (txt.isNotEmpty) row.add(_inline(txt));
          row.add(_chatImage(m.group(1)!));
          lastEnd = m.end;
        }
        final tail = line.substring(lastEnd).trim();
        if (tail.isNotEmpty) row.add(_inline(tail));
        blocks.add(
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: row),
        );
        i++;
        continue;
      }
      final bulletRe = RegExp(r'^(?:[-*]|\d+[.)]) ');
      if (bulletRe.hasMatch(t)) {
        blocks.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 4,
                  height: 4,
                  margin: const EdgeInsets.only(right: 9, top: 6),
                  decoration: const BoxDecoration(
                    color: Color(0x993AC9F5),
                    shape: BoxShape.circle,
                  ),
                ),
                Expanded(child: _inline(t.replaceFirst(bulletRe, ''))),
              ],
            ),
          ),
        );
        i++;
        continue;
      }
      blocks.add(_inline(line));
      i++;
    }
    return SelectionArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: blocks,
      ),
    );
  }

  Widget _chatImage(String url) {
    if (url.isEmpty) return const SizedBox.shrink();
    final maxW = MediaQuery.of(context).size.width * 0.66;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: PressableScale(
        onTap: () => _openFile(url, '图片', 'image', '', ''),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxW),
            child: CachedNetworkImageCompat(
              url: url,
              fit: BoxFit.fitWidth,
              memCacheWidth: (maxW * 2).round(),
              placeholder: Container(
                width: maxW,
                height: 150,
                color: const Color(AfPalette.card2),
                alignment: Alignment.center,
                child: const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 1.6),
                ),
              ),
              errorWidget: Container(
                width: maxW,
                height: 120,
                decoration: BoxDecoration(
                  color: const Color(AfPalette.card2),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(AfPalette.line)),
                ),
                alignment: Alignment.center,
                child: const Text(
                  '图片加载失败',
                  style: TextStyle(fontSize: 11, color: Color(AfPalette.text3)),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _inline(String s) {
    final spans = <InlineSpan>[];
    final re = RegExp(r'(\*\*[^*]+\*\*|`[^`]+`|\[[^\]]+\]\([^()]+\))');
    var last = 0;
    for (final m in re.allMatches(s)) {
      if (m.start > last) {
        spans.add(TextSpan(text: s.substring(last, m.start)));
      }
      final tok = m.group(0)!;
      if (tok.startsWith('**') && tok.endsWith('**')) {
        spans.add(
          TextSpan(
            text: tok.substring(2, tok.length - 2),
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        );
      } else if (tok.startsWith('`')) {
        spans.add(
          TextSpan(
            text: tok.substring(1, tok.length - 1),
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 12.5,
              backgroundColor: Color(0x1FFFFFFF),
            ),
          ),
        );
      } else {
        final inner = tok.substring(1, tok.length - 1);
        final cut = inner.indexOf('](');
        final label = inner.substring(0, cut);
        final url = inner.substring(cut + 2);
        final tap = TapGestureRecognizer()
          ..onTap = () {
            unawaited(SecureLinks.openExternal(url));
          };
        _taps.add(tap);
        spans.add(
          TextSpan(
            text: label,
            recognizer: tap,
            style: const TextStyle(
              color: Color(AfPalette.accent),
              decoration: TextDecoration.underline,
            ),
          ),
        );
      }
      last = m.end;
    }
    if (last < s.length) spans.add(TextSpan(text: s.substring(last)));
    return Text.rich(
      TextSpan(children: spans),
      style: AppType.body.copyWith(fontSize: 14, height: 1.6),
    );
  }

  Widget _codeCard(String lang, String code) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFF0B0E14),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: const Color(AfPalette.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(10, 5, 6, 5),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: Color(0x14FFFFFF))),
            ),
            child: Row(
              children: [
                Text(
                  lang.isEmpty ? 'code' : lang,
                  style: AppType.micro.copyWith(
                    fontSize: 10.5,
                    letterSpacing: .6,
                    color: const Color(AfPalette.text3),
                  ),
                ),
                const Spacer(),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () async {
                    await Clipboard.setData(ClipboardData(text: code));
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('已复制代码'),
                        duration: Duration(milliseconds: 1400),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                  },
                  child: Row(
                    children: const [
                      Icon(
                        Icons.copy_rounded,
                        size: 13,
                        color: Color(AfPalette.accent),
                      ),
                      SizedBox(width: 4),
                      Text(
                        '复制',
                        style: TextStyle(
                          fontSize: 11,
                          color: Color(AfPalette.accent),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 320),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
                  child: Text(
                    code,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontFamilyFallback: ['CJK'],
                      fontSize: 12.5,
                      height: 1.5,
                      color: Color(AfPalette.text),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 一轮 AI 回复：豆包 App 的任务消息卡。
  ///
  /// 一张大圆角卡包住整轮：顶部「已处理 13 分 20 秒」+ 虚线；正文用
  /// 「小图标 + 阶段标题 + ›」串起执行过程，最终答复直接接在同一条卡里。
  Widget _aiTurn(_Turn t) {
    final m = t.msg;
    final parts = afSplitSummary(m.text);
    final streamingNow = m.streaming || identical(m, _activeAi);
    final hasThinking = m.reasoning.trim().isNotEmpty;
    final hasBody =
        parts.body.trim().isNotEmpty || parts.summary.trim().isNotEmpty;
    final hasProcess = hasThinking || t.tools.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
        decoration: BoxDecoration(
          color: const Color(0xFF22262C),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: const Color(0x14FFFFFF)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _processedHead(t),
            const SizedBox(height: 9),
            const _DashLine(),
            if (parts.summary.isNotEmpty) ...[
              const SizedBox(height: 16),
              DefaultTextStyle.merge(
                style: const TextStyle(
                  fontSize: 14.5,
                  height: 1.65,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFFF2F4F7),
                ),
                child: _richBody(parts.summary),
              ),
            ],
            if (hasProcess || parts.body.trim().isNotEmpty)
              const SizedBox(height: 16),
            if (hasThinking) _thinkingRow(t),
            if (t.tools.isNotEmpty) _taskTrace(t),
            if (parts.body.trim().isNotEmpty) ...[
              if (hasProcess) const SizedBox(height: 14),
              DefaultTextStyle.merge(
                style: const TextStyle(
                  fontSize: 14,
                  height: 1.7,
                  color: Color(0xFFE7EBF1),
                ),
                child: (m.streaming || identical(m, _activeAi))
                    ? PhraseRevealText(
                        text: parts.body,
                        animate: true,
                        style: const TextStyle(
                          fontSize: 14,
                          height: 1.7,
                          color: Color(0xFFE7EBF1),
                        ),
                      )
                    : _richBody(parts.body),
              ),
            ] else if (!hasBody &&
                (m.streaming || identical(m, _activeAi)) &&
                !hasProcess)
              const Padding(
                padding: EdgeInsets.only(top: 14),
                child: ThinkingDots(),
              ),
            if (!streamingNow) ...[const SizedBox(height: 4), _sources(t)],
            if (t.files.isNotEmpty) ...[
              const SizedBox(height: 4),
              for (final f in t.files)
                _fileCard((f.tool?['detail'] as Map?) ?? {}),
            ],
            _msgActions(m),
          ],
        ),
      ),
    );
  }

  /// 豆包卡顶部的处理时长。跨过一分钟用「X 分 Y 秒」，与豆包一致。
  Widget _processedHead(_Turn t) {
    final m = t.msg;
    final streaming = m.streaming || identical(m, _activeAi);
    final text = streaming ? '正在处理' : _formatProcessMs(m.ms);
    return Row(
      children: [
        Text(
          text,
          style: const TextStyle(
            fontSize: 19,
            height: 1.35,
            fontWeight: FontWeight.w500,
            letterSpacing: .1,
            color: Color(0xFFC9D1DB),
          ),
        ),
        if (streaming) ...[const SizedBox(width: 8), const ThinkingDots()],
      ],
    );
  }

  String _formatProcessMs(int ms) {
    if (ms < 1000) return '任务已完成';
    final total = (ms / 1000).round();
    if (total < 60) return '已处理 $total 秒';
    final min = total ~/ 60;
    final sec = total % 60;
    return '已处理 $min 分 $sec 秒';
  }

  /// 阶段块之间留 18px，与豆包卡里的任务过程一致。
  Widget _taskTrace(_Turn t) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < t.tools.length; i++) ...[
          _taskStep(t.tools[i]),
          if (i < t.tools.length - 1) const SizedBox(height: 18),
        ],
      ],
    );
  }

  /// 单个任务阶段：小图标 + 阶段标题 + ›，下面一句人话。
  Widget _taskStep(_Msg m) {
    final t = m.tool ?? const <String, dynamic>{};
    final name = (t['name'] ?? '').toString();
    final meta = _toolMeta(name);
    final title = _stepTitle(m);
    final open = m.stepOpen;
    final raw = _stepRaw(m);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: raw.isEmpty
                ? null
                : () => setState(() => m.stepOpen = !m.stepOpen),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Icon(meta.$1, size: 15, color: const Color(0xFF9FA8B6)),
                  const SizedBox(width: 7),
                  Flexible(
                    child: Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13.5,
                        height: 1.45,
                        letterSpacing: .1,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFFC4CCD7),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  AnimatedRotation(
                    turns: open ? .25 : 0,
                    duration: const Duration(milliseconds: 160),
                    curve: Curves.easeOutCubic,
                    child: const Icon(
                      Icons.chevron_right_rounded,
                      size: 14,
                      color: Color(0xFF9FA8B6),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 7),
        Text(
          _stepNarrative(m),
          style: const TextStyle(
            fontSize: 14,
            height: 1.7,
            color: Color(0xFFE7EBF1),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: open && raw.isNotEmpty
              ? Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(top: 8),
                  padding: const EdgeInsets.only(left: 10),
                  decoration: const BoxDecoration(
                    border: Border(
                      left: BorderSide(color: Color(0x33FFFFFF), width: 1),
                    ),
                  ),
                  child: SelectionArea(
                    child: Text(
                      raw,
                      style: const TextStyle(
                        fontSize: 11.5,
                        height: 1.7,
                        color: Color(0xFF98A2B3),
                      ),
                    ),
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }

  String _stepTitle(_Msg m) {
    final t = m.tool ?? const <String, dynamic>{};
    final name = (t['name'] ?? '').toString();
    switch (name) {
      case 'web_search':
        return '检索资料';
      case 'fetch_url':
        return '读取资料';
      case 'bash':
        return '执行命令';
      case 'list_files':
        return '查看文件';
      case 'read_file':
        return '读取文件';
      case 'write_file':
        return '生成文件';
      case 'publish_file':
        return '交付成品';
      case 'gen_image':
        return '生成图片';
      case 'save_memory':
        return '记录偏好';
      default:
        return _toolMeta(name).$3;
    }
  }

  String _stepNarrative(_Msg m) {
    final t = m.tool ?? const <String, dynamic>{};
    final name = (t['name'] ?? '').toString();
    final st = (t['status'] ?? '').toString();
    final a = _asMap(t['args'] ?? const {});
    final d = _asMap(t['detail'] ?? const {});
    final err = (t['result'] ?? '').toString().trim();
    final running = st == 'running';
    if (st == 'error') {
      return '这一步没有成功${err.isEmpty ? '，我换一种方式继续。' : '：${_clip(err.split('\n').first, 70)}'}';
    }
    switch (name) {
      case 'web_search':
        final q = _clip((a['query'] ?? '').toString(), 44);
        if (running) return '正在搜索「$q」，并核对返回的来源。';
        final n = d['count'] ?? ((d['results'] as List?) ?? const []).length;
        final first = ((d['results'] as List?) ?? const []).isEmpty
            ? ''
            : ((_asMap(((d['results'] as List?) ?? const []).first)['domain'] ??
                      '')
                  .toString());
        return '「$q」搜索完成，找到 $n 条结果${first.isEmpty ? '' : '，先看 $first'}。';
      case 'fetch_url':
        final dom = (d['domain'] ?? '').toString();
        final title = _clip((d['title'] ?? '').toString(), 40);
        if (running) {
          return dom.isEmpty ? '正在打开页面读取正文。' : '正在打开 $dom 的页面读取正文。';
        }
        if (title.isNotEmpty) return '已读取《$title》，用来核对关键信息。';
        return dom.isEmpty ? '页面正文已读取。' : '已读取 $dom 的页面正文。';
      case 'bash':
        final cmd = _clip(
          (a['cmd'] ?? '').toString().replaceAll(RegExp(r'\s+'), ' '),
          56,
        );
        if (running) return cmd.isEmpty ? '正在执行命令，完成后继续下一步。' : '正在执行 $cmd。';
        final code = d['code'] ?? 0;
        final ms = d['ms'];
        final sec = ms is num
            ? ' · 用时 ${(ms / 1000).toStringAsFixed(1)} 秒'
            : '';
        return '${cmd.isEmpty ? '命令' : cmd} 已执行完成，退出码 $code$sec。';
      case 'list_files':
        final p = _clip((a['path'] ?? '').toString(), 56);
        return running
            ? '正在查看${p.isEmpty ? '文件目录' : ' $p'}。'
            : '已查看${p.isEmpty ? '文件目录' : ' $p'}。';
      case 'read_file':
        final p = _clip((a['path'] ?? '').toString(), 56);
        return running
            ? '正在读取${p.isEmpty ? '文件' : ' $p'}。'
            : '已读取${p.isEmpty ? '文件' : ' $p'}。';
      case 'write_file':
        final p = _clip((a['path'] ?? '').toString(), 56);
        return running
            ? '正在生成${p.isEmpty ? '文件' : ' $p'}。'
            : '${p.isEmpty ? '文件' : p} 已生成。';
      case 'publish_file':
        final f = (d['file'] ?? a['path'] ?? '成品').toString();
        final sz = d['size'];
        final kb = sz is num ? '，大小 ${(sz / 1024).toStringAsFixed(1)} KB' : '';
        return running ? '正在整理并交付 $f。' : '$f 已生成并交付$kb。';
      case 'gen_image':
        return running ? '正在生成图片。' : '图片已生成，正在整理交付。';
      case 'save_memory':
        return running ? '正在写入长期记忆。' : '已记录到长期记忆。';
      default:
        final sub = _toolSub(t);
        return sub.isEmpty ? (running ? '正在执行这一步。' : '这一步已完成。') : sub;
    }
  }

  String _stepRaw(_Msg m) {
    final t = m.tool ?? const <String, dynamic>{};
    final main = _toolMain(t).replaceAll(RegExp(r'\s+'), ' ').trim();
    final sub = _toolSub(t).replaceAll(RegExp(r'\s+'), ' ').trim();
    final dur = _toolElapsed(m);
    final parts = <String>[
      if (main.isNotEmpty) '参数  $main',
      if (sub.isNotEmpty) '结果  $sub',
      if (dur.isNotEmpty) '耗时  $dur',
    ];
    return parts.join('\n');
  }

  String _clip(String s, int max) {
    final t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (t.length <= max) return t;
    return '${t.substring(0, max)}…';
  }

  /// 思考过程：与任务阶段同构的一行入口；默认折叠，展开才看原文。
  Widget _thinkingRow(_Turn t) {
    final m = t.msg;
    final text = m.reasoning.trim();
    if (text.isEmpty) return const SizedBox.shrink();
    final streaming = m.streaming || identical(m, _activeAi);
    final open = m.reasoningOpen;
    final hasTrace = t.tools.isNotEmpty;
    return Padding(
      padding: EdgeInsets.only(bottom: hasTrace ? 18 : 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => setState(() => m.reasoningOpen = !m.reasoningOpen),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    const Icon(
                      Icons.psychology_alt_outlined,
                      size: 15,
                      color: Color(0xFF9FA8B6),
                    ),
                    const SizedBox(width: 7),
                    Text(
                      streaming ? '正在深度思考' : '思考过程',
                      style: const TextStyle(
                        fontSize: 13.5,
                        height: 1.45,
                        fontWeight: FontWeight.w500,
                        letterSpacing: .1,
                        color: Color(0xFFC4CCD7),
                      ),
                    ),
                    if (streaming) ...[
                      const SizedBox(width: 6),
                      const ThinkingDots(),
                    ],
                    const SizedBox(width: 4),
                    AnimatedRotation(
                      turns: open ? .25 : 0,
                      duration: const Duration(milliseconds: 160),
                      curve: Curves.easeOutCubic,
                      child: const Icon(
                        Icons.chevron_right_rounded,
                        size: 14,
                        color: Color(0xFF9FA8B6),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: open
                ? Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(top: 8),
                    padding: const EdgeInsets.only(left: 10),
                    constraints: const BoxConstraints(maxHeight: 260),
                    decoration: const BoxDecoration(
                      border: Border(
                        left: BorderSide(color: Color(0x33FFFFFF), width: 1),
                      ),
                    ),
                    child: SingleChildScrollView(
                      primary: false,
                      child: SelectionArea(
                        child: Text(
                          text,
                          style: const TextStyle(
                            fontSize: 11.5,
                            height: 1.8,
                            color: Color(0xFF98A2B3),
                          ),
                        ),
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  /// 工具名 → 图标/颜色/人话标签。现在只用 label 兜底，不再露图标。
  (IconData, Color, String) _toolMeta(String name) {
    switch (name) {
      case 'web_search':
        return (Icons.travel_explore_rounded, const Color(0xFF3AC9F5), '联网搜索');
      case 'fetch_url':
        return (Icons.language_rounded, const Color(0xFF3AC9F5), '读取网页');
      case 'bash':
        return (Icons.terminal_rounded, const Color(0xFFFFB020), '执行命令');
      case 'list_files':
        return (Icons.folder_open_rounded, const Color(0xFFB692FF), '查看文件');
      case 'read_file':
        return (Icons.description_rounded, const Color(0xFFB692FF), '读取文件');
      case 'write_file':
        return (Icons.edit_document, const Color(0xFF5B8DFF), '写入文件');
      case 'publish_file':
        return (Icons.download_rounded, const Color(0xFF35C759), '交付成品');
      case 'gen_image':
        return (Icons.auto_awesome_rounded, const Color(0xFFFF9F45), '生成图片');
      case 'save_memory':
        return (
          Icons.psychology_alt_rounded,
          const Color(0xFF9AA7B8),
          '记入长期记忆',
        );
      default:
        return (
          Icons.build_circle_rounded,
          const Color(AfPalette.accent),
          name,
        );
    }
  }

  String _toolMain(Map t) {
    final name = (t['name'] ?? '').toString();
    final a = _asMap(t['args'] ?? const {});
    if (name == 'web_search') return (a['query'] ?? '').toString();
    if (name == 'fetch_url') return (a['url'] ?? '').toString();
    if (name == 'bash') return (a['cmd'] ?? '').toString();
    if (name == 'gen_image') return (a['prompt'] ?? '').toString();
    final p = (a['path'] ?? a['file'] ?? '').toString();
    if (p.isNotEmpty) return p;
    return (a['url'] ?? a['content'] ?? '').toString();
  }

  String _toolSub(Map t) {
    final name = (t['name'] ?? '').toString();
    final d = _asMap(t['detail'] ?? const {});
    final st = (t['status'] ?? '').toString();
    if (st == 'running') return '正在执行…';
    if (st == 'error') {
      final r = (t['result'] ?? '').toString().trim();
      return r.isEmpty ? '执行失败' : r.split('\n').first;
    }
    if (name == 'web_search') {
      final c = d['count'];
      final rs = (d['results'] as List?) ?? const [];
      final first = rs.isEmpty
          ? ''
          : ((_asMap(rs.first)['domain'] ?? '').toString());
      return '${c ?? rs.length} 条结果${first.isEmpty ? '' : ' · $first'}';
    }
    if (name == 'fetch_url') {
      final title = (d['title'] ?? '').toString();
      final dom = (d['domain'] ?? '').toString();
      if (title.isNotEmpty) return title;
      return dom.isNotEmpty ? dom : '已读取正文';
    }
    if (name == 'bash') {
      final code = d['code'];
      final ms = d['ms'];
      final sec = ms is num ? (ms / 1000).toStringAsFixed(1) : '';
      return '退出 ${code ?? 0}${sec.isEmpty ? '' : ' · ${sec}s'}';
    }
    if (name == 'publish_file') {
      final f = (d['file'] ?? '').toString();
      final sz = d['size'];
      final kb = sz is num ? '${(sz / 1024).toStringAsFixed(1)} KB' : '';
      return [f, kb].where((e) => e.isNotEmpty).join(' · ');
    }
    if (name == 'write_file' || name == 'read_file' || name == 'list_files') {
      return (d['cmd'] ?? '').toString();
    }
    if (name == 'gen_image') {
      return (d['url'] ?? '').toString().isNotEmpty ? '图片已生成' : '已返回';
    }
    return (d['cmd'] ?? '').toString();
  }

  String _toolElapsed(_Msg m) {
    final a = m.toolStartedAt;
    final b = m.toolEndedAt;
    if (a == null) return '';
    final end = b ?? DateTime.now();
    final ms = end.difference(a).inMilliseconds;
    if (ms < 350) return '';
    if (ms < 1000) return '${ms}ms';
    return '${(ms / 1000).toStringAsFixed(1)}s';
  }

  /// 本轮引用过的来源：搜索命中 + 读过的网页，做成可点的域名 chips。
  Widget _sources(_Turn t) {
    final items = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final m in t.tools) {
      final d = _asMap(m.tool?['detail'] ?? const {});
      final name = (m.tool?['name'] ?? '').toString();
      if (name == 'web_search') {
        for (final r in ((d['results'] as List?) ?? const [])) {
          final x = _asMap(r);
          final u = (x['url'] ?? '').toString();
          if (u.isEmpty || !seen.add(u)) continue;
          items.add(x);
          if (items.length >= 5) break;
        }
      } else if (name == 'fetch_url') {
        final u = (d['url'] ?? '').toString();
        if (u.isEmpty || !seen.add(u)) continue;
        items.add({
          'url': u,
          'title': (d['title'] ?? '').toString(),
          'domain': (d['domain'] ?? '').toString(),
        });
      }
      if (items.length >= 5) break;
    }
    if (items.isEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.hub_outlined,
                size: 11,
                color: Color(AfPalette.text3),
              ),
              const SizedBox(width: 5),
              Text(
                '来源 · ${items.length}',
                style: const TextStyle(
                  fontSize: 10,
                  letterSpacing: .4,
                  color: Color(AfPalette.text3),
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final x in items)
                GestureDetector(
                  onTap: () async {
                    final u = (x['url'] ?? '').toString();
                    if (u.isEmpty) return;
                    final ok = await SecureLinks.openExternal(u);
                    if (!ok && mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('链接不在 HTTPS 安全域，已阻断'),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    }
                  },
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 210),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(AfPalette.card2),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: const Color(AfPalette.line)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 13,
                          height: 13,
                          alignment: Alignment.center,
                          decoration: const BoxDecoration(
                            color: Color(0x223AC9F5),
                            shape: BoxShape.circle,
                          ),
                          child: Text(
                            (x['domain'] ?? '?').toString().isEmpty
                                ? '?'
                                : (x['domain'] ?? '?')
                                      .toString()
                                      .substring(0, 1)
                                      .toUpperCase(),
                            style: const TextStyle(
                              fontSize: 8,
                              fontWeight: FontWeight.w700,
                              color: Color(AfPalette.accent),
                            ),
                          ),
                        ),
                        const SizedBox(width: 5),
                        Flexible(
                          child: Text(
                            (x['domain'] ?? '').toString().isEmpty
                                ? (x['title'] ?? '来源').toString()
                                : (x['domain'] ?? '').toString(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 10,
                              color: Color(AfPalette.text2),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  String _replyPlain(_Msg m) {
    final p = afSplitSummary(m.text);
    return [p.summary, p.body].where((e) => e.trim().isNotEmpty).join('\n\n');
  }

  Widget _msgActions(_Msg m) {
    if (m.role != 'ai' || m.streaming || m.text.trim().isEmpty) {
      return const SizedBox.shrink();
    }
    Widget btn(
      IconData ic,
      String semantic,
      VoidCallback onTap, {
      bool active = false,
    }) {
      return Semantics(
        button: true,
        label: semantic,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: active ? const Color(0x1F4C8DFF) : Colors.transparent,
              border: Border.all(
                color: active
                    ? const Color(0xFF4C8DFF)
                    : const Color(0x664C8DFF),
              ),
            ),
            child: Icon(
              ic,
              size: 17,
              color: active ? const Color(0xFF8BB8FF) : const Color(0xFF4C8DFF),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 2),
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          btn(Icons.copy_rounded, '复制', () async {
            await Clipboard.setData(ClipboardData(text: _replyPlain(m)));
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('已复制'),
                duration: Duration(milliseconds: 1200),
                behavior: SnackBarBehavior.floating,
              ),
            );
          }),
          btn(
            Icons.thumb_up_alt_outlined,
            '有帮助',
            () => setState(() => m.feedback = m.feedback == 1 ? 0 : 1),
            active: m.feedback == 1,
          ),
          btn(
            Icons.thumb_down_alt_outlined,
            '没帮助',
            () => setState(() => m.feedback = m.feedback == -1 ? 0 : -1),
            active: m.feedback == -1,
          ),
          btn(Icons.ios_share_rounded, '分享', () async {
            try {
              await Share.share(_replyPlain(m), subject: '小萤 Agent');
            } catch (_) {}
          }),
        ],
      ),
    );
  }

  Widget _userAtts(List<_Attach> atts) {
    final imgs = atts.where((a) => a.isImg).toList();
    final files = atts.where((a) => !a.isImg).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (imgs.isNotEmpty)
          Wrap(
            spacing: 6,
            runSpacing: 8,
            children: [for (final a in imgs) _userImage(a)],
          ),
        if (files.isNotEmpty) ...[
          if (imgs.isNotEmpty) const SizedBox(height: 8),
          for (final a in files)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: _userFile(a),
            ),
        ],
      ],
    );
  }

  Widget _userImage(_Attach a) {
    final url = (a.url ?? '').trim();
    Widget thumb;
    if (a.local != null) {
      thumb = Image.memory(a.local!, fit: BoxFit.cover);
    } else if (url.isNotEmpty) {
      thumb = CachedNetworkImageCompat(
        url: url,
        width: 84,
        height: 84,
        fit: BoxFit.cover,
        memCacheWidth: 240,
        placeholder: const ColoredBox(
          color: Color(AfPalette.card2),
          child: Center(
            child: SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                color: Color(AfPalette.accent),
              ),
            ),
          ),
        ),
        errorWidget: const ColoredBox(
          color: Color(AfPalette.card2),
          child: Center(
            child: Icon(
              Icons.image_not_supported_outlined,
              size: 17,
              color: Color(AfPalette.text3),
            ),
          ),
        ),
      );
    } else {
      thumb = const ColoredBox(
        color: Color(AfPalette.card2),
        child: Center(
          child: Icon(
            Icons.image_outlined,
            size: 18,
            color: Color(AfPalette.text3),
          ),
        ),
      );
    }
    return GestureDetector(
      onTap: url.isEmpty ? null : () => _openFile(url, a.name, 'image', '', ''),
      child: SizedBox(
        width: 84,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(width: 84, height: 84, child: thumb),
            ),
            const SizedBox(height: 4),
            Text(
              a.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 9.5, color: Color(0xCCFFFFFF)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _userFile(_Attach a) {
    final url = (a.url ?? '').trim();
    return GestureDetector(
      onTap: url.isEmpty
          ? null
          : () => _openFile(url, a.name, _kindOf(a.name, ''), '', ''),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 250),
        padding: const EdgeInsets.fromLTRB(9, 8, 9, 8),
        decoration: BoxDecoration(
          color: const Color(0x2EFFFFFF),
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: const Color(0x4DFFFFFF)),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.insert_drive_file_outlined,
              size: 19,
              color: Color(0xE6FFFFFF),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    a.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11.5,
                      height: 1.25,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    _sizeLabel(a.size),
                    style: const TextStyle(
                      fontSize: 9.5,
                      color: Color(0xB3FFFFFF),
                    ),
                  ),
                ],
              ),
            ),
            if (url.isNotEmpty) ...[
              const SizedBox(width: 6),
              const Icon(
                Icons.open_in_new_rounded,
                size: 14,
                color: Color(AfPalette.text3),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _bubble(_Msg m, {String? aiLead, String? aiBody}) {
    final isUser = m.role == 'user';
    final w = MediaQuery.of(context).size.width;
    final lead = isUser ? '' : (aiLead ?? '');
    final body = isUser ? m.text : (aiBody ?? afSplitSummary(m.text).body);
    return TweenAnimationBuilder<double>(
      key: ObjectKey(m),
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      builder: (_, v, child) => Opacity(
        opacity: v,
        child: Transform.translate(
          offset: Offset(0, (1 - v) * 8),
          child: child,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Row(
          mainAxisAlignment: isUser
              ? MainAxisAlignment.end
              : MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (isUser)
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: w * 0.78),
                child: Container(
                  padding: const EdgeInsets.fromLTRB(13, 10, 13, 10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0A84FF),
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(18),
                      topRight: Radius.circular(18),
                      bottomLeft: Radius.circular(18),
                      bottomRight: Radius.circular(6),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (m.text.trim().isNotEmpty)
                        DefaultTextStyle.merge(
                          style: const TextStyle(
                            fontSize: 14,
                            height: 1.6,
                            color: Colors.white,
                          ),
                          child: _richBody(m.text),
                        ),
                      if (m.atts.isNotEmpty) ...[
                        if (m.text.trim().isNotEmpty) const SizedBox(height: 8),
                        _userAtts(m.atts),
                      ],
                    ],
                  ),
                ),
              )
            else
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: w * 0.9),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 豆包式最终答复：不再套「本次总结」卡，结论与正文
                    // 直接作为同一条 AI 消息铺开。
                    if (lead.isNotEmpty) ...[
                      DefaultTextStyle.merge(
                        style: const TextStyle(
                          fontSize: 13.5,
                          height: 1.75,
                          fontWeight: FontWeight.w500,
                          color: Color(AfPalette.text),
                        ),
                        child: _richBody(lead),
                      ),
                      const SizedBox(height: 9),
                    ],
                    if (body.isNotEmpty)
                      DefaultTextStyle.merge(
                        style: const TextStyle(
                          fontSize: 13.5,
                          height: 1.75,
                          color: Color(AfPalette.text),
                        ),
                        child: (m.streaming || identical(m, _activeAi))
                            ? PhraseRevealText(
                                text: body,
                                animate: true,
                                style: const TextStyle(
                                  fontSize: 13.5,
                                  height: 1.75,
                                  color: Color(AfPalette.text),
                                ),
                              )
                            : _richBody(body),
                      )
                    else if ((m.streaming || identical(m, _activeAi)) &&
                        lead.isEmpty &&
                        m.reasoning.trim().isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 3),
                        child: ThinkingDots(),
                      )
                    else if (lead.isEmpty && m.reasoning.trim().isEmpty)
                      const Text(
                        '…',
                        style: TextStyle(
                          fontSize: 14,
                          height: 1.6,
                          color: Color(AfPalette.text),
                        ),
                      ),
                    if (m.costText.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        m.costText,
                        style: const TextStyle(
                          fontSize: 10.5,
                          color: Color(AfPalette.text3),
                        ),
                      ),
                    ],
                    if (!isUser) _msgActions(m),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _kindOf(String name, [String kind = '']) {
    if (kind.isNotEmpty) return kind;
    final low = name.toLowerCase();
    if (low.endsWith('.pptx') || low.endsWith('.ppt')) return 'ppt';
    if (low.endsWith('.docx') || low.endsWith('.doc')) return 'word';
    if (low.endsWith('.xlsx') || low.endsWith('.xls') || low.endsWith('.csv'))
      return 'excel';
    if (low.endsWith('.pdf')) return 'pdf';
    if (low.endsWith('.png') ||
        low.endsWith('.jpg') ||
        low.endsWith('.jpeg') ||
        low.endsWith('.webp')) {
      return 'image';
    }
    if (low.endsWith('.html') || low.endsWith('.htm')) return 'html';
    return 'file';
  }

  (IconData, Color) _kindStyle(String kind) {
    switch (kind) {
      case 'ppt':
        return (Icons.slideshow_rounded, const Color(0xFFFF9F45));
      case 'word':
        return (Icons.description_rounded, const Color(0xFF5B8DFF));
      case 'excel':
        return (Icons.table_chart_rounded, const Color(0xFF35C759));
      case 'pdf':
        return (Icons.picture_as_pdf_rounded, const Color(0xFFFF5A5F));
      case 'image':
        return (Icons.image_rounded, const Color(0xFFB692FF));
      case 'html':
        return (Icons.language_rounded, const Color(AppColors.accent));
      default:
        return (
          Icons.insert_drive_file_rounded,
          const Color(AppColors.textSecondary),
        );
    }
  }

  /// 豆包式文件卡：左竖条 + 类型块 + 文件名/大小 + 下载 / 放大预览
  Widget _fileCard(Map d) {
    final url = (d['url'] ?? '').toString();
    final name = (d['file'] ?? '文件').toString();
    final size = d['size'] is num ? (d['size'] as num).toDouble() : null;
    final kind = _kindOf(name, (d['kind'] ?? '').toString());
    final office = (d['office'] ?? '').toString();
    final preview = (d['preview'] ?? '').toString();
    final st = _kindStyle(kind);
    final sub = [
      if (size != null) '${(size / 1024).toStringAsFixed(1)} KB',
      kind == 'ppt'
          ? 'PPT'
          : kind == 'word'
          ? 'Word'
          : kind == 'excel'
          ? 'Excel'
          : kind == 'pdf'
          ? 'PDF'
          : kind == 'image'
          ? '图片'
          : kind == 'html'
          ? '网页'
          : '文件',
    ].join(' · ');
    return Container(
      margin: const EdgeInsets.fromLTRB(0, 8, 0, 8),
      decoration: BoxDecoration(
        color: const Color(AfPalette.card),
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: const Color(AfPalette.line)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            child: Container(
              width: 2.5,
              decoration: const BoxDecoration(gradient: AfPalette.edgeGrad),
            ),
          ),
          if (kind == 'image' && url.isNotEmpty)
            Positioned(
              left: 2.5,
              top: 0,
              bottom: 0,
              child: GestureDetector(
                onTap: () => _openFile(url, name, kind, office, preview),
                child: SizedBox(
                  width: 108,
                  height: 108,
                  child: CachedNetworkImageCompat(
                    url: url,
                    width: 108,
                    height: 108,
                    fit: BoxFit.cover,
                    memCacheWidth: 320,
                    placeholder: const ColoredBox(
                      color: Color(AfPalette.card2),
                    ),
                    errorWidget: const ColoredBox(
                      color: Color(AfPalette.card2),
                      child: Center(
                        child: Icon(
                          Icons.image_not_supported_outlined,
                          size: 18,
                          color: Color(AfPalette.text3),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              kind == 'image' && url.isNotEmpty ? 122 : 14,
              11,
              9,
              11,
            ),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: const Color(AfPalette.accentSoft),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: const Color(AfPalette.accentLine),
                    ),
                  ),
                  child: Icon(st.$1, size: 16, color: st.$2),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: PressableScale(
                    onTap: () => _openFile(url, name, kind, office, preview),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            height: 1.3,
                            color: Color(AfPalette.text),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          sub,
                          style: const TextStyle(
                            fontSize: 10,
                            letterSpacing: .2,
                            color: Color(AfPalette.text3),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                _fileBtn(
                  Icons.download_rounded,
                  '下载',
                  () => _download(url, name),
                ),
                _fileBtn(
                  Icons.open_in_full_rounded,
                  '放大预览',
                  () => _openFile(url, name, kind, office, preview),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _fileBtn(IconData icon, String tip, VoidCallback onTap) {
    return Tooltip(
      message: tip,
      child: PressableScale(
        onTap: onTap,
        child: Container(
          width: 30,
          height: 30,
          margin: const EdgeInsets.only(left: 6),
          decoration: BoxDecoration(
            color: const Color(0x0FFFFFFF),
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: const Color(AfPalette.line)),
          ),
          child: Icon(icon, size: 15, color: const Color(AfPalette.text2)),
        ),
      ),
    );
  }

  void _openFile(
    String url,
    String name,
    String kind,
    String office,
    String preview,
  ) {
    if (kind == 'image') {
      if (url.isEmpty) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => _ImageViewPage(url: url, name: name),
        ),
      );
      return;
    }
    // 只有网页产物优先打开可直接渲染的预览副本；doc/pdf/ppt 一律走原文件（office 在线预览）
    final isHtml =
        kind == 'html' ||
        name.toLowerCase().endsWith('.html') ||
        name.toLowerCase().endsWith('.htm');
    final target = isHtml && preview.isNotEmpty ? preview : url;
    if (target.isEmpty) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            _PreviewPage(url: target, name: name, kind: kind, office: office),
      ),
    );
  }

  Future<void> _download(String url, String name) async {
    if (url.isEmpty) return;
    final sm = ScaffoldMessenger.of(context);
    sm.showSnackBar(
      const SnackBar(
        content: Text('正在下载…'),
        duration: Duration(milliseconds: 1200),
        behavior: SnackBarBehavior.floating,
      ),
    );
    try {
      final r = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 120));
      if (r.statusCode != 200) throw 'HTTP ${r.statusCode}';
      final dir = await getTemporaryDirectory();
      final f = File('${dir.path}/$name');
      await f.writeAsBytes(r.bodyBytes, flush: true);
      await Share.shareXFiles([XFile(f.path)], text: name);
    } catch (e) {
      sm.showSnackBar(
        SnackBar(content: Text('下载失败：$e'), behavior: SnackBarBehavior.floating),
      );
    }
  }

  /// 按住说话：按下开始识别，松手结束并保留已识别文字
  Future<void> _startListening() async {
    if (_micOn) return;
    if (!_micReady) {
      final ok = await _speech.initialize();
      if (!ok) return;
      _micReady = true;
    }
    setState(() => _micOn = true);
    try {
      await _speech.listen(
        localeId: 'zh_CN',
        listenFor: const Duration(seconds: 60),
        pauseFor: const Duration(seconds: 3),
        onResult: (r) {
          if (mounted) setState(() => _input.text = r.recognizedWords);
        },
      );
    } catch (_) {
      if (mounted) setState(() => _micOn = false);
    }
  }

  Future<void> _stopListening() async {
    if (!_micOn) return;
    try {
      await _speech.stop();
    } catch (_) {}
    if (mounted) setState(() => _micOn = false);
  }

  Widget _attStrip() {
    if (_atts.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 72,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(
          AppSpace.gutter,
          8,
          AppSpace.gutter,
          6,
        ),
        itemCount: _atts.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final a = _atts[i];
          final isImg = (a.mime ?? '').startsWith('image/');
          return Container(
            width: 190,
            height: 58,
            padding: const EdgeInsets.fromLTRB(6, 6, 4, 6),
            decoration: BoxDecoration(
              color: const Color(AfPalette.card),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(AfPalette.lineStrong)),
            ),
            child: Row(
              children: [
                Stack(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(7),
                      child: SizedBox(
                        width: 42,
                        height: 42,
                        child: isImg && a.local != null
                            ? Image.memory(a.local!, fit: BoxFit.cover)
                            : ColoredBox(
                                color: const Color(AfPalette.card2),
                                child: Icon(
                                  isImg
                                      ? Icons.image_outlined
                                      : Icons.insert_drive_file_outlined,
                                  size: 17,
                                  color: const Color(AfPalette.text3),
                                ),
                              ),
                      ),
                    ),
                    if (a.uploading)
                      const Positioned.fill(
                        child: ColoredBox(
                          color: Color(0x88060A10),
                          child: Center(
                            child: SizedBox(
                              width: 13,
                              height: 13,
                              child: CircularProgressIndicator(
                                strokeWidth: 1.5,
                                color: Color(AfPalette.accent),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        a.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11.5,
                          height: 1.25,
                          fontWeight: FontWeight.w600,
                          color: Color(AfPalette.text),
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        a.uploading ? '上传中…' : _sizeLabel(a.size),
                        style: const TextStyle(
                          fontSize: 9.5,
                          color: Color(AfPalette.text3),
                        ),
                      ),
                    ],
                  ),
                ),
                GestureDetector(
                  onTap: () => setState(() => _atts.removeAt(i)),
                  behavior: HitTestBehavior.opaque,
                  child: const Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(
                      Icons.close_rounded,
                      size: 14,
                      color: Color(AfPalette.text3),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _composer() {
    return InputPanelHost(
      absorbInsets: false,
      surfaceColor: const Color(AfPalette.bg),
      fallbackHeight: 286,
      inputBar: _composerBar(),
      panel: _attachOpen ? _attachPanel() : null,
    );
  }

  void _toggleAttachPanel() {
    if (_busy) return;
    if (_attachOpen) {
      setState(() => _attachOpen = false);
      return;
    }
    // 保留输入框焦点；面板占住键盘位置，不叠一层弹窗
    _inputFocus.requestFocus();
    unawaited(SystemChannels.textInput.invokeMethod('TextInput.hide'));
    setState(() => _attachOpen = true);
    _scrollBottom(force: true);
  }

  void _closeAttachPanel({bool unfocus = false}) {
    if (_attachOpen) setState(() => _attachOpen = false);
    if (unfocus && _inputFocus.hasFocus) _inputFocus.unfocus();
  }

  void _closeAttachForTyping() {
    if (_attachOpen) setState(() => _attachOpen = false);
  }

  Widget _composerBar() {
    final blocked = _token != null && _left <= 0;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 10),
      decoration: const BoxDecoration(
        color: Color(AfPalette.bg),
        border: Border(top: BorderSide(color: Color(AfPalette.line))),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _modeBar(),
          _attStrip(),
          const SizedBox(height: 6),
          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            padding: const EdgeInsets.fromLTRB(9, 8, 8, 8),
            decoration: BoxDecoration(
              // 输入框必须是不透明底，不能透出后面的消息列表
              color: const Color(AfPalette.card2),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                color: _focused
                    ? const Color(AfPalette.accentLineStrong)
                    : const Color(AfPalette.lineStrong),
              ),
            ),
            child: Row(
              children: [
                PressableScale(
                  onTap: _busy ? null : _toggleAttachPanel,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: _attachOpen
                          ? const Color(AfPalette.accentSoft)
                          : const Color(0x08FFFFFF),
                      borderRadius: BorderRadius.circular(11),
                      border: Border.all(
                        color: _attachOpen
                            ? const Color(AfPalette.accentLine)
                            : const Color(AfPalette.line),
                      ),
                    ),
                    child: AnimatedRotation(
                      turns: _attachOpen ? .125 : 0,
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeOut,
                      child: Icon(
                        Icons.add_rounded,
                        size: 15,
                        color: _attachOpen
                            ? const Color(AfPalette.accent)
                            : const Color(AfPalette.text2),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: TextField(
                    focusNode: _inputFocus,
                    controller: _input,
                    minLines: 1,
                    maxLines: 4,
                    cursorColor: const Color(AfPalette.accent),
                    style: const TextStyle(
                      fontSize: 13,
                      height: 1.5,
                      color: Color(AfPalette.text),
                    ),
                    onTap: _closeAttachForTyping,
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: const Color(AfPalette.card2),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      disabledBorder: InputBorder.none,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 6),
                      hintText: _micOn
                          ? '正在听…松手结束'
                          : (_token == null
                                ? '登录后可用…'
                                : (_left <= 0
                                      ? '额度已用完'
                                      : (_mode == 'work'
                                            ? '给我一个目标，我来拆步骤…'
                                            : '问点什么…'))),
                      hintStyle: const TextStyle(
                        fontSize: 13,
                        color: Color(AfPalette.text3),
                      ),
                    ),
                    onSubmitted: (_) => _send(),
                  ),
                ),
                GestureDetector(
                  onLongPressStart: (_) => _startListening(),
                  onLongPressEnd: (_) => _stopListening(),
                  onLongPressCancel: _stopListening,
                  behavior: HitTestBehavior.opaque,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    width: 28,
                    height: 30,
                    decoration: BoxDecoration(
                      color: _micOn
                          ? const Color(0x263AC9F5)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Icon(
                      _micOn
                          ? Icons.graphic_eq_rounded
                          : Icons.mic_none_rounded,
                      size: 17,
                      color: _micOn
                          ? const Color(AfPalette.accent)
                          : const Color(AfPalette.text3),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                PressableScale(
                  onTap: _busy ? _abort : (blocked ? null : _send),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOut,
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      gradient: blocked && !_busy ? null : AfPalette.accentGrad,
                      color: blocked && !_busy
                          ? const Color(AfPalette.card2)
                          : null,
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: blocked && !_busy ? null : AfPalette.glow(),
                    ),
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 180),
                      switchInCurve: Curves.easeOut,
                      switchOutCurve: Curves.easeIn,
                      transitionBuilder: (c, a) =>
                          ScaleTransition(scale: a, child: c),
                      child: _busy
                          ? const Icon(
                              Icons.stop_rounded,
                              key: ValueKey('stop'),
                              size: 17,
                              color: Color(AfPalette.onAccent),
                            )
                          : Icon(
                              Icons.arrow_upward_rounded,
                              key: const ValueKey('send'),
                              size: 18,
                              color: blocked
                                  ? const Color(AfPalette.text3)
                                  : const Color(AfPalette.onAccent),
                            ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _attachPanel() {
    return Container(
      color: const Color(AfPalette.bg),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                '添加到对话',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Color(AfPalette.text),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _model == 'deepseek-v4-pro'
                      ? '带图这轮会切到「快速」视觉模型'
                      : '图片和文件会读进上下文',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10.5,
                    color: Color(AfPalette.text3),
                  ),
                ),
              ),
              GestureDetector(
                onTap: () => _closeAttachPanel(),
                behavior: HitTestBehavior.opaque,
                child: const Padding(
                  padding: EdgeInsets.all(5),
                  child: Icon(
                    Icons.close_rounded,
                    size: 17,
                    color: Color(AfPalette.text3),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (context, c) {
              final w = (c.maxWidth - 24) / 3;
              final items = <(IconData, String, VoidCallback, Color)>[
                (
                  Icons.photo_library_outlined,
                  '相册',
                  () {
                    _closeAttachPanel(unfocus: true);
                    _pickImage();
                  },
                  const Color(0xFF5B8DFF),
                ),
                (
                  Icons.photo_camera_outlined,
                  '拍照',
                  () {
                    _closeAttachPanel(unfocus: true);
                    _pickCamera();
                  },
                  const Color(AppColors.accent),
                ),
                (
                  Icons.attach_file_rounded,
                  '文件',
                  () {
                    _closeAttachPanel(unfocus: true);
                    _pickFile();
                  },
                  const Color(0xFFFFA94D),
                ),
                (
                  Icons.psychology_alt_outlined,
                  '记忆',
                  () {
                    _closeAttachPanel(unfocus: true);
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const AfMemoryPage()),
                    );
                  },
                  const Color(0xFFB692FF),
                ),
                (
                  Icons.add_comment_outlined,
                  '新对话',
                  () {
                    _closeAttachPanel(unfocus: true);
                    _newConv();
                  },
                  const Color(0xFF8E8E96),
                ),
              ];
              return Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final it in items)
                    _attachTile(it.$1, it.$2, it.$3, it.$4, width: w),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _attachTile(
    IconData icon,
    String label,
    VoidCallback onTap,
    Color tint, {
    required double width,
  }) {
    return PressableScale(
      onTap: onTap,
      child: SizedBox(
        width: width,
        height: 78,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: tint.withValues(alpha: .11),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: tint.withValues(alpha: .20)),
              ),
              child: Icon(icon, size: 21, color: tint),
            ),
            const SizedBox(height: 7),
            Text(
              label,
              style: const TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w500,
                color: Color(AfPalette.text2),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 网页预览：AI 写出来的 HTML 直接在这里看，不跳浏览器。
class _PreviewPage extends StatefulWidget {
  const _PreviewPage({required this.url, this.name, this.kind, this.office});
  final String url;
  final String? name;
  final String? kind;
  final String? office;

  @override
  State<_PreviewPage> createState() => _PreviewPageState();
}

class _PreviewPageState extends State<_PreviewPage> {
  WebViewController? _web;
  bool _ready = false;
  bool _textMode = false;
  bool _textLoading = false;
  String? _textErr;
  List<dynamic> _pages = const [];

  Map<String, dynamic> _m(dynamic x) => x is Map
      ? x.map((k, v) => MapEntry(k.toString(), v))
      : <String, dynamic>{};

  bool get _isOffice =>
      (widget.kind == 'ppt' ||
          widget.kind == 'word' ||
          widget.kind == 'excel') &&
      (widget.office ?? '').isNotEmpty;
  bool get _isPdf =>
      (widget.kind == 'pdf') || widget.url.toLowerCase().endsWith('.pdf');

  @override
  void initState() {
    super.initState();
    // office 类默认先给文字版（秒开），点「看版式」再加载微软在线预览
    if (_isOffice) {
      _textMode = true;
      _loadText();
    } else {
      _initWeb();
    }
  }

  bool _allowedPreviewHost(Uri uri) {
    if (uri.scheme != 'https') return false;
    final api = Uri.tryParse(ApiClient.baseUrl);
    final host = uri.host.toLowerCase();
    if (api != null && host == api.host.toLowerCase()) return true;
    // Office 在线预览只放行微软官方预览域；其他外部跳转一律阻断。
    return host == 'view.officeapps.live.com' ||
        host.endsWith('.officeapps.live.com');
  }

  void _initWeb() {
    if (_web != null) return;
    final target = Uri.tryParse(_isOffice ? widget.office! : widget.url);
    if (target == null || !_allowedPreviewHost(target)) {
      _switchText();
      return;
    }
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(AppColors.bg))
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            final uri = Uri.tryParse(request.url);
            if (uri == null || !_allowedPreviewHost(uri)) {
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
          onPageFinished: (_) => setState(() => _ready = true),
          onWebResourceError: (_) {
            setState(() => _ready = true);
            if (_isOffice) _switchText();
          },
        ),
      )
      ..loadRequest(target);
  }

  Future<void> _loadText() async {
    setState(() => _textLoading = true);
    try {
      final r = await http
          .get(
            Uri.parse(
              '$kApiBase/af/doc_text?url=${Uri.encodeComponent(widget.url)}',
            ),
            headers: {
              if (ApiClient.token != null)
                'Authorization': 'Bearer ${ApiClient.token}',
            },
          )
          .timeout(const Duration(seconds: 40));
      final j = _m(jsonDecode(r.body));
      if (j['ok'] == true) {
        setState(() => _pages = (j['pages'] as List?) ?? const []);
      } else {
        setState(() => _textErr = (j['error'] ?? '解析失败').toString());
      }
    } catch (e) {
      setState(() => _textErr = e.toString());
    } finally {
      if (mounted) setState(() => _textLoading = false);
    }
  }

  void _switchText() {
    if (!mounted) return;
    setState(() => _textMode = true);
    if (_pages.isEmpty && _textErr == null) _loadText();
  }

  Widget _textBody() {
    if (_textLoading) {
      return const Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: Color(AppColors.accent),
          ),
        ),
      );
    }
    if (_textErr != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '这个文件读不出内容：$_textErr',
            style: const TextStyle(color: Color(AppColors.textTertiary)),
          ),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
      children: [
        for (final pg in _pages)
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            decoration: BoxDecoration(
              color: const Color(AppColors.card),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0x14FFFFFF)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  (_m(pg)['title'] ?? '').toString(),
                  style: AppType.body.copyWith(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: const Color(AppColors.accent),
                  ),
                ),
                const SizedBox(height: 6),
                for (final l in ((_m(pg)['lines'] as List?) ?? const []))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Text(
                      l.toString(),
                      style: AppType.body.copyWith(fontSize: 13, height: 1.55),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(AppColors.bg),
      appBar: AppBar(
        backgroundColor: const Color(AppColors.bg),
        title: Text(
          widget.name ?? (_isPdf ? 'PDF' : '预览'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 15),
        ),
        actions: [
          if (_isOffice)
            TextButton(
              onPressed: () {
                if (_textMode) {
                  setState(() => _textMode = false);
                  _initWeb();
                } else {
                  setState(() => _textMode = true);
                }
              },
              child: Text(
                _textMode ? '看版式' : '文字版',
                style: const TextStyle(
                  fontSize: 12.5,
                  color: Color(AppColors.accent),
                ),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.download_rounded, size: 19),
            onPressed: () =>
                _saveShare(context, widget.url, widget.name ?? 'file'),
          ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded, size: 19),
            onPressed: () {
              if (_textMode) {
                _loadText();
              } else {
                _web?.reload();
              }
            },
          ),
        ],
      ),
      body: _textMode
          ? _textBody()
          : Stack(
              children: [
                if (_web != null) WebViewWidget(controller: _web!),
                if (!_ready)
                  const Center(
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Color(AppColors.accent),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

/// 图片产物：全屏可缩放。
class _ImageViewPage extends StatelessWidget {
  const _ImageViewPage({required this.url, this.name});
  final String url;
  final String? name;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text(
          name ?? '图片',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 15),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.download_rounded, size: 19),
            onPressed: () => _saveShare(context, url, name ?? 'image.png'),
          ),
        ],
      ),
      body: Center(
        child: InteractiveViewer(
          maxScale: 4,
          child: CachedNetworkImageCompat(
            url: url,
            fit: BoxFit.contain,
            memCacheWidth:
                (MediaQuery.sizeOf(context).width *
                        MediaQuery.devicePixelRatioOf(context))
                    .ceil(),
            placeholder: const Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Color(AppColors.accent),
                ),
              ),
            ),
            errorWidget: const ImagePlaceholder(
              icon: Icons.broken_image_outlined,
              radius: 0,
            ),
          ),
        ),
      ),
    );
  }
}

/// 豆包过程区顶部的细分隔线。
class _DashLine extends StatelessWidget {
  const _DashLine();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 1,
      child: CustomPaint(painter: _DashPainter()),
    );
  }
}

class _DashPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0x99FFFFFF)
      ..strokeWidth = 1;
    const gap = 4.0;
    const dash = 3.0;
    var x = 0.0;
    while (x < size.width) {
      canvas.drawLine(Offset(x, 0), Offset(x + dash, 0), paint);
      x += dash + gap;
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

Future<void> _saveShare(BuildContext context, String url, String name) async {
  final sm = ScaffoldMessenger.maybeOf(context);
  sm?.showSnackBar(
    const SnackBar(
      content: Text('正在准备文件…'),
      duration: Duration(milliseconds: 1200),
      behavior: SnackBarBehavior.floating,
    ),
  );
  try {
    final r = await http
        .get(Uri.parse(url))
        .timeout(const Duration(seconds: 120));
    if (r.statusCode != 200) throw 'HTTP ${r.statusCode}';
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/$name');
    await f.writeAsBytes(r.bodyBytes, flush: true);
    await Share.shareXFiles([XFile(f.path)], text: name);
  } catch (e) {
    sm?.showSnackBar(
      SnackBar(content: Text('下载失败：$e'), behavior: SnackBarBehavior.floating),
    );
  }
}
