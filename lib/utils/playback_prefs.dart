/// 播放偏好：短视频静音状态全局共享（滑到下一条也保持静音）。
library;

import 'package:flutter/foundation.dart';

class PlaybackPrefs {
  PlaybackPrefs._();

  /// 全局静音（短视频原声 + 配乐）
  static final ValueNotifier<bool> muted = ValueNotifier<bool>(false);
}
