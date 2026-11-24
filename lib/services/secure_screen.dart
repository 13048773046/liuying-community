/// 流萤社区 · 敏感页面屏幕保护
///
/// Android 通过 FLAG_SECURE 阻止截图/录屏和最近任务预览；iOS 没有等价能力，
/// 这里只做无操作调用。页面使用 [SecureScreenMixin] 进入/退出，内部按引用计数，
/// 避免登录页跳转到验证码/支付页时 premature 关闭保护。
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

class SecureScreen {
  SecureScreen._();

  static const _channel = MethodChannel(
    'com.community.community_app/secure_screen',
  );

  static int _holders = 0;

  static Future<void> acquire() async {
    _holders++;
    if (_holders == 1) await _apply(true);
  }

  static Future<void> release() async {
    if (_holders <= 0) return;
    _holders--;
    if (_holders == 0) await _apply(false);
  }

  static Future<void> _apply(bool secure) async {
    try {
      await _channel.invokeMethod<void>('setSecure', secure);
    } on MissingPluginException {
      // iOS / widget 测试没有原生通道，忽略。
    } catch (_) {
      // 原生侧不可用时不能影响页面本身。
    }
  }
}

/// 放到 State 上：`class _LoginPageState extends State<LoginPage> with SecureScreenMixin`
mixin SecureScreenMixin<T extends StatefulWidget> on State<T> {
  @override
  void initState() {
    super.initState();
    unawaited(SecureScreen.acquire());
  }

  @override
  void dispose() {
    unawaited(SecureScreen.release());
    super.dispose();
  }
}
