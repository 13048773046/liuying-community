// 会员开通弹层视觉检查：渲染「开通 SVIP」底部弹层整屏。
// 运行：flutter test test/member_sheet_shot_test.dart --update-goldens
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:community_app/api/client.dart';
import 'package:community_app/design/tokens.dart';
import 'package:community_app/pages/mine/member_page.dart';

const _plans = [
  {
    'id': 'p_vip_1',
    'level': 'member',
    'label': 'VIP',
    'name': '月卡',
    'days': 30,
    'price': 1200,
  },
  {
    'id': 'p_vip_3',
    'level': 'member',
    'label': 'VIP',
    'name': '季卡',
    'days': 90,
    'price': 3000,
  },
  {
    'id': 'p_vip_12',
    'level': 'member',
    'label': 'VIP',
    'name': '年卡',
    'days': 365,
    'price': 9800,
  },
  {
    'id': 'p_svip_1',
    'level': 'svip',
    'label': 'SVIP',
    'name': '月卡',
    'days': 30,
    'price': 3000,
  },
  {
    'id': 'p_svip_3',
    'level': 'svip',
    'label': 'SVIP',
    'name': '季卡',
    'days': 90,
    'price': 7800,
  },
  {
    'id': 'p_svip_12',
    'level': 'svip',
    'label': 'SVIP',
    'name': '年卡',
    'days': 365,
    'price': 26800,
  },
];

Map<String, dynamic> _me() => {
  'level': '',
  'label': '',
  'expire': 0,
  'daysLeft': 0,
  'expiring': false,
  'emojiLimit': 500,
  'emojiUsed': 0,
};

Future<void> _loadFont() async {
  final ico = File(
    '/home/user/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  );
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

void main() {
  testWidgets('开通弹层', (tester) async {
    await _loadFont();
    tester.view.physicalSize = const Size(390 * 2, 844 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    ApiClient.token = 'preview-token';
    await tester.pumpWidget(
      MaterialApp(
        theme: buildImmersiveTheme().copyWith(
          textTheme: buildImmersiveTheme().textTheme.apply(
            fontFamily: 'NotoSansCJK',
          ),
        ),
        home: MemberPage(seed: {'plans': _plans, 'me': _me()}),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('立即开通 SVIP'));
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/member_sheet.png'),
    );

    // 易支付不可用时的兜底：凭证人工开通弹层
    await tester.tap(find.text('支付遇到问题？改用凭证人工开通'));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/member_manual.png'),
    );
  });
}
