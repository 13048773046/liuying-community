// 我的页入口区视觉回归：会员状态条 + 四格快捷入口。
// 运行：flutter test test/mine_entry_golden_test.dart --update-goldens
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:community_app/design/tokens.dart';
import 'package:community_app/pages/mine/mine_entry_section.dart';

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

Map<String, dynamic> _member({required bool active}) => active
    ? {
        'level': 'svip',
        'label': 'SVIP',
        'daysLeft': 123,
        'expiring': false,
        'expire': DateTime(2027, 3, 21).millisecondsSinceEpoch ~/ 1000,
      }
    : const {};

Future<void> _shot(
  WidgetTester tester, {
  required bool active,
  required String name,
}) async {
  tester.view.physicalSize = const Size(390 * 2, 260 * 2);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);

  final theme = buildImmersiveTheme();
  await tester.pumpWidget(
    MaterialApp(
      theme: theme.copyWith(
        textTheme: theme.textTheme.apply(fontFamily: 'NotoSansCJK'),
      ),
      home: Scaffold(
        backgroundColor: const Color(AppColors.bg),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
            child: MineEntrySection(
              member: _member(active: active),
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
  await tester.pumpAndSettle();
  await expectLater(
    find.byType(MineEntrySection),
    matchesGoldenFile('goldens/mine_entry_$name.png'),
  );
}

void main() {
  testWidgets('渲染会员与未开通两态', (tester) async {
    await _loadFont();
    await _shot(tester, active: true, name: 'svip');
    await _shot(tester, active: false, name: 'new');
  });
}
