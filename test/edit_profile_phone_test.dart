// 编辑资料页手机号展示与绑定/更换弹层测试。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:community_app/design/components.dart';
import 'package:community_app/pages/mine/edit_profile_page.dart';

Widget _app(Map<String, dynamic> user) => MaterialApp(
  theme: buildImmersiveTheme(),
  home: EditProfilePage(user: user),
);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('未绑定手机号显示“未绑定”并可打开绑定弹层', (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _app({
        'id': 'u1',
        'name': '测试用户',
        'email': 'test@example.com',
        'phoneMask': '',
        'phoneVerified': false,
      }),
    );
    await tester.pumpAndSettle();

    expect(find.text('未绑定'), findsOneWidget);
    expect(find.text('去绑定'), findsOneWidget);

    await tester.tap(find.text('去绑定'));
    await tester.pumpAndSettle();
    expect(find.text('绑定手机号'), findsOneWidget);
    expect(find.text('输入手机号'), findsOneWidget);
    expect(find.text('一个手机号只能绑定一个流萤社区账号；验证码 5 分钟内有效，请勿泄露给他人。'), findsOneWidget);
  });

  testWidgets('已绑定手机号只显示掩码并可打开更换弹层', (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _app({
        'id': 'u2',
        'name': '已绑定用户',
        'email': 'bound@example.com',
        'phoneMask': '138****8000',
        'phoneVerified': true,
      }),
    );
    await tester.pumpAndSettle();

    expect(find.text('138****8000'), findsOneWidget);
    expect(find.text('更换'), findsOneWidget);
    expect(find.text('未绑定'), findsNothing);

    await tester.tap(find.text('更换'));
    await tester.pumpAndSettle();
    expect(find.text('更换手机号'), findsOneWidget);
    expect(find.textContaining('当前 138****8000'), findsOneWidget);
  });
}
