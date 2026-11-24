import 'package:flutter/foundation.dart';

/// 用户资料 / 会员 / 等级等「我的」页数据变更通知。
///
/// 编辑资料、上传头像、开通或续费会员、兑换会员、签到升级等动作完成后调用
/// [touch]，所有正在监听「我的」数据的页面会重新拉取自己需要的那一份，
/// 不依赖页面返回顺序，也不会把旧账号/旧资料结果写回。
class UserDataBus {
  UserDataBus._();

  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static void touch() => revision.value++;
}
