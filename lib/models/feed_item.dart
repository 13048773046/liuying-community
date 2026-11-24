/// 信息流统一模型：帖子（text/image/poll）与短视频（video）共用 feed 结构。
library;

import 'dart:convert';

import '../config.dart';

/// 容错 Map 解析：后端可能给 null、`Map<dynamic, dynamic>`（空字面量）或 JSON 字符串，
/// 直接 `as Map<String, dynamic>` 会抛类型异常，把整页列表一起打断。
Map<String, dynamic> mapOf(dynamic v) {
  if (v is Map<String, dynamic>) return v;
  if (v is Map) {
    return {for (final e in v.entries) e.key.toString(): e.value};
  }
  return <String, dynamic>{};
}

/// 容错配乐解析：后端可能给 JSON 字符串、已解码对象，或空串/空对象；无有效 url 视为无配乐。
Map<String, dynamic>? musicOf(dynamic v) {
  dynamic raw = v;
  if (raw is String) {
    if (raw.trim().isEmpty) return null;
    try {
      raw = jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }
  if (raw is! Map) return null;
  final m = mapOf(raw);
  final url = m['url'];
  if (url is! String || url.isEmpty) return null;
  return m;
}

/// 容错整数解析：后端可能给 num、数字字符串或脏值，`as num` 抛异常会打断整页列表。
int intOf(dynamic v, [int fallback = 0]) {
  if (v is num) return v.toInt();
  if (v is String) {
    final n = int.tryParse(v.trim());
    if (n != null) return n;
    final d = double.tryParse(v.trim());
    if (d != null) return d.toInt();
  }
  return fallback;
}

/// 百分比（0-100）解析：越界钳制、脏值回落默认。
int pctOf(dynamic v, int fallback) => intOf(v, fallback).clamp(0, 100);

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

/// 认证状态解析：后端 `verified` 是文本类型，`个人` / `官方` 等非空值表示已认证，
/// 空串、`false`、`0`、`none`、`未认证` 表示未认证。
bool verifiedOf(dynamic v) {
  if (v == null) return false;
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) {
    final s = v.trim().toLowerCase();
    if (s.isEmpty ||
        s == 'false' ||
        s == '0' ||
        s == 'none' ||
        s == 'null' ||
        s == '未认证') {
      return false;
    }
    return true;
  }
  return false;
}

/// 作者认证：后端的 `verified` 可能是 `个人`/`官方`/`1`，也可能只给 `verifiedLabel`。
bool _authorVerified(Map<String, dynamic> j) {
  if (verifiedOf(j['verified'])) return true;
  return _authorVerifiedLabel(j).isNotEmpty;
}

String _authorVerifiedLabel(Map<String, dynamic> j) {
  final raw = (j['verifiedLabel'] ?? j['verified_label'] ?? '')
      .toString()
      .trim();
  return raw;
}

bool _authorIsAi(Map<String, dynamic> j) {
  if (boolOf(j['isAi'] ?? j['is_ai'])) return true;
  return _authorVerifiedLabel(j).toUpperCase() == 'AI';
}

class Author {
  final String id;
  final String name;
  final String avatar;
  final int level;
  final String frameId;
  final int adminLevel;
  final String adminName;
  final bool verified;
  final String verifiedLabel;
  final bool isAi;

  /// 当前登录用户是否已关注该作者；信息流/主页接口下发时可直接用来决定「+」是否显示。
  final bool following;

  /// 后端是否真的下发了关注关系。false 表示未知，短视频页会按需补拉一次。
  final bool followingKnown;

  Author.fromJson(Map<String, dynamic> j)
    : id = (j['id'] ?? '') as String,
      name = (j['name'] ?? '') as String,
      avatar = (j['avatar'] ?? '') as String,
      level = intOf(j['level']),
      frameId = (j['frameId'] ?? '') as String,
      adminLevel = intOf(j['adminLevel']),
      adminName = (j['adminName'] ?? '') as String,
      verified = _authorVerified(j),
      verifiedLabel = _authorVerifiedLabel(j),
      isAi = _authorIsAi(j),
      following = boolOf(j['following'] ?? j['isFollowing']),
      followingKnown =
          j.containsKey('following') || j.containsKey('isFollowing');

  bool get isAdmin => adminLevel > 0;

  /// 头像 URL：优先用接口下发的文件名（[avatarUrl] 会解析带时间戳的 AI 图），
  /// 文件名缺失时用 uid 走头像代理兜底。
  String get avatarUrlResolved => avatarUrlFor(avatar, id);
}

class PostAttachment {
  final String name;
  final String label;
  final int size;
  final String ext;
  final String mime;

  const PostAttachment({
    required this.name,
    required this.label,
    required this.size,
    required this.ext,
    required this.mime,
  });

  factory PostAttachment.fromJson(Map<String, dynamic> j) => PostAttachment(
    name: (j['name'] ?? '').toString(),
    label: (j['label'] ?? j['originalName'] ?? j['name'] ?? '').toString(),
    size: intOf(j['size']),
    ext: (j['ext'] ?? '').toString().toLowerCase(),
    mime: (j['mime'] ?? '').toString(),
  );

  String get url => attachmentUrl(name, label);
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

  /// 个性化推荐理由（推荐流才有；其它信息流为空串）
  final String reason;
  final int auditStatus; // 0 待审 / 1 通过 / 2 拒绝
  final String auditReason;
  final bool takenDown;
  final Map<String, dynamic>? poll; // 投票帖：question/options/votes/voted/closed
  final List<PostAttachment> attachments; // 帖子附件（≤2 个）
  final Map<String, dynamic>? music; // 配乐 {url,name,cover,trackId}
  final int audioVolume; // 原声音量 0-100（发布者设定，默认 100）
  final int musicVolume; // 配乐音量 0-100（发布者设定，默认 50）
  final int created;
  final Author author;

  FeedItem.fromJson(Map<String, dynamic> j)
    : id = (j['id'] ?? '') as String,
      type = (j['type'] ?? 'text') as String,
      content = (j['content'] ?? '') as String,
      images = ((j['images'] ?? []) as List).map((e) => e.toString()).toList(),
      video = (j['video'] ?? '') as String,
      cover = (j['cover'] ?? '') as String,
      duration = intOf(j['duration']),
      boardId = (j['boardId'] ?? '') as String,
      tag = (j['tag'] ?? '') as String,
      topic = ((j['topic'] ?? []) as List).map((e) => e.toString()).toList(),
      mentions = ((j['mentions'] ?? []) as List)
          .map((e) => e.toString())
          .toList(),
      likeCount = intOf(j['likeCount']),
      commentCount = intOf(j['commentCount']),
      shareCount = intOf(j['shareCount']),
      liked = boolOf(j['liked']),
      faved = boolOf(j['faved']),
      sticky = boolOf(j['sticky']),
      featured = boolOf(j['featured']),
      reason = (j['reason'] ?? '') as String,
      auditStatus = intOf(j['auditStatus']),
      auditReason = (j['auditReason'] ?? '') as String,
      takenDown = boolOf(j['takenDown']),
      poll = (j['poll'] is Map) ? mapOf(j['poll']) : null,
      attachments = ((j['attachments'] ?? const []) as List)
          .whereType<Map>()
          .map((e) => PostAttachment.fromJson(mapOf(e)))
          .where((a) => a.name.isNotEmpty)
          .toList(),
      music = musicOf(j['music']),
      audioVolume = pctOf(j['audioVolume'], 100),
      musicVolume = pctOf(j['musicVolume'], 50),
      created = intOf(j['created']),
      author = Author.fromJson(mapOf(j['author']));

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

/// 相对时间展示。
///
/// `debugNow` 仅给视觉回归测试固定时钟用；线上永远走 DateTime.now()。
/// 没有它，golden 会在跨天后把“22小时前”变成“1天前”，测试就变成
/// 日更的假失败。
DateTime? debugTimeAgoNow;

String timeAgo(int ts) {
  final now = debugTimeAgoNow ?? DateTime.now();
  final diff = now.millisecondsSinceEpoch ~/ 1000 - ts;
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

/// 文件大小展示：B / KB / MB，附件卡片与下载进度共用。
String fileSizeText(int bytes) {
  if (bytes <= 0) return '';
  if (bytes < 1024) return '${bytes}B';
  final kb = bytes / 1024;
  if (kb < 1024) {
    return kb < 10 ? '${kb.toStringAsFixed(1)}KB' : '${kb.round()}KB';
  }
  final mb = kb / 1024;
  return mb < 10 ? '${mb.toStringAsFixed(1)}MB' : '${mb.round()}MB';
}
