import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 全局测试夹具：所有 Widget 测试默认具备 path_provider 临时目录。
///
/// `CachedNetworkImage` 的磁盘缓存会调用 `getTemporaryDirectory` /
/// `getApplicationSupportDirectory`；若不 mock，任何带网络图的页面测试都会
/// 抛 MissingPluginException，和真正的 UI 断言混在一起，难以定位。
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async => '/tmp');
  await testMain();
}
