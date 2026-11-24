// 四条动效提示词的组件级回归：共享扫光、错峰、三点、逐段显现。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:community_app/design/components.dart';

void main() {
  group('phraseChunks', () {
    test('按中文 2–4 字切段且拼回原文', () {
      const text = '你好世界这是测试，AI 回复要一段段出现。';
      final chunks = phraseChunks(text);
      expect(chunks.join(), text);
      expect(chunks.length, greaterThan(1));
      for (final chunk in chunks) {
        if (RegExp(r'^[\u4e00-\u9fff，。！？、；：]+$').hasMatch(chunk)) {
          expect(
            chunk.runes.length,
            lessThanOrEqualTo(5),
            reason: '中文段含标点时不应超过 5 个字符: $chunk',
          );
        }
      }
    });

    test('英文单词和 URL 不被拆开', () {
      const text = '打开 https://example.com/a 然后测试';
      final chunks = phraseChunks(text);
      expect(chunks.join(), text);
      expect(chunks.any((c) => c.contains('https://example.com/a')), isTrue);
    });

    test('空文本不产生段', () {
      expect(phraseChunks(''), isEmpty);
    });
  });

  testWidgets('骨架扫光、错峰和加载三点可以共存', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: ShimmerScope(
            child: Column(
              children: [
                StaggerReveal(
                  index: 3,
                  child: SkeletonBox(width: 120, height: 20),
                ),
                SizedBox(height: 10),
                SkeletonBox(width: 180, height: 14),
                SizedBox(height: 20),
                LoadMoreDots(),
                SizedBox(height: 12),
                ThinkingDots(),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.pump(const Duration(milliseconds: 16));
    expect(find.byType(SkeletonBox), findsNWidgets(2));
    expect(find.byType(LoadMoreDots), findsOneWidget);
    expect(find.byType(ThinkingDots), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 900));
    expect(tester.takeException(), isNull);
  });

  testWidgets('流式文本逐段显现、追加和光标不溢出', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Padding(
            padding: EdgeInsets.all(16),
            child: PhraseRevealText(
              text: '你好世界，这是第一段回复。',
              style: TextStyle(fontSize: 14, color: Colors.white),
            ),
          ),
        ),
      ),
    );

    await tester.pump(const Duration(milliseconds: 40));
    expect(find.byType(BlinkingCaret), findsOneWidget);
    expect(tester.takeException(), isNull);

    // 模拟后端 delta 追加：旧段保持已显示，新段继续逐段出现。
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Padding(
            padding: EdgeInsets.all(16),
            child: PhraseRevealText(
              text: '你好世界，这是第一段回复。后面继续追加内容。',
              style: TextStyle(fontSize: 14, color: Colors.white),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 1000));
    expect(tester.takeException(), isNull);

    // 关闭动画时必须立刻完整展示，避免历史消息重播。
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: PhraseRevealText(
            text: '完整展示',
            animate: false,
            style: TextStyle(fontSize: 14),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('完整展示'), findsOneWidget);
  });
}
