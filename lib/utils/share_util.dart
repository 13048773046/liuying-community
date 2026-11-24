/// 系统分享封装（share_plus）。
///
/// - iPad 上 `sharePositionOrigin` 必填，否则系统会崩；这里允许调用方传入点击位置。
/// - 分享失败（模拟器/桌面端不支持）静默处理，不影响主流程。
library;

import 'dart:ui';

import '../api/client.dart';
import '../config.dart';
import '../design/system.dart';

Future<void> shareToSystem(String text, {String? subject, Rect? origin}) async {
  try {
    await AppShare.shareText(text, subject: subject, origin: origin);
  } catch (_) {
    // 平台不支持时静默
  }
}

String postShareUrl(String postId) =>
    '$kSiteBase/community/share.html?id=$postId';

String userShareUrl(String uid) => '$kSiteBase/community/share.html?uid=$uid';

/// 帖子短链；接口异常时回退 H5 长链。
Future<String> resolvePostShareUrl(String postId) =>
    ApiClient.shareShortLink('post', postId, fallback: postShareUrl(postId));

/// 用户主页短链；接口异常时回退 H5 长链。
Future<String> resolveUserShareUrl(String uid) =>
    ApiClient.shareShortLink('user', uid, fallback: userShareUrl(uid));

/// 分享一条帖子的文案（标题 + 短链）。
///
/// 短链由服务端按 postId 复用，匿名也可生成；接口不可用时回退长链。
Future<void> sharePostLink(String title, String postId, {Rect? origin}) async {
  final url = await resolvePostShareUrl(postId);
  final t = title.trim();
  final head = t.isEmpty ? '流萤社区' : '《$t》- 流萤社区';
  await shareToSystem('$head\n$url', subject: '流萤社区', origin: origin);
}

/// 应用分享落地页（长链兜底）：服务端渲染应用信息、截图和安装入口。
String appShareUrl(String appId) => '$kSiteBase/community/app/$appId';

/// 生成应用短链；接口异常时回退到 H5 落地页长链。
Future<String> resolveAppShareUrl(String appId) =>
    ApiClient.shareShortLink('app', appId, fallback: appShareUrl(appId));

/// 分享一款应用的文案（名称 + 版本 + 短链）。
String appShareText({
  required String name,
  required String version,
  required String appId,
  String? url,
}) {
  final v = version.trim();
  final head = v.isEmpty ? '《$name》' : '《$name》 v$v';
  return '$head\n来自流萤社区应用市场\n${(url ?? '').trim().isEmpty ? appShareUrl(appId) : url!.trim()}';
}
