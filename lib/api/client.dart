/// 流萤社区 · API 客户端
/// - 社区接口：Bearer token（与音乐 tokens 表互通）
/// - 登录：走音乐 /music/api/login（multipart），拿同一份 token
library;

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

  /// 账号密码登录（走音乐登录接口，返回 token 与用户资料）
  /// 返回 null 表示失败（message 已抛异常）。
  static Future<Map<String, dynamic>> login(String account, String password) async {
    final req = http.MultipartRequest('POST', Uri.parse('$kMusicBase/api/login'));
    req.fields['account'] = account;
    req.fields['password'] = password;
    final streamed = await req.send().timeout(const Duration(seconds: 20));
    final r = await http.Response.fromStream(streamed);
    return _unwrap(r); // {ok, token, user:{...}}
  }

  // ---------- 信息流 ----------

  /// 信息流：tab=all|follow|recommend；type 留空 = 全部，video = 短视频流，post = 帖子流
  static Future<FeedPage> feed({
    String tab = 'all',
    String type = '',
    int page = 1,
    int size = 10,
    String boardId = '',
  }) async {
    final j = await get('/feed', query: {
      'tab': tab,
      'page': '$page',
      'size': '$size',
      if (type.isNotEmpty) 'type': type,
      if (boardId.isNotEmpty) 'board_id': boardId,
    });
    return FeedPage.fromJson(j);
  }

  // ---------- 上传（multipart） ----------

  /// 上传图片（返回 {name}）
  static Future<Map<String, dynamic>> uploadImage(String filePath) async {
    final req = http.MultipartRequest('POST', Uri.parse('$kApiBase/upload-image'));
    if (token != null && token!.isNotEmpty) {
      req.headers['Authorization'] = 'Bearer $token';
    }
    req.files.add(await http.MultipartFile.fromPath('file', filePath));
    final r = await http.Response.fromStream(
        await req.send().timeout(const Duration(seconds: 90)));
    return _unwrap(r);
  }

  /// 上传视频（返回 {videoId, name, status}，异步转码）
  static Future<Map<String, dynamic>> uploadVideo(String filePath) async {
    final req = http.MultipartRequest('POST', Uri.parse('$kApiBase/upload-video'));
    if (token != null && token!.isNotEmpty) {
      req.headers['Authorization'] = 'Bearer $token';
    }
    req.files.add(await http.MultipartFile.fromPath('file', filePath));
    final r = await http.Response.fromStream(
        await req.send().timeout(const Duration(seconds: 300)));
    return _unwrap(r);
  }

  /// 视频状态（转码进度）
  static Future<Map<String, dynamic>> videoStatus(String videoId) =>
      get('/video/$videoId/status');

  // ---------- 版块 / 话题 ----------

  static Future<Map<String, dynamic>> boards() => get('/boards');
  static Future<Map<String, dynamic>> topics() => get('/topics');

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
  static Future<Map<String, dynamic>> myProfile() => get('/user/me');

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
