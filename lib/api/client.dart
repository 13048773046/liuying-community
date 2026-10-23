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

  static Future<Map<String, dynamic>> addComment(String postId, String content,
      {String? sticker}) async {
    return post('/post/$postId/comment', body: {
      'content': content,
      if (sticker != null) 'sticker': sticker,
    });
  }
}
