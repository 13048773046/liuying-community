// 登录页单输入框手机号/邮箱自动识别提示测试。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:community_app/design/components.dart';
import 'package:community_app/pages/mine/login_page.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('验证码登录输入手机号提示发短信，输入邮箱提示发邮件', (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(theme: buildImmersiveTheme(), home: const LoginPage()),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('验证码登录'));
    await tester.pumpAndSettle();
    expect(find.text('手机号或邮箱'), findsOneWidget);
    expect(find.text('自动识别：手机号发短信，邮箱发邮件'), findsOneWidget);

    final identifier = find.byType(TextField).first;
    await tester.enterText(identifier, '13800138000');
    await tester.pumpAndSettle();
    expect(find.text('将发送短信验证码'), findsOneWidget);

    await tester.enterText(identifier, 'tester@example.com');
    await tester.pumpAndSettle();
    expect(find.text('将发送邮箱验证码'), findsOneWidget);
  });
}
