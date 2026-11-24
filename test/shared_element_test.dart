import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:community_app/design/shared_element.dart';
import 'package:community_app/design/tokens.dart';

Widget _box(String label, {double size = 80}) => SizedBox(
  width: size,
  height: size,
  child: ColoredBox(
    color: const Color(AppColors.accent),
    child: Center(child: Text(label)),
  ),
);

void main() {
  test('页面转场时长：前进 260ms，返回 220ms', () {
    final route = AppPageRoute<void>(builder: (_) => const SizedBox());
    expect(route.transitionDuration, AppMotion.sharedForward);
    expect(route.reverseTransitionDuration, AppMotion.sharedBack);
    route.dispose();
  });

  testWidgets('减弱动态效果时 AppHero 不注册飞行', (tester) async {
    await tester.pumpWidget(
      const MediaQuery(
        data: MediaQueryData(disableAnimations: true),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: AppHero(tag: 'a', child: SizedBox(width: 40, height: 40)),
        ),
      ),
    );
    expect(find.byType(Hero), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('共享元素可跨 AppPageRoute 飞行且不抛异常', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: AppHero(tag: 'shared-box', child: _box('源')),
          ),
        ),
      ),
    );

    final nav = tester.state<NavigatorState>(find.byType(Navigator));
    nav.push(
      AppPageRoute<void>(
        builder: (_) => Scaffold(
          body: Center(
            child: AppHero(tag: 'shared-box', child: _box('目标', size: 160)),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();
    expect(find.text('目标'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
