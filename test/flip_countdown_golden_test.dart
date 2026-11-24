import 'dart:io';

import 'package:community_app/design/components.dart';
import 'package:community_app/design/flip_countdown_button.dart';
import 'package:community_app/pages/mine/login_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _loadFonts() async {
  Future<void> load(String name, String path) async {
    final f = File(path);
    if (!f.existsSync()) return;
    final bytes = await f.readAsBytes();
    final loader = FontLoader(name)
      ..addFont(Future.value(ByteData.view(bytes.buffer)));
    await loader.load();
  }

  await load('NotoSansSC', 'assets/fonts/NotoSansSC-Regular.otf');
  await load(
    'MaterialIcons',
    '/home/user/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  );
}

void main() {
  setUpAll(_loadFonts);

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('验证码按钮在 108 宽内完整显示倒计时', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 300 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildImmersiveTheme().copyWith(
          textTheme: buildImmersiveTheme().textTheme.apply(
            fontFamily: 'NotoSansSC',
          ),
        ),
        home: Scaffold(
          backgroundColor: const Color(AppColors.bg),
          body: Padding(
            padding: const EdgeInsets.fromLTRB(24, 80, 24, 0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    readOnly: true,
                    decoration: InputDecoration(
                      hintText: '验证码',
                      filled: true,
                      fillColor: const Color(AppColors.card),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FlipCountdownButton(
                  width: 108,
                  seconds: 60,
                  onSend: () async => true,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/flip_countdown_idle_390.png'),
    );

    await tester.tap(find.byType(FlipCountdownButton));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
    expect(find.text('s 后重发'), findsOneWidget);

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/flip_countdown_running_390.png'),
    );
  });

  testWidgets('登录页验证码行 320 宽不溢出', (tester) async {
    tester.view.physicalSize = const Size(320 * 3, 700 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildImmersiveTheme().copyWith(
          textTheme: buildImmersiveTheme().textTheme.apply(
            fontFamily: 'NotoSansSC',
          ),
        ),
        home: const LoginPage(),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('验证码登录'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    expect(find.byType(FlipCountdownButton), findsOneWidget);
    expect(find.text('发送验证码'), findsOneWidget);
  });
}
