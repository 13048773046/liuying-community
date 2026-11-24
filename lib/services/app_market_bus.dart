import 'package:flutter/foundation.dart';

/// 应用市场数据版本。
///
/// 首页的应用橱窗是常驻页面，返回时不需要为「看了一眼应用市场」重新请求；
/// 只有投稿/编辑成功真正改变数据时才 `touch()`，首页据此决定是否需要补一次。
class AppMarketBus {
  AppMarketBus._();

  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static int get value => revision.value;

  static void touch() => revision.value++;
}
