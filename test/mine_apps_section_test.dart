/// 我的页应用投稿区：审核状态与驳回原因必须「看得见」。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:community_app/design/components.dart';
import 'package:community_app/models/app_market.dart';
import 'package:community_app/pages/mine/mine_apps_section.dart';

MarketApp _app({
  required String id,
  required String name,
  required int status,
  required String statusText,
  String rejectReason = '',
}) => MarketApp(
  id: id,
  name: name,
  category: '工具',
  subCategory: '系统',
  description: '一个用来测试审核提示的应用。',
  status: status,
  statusText: statusText,
  rejectReason: rejectReason,
  downloadCount: status == 2 ? 128 : 0,
);

Widget _host(Widget child, {double width = 390}) => MaterialApp(
  theme: buildImmersiveTheme(),
  home: MediaQuery(
    data: MediaQueryData(size: Size(width, 844)),
    child: Scaffold(
      backgroundColor: const Color(AppColors.bg),
      body: SingleChildScrollView(child: child),
    ),
  ),
);

void main() {
  testWidgets('待审核 / 未通过 / 已上架都有明确提示', (tester) async {
    tester.view.physicalSize = const Size(390 * 2, 844 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    var opened = 0;
    await tester.pumpWidget(
      _host(
        MineAppsSection(
          apps: [
            _app(
              id: 'pending',
              name: '待审应用甲',
              status: 1,
              statusText: '审核中',
            ),
            _app(
              id: 'rejected',
              name: '被拒应用乙',
              status: 3,
              statusText: '未通过',
              rejectReason: '截图不清晰，请补充应用截图',
            ),
            _app(
              id: 'published',
              name: '已上架应用丙',
              status: 2,
              statusText: '已上架',
            ),
          ],
          loading: false,
          error: null,
          onManage: () {},
          onSubmit: () {},
          onRetry: () {},
          onOpen: (_) => opened++,
        ),
      ),
    );
    await tester.pump();

    expect(find.textContaining('1 款审核中'), findsOneWidget);
    expect(find.textContaining('1 款未通过'), findsOneWidget);
    expect(find.textContaining('1 款已上架'), findsOneWidget);
    expect(find.text('审核中'), findsOneWidget);
    expect(find.text('未通过'), findsOneWidget);
    expect(find.textContaining('截图不清晰'), findsOneWidget);

    await tester.tap(find.text('待审应用甲'));
    expect(opened, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('320 小屏横向卡片不溢出，空投稿有入口', (tester) async {
    tester.view.physicalSize = const Size(320 * 2, 700 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _host(
        MineAppsSection(
          apps: [
            _app(
              id: 'pending',
              name: '一个名字很长很长的待审核应用',
              status: 1,
              statusText: '审核中',
            ),
            _app(
              id: 'rejected',
              name: '另一个名字也很长的未通过应用',
              status: 3,
              statusText: '未通过',
              rejectReason: '应用描述太短，需要补充完整功能介绍与使用说明',
            ),
          ],
          loading: false,
          error: null,
          onManage: () {},
          onSubmit: () {},
          onRetry: () {},
          onOpen: (_) {},
        ),
        width: 320,
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(
      _host(
        MineAppsSection(
          apps: const [],
          loading: false,
          error: null,
          onManage: () {},
          onSubmit: () {},
          onRetry: () {},
          onOpen: (_) {},
        ),
        width: 320,
      ),
    );
    await tester.pump();
    expect(find.text('分享你的第一个应用'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
