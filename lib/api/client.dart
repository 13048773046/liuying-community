/// 流萤社区 · API 客户端
/// - 社区接口：Bearer token（与音乐 tokens 表互通）
/// - 登录：走音乐 /music/api/login（multipart），拿同一份 token
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../config.dart';
import '../models/feed_item.dart';

class ApiException implements Exception {
  final int code;
  final String message;
  ApiException(this.code, this.message);
  @override
  String toString() => message;
}

class ApiClient {
  static String? token; // 全局登录态（内存缓存）
  static String? userId; // 当前登录用户 id（myProfile 成功后缓存）

  // ---------- 基础请求 ----------

  static Map<String, String> _headers({bool json = true}) => {
        if (token != null && token!.isNotEmpty)
          'Authorization': 'Bearer $token',
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
      throw ApiException(r.statusCode, (j['error'] ?? j['msg'] ?? '请求失败') as String);
    }
    return j;
  }

  static Future<Map<String, dynamic>> get(String path,
      {Map<String, String>? query}) async {
    var uri = Uri.parse('$kApiBase$path');
    if (query != null && query.isNotEmpty) {
      uri = uri.replace(queryParameters: {...uri.queryParameters, ...query});
    }
    final r = await http.get(uri, headers: _headers()).timeout(
        const Duration(seconds: 15));
    return _unwrap(r);
  }

  static Future<Map<String, dynamic>> post(String path,
      {Map<String, dynamic>? body}) async {
    final r = await http
        .post(Uri.parse('$kApiBase$path'),
            headers: _headers(), body: jsonEncode(body ?? {}))
        .timeout(const Duration(seconds: 20));
    return _unwrap(r);
  }

  static Future<Map<String, dynamic>> put(String path,
      {Map<String, dynamic>? body}) async {
    final r = await http
        .put(Uri.parse('$kApiBase$path'),
            headers: _headers(), body: jsonEncode(body ?? {}))
        .timeout(const Duration(seconds: 20));
    return _unwrap(r);
  }

  static Future<Map<String, dynamic>> delete(String path) async {
    final r = await http
        .delete(Uri.parse('$kApiBase$path'), headers: _headers())
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
      RegExp(r'^[a-zA-Z0-9_.+-]+@[a-zA-Z0-9-]+\.[a-zA-Z0-9-.]+$').hasMatch(email);

  /// 发送邮箱验证码（音乐 /music/api/send-email-code）
  ///
  /// 注意：改用 JSON 请求而非 multipart。原因——Dart http 包的 multipart 字段头
  /// 是小写 `content-disposition`，音乐后端 _parse_multipart 大小写敏感匹配
  /// `Content-Disposition` 会跳过所有字段（email 解析为空 → 报"邮箱格式不正确"）。
  /// 服务端对非 multipart 请求有 JSON fallback 解析（实测 {"email":..} → ok）。
  static Future<void> sendEmailCode(String email) async {
    final r = await http
        .post(
          Uri.parse('$kMusicBase/api/send-email-code'),
          headers: _headers(),
          body: jsonEncode({'email': normalizeEmail(email)}),
        )
        .timeout(const Duration(seconds: 20));
    final Map<String, dynamic> j;
    try {
      j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {
      throw ApiException(r.statusCode, '响应解析失败 (HTTP ${r.statusCode})');
    }
    if (r.statusCode != 200 || j['ok'] != true) {
      throw ApiException(r.statusCode,
          (j['err'] ?? j['error'] ?? j['msg'] ?? '发送失败') as String);
    }
  }

  /// 邮箱验证码登录 / 注册（音乐 /music/api/login-email，新邮箱自动注册）
  /// 成功返回用户资料（含 token）。同样用 JSON 而非 multipart（见 sendEmailCode）。
  static Future<Map<String, dynamic>> loginEmail(
      String email, String code) async {
    final r = await http
        .post(
          Uri.parse('$kMusicBase/api/login-email'),
          headers: _headers(),
          body: jsonEncode({'email': normalizeEmail(email), 'code': code.trim()}),
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
      throw ApiException(r.statusCode,
          (j['err'] ?? j['error'] ?? j['msg'] ?? '登录失败') as String);
    }
    return j;
  }

  /// 账号密码登录（音乐 /music/api/login，返回 token 与用户资料）
  /// 返回 null 表示失败（message 已抛异常）。
  static Future<Map<String, dynamic>> login(String account, String password) async {
    final req = http.MultipartRequest('POST', Uri.parse('$kMusicBase/api/login'));
    req.fields['account'] = account;
    req.fields['password'] = password;
    final streamed = await req.send().timeout(const Duration(seconds: 20));
    final r = await http.Response.fromStream(streamed);
    final Map<String, dynamic> j;
    try {
      j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {
      throw ApiException(r.statusCode, '响应解析失败 (HTTP ${r.statusCode})');
    }
    if (r.statusCode != 200) {
      throw ApiException(r.statusCode, (j['err'] ?? j['error'] ?? j['msg'] ?? '登录失败') as String);
    }
    return j;
  }

  // ---------- 信息流 ----------

  /// 信息流：tab=all|follow|recommend；type 留空 = 全部，video = 短视频流，post = 帖子流
  static Future<FeedPage> feed({
    String tab = 'all',
    String type = '',
    int page = 1,
    int size = 10,
    String boardId = '',
    String topic = '',
  }) async {
    final j = await get('/feed', query: {
      'tab': tab,
      'page': '$page',
      'size': '$size',
      if (type.isNotEmpty) 'type': type,
      if (boardId.isNotEmpty) 'board_id': boardId,
      if (topic.isNotEmpty) 'topic': topic,
    });
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
      final req = http.MultipartRequest('POST', Uri.parse('$kApiBase/upload-image'));
      if (token != null && token!.isNotEmpty) {
        req.headers['Authorization'] = 'Bearer $token';
      }
      req.files.add(await http.MultipartFile.fromPath('file', filePath));
      final r = await http.Response.fromStream(
          await req.send().timeout(const Duration(seconds: 90)));
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
        final req =
            http.MultipartRequest('POST', Uri.parse('$kApiBase/upload-video'));
        if (token != null && token!.isNotEmpty) {
          req.headers['Authorization'] = 'Bearer $token';
        }
        req.files.add(await http.MultipartFile.fromPath('file', filePath));
        final r = await http.Response.fromStream(
            await req.send().timeout(const Duration(seconds: 300)));
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

  // ---------- 版块 / 话题 ----------

  static Future<Map<String, dynamic>> boards() => get('/boards');
  static Future<Map<String, dynamic>> topics() => get('/topics');

  // ---------- 收藏 / 稍后看 ----------

  /// 收藏列表：kind=fav（收藏）| later（稍后看），返回 decorate_post 结构
  static Future<Map<String, dynamic>> favorites({
    String kind = 'fav',
    int page = 1,
    int size = 20,
  }) =>
      get('/favorites', query: {
        'kind': kind,
        'page': '$page',
        'size': '$size',
      });

  // ---------- 意见反馈 ----------

  /// 提交意见反馈：type=bug|suggestion|other
  static Future<Map<String, dynamic>> submitFeedback({
    required String type,
    required String content,
    String contact = '',
  }) =>
      post('/feedback', body: {
        'type': type,
        'content': content,
        'contact': contact,
      });

  // ---------- 通知（互动 + 社区官方，官方与音乐完全分离） ----------

  static Future<Map<String, dynamic>> notifications(
          {String group = '', int page = 1, int size = 20}) =>
      get('/notifications', query: {
        if (group.isNotEmpty) 'group': group,
        'page': '$page',
        'size': '$size',
      });

  static Future<Map<String, dynamic>> notificationsUnread() =>
      get('/notifications/unread');

  static Future<void> markNotificationsRead({String? id}) async {
    await post('/notifications/read', body: {if (id != null) 'id': id});
  }

  static Future<Map<String, dynamic>> officialMessages({double after = 0}) =>
      get('/official-messages', query: {'after': '$after'});

  static Future<void> markOfficialRead() async {
    await post('/official-messages/read');
  }

  // ---------- 等级 / 签到 / 任务 ----------

  static Future<Map<String, dynamic>> levelMe() => get('/level/me');
  static Future<Map<String, dynamic>> levelRules() => get('/level/rules');
  static Future<Map<String, dynamic>> signins() => get('/signins');
  static Future<Map<String, dynamic>> signin() => post('/signin');
  static Future<Map<String, dynamic>> tasks() => get('/tasks');
  static Future<Map<String, dynamic>> claimTask(String id) =>
      post('/tasks/$id/claim');

  // ---------- 装扮（头像框） ----------

  static Future<Map<String, dynamic>> frames() => get('/frames');
  static Future<Map<String, dynamic>> myFrame() => get('/frame/mine');
  static Future<Map<String, dynamic>> equipFrame(String frameId) =>
      post('/frame/equip', body: {'frameId': frameId});

  // ---------- 互动（路由与后端一致：POST /post/{id}/like 等） ----------

  /// 点赞/取消赞（帖子与视频共用）
  static Future<Map<String, dynamic>> toggleLike(String postId) =>
      post('/post/$postId/like');

  /// 收藏/取消收藏（kind=fav 收藏 | later 稍后看）
  static Future<Map<String, dynamic>> toggleFav(String postId,
      {String kind = 'fav'}) =>
      post('/post/$postId/$kind');

  /// 分享计数上报（返回最新 count）
  static Future<Map<String, dynamic>> reportShare(String postId) =>
      post('/post/$postId/share');

  /// 关注/取关（互通：写音乐 follows 表）
  static Future<Map<String, dynamic>> toggleFollow(String uid) =>
      post('/user/$uid/follow');

  /// 当前用户主页
  static Future<Map<String, dynamic>> myProfile() async {
    final j = await get('/user/me');
    final u = j['user'];
    if (u is Map && u['id'] != null) {
      userId = u['id'] as String;
    }
    return j;
  }

  /// 指定用户主页
  static Future<Map<String, dynamic>> userProfile(String uid) =>
      get('/user/$uid/profile');

  // ---------- 评论（帖/视频共用） ----------

  static Future<Map<String, dynamic>> comments(String postId,
      {int page = 1, int size = 20}) async {
    final j = await get('/post/$postId/comments', query: {
      'page': '$page',
      'size': '$size',
    });
    return j;
  }

  static Future<Map<String, dynamic>> postDetail(String postId) =>
      get('/post/$postId');

  static Future<Map<String, dynamic>> addComment(String postId, String content,
      {String? sticker, List<String> images = const []}) async {
    return post('/post/$postId/comment', body: {
      'content': content,
      'images': images,
      if (sticker != null) 'sticker': sticker,
    });
  }
}
