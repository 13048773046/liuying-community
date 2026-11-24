import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:community_app/design/components.dart';

Widget _app(PreferredSizeWidget bar) => MaterialApp(
  home: Scaffold(appBar: bar, body: const SizedBox.expand()),
);

void main() {
  testWidgets('透明顶栏不挂 BackdropFilter，实底/浮起才挂', (tester) async {
    await tester.pumpWidget(
      _app(const GlassTopBar(title: '透明', showBack: false)),
    );
    expect(find.byType(BackdropFilter), findsNothing);

    await tester.pumpWidget(
      _app(const GlassTopBar(title: '实底', showBack: false, solid: true)),
    );
    expect(find.byType(BackdropFilter), findsOneWidget);

    await tester.pumpWidget(
      _app(const GlassTopBar(title: '浮起', showBack: false, floating: true)),
    );
    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
