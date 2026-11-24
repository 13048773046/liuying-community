import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:community_app/features/emoji/text_emoji.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('50 个表情定义唯一且资源全部存在', () async {
    expect(kTextEmojis.length, 50);
    expect(kTextEmojiByCode.length, 50);
    expect(kTextEmojis.map((e) => e.id).toSet().length, 50);
    expect(kTextEmojis.map((e) => e.code).toSet().length, 50);
    for (final e in kTextEmojis) {
      expect(e.code.contains('['), isFalse);
      expect(e.code.contains(']'), isFalse);
      expect(e.asset, startsWith('assets/emoji_text/'));
      expect(e.imagePath, startsWith('emoji_official/liuying/'));
      expect(e.imagePath, endsWith('.webp'));
      final data = await rootBundle.load(e.asset);
      expect(data.lengthInBytes, greaterThan(1000));
    }
    // 图片消息落库用相对路径；50 个 id 不能有两个指到同一张图。
    expect(kTextEmojis.map((e) => e.imagePath).toSet().length, 50);
  });

  test('历史 128 PNG 媒体路径升级为同 id 的 1024 WebP', () {
    expect(
      upgradeEmojiMediaPath('emoji_official/liuying/ly01.png'),
      'emoji_official/liuying/ly01.webp',
    );
    expect(
      upgradeEmojiMediaPath('emoji_official/liuying/ly50.png'),
      'emoji_official/liuying/ly50.webp',
    );
    // 已经是 WebP、非流萤表情、普通聊天图片都不改。
    expect(
      upgradeEmojiMediaPath('emoji_official/liuying/ly07.webp'),
      'emoji_official/liuying/ly07.webp',
    );
    expect(
      upgradeEmojiMediaPath('community_img_abc.png'),
      'community_img_abc.png',
    );
  });

  test('输入框插入 token 且退格落在 token 内时整段删除', () {
    final c = TextEmojiEditingController();
    c.value = const TextEditingValue(
      text: '今晚一起听歌吗',
      selection: TextSelection.collapsed(offset: 7),
    );
    c.insertEmojiCode('比心');
    expect(c.text, '今晚一起听歌吗[比心]');
    expect(c.selection.baseOffset, c.text.length);

    // 退格删掉右方括号，应连带删掉整个表情 token，而不是留下半个。
    c.value = TextEditingValue(
      text: c.text.replaceRange(c.text.length - 1, c.text.length, ''),
      selection: TextSelection.collapsed(offset: c.text.length - 1),
    );
    expect(c.text, '今晚一起听歌吗');

    // 未知方括号不是表情，按普通文字逐字删除。
    c.value = const TextEditingValue(
      text: '保留[未知]文本',
      selection: TextSelection.collapsed(offset: 6),
    );
    c.value = TextEditingValue(
      text: '保留[未]文本',
      selection: const TextSelection.collapsed(offset: 5),
    );
    expect(c.text, '保留[未]文本');
  });

  testWidgets('输入框显示文字 token，插入表情后仍能继续输入', (tester) async {
    final c = TextEmojiEditingController(text: '发一张[比心]');
    c.selection = TextSelection.collapsed(offset: c.text.length);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TextField(controller: c, maxLines: 3)),
      ),
    );
    await tester.pump();
    // 输入框不再塞 WidgetSpan，避免原生光标/输入法位置被占位图打乱。
    expect(find.byType(Image), findsNothing);
    final editable = tester.widget<EditableText>(find.byType(EditableText));
    expect(editable.controller.text, '发一张[比心]');

    await tester.tap(find.byType(TextField));
    await tester.pump();
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '发一张[比心]给你',
        selection: TextSelection.collapsed(offset: 8),
      ),
    );
    await tester.pump();
    expect(c.text, '发一张[比心]给你');
    expect(tester.takeException(), isNull);
  });

  testWidgets('正文中的表情按小图内嵌，未知方括号原样保留', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: TextEmojiText('今晚一起听歌吗[比心] 也看看[不存在]')),
      ),
    );
    await tester.pump();
    final images = find.byType(Image);
    expect(images, findsOneWidget);
    final image = tester.widget<Image>(images);
    expect(image.image, isA<AssetImage>());
    expect((image.image as AssetImage).assetName, contains('22_比心.webp'));
    final rich = tester.widget<RichText>(find.byType(RichText));
    expect(rich.text.toPlainText(), contains('[不存在]'));
    expect(rich.text.toPlainText(), isNot(contains('[比心]')));
  });

  testWidgets('长文多表情可限制行数并省略', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 200,
            child: TextEmojiText(
              '${List.filled(20, '很开心[开心大笑]').join()}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byType(Image), findsWidgets);
  });
}
