/// 系统分享封装（share_plus）。
///
/// - iPad 上 `sharePositionOrigin` 必填，否则系统会崩；这里允许调用方传入点击位置。
/// - 分享失败（模拟器/桌面端不支持）静默处理，不影响主流程。
library;

import 'dart:ui';

import 'package:share_plus/share_plus.dart';

Future<void> shareToSystem(
  String text, {
  String? subject,
  Rect? origin,
}) async {
  try {
    await Share.share(
      text,
      subject: subject,
      sharePositionOrigin: origin,
    );
  } catch (_) {
    // 平台不支持时静默
  }
}

/// 分享一条帖子的文案（标题 + 链接）。
Future<void> sharePostLink(
  String title,
  String postId, {
  Rect? origin,
}) {
  final t = title.trim();
  final head = t.isEmpty ? '流萤社区' : '《$t》- 流萤社区';
  return shareToSystem(
    '$head\nhttps://www.dbmt999.asia/community/share.html?id=$postId',
    subject: '流萤社区',
    origin: origin,
  );
}
