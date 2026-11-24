/// 流萤社区 · API 客户端
/// - 社区接口：Bearer token（与音乐 tokens 表互通）
/// - 登录：走音乐 /music/api/login（multipart），拿同一份 token
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:http/http.dart' as http;

import '../config.dart';
import '../models/feed_item.dart';

class _SecureHttpClient extends http.BaseClient {
  final http.Client _inner = http.Client();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    // 禁止 API 请求跟随 302：避免 Authorization 被带到第三方/CDN 域名。
    request.followRedirects = false;
    return _inner.send(request);
  }
}

class ApiException implements Exception {
  final int code;
  final String message;
  ApiException(this.code, this.message);
  @override
  String toString() => message;
}

/// 人机验证答案：Cap 一次性 token、自托管滑块(id+x/y)、图片(id+code) 或腾讯(ticket+randstr)。
class CaptchaAnswer {
  final String id;
  final String code;
  final String capToken;
  final String ticket;
  final String randstr;
  final double? x;
  final double? y;
  const CaptchaAnswer({
    this.id = '',
    this.code = '',
    this.capToken = '',
    this.ticket = '',
    this.randstr = '',
    this.x,
    this.y,
  });

  const CaptchaAnswer.cap({
    required this.capToken,
    this.id = '',
    this.code = '',
    this.ticket = '',
    this.randstr = '',
    this.x,
    this.y,
  });

  const CaptchaAnswer.slider({
    required this.id,
    required this.x,
    this.y,
    this.code = '',
    this.capToken = '',
    this.ticket = '',
    this.randstr = '',
  });

  const CaptchaAnswer.tencent({
    required this.ticket,
    required this.randstr,
    this.id = '',
    this.code = '',
    this.capToken = '',
    this.x,
    this.y,
  });

  bool get isCap => capToken.isNotEmpty;
  bool get isTencent => ticket.isNotEmpty;

  Map<String, dynamic> toBody() {
    if (isCap) {
      return {'cap_token': capToken};
    }
    if (isTencent) {
      return {'captcha_ticket': ticket, 'captcha_randstr': randstr};
    }
    if (x != null) {
      return {
        'captcha_id': id,
        'captcha_x': x,
        if (y != null) 'captcha_y': y,
      };
    }
    return {'captcha_id': id, 'captcha_code': code};
  }
}

/// 人机验证配置：cap=自托管挑战，tencent=Ticket 滑块。
class CaptchaConfig {
  final String provider;
  final String appId;
  const CaptchaConfig({required this.provider, required this.appId});
  bool get isCap => provider == 'cap';
  bool get isTencent => provider == 'tencent' && appId.isNotEmpty;
}

/// 自托管滑动拼图挑战（背景图 + 透明拼图块 + 初始位置）。
class CaptchaChallenge {
  final String id;
  final String bg;
  final String tile;
  final int width;
  final int height;
  final double y;
  final double tileX;
  final double tileY;
  final int pieceWidth;
  final int pieceHeight;
  const CaptchaChallenge({
    required this.id,
    required this.bg,
    required this.tile,
    required this.width,
    required this.height,
    required this.y,
    required this.tileX,
    required this.tileY,
    required this.pieceWidth,
    required this.pieceHeight,
  });
}

class ApiClient {
  /// 可注入的 HTTP 客户端：生产用默认 Client，测试用 MockClient 复用请求层。
  static http.Client httpClient = _SecureHttpClient();

  /// 仅测试使用：覆盖 API 基址，生产必须保持 null。
  static String? baseOverride;
  static String get baseUrl => baseOverride ?? kApiBase;

  /// 只允许 HTTPS（本地调试/单测覆盖除外），防止 token 走明文链路。
  static Uri _safeUri(String raw) {
    final uri = Uri.parse(raw);
    if (uri.scheme == 'https') return uri;
    final local = uri.host == '127.0.0.1' || uri.host == 'localhost';
    if (baseOverride != null || (kDebugMode && local)) return uri;
    throw ApiException(0, '为保证账号安全，请使用 HTTPS 连接');
  }

  static Uri _apiUri(String path) => _safeUri('$baseUrl$path');

  static String? token; // 全局登录态（内存缓存）
  static String? userId; // 当前登录用户 id（myProfile 成功后缓存）

  /// 当前登录用户资料缓存：头像角标等局部组件用，避免每个入口再拉一次 /user/me。
  static Map<String, dynamic>? meProfile;
  static String? meSignature; // 当前登录用户简介（myProfile 成功后缓存）

  // ---------- 基础请求 ----------

  static Map<String, String> _headers({bool json = true}) => {
    if (token != null && token!.isNotEmpty) 'Authorization': 'Bearer $token',
    if (json) 'Content-Type': 'application/json; charset=utf-8',
  };

  /// 解析后端统一响应 {ok, error/msg, ...}
  static Map<String, dynamic> _unwrap(http.Response r) {
    final Map<String, dynamic> j;
    try {
      j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {
      throw ApiException(r.statusCode, '响应解析失败 (HTTP ${r.statusCode})');
    }
    if (r.statusCode != 200 || (j['ok'] != true)) {
      throw ApiException(
        r.statusCode,
        (j['error'] ?? j['msg'] ?? '请求失败') as String,
      );
    }
    return j;
  }

  static Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    var uri = _apiUri(path);
    if (query != null && query.isNotEmpty) {
      uri = uri.replace(queryParameters: {...uri.queryParameters, ...query});
    }
    final r = await httpClient
        .get(uri, headers: _headers())
        .timeout(const Duration(seconds: 15));
    return _unwrap(r);
  }

  /// 检查客户端更新（公开接口，不需要登录 token）。
  /// 后端按平台返回最高且已上线的版本，并在服务端完成版本/build 比较。
  static Future<Map<String, dynamic>> appVersion({
    required String platform,
    required String version,
    required int build,
    String channel = 'stable',
    String device = '',
  }) => get(
    '/app/version',
    query: {
      'platform': platform,
      'version': version,
      'build': '$build',
      'channel': channel,
      if (device.isNotEmpty) 'device': device,
    },
  );

  /// 拉取远程配置（公开接口）：服务端按平台/渠道/build/灰度完成过滤。
  static Future<Map<String, dynamic>> hotUpdate({
    required String platform,
    required String version,
    required int build,
    required String channel,
    required String device,
  }) => get(
    '/app/hot-update',
    query: {
      'platform': platform,
      'version': version,
      'build': '$build',
      'channel': channel,
      'device': device,
    },
  );

  static Future<Map<String, dynamic>> post(
    String path, {
    Map<String, dynamic>? body,
  }) async {
    final r = await httpClient
        .post(
          _apiUri(path),
          headers: _headers(),
          // 无 body 时不要发 "{}"：部分后端路由不读 body，{} 会留在
          // HTTP/1.1 keep-alive 连接里，污染下一个请求。
          body: body == null ? null : jsonEncode(body),
        )
        .timeout(const Duration(seconds: 20));
    return _unwrap(r);
  }

  static Future<Map<String, dynamic>> put(
    String path, {
    Map<String, dynamic>? body,
  }) async {
    final r = await httpClient
        .put(
          _apiUri(path),
          headers: _headers(),
          body: jsonEncode(body ?? {}),
        )
        .timeout(const Duration(seconds: 20));
    return _unwrap(r);
  }

  static Future<Map<String, dynamic>> delete(String path) async {
    final r = await httpClient
        .delete(_apiUri(path), headers: _headers())
        .timeout(const Duration(seconds: 20));
    return _unwrap(r);
  }

  // ---------- 登录互通（音乐） ----------

  /// 邮箱规范化：全角→半角、去零宽字符/内部空格、统一小写。
  ///
  /// 后端邮箱正则仅允许 [a-zA-Z0-9_.+-]@[a-zA-Z0-9-].[a-zA-Z0-9-.]+，
  /// 全角字符（＠、ＡＢＣ、．）、零宽空格、内部空格都会导致「邮箱格式不正确」，
  /// 这里在客户端先纠正，让"看起来正确"的邮箱能正常通过。
  static String normalizeEmail(String raw) {
    final buf = StringBuffer();
    for (final ch in raw.trim().runes) {
      if (ch >= 0xFF01 && ch <= 0xFF5E) {
        buf.writeCharCode(ch - 0xFEE0); // 全角 → 半角
      } else if (ch == 0x3000 || ch == 0x20) {
        continue; // 全角空格/普通空格一律剔除
      } else if (ch == 0x200B || ch == 0x200C || ch == 0x200D || ch == 0xFEFF) {
        continue; // 剔除零宽空格/BOM
      } else {
        buf.writeCharCode(ch);
      }
    }
    return buf.toString().toLowerCase();
  }

  /// 本地邮箱格式校验（与服务端校验正则完全一致）
  static bool isValidEmail(String email) =>
      RegExp(r'^[a-zA-Z0-9_.+-]+@[a-zA-Z0-9-]+\.[a-zA-Z0-9-.]+$')
          .hasMatch(email);

  /// 大陆手机号规范化：去空格/横线/括号，+86 前缀。
  static String normalizePhone(String raw) {
    var s = raw.trim().replaceAll(RegExp(r'[\s\-()]'), '');
    if (s.startsWith('+86')) s = s.substring(3);
    if (s.startsWith('86') && s.length == 13) s = s.substring(2);
    return s;
  }

  static bool isValidPhone(String phone) =>
      RegExp(r'^1[3-9]\d{9}$').hasMatch(normalizePhone(phone));

  /// 获取自托管滑动拼图挑战（发送短信/邮件验证码前调用）。
  static Future<CaptchaChallenge> fetchCaptcha() async {
    final r = await httpClient
        .get(_apiUri('/captcha'), headers: _headers(json: false))
        .timeout(const Duration(seconds: 15));
    final Map<String, dynamic> j;
    try {
      j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {
      throw ApiException(r.statusCode, '滑块验证加载失败');
    }
    if (r.statusCode != 200 || j['ok'] != true) {
      throw ApiException(
        r.statusCode,
        (j['error'] ?? j['msg'] ?? '滑块验证加载失败') as String,
      );
    }
    final id = (j['id'] ?? '').toString();
    final bg = (j['bg'] ?? '').toString();
    final tile = (j['tile'] ?? '').toString();
    if (id.isEmpty ||
        !bg.startsWith('data:image/') ||
        !tile.startsWith('data:image/')) {
      throw ApiException(0, '滑块验证数据异常');
    }
    return CaptchaChallenge(
      id: id,
      bg: bg,
      tile: tile,
      width: (j['width'] as num?)?.toInt() ?? 300,
      height: (j['height'] as num?)?.toInt() ?? 220,
      y: (j['y'] as num?)?.toDouble() ?? 0,
      tileX: (j['tile_x'] as num?)?.toDouble() ?? 0,
      tileY: (j['tile_y'] as num?)?.toDouble() ?? 0,
      pieceWidth: (j['piece_width'] as num?)?.toInt() ?? 60,
      pieceHeight: (j['piece_height'] as num?)?.toInt() ?? 60,
    );
  }

  /// 获取人机验证配置：腾讯密钥完整时优先腾讯，否则走 Cap 自托管挑战。
  static Future<CaptchaConfig> fetchCaptchaConfig() async {
    final r = await httpClient
        .get(_apiUri('/captcha/config'), headers: _headers(json: false))
        .timeout(const Duration(seconds: 10));
    Map<String, dynamic> j;
    try {
      j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {
      throw ApiException(r.statusCode, '人机验证配置加载失败');
    }
    if (r.statusCode != 200 || j['ok'] != true) {
      throw ApiException(
        r.statusCode,
        (j['error'] ?? j['msg'] ?? '人机验证配置加载失败') as String,
      );
    }
    return CaptchaConfig(
      provider: (j['provider'] ?? 'cap').toString(),
      appId: (j['app_id'] ?? '').toString(),
    );
  }

  /// 单输入框验证码发送：手机号走社区短信，邮箱走社区邮件。
  /// 两个入口都必须携带人机验证，服务端会再次校验。
  static Future<void> sendLoginCode(
    String identifier,
    CaptchaAnswer captcha,
  ) async {
    final raw = identifier.trim();
    if (isValidPhone(raw)) {
      await _postLogin(_apiUri('/auth/send-code'), {
        'identifier': normalizePhone(raw),
        ...captcha.toBody(),
      });
      return;
    }
    final email = normalizeEmail(raw);
    if (!isValidEmail(email)) {
      throw ApiException(0, '请输入正确的手机号或邮箱');
    }
    await sendEmailCode(email, captcha);
  }

  /// 单输入框验证码登录/注册：手机号走社区，邮箱沿用音乐优先回退社区。
  static Future<Map<String, dynamic>> loginCode(
    String identifier,
    String code,
  ) async {
    final raw = identifier.trim();
    if (isValidPhone(raw)) {
      return _postLogin(_apiUri('/auth/login-code'), {
        'identifier': normalizePhone(raw),
        'code': code.trim(),
      });
    }
    final email = normalizeEmail(raw);
    if (!isValidEmail(email)) {
      throw ApiException(0, '请输入正确的手机号或邮箱');
    }
    return loginEmail(email, code);
  }

  /// 发送邮箱验证码（统一走社区 /auth/send-email-code）。
  ///
  /// 必须由社区服务端校验人机验证；不能再走音乐接口，否则可绕过 captcha。
  /// 使用 JSON 而非 multipart，避免服务端 multipart 字段名大小写差异。
  static Future<void> sendEmailCode(
    String email,
    CaptchaAnswer captcha,
  ) async {
    final normalized = normalizeEmail(email);
    await _postLogin(_apiUri('/auth/send-email-code'), {
      'email': normalized,
      ...captcha.toBody(),
    });
  }

  /// 邮箱验证码登录 / 注册（音乐优先，5xx/不可达回退社区 /auth/login-email；新邮箱自动注册）
  /// 成功返回用户资料（含 token）。同样用 JSON 而非 multipart（见 sendEmailCode）。
  static Future<Map<String, dynamic>> loginEmail(
    String email,
    String code,
  ) async {
    final normalized = normalizeEmail(email);
    try {
      final r = await httpClient
          .post(
            _safeUri('$kMusicBase/api/login-email'),
            headers: _headers(),
            body: jsonEncode({'email': normalized, 'code': code.trim()}),
          )
          .timeout(const Duration(seconds: 20));
      final Map<String, dynamic> j;
      try {
        j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
      } catch (_) {
        throw ApiException(r.statusCode, '响应解析失败 (HTTP ${r.statusCode})');
      }
      // 音乐登录成功直接返回用户 JSON（含 token，无 ok 包装）；失败返回 {err: msg}
      if (r.statusCode != 200) {
        throw ApiException(
          r.statusCode,
          (j['err'] ?? j['error'] ?? j['msg'] ?? '登录失败') as String,
        );
      }
      return j;
    } catch (e) {
      if (!_loginFallbackAllowed(e)) rethrow;
      try {
        return await _postLogin(_apiUri('/auth/login-email'), {
          'email': normalized,
          'code': code.trim(),
        });
      } catch (_) {
        throw e;
      }
    }
  }

  /// 账号密码登录（音乐 /music/api/login，返回 token 与用户资料）
  ///
  /// 用 JSON 而不是 multipart：Dart http 的 multipart 会写小写
  /// `content-disposition` 头，音乐后端曾按大小写敏感匹配导致字段被丢弃，
  /// 表现为「密码明明是对的却一直提示账号或密码错误」。
  /// 服务端现已兼容小写头，同时 /api/login 也支持 JSON 提交。
  ///
  /// 音乐进程停止/网关 5xx 时，自动回退到社区 `/auth/login`：
  /// 两边共用 users/tokens 表，token 互通，不改变登录结果。
  static Future<Map<String, dynamic>> login(
    String account,
    String password,
  ) async {
    final body = {'account': account.trim(), 'password': password};
    try {
      return await _postLogin(_safeUri('$kMusicBase/api/login'), body);
    } catch (e) {
      if (!_loginFallbackAllowed(e)) rethrow;
      try {
        return await _postLogin(_apiUri('/auth/login'), body);
      } catch (_) {
        throw e;
      }
    }
  }

  /// 服务端撤销当前 token；失败不阻塞本地退出（本地仍会清安全存储）。
  static Future<void> logout() async {
    if (token == null || token!.isEmpty) return;
    try {
      await post('/auth/logout');
    } catch (_) {
      // 离线退出：本地清除即可，服务端 token 到期后自然失效。
    }
  }

  static bool _loginFallbackAllowed(Object e) {
    if (e is SocketException || e is TimeoutException) return true;
    if (e is http.ClientException) return true;
    if (e is ApiException) return e.code >= 500 || e.code == 404;
    return false;
  }

  static Future<Map<String, dynamic>> _postLogin(
    Uri uri,
    Map<String, dynamic> body,
  ) async {
    final r = await httpClient
        .post(
          uri,
          headers: const {'Content-Type': 'application/json; charset=utf-8'},
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 20));
    final Map<String, dynamic> j;
    try {
      j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {
      throw ApiException(r.statusCode, '响应解析失败 (HTTP ${r.statusCode})');
    }
    if (r.statusCode != 200) {
      throw ApiException(
        r.statusCode,
        (j['err'] ?? j['error'] ?? j['msg'] ?? '登录失败') as String,
      );
    }
    return j;
  }

  // ---------- 搜索 ----------

  /// 全局搜索：posts/videos/users/topics（type 留空 = 全部）
  static Future<Map<String, dynamic>> search(
    String q, {
    String type = '',
    int page = 1,
    int size = 20,
  }) => get(
    '/search',
    query: {
      'q': q,
      if (type.isNotEmpty) 'type': type,
      'page': '$page',
      'size': '$size',
    },
  );

  /// 搜索联想：topics + users
  static Future<Map<String, dynamic>> searchSuggest(String q) =>
      get('/search/suggest', query: {'q': q});

  /// 热门搜索词
  static Future<List<Map<String, dynamic>>> searchHot() async {
    final j = await get('/search/hot');
    return ((j['list'] ?? []) as List)
        .whereType<Map<String, dynamic>>()
        .toList();
  }

  /// 运营位 Banner：`{list, fallback}`。fallback 仅在无启用 Banner 时由客户端使用。
  static Future<Map<String, dynamic>> banners() async => get('/banners');

  /// 排行榜：type=post|topic|user
  static Future<Map<String, dynamic>> rankings(String type, {int limit = 20}) =>
      get('/rankings', query: {'type': type, 'limit': '$limit'});

  /// 热门话题（含 post_count）
  /// 配乐曲库（分页）：社区后端 `/music/tracks` 转发音乐项目
  /// `/api/community/tracks`，返回 {list,total,offset,hasMore}。
  /// - 选配乐弹层下拉即加载下一页；`q` 由服务端全库模糊匹配（歌名/歌手/专辑/上传者）
  static Future<Map<String, dynamic>> musicTracksPage({
    int offset = 0,
    int limit = 20,
    String q = '',
  }) => get(
    '/music/tracks',
    query: {
      'offset': '$offset',
      'limit': '$limit',
      if (q.trim().isNotEmpty) 'q': q.trim(),
    },
  );

  /// 配乐候选列表：直连音乐项目 /music/api/tracks?local=1（本地可播，无需登录）
  static Future<List<Map<String, dynamic>>> musicTracks() async {
    final r = await http
        .get(_safeUri('$kMusicBase/api/tracks?local=1'))
        .timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) throw ApiException(r.statusCode, '配乐加载失败');
    try {
      final d = jsonDecode(utf8.decode(r.bodyBytes));
      if (d is List) {
        return d
            .whereType<Map<String, dynamic>>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
      }
    } catch (_) {}
    return [];
  }

  static Future<List<Map<String, dynamic>>> topicsHot() async {
    final j = await get('/topics', query: {'hot': '1'});
    return ((j['list'] ?? []) as List)
        .whereType<Map<String, dynamic>>()
        .toList();
  }

  /// 话题搜索 / 创建（用户级）
  static Future<List<Map<String, dynamic>>> topicsSearch(String q) async {
    final j = await get('/topics', query: {'q': q});
    return ((j['list'] ?? []) as List)
        .whereType<Map<String, dynamic>>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  static Future<Map<String, dynamic>> createTopic(String name) =>
      post('/topics', body: {'name': name});

  /// 举报（post/comment）
  static Future<Map<String, dynamic>> report(
    String targetType,
    String targetId,
    String reason,
  ) => post(
    '/report',
    body: {'targetType': targetType, 'targetId': targetId, 'reason': reason},
  );

  /// 领取任务奖励
  static Future<Map<String, dynamic>> taskClaim(String taskId) =>
      post('/tasks/$taskId/claim');

  /// 投票
  static Future<Map<String, dynamic>> pollVote(String postId, int option) =>
      post('/poll/vote', body: {'postId': postId, 'option': option});

  // ---------- 信息流 ----------

  /// 信息流：tab=all|follow|recommend；type 留空 = 全部，video = 短视频流，post = 帖子流
  static Future<FeedPage> feed({
    String tab = 'all',
    String type = '',
    int page = 1,
    int size = 10,
    String boardId = '',
    String topic = '',
    String exclude = '',
    bool fresh = false,
  }) async {
    final j = await get(
      '/feed',
      query: {
        'tab': tab,
        'page': '$page',
        'size': '$size',
        if (type.isNotEmpty) 'type': type,
        if (boardId.isNotEmpty) 'board_id': boardId,
        if (topic.isNotEmpty) 'topic': topic,
        if (exclude.isNotEmpty) 'exclude': exclude,
        if (fresh) 'fresh': '1',
      },
    );
    return FeedPage.fromJson(j);
  }

  // ---------- 上传（multipart） ----------

  /// 将底层网络异常归类为用户可读的中文提示；未知异常保留原文。
  static ApiException _netError(Object e, String action) {
    if (e is TimeoutException) {
      return ApiException(0, '$action超时，请检查网络后重试');
    }
    if (e is SocketException) {
      return ApiException(0, '网络连接中断，请检查网络后重试');
    }
    if (e is http.ClientException) {
      final msg = e.message;
      if (msg.contains('SocketException') || msg.contains('Connection')) {
        return ApiException(0, '网络连接异常，请稍后重试');
      }
      return ApiException(0, '$action失败：$msg');
    }
    if (e is ApiException) return e;
    return ApiException(0, '$action失败，请重试');
  }

  /// 上传图片（返回 {name}；上传前本地校验 ≤10MB，失败中文提示）
  static Future<Map<String, dynamic>> uploadImage(String filePath) async {
    const maxBytes = 10 * 1024 * 1024; // 10MB
    final f = File(filePath);
    if (!f.existsSync()) throw ApiException(400, '图片文件不存在');
    final size = f.lengthSync();
    if (size > maxBytes) {
      throw ApiException(413, '图片过大（≤10MB），请压缩后重试');
    }
    try {
      final req = http.MultipartRequest(
        'POST',
        _apiUri('/upload-image'),
      );
      if (token != null && token!.isNotEmpty) {
        req.headers['Authorization'] = 'Bearer $token';
      }
      req.files.add(await http.MultipartFile.fromPath('file', filePath));
      final r = await http.Response.fromStream(
        await req.send().timeout(const Duration(seconds: 90)),
      );
      return _unwrap(r);
    } catch (e) {
      throw _netError(e, '图片上传');
    }
  }

  /// 上传视频（返回 {videoId, name, status}，异步转码）
  ///
  /// - 上传前本地校验：文件存在、≤50MB（服务端限制），超限直接中文提示；
  /// - 网络中断（SocketException/Broken pipe，多为网关/服务端拒绝大文件或断网）自动重试 1 次；
  /// - 所有网络异常归类为中文文案，不再把原始英文异常抛给 UI。
  static Future<Map<String, dynamic>> uploadVideo(String filePath) async {
    const maxBytes = 50 * 1024 * 1024; // 50MB
    final f = File(filePath);
    if (!f.existsSync()) throw ApiException(400, '视频文件不存在');
    final size = f.lengthSync();
    if (size > maxBytes) {
      throw ApiException(413, '视频过大（≤50MB），请压缩后重试');
    }
    Object? lastErr;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final req = http.MultipartRequest(
          'POST',
          _apiUri('/upload-video'),
        );
        if (token != null && token!.isNotEmpty) {
          req.headers['Authorization'] = 'Bearer $token';
        }
        req.files.add(await http.MultipartFile.fromPath('file', filePath));
        final r = await http.Response.fromStream(
          await req.send().timeout(const Duration(seconds: 300)),
        );
        return _unwrap(r);
      } catch (e) {
        // 仅在“未收到服务端响应”的网络类异常下重试，业务错误（_unwrap 抛的
        // ApiException）直接透传，不重试。
        if (e is ApiException) rethrow;
        lastErr = e;
        if (attempt == 0) {
          await Future.delayed(const Duration(seconds: 2));
        }
      }
    }
    throw _netError(lastErr!, '视频上传');
  }

  /// 视频状态（转码进度）
  static Future<Map<String, dynamic>> videoStatus(String videoId) =>
      get('/video/$videoId/status');

  /// 从已上传视频里按指定秒数抽一帧作为封面。
  /// 返回 {cover: '/community/api/media/community_video_xxx_frame.jpg'}
  static Future<Map<String, dynamic>> coverFrame(
    String videoId,
    double frameTime,
  ) => post('/video/$videoId/cover-frame', body: {'frameTime': frameTime});

  // ---------- 版块 / 话题 ----------

  static Future<Map<String, dynamic>> boards() => get('/boards');
  static Future<Map<String, dynamic>> topics() => get('/topics');

  // ---------- 收藏 / 稍后看 ----------

  /// 收藏列表：kind=fav（收藏）| later（稍后看），返回 decorate_post 结构
  static Future<Map<String, dynamic>> favorites({
    String kind = 'fav',
    int page = 1,
    int size = 20,
  }) => get(
    '/favorites',
    query: {'kind': kind, 'page': '$page', 'size': '$size'},
  );

  // ---------- 意见反馈 ----------

  /// 提交意见反馈：type=bug|suggestion|other
  static Future<Map<String, dynamic>> submitFeedback({
    required String type,
    required String content,
    String contact = '',
  }) => post(
    '/feedback',
    body: {'type': type, 'content': content, 'contact': contact},
  );

  // ---------- 通知（互动 + 社区官方，官方与音乐完全分离） ----------

  static Future<Map<String, dynamic>> notifications({
    String group = '',
    int page = 1,
    int size = 20,
  }) => get(
    '/notifications',
    query: {
      if (group.isNotEmpty) 'group': group,
      'page': '$page',
      'size': '$size',
    },
  );

  static Future<Map<String, dynamic>> notificationsUnread() =>
      get('/notifications/unread');

  /// 标记互动通知已读：传 [id] 单条；传 [group] 按分类
  /// （like/comment/follow/audit）；都不传则全部互动通知已读。
  static Future<void> markNotificationsRead({String? id, String? group}) async {
    await post('/notifications/read', body: {'id': ?id, 'group': ?group});
  }

  /// 删除单条互动通知（后端软删除，列表里即可左滑删除）
  static Future<void> deleteNotification(String id) async {
    await delete('/notifications/$id');
  }

  static Future<Map<String, dynamic>> officialMessages({double after = 0}) =>
      get('/official-messages', query: {'after': '$after'});

  static Future<void> markOfficialRead() async {
    await post('/official-messages/read');
  }

  // ---------- 私信 IM（1对1，仅互关可发） ----------

  /// 会话列表
  static Future<Map<String, dynamic>> dmConversations({
    int page = 1,
    int size = 20,
  }) => get('/dm/conversations', query: {'page': '$page', 'size': '$size'});

  /// 聊天记录（created 升序返回）
  static Future<Map<String, dynamic>> dmMessages({
    required String peer,
    double before = 0,
    int limit = 30,
  }) => get(
    '/dm/messages',
    query: {
      'peer': peer,
      if (before > 0) 'before': '$before',
      'limit': '$limit',
    },
  );

  /// 发送私信（互关校验在服务端；type: text/image/video/location/card）
  static Future<Map<String, dynamic>> dmSend(
    String peer,
    String content, {
    String type = 'text',
  }) =>
      post('/dm/send', body: {'peer': peer, 'content': content, 'type': type});

  /// 标记某会话已读
  static Future<void> dmRead(String peer) async {
    await post('/dm/read', body: {'peer': peer});
  }

  /// 标记全部私信会话已读（服务端批量清零并给各会话发送已读回执）
  static Future<void> dmReadAll() async {
    await post('/dm/read-all');
  }

  /// 私信总未读
  static Future<Map<String, dynamic>> dmUnread() => get('/dm/unread');

  /// 互关好友（仅双向关注，可用于应用分享选人）
  static Future<Map<String, dynamic>> dmFriends({
    String q = '',
    int limit = 60,
  }) => get('/dm/friends', query: {'q': q, 'limit': '$limit'});

  /// 分享给互关好友：应用 / 帖子 / 主页统一走 card 消息并 WS 推送
  static Future<Map<String, dynamic>> dmShareTarget({
    required String type,
    required String id,
    required List<String> peers,
    String note = '',
  }) => post(
    '/dm/share-card',
    body: {
      'type': type,
      'id': id,
      'peers': peers,
      if (note.trim().isNotEmpty) 'note': note.trim(),
    },
  );

  /// 应用分享兼容入口
  static Future<Map<String, dynamic>> dmShareApp({
    required String appId,
    required List<String> peers,
    String note = '',
  }) => dmShareTarget(type: 'app', id: appId, peers: peers, note: note);

  /// 应用/帖子短链：服务端按目标复用同一个短码
  static Future<String> shareShortLink(
    String type,
    String id, {
    String fallback = '',
  }) async {
    try {
      final j = await post('/share/link', body: {'type': type, 'id': id});
      final url = (j['url'] ?? '').toString().trim();
      return url.isEmpty ? fallback : url;
    } catch (_) {
      return fallback;
    }
  }

  // ---------- 等级 / 签到 / 任务 ----------

  static Future<Map<String, dynamic>> levelMe() => get('/level/me');
  static Future<Map<String, dynamic>> levelRules() => get('/level/rules');
  static Future<Map<String, dynamic>> signins() => get('/signins');
  static Future<Map<String, dynamic>> signin() => post('/signin');
  static Future<Map<String, dynamic>> tasks() => get('/tasks');
  static Future<Map<String, dynamic>> claimTask(String id) =>
      post('/tasks/$id/claim');
  static Future<Map<String, dynamic>> activities() => get('/activities');

  // ---------- 装扮（头像框） ----------

  static Future<Map<String, dynamic>> frames() => get('/frames');
  static Future<Map<String, dynamic>> myFrame() => get('/frame/mine');
  static Future<Map<String, dynamic>> equipFrame(String frameId) =>
      post('/frame/equip', body: {'frameId': frameId});

  // ---------- 互动（路由与后端一致：POST /post/{id}/like 等） ----------

  /// 点赞状态设置：liked=true → POST（点赞）/ false → DELETE（取消赞）。
  /// 注意：后端 POST 是「幂等添加」而不是切换，必须显式传目标状态。
  static Future<Map<String, dynamic>> setPostLike(
    String postId, {
    required bool liked,
  }) => liked ? post('/post/$postId/like') : delete('/post/$postId/like');

  /// 收藏/取消收藏（kind=fav 收藏 | later 稍后看）
  static Future<Map<String, dynamic>> toggleFav(
    String postId, {
    String kind = 'fav',
    bool? faved,
  }) => (faved == true)
      ? delete('/post/$postId/$kind')
      : post('/post/$postId/$kind');

  /// 分享计数上报（返回最新 count）
  static Future<Map<String, dynamic>> reportShare(String postId) =>
      post('/post/$postId/share');

  /// 评论点赞状态设置（同 setPostLike：后端 POST=添加、DELETE=取消）
  static Future<Map<String, dynamic>> setCommentLike(
    String commentId, {
    required bool liked,
  }) => liked
      ? post('/comment/$commentId/like')
      : delete('/comment/$commentId/like');

  /// 关注/取关（互通：写音乐 follows 表）
  static Future<Map<String, dynamic>> toggleFollow(String uid) =>
      post('/user/$uid/follow');

  /// 当前用户主页
  static Future<Map<String, dynamic>> myProfile() async {
    final j = await get('/user/me');
    final u = j['user'];
    if (u is Map) {
      final id = (u['id'] ?? '').toString();
      if (id.isNotEmpty) userId = id;
      meProfile = Map<String, dynamic>.from(u);
      meSignature = (u['signature'] ?? '').toString();
    }
    return j;
  }

  /// 指定用户主页
  static Future<Map<String, dynamic>> userProfile(String uid) =>
      get('/user/$uid/profile');

  /// 更新我的资料（昵称/签名/性别/年龄/地址；邮箱需带验证码）
  static Future<Map<String, dynamic>> updateProfile({
    String? name,
    String? signature,
    String? gender,
    int? age,
    String? city,
    String? email,
    String? code,
  }) => post(
    '/user/me',
    body: {
      if (name != null && name.isNotEmpty) 'name': name,
      'signature': ?signature,
      'gender': ?gender,
      'age': ?age,
      'city': ?city,
      if (email != null && email.isNotEmpty) 'email': email,
      if (code != null && code.isNotEmpty) 'code': code,
    },
  );

  /// 发送邮箱验证码（社区改绑邮箱，5 分钟有效）
  static Future<Map<String, dynamic>> sendEmailCodeCommunity(
    String email,
    CaptchaAnswer captcha,
  ) => post(
    '/user/email-code',
    body: {
      'email': email,
      ...captcha.toBody(),
    },
  );

  /// 绑定/更换手机号：发送短信验证码（需登录）
  static Future<Map<String, dynamic>> sendBindPhoneCode(
    String phone,
    CaptchaAnswer captcha,
  ) => post(
    '/invite/phone/send',
    body: {
      'phone': normalizePhone(phone),
      ...captcha.toBody(),
    },
  );

  /// 绑定/更换手机号：校验验证码并落库（需登录）
  static Future<Map<String, dynamic>> confirmBindPhone(
    String phone,
    String code,
  ) => post(
    '/invite/phone/confirm',
    body: {'phone': normalizePhone(phone), 'code': code.trim()},
  );

  /// 上传头像（multipart，写音乐 files 目录 + users.avatar）
  static Future<Map<String, dynamic>> uploadAvatar(File file) async {
    final req = http.MultipartRequest(
      'POST',
      _apiUri('/user/me/avatar'),
    );
    if (token != null && token!.isNotEmpty) {
      req.headers['Authorization'] = 'Bearer $token';
    }
    req.files.add(await http.MultipartFile.fromPath('avatar', file.path));
    final streamed = await req.send().timeout(const Duration(seconds: 60));
    final r = await http.Response.fromStream(streamed);
    return _unwrap(r);
  }

  // ---------- 表情包 ----------

  /// 官方表情包全量
  static Future<Map<String, dynamic>> emojis() => get('/emojis');

  /// 我的收藏表情
  static Future<Map<String, dynamic>> emojiFavs() => get('/emojis/favs');

  /// 收藏/取消收藏表情
  static Future<Map<String, dynamic>> emojiFav(
    String emojiId, {
    bool fav = true,
  }) async {
    if (fav) {
      return post('/emoji/fav', body: {'emojiId': emojiId});
    }
    final r = await http
        .delete(
          _apiUri('/emoji/fav'),
          headers: _headers(),
          body: jsonEncode({'emojiId': emojiId}),
        )
        .timeout(const Duration(seconds: 20));
    return _unwrap(r);
  }

  /// 上传自定义表情（图片/GIF，自动加入收藏）
  static Future<Map<String, dynamic>> uploadCustomEmoji(File file) async {
    final req = http.MultipartRequest(
      'POST',
      _apiUri('/emojis/custom'),
    );
    if (token != null && token!.isNotEmpty) {
      req.headers['Authorization'] = 'Bearer $token';
    }
    req.files.add(await http.MultipartFile.fromPath('image', file.path));
    final streamed = await req.send().timeout(const Duration(seconds: 60));
    final r = await http.Response.fromStream(streamed);
    return _unwrap(r);
  }

  // ---------- 管理员审核（App 内入口，普通 token 鉴权） ----------

  /// 审核列表：audit=0 待审 / 1 通过 / 2 已拒绝（管理员）
  static Future<Map<String, dynamic>> adminPosts({int? audit, int page = 1}) =>
      get(
        '/admin/posts',
        query: {if (audit != null) 'audit': '$audit', 'page': '$page'},
      );

  /// 审核动作：audit(通过/拒绝) / pin(置顶) / featured(精华) / takedown(下架)
  static Future<Map<String, dynamic>> adminAction(
    String postId,
    String action, {
    String? reason,
  }) async {
    Map<String, dynamic> body = {};
    if (action == 'audit') {
      if (reason != null && reason.isNotEmpty) {
        body = {'action': 'reject', 'reason': reason};
      } else {
        body = {'action': 'approve'};
      }
    }
    return post('/admin/posts/$postId/$action', body: body);
  }

  /// 关注 / 粉丝列表
  static Future<Map<String, dynamic>> userList(
    String uid, {
    required String kind,
    int page = 1,
    int size = 20,
  }) => get('/user/$uid/$kind', query: {'page': '$page', 'size': '$size'});

  // ---------- 评论（帖/视频共用） ----------

  static Future<Map<String, dynamic>> comments(
    String postId, {
    int page = 1,
    int size = 20,
  }) async {
    final j = await get(
      '/post/$postId/comments',
      query: {'page': '$page', 'size': '$size'},
    );
    return j;
  }

  static Future<Map<String, dynamic>> postDetail(String postId) =>
      get('/post/$postId');

  static Future<Map<String, dynamic>> addComment(
    String postId,
    String content, {
    String? sticker,
    List<String> images = const [],
  }) async {
    return post(
      '/post/$postId/comment',
      body: {'content': content, 'images': images, 'sticker': ?sticker},
    );
  }
  // ---------- 会员（社区会员，独立于音乐会员） ----------

  static Future<Map<String, dynamic>> memberPlans() => get('/member/plans');

  static Future<Map<String, dynamic>> memberStatus() => get('/member/status');

  static Future<Map<String, dynamic>> memberRedeem(String code) =>
      post('/member/redeem', body: {'code': code});

  static Future<Map<String, dynamic>> memberApply({
    required String planId,
    String contact = '',
    String note = '',
    String proof = '',
  }) => post(
    '/member/apply',
    body: {'planId': planId, 'contact': contact, 'note': note, 'proof': proof},
  );

  /// 上传支付凭证等文件（图片 / PDF，≤10MB），返回 {url, name, size}
  static Future<Map<String, dynamic>> uploadProof(String filePath) async {
    final f = File(filePath);
    if (!f.existsSync()) throw ApiException(400, '文件不存在');
    if (f.lengthSync() > 10 * 1024 * 1024) {
      throw ApiException(413, '文件过大（≤10MB）');
    }
    try {
      final req = http.MultipartRequest(
        'POST',
        _apiUri('/upload-file'),
      );
      if (token != null && token!.isNotEmpty) {
        req.headers['Authorization'] = 'Bearer $token';
      }
      req.files.add(await http.MultipartFile.fromPath('file', filePath));
      final r = await http.Response.fromStream(
        await req.send().timeout(const Duration(seconds: 90)),
      );
      return _unwrap(r);
    } catch (e) {
      throw _netError(e, '文件上传');
    }
  }

  /// 上传帖子附件（PDF / Office / 文本 / 压缩包，≤20MB）
  static Future<Map<String, dynamic>> uploadAttachment(
    String filePath, {
    String filename = '',
  }) async {
    final f = File(filePath);
    if (!f.existsSync()) throw ApiException(400, '文件不存在');
    if (f.lengthSync() > 20 * 1024 * 1024) {
      throw ApiException(413, '附件过大（≤20MB）');
    }
    try {
      final req = http.MultipartRequest(
        'POST',
        _apiUri('/upload-attachment'),
      );
      if (token != null && token!.isNotEmpty) {
        req.headers['Authorization'] = 'Bearer $token';
      }
      req.files.add(
        await http.MultipartFile.fromPath(
          'file',
          filePath,
          filename: filename.isEmpty ? null : filename,
        ),
      );
      final r = await http.Response.fromStream(
        await req.send().timeout(const Duration(seconds: 90)),
      );
      return _unwrap(r);
    } catch (e) {
      throw _netError(e, '附件上传');
    }
  }

  static Future<Map<String, dynamic>> memberOrders() => get('/member/orders');

  /// 易支付下单：返回 {orderId, money, payUrl, payType}
  static Future<Map<String, dynamic>> memberPayCreate({
    required String planId,
    String channel = 'wxpay',
  }) =>
      post('/member/pay-create', body: {'planId': planId, 'channel': channel});

  /// 查单：status 0 待支付 / 1 已支付
  static Future<Map<String, dynamic>> memberPayStatus(String orderId) =>
      get('/member/pay-status', query: {'orderId': orderId});
}
