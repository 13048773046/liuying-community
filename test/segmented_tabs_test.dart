library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:community_app/design/components.dart';

void main() {
  testWidgets('分段标签跟手拖动后会吸附到下一项', (tester) async {
    var index = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) => Scaffold(
            body: Center(
              child: SegmentedTabs(
                labels: const ['关注', '推荐'],
                index: index,
                onChanged: (i) => setState(() => index = i),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('推荐'));
    await tester.pumpAndSettle();
    expect(index, 1);

    await tester.tap(find.text('关注'));
    await tester.pumpAndSettle();
    expect(index, 0);

    await tester.drag(find.byType(SegmentedTabs), const Offset(-78, 0));
    await tester.pumpAndSettle();
    expect(index, 1);
  });
}
