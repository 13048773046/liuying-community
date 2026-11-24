import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Widget 测试里没有真实 path_provider 插件；CachedNetworkImage 会用临时目录，
/// 不 mock 就会抛 MissingPluginException，把与图片无关的交互测试一起打断。
void mockPathProvider() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async => '/tmp');
}
