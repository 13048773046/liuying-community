import 'package:community_app/features/emoji/text_emoji.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('插入表情后光标在末尾，再继续输入文字', (tester) async {
    final c = TextEmojiEditingController(text: '发一张[比心]');
    c.selection = TextSelection.collapsed(offset: c.text.length);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: TextField(controller: c, autofocus: true))));
    await tester.pump();
    expect(tester.takeException(), isNull);
    c.value = TextEditingValue(text: '${c.text}好', selection: TextSelection.collapsed(offset: c.text.length + 1));
    await tester.pump();
    expect(c.text, '发一张[比心]好');
    expect(tester.takeException(), isNull);
  });
}
