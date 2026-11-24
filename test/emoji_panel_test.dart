import 'package:community_app/services/hot_update.dart';
import 'package:community_app/widgets/emoji_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    HotUpdateService.instance.config.value = const HotConfig();
  });

  Future<Map<String, dynamic>?> pickFirst(
    WidgetTester tester, {
    required bool inline,
  }) async {
    HotUpdateService.instance.config.value = HotConfig(
      master: true,
      configs: {
        'feature_flags': {'inline_text_emoji': inline},
      },
    );
    Map<String, dynamic>? picked;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 390,
            height: 520,
            child: EmojiPanel(
              compact: true,
              onPick: (e) => picked = e,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final firstImage = find.byType(Image).first;
    expect(firstImage, findsOneWidget);
    await tester.tap(firstImage);
    await tester.pump();
    return picked;
  }

  testWidgets('默认关闭文字混排：选中流萤表情返回图片路径', (tester) async {
    final picked = await pickFirst(tester, inline: false);
    expect(picked, isNotNull);
    final e = picked!;
    expect((e['textCode'] ?? '').toString(), isEmpty);
    expect(e['image'], 'emoji_official/liuying/ly01.webp');
    expect(e['asset'], startsWith('assets/emoji_text/'));
  });

  testWidgets('远程开启文字混排：同一入口恢复 token 插入字段', (tester) async {
    final picked = await pickFirst(tester, inline: true);
    expect(picked, isNotNull);
    final e = picked!;
    expect(e['textCode'], '开心大笑');
    // 图片路径仍保留，便于以后把旧的 token 输入切回图片发送。
    expect(e['image'], 'emoji_official/liuying/ly01.webp');
  });
}
