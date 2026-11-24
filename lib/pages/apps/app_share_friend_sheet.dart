/// 应用分享 · 互关好友选择（兼容入口，实际 UI 复用全站 ShareFriendSheet）
library;

import 'package:flutter/material.dart';

import '../../models/app_market.dart';
import '../share/share_friend_sheet.dart';
import 'app_widgets.dart';

Future<void> showAppShareFriendSheet(BuildContext context, MarketApp app) {
  return showShareFriendSheet(
    context,
    ShareFriendTarget(
      type: 'app',
      id: app.id,
      title: app.name,
      subtitle: '${app.packageLabel} · v${app.version}',
      iconUrl: iconUrlOf(app),
      shareUrl: app.shortUrl.isNotEmpty ? app.shortUrl : app.shareUrl,
    ),
  );
}
