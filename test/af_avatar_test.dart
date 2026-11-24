import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:community_app/widgets/ai_avatar.dart';

void main() {
  testWidgets('AI 头像动图播完切静态', (tester) async {
    final key = GlobalKey();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        backgroundColor: const Color(0xFF05080F),
        body: Center(
          child: RepaintBoundary(key: key, child: const AiAvatar(size: 112)),
        ),
      ),
    ));
    await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 1)));
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await expectLater(
      find.byKey(key),
      matchesGoldenFile('goldens/af_avatar_done.png'),
    );
  });
}
