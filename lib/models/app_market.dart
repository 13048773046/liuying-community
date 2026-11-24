/// 流萤社区 · 应用市场数据模型
///
/// 所有字段来自 `/community/api/apps*`。公开列表/详情只给稳定下载入口，
/// 原始网盘地址不会下发到客户端，下载统一由 [AppDownloadManager] 走服务端网关。
library;

import 'feed_item.dart' show timeAgo;

int _int(dynamic v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;
String _str(dynamic v) => v == null ? '' : v.toString();
bool _bool(dynamic v) => v == true || v == 'true' || v == 1;

class AppCategory {
  final String id;
  final String name;
  final String slug;
  final String parentId;
  final List<AppCategory> children;

  const AppCategory({
    required this.id,
    required this.name,
    this.slug = '',
    this.parentId = '',
    this.children = const [],
  });

  factory AppCategory.fromJson(Map<String, dynamic> j) => AppCategory(
    id: _str(j['id']),
    name: _str(j['name']),
    slug: _str(j['slug']),
    parentId: _str(j['parentId']),
    children: ((j['children'] ?? []) as List)
        .whereType<Map>()
        .map((e) => AppCategory.fromJson(Map<String, dynamic>.from(e)))
        .toList(),
  );
}

class AppAuthor {
  final String id;
  final String name;
  final String avatar;
  final int level;
  final bool verified;
  final String verifiedLabel;
  final bool isAi;

  const AppAuthor({
    required this.id,
    required this.name,
    this.avatar = '',
    this.level = 0,
    this.verified = false,
    this.verifiedLabel = '',
    this.isAi = false,
  });

  factory AppAuthor.fromJson(Map<String, dynamic>? j) {
    if (j == null) return const AppAuthor(id: '', name: '社区用户');
    final label = _str(j['verifiedLabel'] ?? j['verified_label']).trim();
    final rawVerified = j['verified'];
    final verified =
        (rawVerified is bool && rawVerified) ||
        (rawVerified is num && rawVerified != 0) ||
        _str(rawVerified).trim().toLowerCase() != 'false' &&
            _str(rawVerified).trim().toLowerCase() != '0' &&
            _str(rawVerified).trim().isNotEmpty ||
        label.isNotEmpty;
    return AppAuthor(
      id: _str(j['id']),
      name: _str(j['name']).isEmpty ? '社区用户' : _str(j['name']),
      avatar: _str(j['avatar']),
      level: _int(j['level']),
      verified: verified,
      verifiedLabel: label,
      isAi: _bool(j['isAi'] ?? j['is_ai']) || label.toUpperCase() == 'AI',
    );
  }
}

class MarketApp {
  final String id;
  final String name;
  final String icon;
  final String platform;
  final String packageType;
  final String packageName;
  final String version;
  final String osVersion;
  final String categoryId;
  final String subCategoryId;
  final String category;
  final String subCategory;
  final String description;
  final String shareReason;
  final String reason;
  final int downloadCount;
  final double rating;
  final int ratingCount;
  final int favoriteCount;
  final int commentCount;
  final bool featured;
  final int publishedAt;
  final String downloadUrl;
  final String storeUrl;
  final AppAuthor author;
  final List<String> screenshots;
  final String versionId;
  final int myRating;
  final bool favorited;
  final String shareUrl;
  final String shortUrl;

  // 我的投稿专属字段
  final int status;
  final String statusText;
  final int auditStatus;
  final String auditStatusText;
  final String rejectReason;
  final int created;
  final int updated;

  const MarketApp({
    required this.id,
    required this.name,
    this.icon = '',
    this.platform = '',
    this.packageType = '',
    this.packageName = '',
    this.version = '',
    this.osVersion = '',
    this.categoryId = '',
    this.subCategoryId = '',
    this.category = '',
    this.subCategory = '',
    this.description = '',
    this.shareReason = '',
    this.reason = '',
    this.downloadCount = 0,
    this.rating = 0,
    this.ratingCount = 0,
    this.favoriteCount = 0,
    this.commentCount = 0,
    this.featured = false,
    this.publishedAt = 0,
    this.downloadUrl = '',
    this.storeUrl = '',
    this.author = const AppAuthor(id: '', name: '社区用户'),
    this.screenshots = const [],
    this.versionId = '',
    this.myRating = 0,
    this.favorited = false,
    this.shareUrl = '',
    this.shortUrl = '',
    this.status = -1,
    this.statusText = '',
    this.auditStatus = -1,
    this.auditStatusText = '',
    this.rejectReason = '',
    this.created = 0,
    this.updated = 0,
  });

  factory MarketApp.fromJson(Map<String, dynamic> j) => MarketApp(
    id: _str(j['id']),
    name: _str(j['name']),
    icon: _str(j['icon']),
    platform: _str(j['platform']),
    packageType: _str(j['packageType']),
    packageName: _str(j['packageName']),
    version: _str(j['version']),
    osVersion: _str(j['osVersion']),
    categoryId: _str(j['categoryId']),
    subCategoryId: _str(j['subCategoryId']),
    category: _str(j['category']),
    subCategory: _str(j['subCategory']),
    description: _str(j['description']),
    shareReason: _str(j['shareReason']),
    reason: _str(j['reason']),
    downloadCount: _int(j['downloadCount']),
    rating: (j['rating'] as num?)?.toDouble() ?? 0,
    ratingCount: _int(j['ratingCount']),
    favoriteCount: _int(j['favoriteCount']),
    commentCount: _int(j['commentCount']),
    featured: _bool(j['featured']),
    publishedAt: _int(j['publishedAt']),
    downloadUrl: _str(j['downloadUrl']),
    storeUrl: _str(j['storeUrl']),
    author: AppAuthor.fromJson(
      j['author'] is Map ? Map<String, dynamic>.from(j['author']) : null,
    ),
    screenshots: ((j['screenshots'] ?? []) as List)
        .whereType<String>()
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(),
    versionId: _str(j['versionId']),
    myRating: _int(j['myRating']),
    favorited: _bool(j['favorited']),
    shareUrl: _str(j['shareUrl']),
    shortUrl: _str(j['shortUrl']),
    status: j.containsKey('status') ? _int(j['status']) : -1,
    statusText: _str(j['statusText']),
    auditStatus: j.containsKey('auditStatus') ? _int(j['auditStatus']) : -1,
    auditStatusText: _str(j['auditStatusText']),
    rejectReason: _str(j['rejectReason']),
    created: _int(j['created']),
    updated: _int(j['updated']),
  );

  bool get isMine => status >= 0;
  bool get isPublished => status == 2;
  bool get needsEdit => status == 0 || status == 3;

  String get platformLabel => switch (platform) {
    'android' => 'Android',
    'ios' => 'iOS',
    'harmony' => '鸿蒙',
    'windows' => 'Windows',
    _ => platform.isEmpty ? '未知平台' : platform,
  };

  /// iOS 早期数据把商店条目误写成 app；只要带真实商店链接且不是 IPA，
  /// 也按商店应用处理，避免把用户引向无效的安装包下载。
  bool get isStore {
    final t = packageType.toLowerCase();
    if (t == 'store') return true;
    if (platform.toLowerCase() == 'ios' &&
        t != 'ipa' &&
        storeUrl.trim().isNotEmpty) {
      return true;
    }
    return false;
  }

  String get storeLabel => switch (platform.toLowerCase()) {
    'ios' => 'App Store',
    'windows' => 'Microsoft Store',
    _ => '应用商店',
  };

  String get packageLabel {
    switch (packageType.toLowerCase()) {
      case 'apk':
        return 'APK';
      case 'ipa':
        return 'IPA';
      case 'store':
        return storeLabel;
      case 'hap':
        return 'HAP';
      case 'app':
        return 'APP';
      case 'exe':
        return 'EXE';
      case 'msi':
        return 'MSI';
      default:
        return packageType.isEmpty ? '安装包' : packageType.toUpperCase();
    }
  }

  String get extension {
    final t = packageType.toLowerCase();
    if (t == 'apk' ||
        t == 'ipa' ||
        t == 'hap' ||
        t == 'app' ||
        t == 'exe' ||
        t == 'msi') {
      return t;
    }
    return 'bin';
  }

  String get ratingText =>
      ratingCount <= 0 ? '暂无评分' : rating.toStringAsFixed(1);
}

class MarketAppPage {
  final List<MarketApp> list;
  final int page;
  final int pageSize;
  final int total;
  final bool personalized;
  final bool fresh;

  const MarketAppPage({
    this.list = const [],
    this.page = 1,
    this.pageSize = 20,
    this.total = 0,
    this.personalized = false,
    this.fresh = false,
  });

  factory MarketAppPage.fromJson(Map<String, dynamic> j) => MarketAppPage(
    list: ((j['list'] ?? []) as List)
        .whereType<Map>()
        .map((e) => MarketApp.fromJson(Map<String, dynamic>.from(e)))
        .toList(),
    page: _int(j['page']) == 0 ? 1 : _int(j['page']),
    pageSize: _int(j['pageSize']) == 0 ? 20 : _int(j['pageSize']),
    total: _int(j['total']),
    personalized: _bool(j['personalized']),
    fresh: _bool(j['fresh']),
  );

  bool get hasMore => page * pageSize < total;
}

class AppComment {
  final String id;
  final String content;
  final String parentId;
  final int created;
  final int status;
  final AppAuthor author;

  const AppComment({
    required this.id,
    required this.content,
    this.parentId = '',
    this.created = 0,
    this.status = 1,
    this.author = const AppAuthor(id: '', name: '社区用户'),
  });

  factory AppComment.fromJson(Map<String, dynamic> j) => AppComment(
    id: _str(j['id']),
    content: _str(j['content']),
    parentId: _str(j['parentId']),
    created: _int(j['created']),
    status: _int(j['status']) == 0 ? 0 : 1,
    author: AppAuthor.fromJson(
      j['author'] is Map ? Map<String, dynamic>.from(j['author']) : null,
    ),
  );

  String get timeText => created <= 0 ? '' : timeAgo(created);
}

/// 应用投稿表单的提交字段。接口层只做字段拼装，校验在 UI 与服务端同时进行。
class AppSubmissionDraft {
  final String name;
  final String icon;
  final String packageType;
  final String packageName;
  final String categoryId;
  final String subCategoryId;
  final List<String> screenshots;
  final String description;
  final String shareReason;
  final String downloadUrl;
  final String versionName;
  final String osVersion;
  final String shareCode;
  final String? appId;
  final String? versionId;

  const AppSubmissionDraft({
    required this.name,
    required this.icon,
    required this.packageType,
    required this.packageName,
    required this.categoryId,
    required this.subCategoryId,
    required this.screenshots,
    required this.description,
    required this.shareReason,
    required this.downloadUrl,
    required this.versionName,
    this.osVersion = '',
    this.shareCode = '',
    this.appId,
    this.versionId,
  });

  Map<String, dynamic> toJson() => {
    'name': name,
    'icon': icon,
    'packageType': packageType,
    'packageName': packageName,
    'categoryId': categoryId,
    'subcategoryId': subCategoryId,
    'screenshots': screenshots,
    'description': description,
    'shareReason': shareReason,
    'downloadUrl': downloadUrl,
    'versionName': versionName,
    'osVersion': osVersion,
    // 编辑既有投稿时，空提取码不应覆盖服务端原值；只在用户填写时提交。
    if (shareCode.trim().isNotEmpty) 'shareCode': shareCode.trim(),
  };
}
