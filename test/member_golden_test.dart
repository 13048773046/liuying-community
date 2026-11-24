// 会员页视觉回归：用 golden 渲染三态，人工核对布局与配色。
// 运行：flutter test test/member_golden_test.dart --update-goldens
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:community_app/design/tokens.dart';
import 'package:community_app/pages/mine/member_page.dart';

const _plans = [
  {'id': 'p_vip_1', 'level': 'member', 'label': 'VIP', 'name': '月卡', 'days': 30, 'price': 1200},
  {'id': 'p_vip_3', 'level': 'member', 'label': 'VIP', 'name': '季卡', 'days': 90, 'price': 3000},
  {'id': 'p_vip_12', 'level': 'member', 'label': 'VIP', 'name': '年卡', 'days': 365, 'price': 9800},
  {'id': 'p_svip_1', 'level': 'svip', 'label': 'SVIP', 'name': '月卡', 'days': 30, 'price': 3000},
  {'id': 'p_svip_3', 'level': 'svip', 'label': 'SVIP', 'name': '季卡', 'days': 90, 'price': 7800},
  {'id': 'p_svip_12', 'level': 'svip', 'label': 'SVIP', 'name': '年卡', 'days': 365, 'price': 26800},
];

// 会员到期日参与 golden；固定时钟，避免跨天运行时前一后一像素差就红。
final _fixedNow = DateTime(2026, 11, 21, 10);

Map<String, dynamic> _state({
  String level = '',
  int daysLeft = 0,
  int limit = 500,
}) =>
    {
      'level': level,
      'label': level == 'svip' ? 'SVIP' : (level == 'member' ? 'VIP' : ''),
      'expire': level.isEmpty ? 0 : _fixedNow.millisecondsSinceEpoch ~/ 1000 + daysLeft * 86400,
      'daysLeft': daysLeft,
      'expiring': false,
      'emojiLimit': limit,
      'emojiUsed': level.isEmpty ? 0 : 318,
    };

Future<void> _loadFont() async {
  final ico = File('/home/user/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  if (ico.existsSync()) {
    try {
      final l = FontLoader('MaterialIcons')
        ..addFont(Future.value(ByteData.sublistView(ico.readAsBytesSync())));
      await l.load();
    } catch (_) {}
  }
  for (final path in [
    '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
    '/usr/share/fonts/truetype/droid/DroidSansFallbackFull.ttf',
  ]) {
    final f = File(path);
    if (!f.existsSync()) continue;
    try {
      final loader = FontLoader('NotoSansCJK')
        ..addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
      await loader.load();
      return;
    } catch (_) {}
  }
}

Future<void> _shot(
  WidgetTester tester,
  Map<String, dynamic> me,
  String name,
) async {
  tester.view.physicalSize = const Size(390 * 2, 844 * 2);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      theme: buildImmersiveTheme().copyWith(
        textTheme: buildImmersiveTheme().textTheme.apply(fontFamily: 'NotoSansCJK'),
      ),
      home: MemberPage(key: ValueKey(name), seed: {'plans': _plans, 'me': me}),
    ),
  );
  await tester.pumpAndSettle();
  await expectLater(
    find.byType(MemberPage),
    matchesGoldenFile('goldens/member_$name.png'),
  );
}

void main() {
  testWidgets('渲染三态', (tester) async {
    await _loadFont();
    await _shot(tester, _state(), 'new');
    await _shot(tester, _state(level: 'svip', daysLeft: 123, limit: 5000), 'svip');
    await _shot(tester, _state(level: 'member', daysLeft: 39, limit: 2000), 'vip');
  });
}
