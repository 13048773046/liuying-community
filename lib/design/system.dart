/// 流萤社区 · 系统能力共享层
///
/// 页面不要直接散落调用 SystemChrome / Share / Clipboard / Haptic：
/// - [AppSystemUi]：状态栏、导航栏、安全区、字号；
/// - [AppHaptics]：轻/中/选择/成功触感；
/// - [AppShare] / [AppClipboard]：系统分享与剪贴板；
/// - [AppPermissions]：权限设置入口（由平台层实现，失败静默）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

class AppSystemUi {
  const AppSystemUi._();

  /// 沉浸式深色：透明状态栏 + 浅色图标；底部导航栏跟随页面底色。
  static void immersiveDark({Color navColor = Colors.black}) {
    SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
        systemNavigationBarColor: navColor,
        systemNavigationBarIconBrightness: Brightness.light,
        systemNavigationBarDividerColor: Colors.transparent,
      ),
    );
  }

  /// 统一安全区读取，避免各页手写 MediaQuery.paddingOf。
  static EdgeInsets safePadding(BuildContext context) =>
      MediaQuery.paddingOf(context);

  /// 大字号保护：页面正文最大 1.35 倍，避免卡片文字撑破布局。
  static double clampedTextScale(BuildContext context) =>
      MediaQuery.textScalerOf(context).scale(1.0).clamp(1.0, 1.35);

  static bool reduceMotion(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context);
}

class AppHaptics {
  const AppHaptics._();

  static Future<void> light() => HapticFeedback.lightImpact();
  static Future<void> medium() => HapticFeedback.mediumImpact();
  static Future<void> selection() => HapticFeedback.selectionClick();
  static Future<void> success() => HapticFeedback.mediumImpact();
}

class AppShare {
  const AppShare._();

  static Future<void> shareText(String text, {String? subject, Rect? origin}) =>
      Share.share(text, subject: subject, sharePositionOrigin: origin);

  static Future<void> shareFiles(
    List<XFile> files, {
    String? text,
    Rect? origin,
  }) => Share.shareXFiles(files, text: text, sharePositionOrigin: origin);
}

class AppClipboard {
  const AppClipboard._();

  static Future<void> copy(String text) =>
      Clipboard.setData(ClipboardData(text: text));
}

class AppPermissions {
  const AppPermissions._();

  /// 打开系统设置；平台未实现时静默，不阻断业务。
  static Future<void> openSettings() async {
    try {
      await SystemChannels.platform.invokeMethod<void>(
        'SystemNavigator.openSettings',
      );
    } catch (_) {}
  }
}
