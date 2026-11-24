/// 投票卡回归：别人投过票不等于“我”已投票。
///
/// 旧逻辑 `_total > 0` 会让第二个用户一进来就看到结果条，选项不可点，
/// 永远无法投票。这里锁住“未投票仍显示可点选项”的行为。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:community_app/widgets/poll_card.dart';

void main() {
  testWidgets('未投票时即使已有票数也显示可选项，不提前展示结果', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: PollCard(
            postId: 'p1',
            poll: {
              'question': '今晚听哪首？',
              'options': ['夜航', '晚风'],
              'votes': [3, 2],
              'voted': false,
              'closed': false,
            },
          ),
        ),
      ),
    );

    expect(find.text('今晚听哪首？'), findsOneWidget);
    expect(find.text('3 票'), findsNothing);
    expect(find.byIcon(Icons.radio_button_unchecked_rounded), findsNWidgets(2));
  });

  testWidgets('已投票后才展示票数与结果条', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: PollCard(
            postId: 'p1',
            poll: {
              'question': '今晚听哪首？',
              'options': ['夜航', '晚风'],
              'votes': [3, 2],
              'voted': true,
              'myOption': 0,
              'closed': false,
            },
          ),
        ),
      ),
    );

    expect(find.text('5 票'), findsOneWidget);
    expect(find.byIcon(Icons.radio_button_unchecked_rounded), findsNothing);
  });
}
