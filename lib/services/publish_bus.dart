/// 发布流程的全局事件：编辑器关闭后，根容器和首页仍需要知道发布状态。
library;

import 'package:flutter/foundation.dart';

class PublishBus {
  PublishBus._();

  /// 发布动作已提交：根容器切回首页 tab。
  static final ValueNotifier<int> goHome = ValueNotifier<int>(0);

  /// 后台发布成功：首页刷新信息流。
  static final ValueNotifier<int> completed = ValueNotifier<int>(0);
}
