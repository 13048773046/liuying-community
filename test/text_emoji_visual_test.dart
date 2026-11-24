import 'dart:io';
import 'dart:typed_data';

import 'package:community_app/design/components.dart';
import 'package:community_app/design/tokens.dart';
import 'package:community_app/features/emoji/text_emoji.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUpAll(() async {
    final font = FontLoader('PreviewCJK')
      ..addFont(
        File('/usr/share/fonts/truetype/droid/DroidSansFallbackFull.ttf')
            .readAsBytes()
            .then((bytes) => ByteData.view(Uint8List.fromList(bytes).buffer)),
      );
    await font.load();
  });

  testWidgets('文字表情全量视觉预览', (tester) async {
    tester.view.physicalSize = const Size(390, 1460);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildImmersiveTheme().copyWith(
          textTheme: buildImmersiveTheme().textTheme.apply(
            fontFamily: 'PreviewCJK',
          ),
        ),
        home: Scaffold(
          backgroundColor: const Color(AppColors.bg),
          body: RepaintBoundary(
            key: const ValueKey('preview'),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '流萤文字表情 · 50 张',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      color: Color(AppColors.textPrimary),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '作为正文 token 内嵌，与文字同高，不是图片消息。',
                    style: AppType.caption.copyWith(
                      color: const Color(AppColors.textSecondary),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final e in kTextEmojis)
                        Container(
                          width: 63,
                          padding: const EdgeInsets.symmetric(vertical: 5),
                          decoration: BoxDecoration(
                            color: const Color(AppColors.card),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Column(
                            children: [
                              SizedBox(
                                width: 38,
                                height: 38,
                                child: Image.asset(e.asset),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                e.code,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 8.5,
                                  color: Color(AppColors.textSecondary),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: const Color(AppColors.card),
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '@小萤',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: Color(AppColors.accent),
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextEmojiText(
                          '今晚一起听歌吗[期待] 我先去占个位置[欢呼跳跃]',
                          style: AppType.body.copyWith(
                            fontSize: 16,
                            height: 1.55,
                            color: const Color(AppColors.textPrimary),
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextEmojiText(
                          '收到！[比心][星星眼] 记得带上你的歌单[听歌陶醉]',
                          style: AppType.bodySm.copyWith(
                            fontSize: 14,
                            height: 1.6,
                            color: const Color(AppColors.textSecondary),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(AppColors.card),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const CircleAvatar(
                          radius: 16,
                          backgroundColor: Color(AppColors.accent),
                          child: Text(
                            '萤',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '小萤  2分钟前',
                                style: AppType.micro.copyWith(
                                  color: const Color(AppColors.textTertiary),
                                ),
                              ),
                              const SizedBox(height: 4),
                              TextEmojiText(
                                '这条评论也支持表情啦[调皮吐舌][庆祝撒花]',
                                style: AppType.bodySm.copyWith(
                                  color: const Color(AppColors.textPrimary),
                                  height: 1.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(() async {
      final context = tester.element(find.byType(Scaffold));
      for (final e in kTextEmojis) {
        await precacheImage(AssetImage(e.asset), context);
      }
    });
    await tester.pumpAndSettle();
    await expectLater(
      find.byKey(const ValueKey('preview')),
      matchesGoldenFile('goldens/text_emoji_preview.png'),
    );
  });
}
