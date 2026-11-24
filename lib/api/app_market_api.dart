/// 流萤社区 · 应用市场 API 封装
///
/// 任何页面都不直接拼接口 URL；投稿上传复用 [ApiClient.uploadImage]，
/// 其余请求复用 [ApiClient] 的鉴权、超时和 `{ok,error}` 响应解析。
library;

import '../models/app_market.dart';
import '../config.dart';
import 'client.dart';

class AppCommentPage {
  final List<AppComment> list;
  final int total;
  final int page;
  final int pageSize;

  const AppCommentPage({
    this.list = const [],
    this.total = 0,
    this.page = 1,
    this.pageSize = 20,
  });

  bool get hasMore => list.length + (page - 1) * pageSize < total;
}

class AppMarketApi {
  const AppMarketApi._();

  static Future<List<AppCategory>> categories() async {
    final j = await ApiClient.get('/apps/categories');
    return ((j['list'] ?? []) as List)
        .whereType<Map>()
        .map((e) => AppCategory.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  static Future<MarketAppPage> list({
    int page = 1,
    int pageSize = 20,
    String category = '',
    String subCategory = '',
    String platform = '',
    String q = '',
    String sort = 'latest',
    String exclude = '',
    bool fresh = false,
  }) async {
    final j = await ApiClient.get(
      '/apps',
      query: {
        'page': '$page',
        'pageSize': '$pageSize',
        if (category.isNotEmpty) 'category': category,
        if (subCategory.isNotEmpty) 'subCategory': subCategory,
        if (platform.isNotEmpty) 'platform': platform,
        if (q.isNotEmpty) 'q': q,
        'sort': sort,
        if (exclude.isNotEmpty) 'exclude': exclude,
        if (fresh) 'fresh': '1',
      },
    );
    return MarketAppPage.fromJson(j);
  }

  static Future<MarketApp> detail(String id) async {
    final j = await ApiClient.get('/apps/$id');
    return MarketApp.fromJson(Map<String, dynamic>.from(j['app'] as Map));
  }

  static Future<List<MarketApp>> mine() async {
    final j = await ApiClient.get('/apps/mine');
    return ((j['list'] ?? []) as List)
        .whereType<Map>()
        .map((e) => MarketApp.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  /// 某位用户已上架的投稿应用（公开主页用；不含草稿/待审/驳回）。
  static Future<MarketAppPage> byUser(
    String uid, {
    int page = 1,
    int pageSize = 12,
  }) async {
    final j = await ApiClient.get(
      '/apps/by-user/$uid',
      query: {'page': '$page', 'pageSize': '$pageSize'},
    );
    return MarketAppPage.fromJson(j);
  }

  static Future<List<MarketApp>> favorites() async {
    final j = await ApiClient.get('/apps/mine/favorites');
    return ((j['list'] ?? []) as List)
        .whereType<Map>()
        .map((e) => MarketApp.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  static Future<Map<String, dynamic>> create(AppSubmissionDraft draft) =>
      ApiClient.post('/apps', body: draft.toJson());

  static Future<Map<String, dynamic>> update(
    String id,
    AppSubmissionDraft draft,
  ) => ApiClient.put('/apps/$id', body: draft.toJson());

  static Future<Map<String, dynamic>> submit(
    String id, {
    required String versionId,
  }) => ApiClient.post('/apps/$id/submit', body: {'versionId': versionId});

  static Future<AppCommentPage> comments(
    String id, {
    int page = 1,
    int pageSize = 20,
  }) async {
    final j = await ApiClient.get(
      '/apps/$id/comments',
      query: {'page': '$page', 'pageSize': '$pageSize'},
    );
    final list = ((j['list'] ?? []) as List)
        .whereType<Map>()
        .map((e) => AppComment.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    return AppCommentPage(
      list: list,
      total: ((j['total'] ?? 0) as num).toInt(),
      page: ((j['page'] ?? page) as num).toInt(),
      pageSize: ((j['pageSize'] ?? pageSize) as num).toInt(),
    );
  }

  static Future<Map<String, dynamic>> addComment(String id, String content) =>
      ApiClient.post('/apps/$id/comments', body: {'content': content});

  static Future<Map<String, dynamic>> deleteComment(
    String id,
    String commentId,
  ) => ApiClient.delete('/apps/$id/comments/$commentId');

  static Future<Map<String, dynamic>> rating(String id, int score) =>
      ApiClient.post('/apps/$id/rating', body: {'score': score});

  static Future<Map<String, dynamic>> favorite(String id, {required bool add}) {
    if (add) return ApiClient.post('/apps/$id/favorite');
    return ApiClient.delete('/apps/$id/favorite');
  }

  static Future<Map<String, dynamic>> report(String id, String reason) =>
      ApiClient.post('/apps/$id/report', body: {'reason': reason});

  static Future<Map<String, dynamic>> uploadImage(String filePath) =>
      ApiClient.uploadImage(filePath);

  /// 下载入口（服务端签发 ticket 后 302 到网关；不在页面加载时调用）。
  static Uri downloadEndpoint(String id) =>
      Uri.parse('${ApiClient.baseUrl}/apps/$id/download');

  static String mediaPathToUrl(String path) {
    final trimmed = path.trim();
    if (trimmed.isEmpty) return '';
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      return trimmed;
    }
    final origin = Uri.parse(ApiClient.baseUrl).origin;
    if (trimmed.startsWith('/community/api/')) return '$origin$trimmed';
    if (trimmed.startsWith('/')) return '$origin$trimmed';
    return mediaUrl(trimmed);
  }
}
