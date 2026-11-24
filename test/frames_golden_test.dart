/// 头像框渲染回归：验证透明 PNG 叠加在头像外圈的位置与比例。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:community_app/design/components.dart';

Future<void> _loadFonts() async {
  final cjk = File('/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc');
  if (cjk.existsSync()) {
    final bytes = cjk.readAsBytesSync();
    final loader = FontLoader('NotoSansCJK');
    loader.addFont(Future.value(ByteData.view(bytes.buffer)));
    await loader.load();
  }
  final icon = File(
      '/home/user/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  if (icon.existsSync()) {
    final bytes = icon.readAsBytesSync();
    final loader = FontLoader('MaterialIcons');
    loader.addFont(Future.value(ByteData.view(bytes.buffer)));
    await loader.load();
  }
}

Widget _stage(Size size, Widget child) => MediaQuery(
      data: const MediaQueryData(size: Size(390, 844), devicePixelRatio: 2),
      child: Theme(
        data: ThemeData(fontFamily: 'NotoSansCJK'),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Container(
          width: size.width,
          height: size.height,
          color: const Color(AppColors.bg),
            alignment: Alignment.center,
            child: child,
          ),
        ),
      ),
    );

Future<void> _precache(WidgetTester tester) async {
  final images = tester.widgetList<Image>(find.byType(Image)).toList();
  if (images.isEmpty) return;
  final ctx = tester.element(find.byType(Image).first);
  await tester.runAsync(() async {
    for (final img in images) {
      await precacheImage(img.image, ctx);
    }
  });
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(_loadFonts);

  testWidgets('frame overlay 12 款比例一致', (tester) async {
    final names = [
      'h01_mint',
      'h02_maid',
      'h03_magic',
      'h04_sakura',
      'h05_music',
      'h06_moon',
      'h07_snow',
      'h08_angel',
      'h09_devil',
      'h10_cat',
      'h11_candy',
      'h12_winter',
    ];
    final grid = Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        for (final n in names)
          AppAvatar(
            size: 46,
            name: '萤',
            url: '',
            frameUrl: 'asset:assets/frames/$n.png',
          ),
      ],
    );
    tester.view.physicalSize = const Size(390 * 2, 844 * 2);
    tester.view.devicePixelRatio = 2;
    await tester.pumpWidget(_stage(const Size(390, 844), grid));
    await tester.pumpAndSettle();
    await _precache(tester);
    await expectLater(
      find.byType(Wrap),
      matchesGoldenFile('goldens/frames_grid.png'),
    );
  });

  testWidgets('我的页头像 68 叠框', (tester) async {
    tester.view.physicalSize = const Size(390 * 2, 844 * 2);
    tester.view.devicePixelRatio = 2;
    await tester.pumpWidget(_stage(
      const Size(390, 844),
      Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          AppAvatar(
            size: 68,
            name: '萤',
            frameUrl: 'asset:assets/frames/h01_mint.png',
            badge: Container(
              width: 22,
              height: 22,
              decoration: const BoxDecoration(
                color: Color(0xFF45E0AE),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.check, size: 14, color: Colors.black),
            ),
          ),
          SizedBox(width: 24),
          AppAvatar(
            size: 40,
            name: '火',
            frameUrl: 'asset:assets/frames/h01_mint.png',
          ),
        ],
      ),
    ));
    await tester.pumpAndSettle();
    await _precache(tester);
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(Row),
      matchesGoldenFile('goldens/frames_avatar.png'),
    );
  });
}
