/// 信息流统一模型：帖子（text/image/poll）与短视频（video）共用 feed 结构。
library;

/// 容错布尔解析：后端可能返回 true/false，也可能返回 1/0（int）或 '1'/'0'（string）。
/// 直接 `as bool` 会在后端返回 0/1 时抛 type 'int' is not a subtype of type 'bool'。
bool boolOf(dynamic v, [bool fallback = false]) {
  if (v == null) return fallback;
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) {
    final s = v.trim().toLowerCase();
    if (s == 'true' || s == '1') return true;
    if (s == 'false' || s == '0') return false;
  }
  return fallback;
}

class Author {
  final String id;
  final String name;
  final String avatar;
  final int level;
  final String frameId;
  final int adminLevel;
  final String adminName;

  Author.fromJson(Map<String, dynamic> j)
      : id = (j['id'] ?? '') as String,
        name = (j['name'] ?? '') as String,
        avatar = (j['avatar'] ?? '') as String,
        level = ((j['level'] ?? 0) as num).toInt(),
        frameId = (j['frameId'] ?? '') as String,
        adminLevel = ((j['adminLevel'] ?? 0) as num).toInt(),
        adminName = (j['adminName'] ?? '') as String;

  bool get isAdmin => adminLevel > 0;
}

class FeedItem {
  final String id;
  final String type; // text | image | video | poll
  final String content;
  final List<String> images;
  final String video; // 文件名（video 类型）
  final String cover; // 封面文件名
  final int duration; // 秒
  final String boardId;
  final String tag;
  final List<String> topic;
  final List<String> mentions;
  final int likeCount;
  final int commentCount;
  final int shareCount;
  final bool liked;
  final bool faved;
  final bool sticky;
  final bool featured;
  final int created;
  final Author author;

  FeedItem.fromJson(Map<String, dynamic> j)
      : id = (j['id'] ?? '') as String,
        type = (j['type'] ?? 'text') as String,
        content = (j['content'] ?? '') as String,
        images = ((j['images'] ?? []) as List).map((e) => e.toString()).toList(),
        video = (j['video'] ?? '') as String,
        cover = (j['cover'] ?? '') as String,
        duration = ((j['duration'] ?? 0) as num).toInt(),
        boardId = (j['boardId'] ?? '') as String,
        tag = (j['tag'] ?? '') as String,
        topic = ((j['topic'] ?? []) as List).map((e) => e.toString()).toList(),
        mentions = ((j['mentions'] ?? []) as List)
            .map((e) => e.toString())
            .toList(),
        likeCount = ((j['likeCount'] ?? 0) as num).toInt(),
        commentCount = ((j['commentCount'] ?? 0) as num).toInt(),
        shareCount = ((j['shareCount'] ?? 0) as num).toInt(),
        liked = boolOf(j['liked']),
        faved = boolOf(j['faved']),
        sticky = boolOf(j['sticky']),
        featured = boolOf(j['featured']),
        created = ((j['created'] ?? 0) as num).toInt(),
        author = Author.fromJson((j['author'] ?? {}) as Map<String, dynamic>);

  bool get isVideo => type == 'video';
}

/// 分页结果
class FeedPage {
  final List<FeedItem> list;
  final int page;
  final bool hasMore;

  FeedPage({required this.list, required this.page, required this.hasMore});

  factory FeedPage.fromJson(Map<String, dynamic> j) => FeedPage(
        list: ((j['list'] ?? []) as List)
            .whereType<Map<String, dynamic>>()
            .map(FeedItem.fromJson)
            .toList(),
        page: ((j['page'] ?? 1) as num).toInt(),
        hasMore: boolOf(j['hasMore']),
      );
}

/// 相对时间展示
String timeAgo(int ts) {
  final diff = DateTime.now().millisecondsSinceEpoch ~/ 1000 - ts;
  if (diff < 60) return '刚刚';
  if (diff < 3600) return '${diff ~/ 60}分钟前';
  if (diff < 86400) return '${diff ~/ 3600}小时前';
  if (diff < 86400 * 30) return '${diff ~/ 86400}天前';
  return '${DateTime.fromMillisecondsSinceEpoch(ts * 1000).year}-'
      '${DateTime.fromMillisecondsSinceEpoch(ts * 1000).month.toString().padLeft(2, '0')}-'
      '${DateTime.fromMillisecondsSinceEpoch(ts * 1000).day.toString().padLeft(2, '0')}';
}

/// 数量缩写（10000+ → 1.2w）
String countText(int n) {
  if (n < 10000) return '$n';
  return '${(n / 10000).toStringAsFixed(1)}w';
}
