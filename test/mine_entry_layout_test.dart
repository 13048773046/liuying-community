import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:community_app/design/tokens.dart';
import 'package:community_app/pages/mine/mine_entry_section.dart';

void main() {
  testWidgets('360 宽 + 1.25 字号不溢出', (tester) async {
    tester.view.physicalSize = const Size(360 * 2, 780 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildImmersiveTheme(),
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(360, 780),
            textScaler: TextScaler.linear(1.25),
            padding: EdgeInsets.only(top: 44, bottom: 34),
          ),
          child: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(AppSpace.gutter),
              child: MineEntrySection(
                member: const {
                  'level': 'svip',
                  'label': 'SVIP',
                  'daysLeft': 123,
                  'expiring': false,
                  'expire': 1800000000,
                },
                onMember: () {},
                onDownloads: () {},
                onWorks: () {},
                onFeedback: () {},
                onAbout: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.takeException(), isNull);
    expect(find.text('SVIP 会员'), findsOneWidget);
    expect(find.text('下载列表'), findsOneWidget);
    expect(find.text('我的作品'), findsOneWidget);
    expect(find.text('意见反馈'), findsOneWidget);
    expect(find.text('关于社区'), findsOneWidget);
  });
}
