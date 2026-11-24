import 'package:community_app/design/components.dart';
import 'package:community_app/pages/onboarding/welcome_guide_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('320x568 小屏欢迎页视觉验收', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildImmersiveTheme(),
        home: WelcomeGuidePage(onDone: () {}),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
    await tester.runAsync(() async {
      final ctx = tester.element(find.byType(WelcomeGuidePage));
      for (final asset in [
        'assets/characters_v2/c01_mint.png',
        'assets/deco/sakura.png',
      ]) {
        await precacheImage(AssetImage(asset), ctx);
      }
    });
    await tester.pump(const Duration(milliseconds: 600));
    await expectLater(
      find.byType(WelcomeGuidePage),
      matchesGoldenFile('goldens/welcome_narrow_320.png'),
    );
  });
}
