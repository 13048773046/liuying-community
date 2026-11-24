import 'package:community_app/design/components.dart';
import 'package:community_app/design/flip_countdown_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('验证码按钮按下后翻牌倒计时，结束恢复重新获取', (tester) async {
    var sent = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildImmersiveTheme(),
        home: Scaffold(
          backgroundColor: const Color(AppColors.bg),
          body: Center(
            child: FlipCountdownButton(
              seconds: 3,
              onSend: () async {
                sent++;
                return true;
              },
            ),
          ),
        ),
      ),
    );

    expect(find.text('发送验证码'), findsOneWidget);
    await tester.tap(find.byType(FlipCountdownButton));
    await tester.pump(const Duration(milliseconds: 350));
    expect(sent, 1);
    expect(find.text('s 后重发'), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    expect(find.text('s 后重发'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);

    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('重新获取'), findsOneWidget);
  });
}
