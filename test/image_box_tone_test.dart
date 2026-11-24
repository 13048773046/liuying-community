import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:community_app/design/components.dart';
import 'package:community_app/widgets/image_box.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _OneFrameProvider extends ImageProvider<_OneFrameProvider> {
  _OneFrameProvider(this.image);
  final ui.Image image;

  @override
  Future<_OneFrameProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<_OneFrameProvider>(this);

  @override
  ImageStreamCompleter loadImage(
    _OneFrameProvider key,
    ImageDecoderCallback decode,
  ) => OneFrameImageStreamCompleter(SynchronousFuture(ImageInfo(image: image)));
}

Future<ui.Image> _decode(Uint8List bytes) {
  final c = Completer<ui.Image>();
  ui.decodeImageFromList(bytes, c.complete);
  return c.future;
}

void main() {
  testWidgets('首图解码后回报主色且只回报一次', (tester) async {
    final bytes = (await tester.runAsync(
      () => File('test/fixtures/tone_red.png').readAsBytes(),
    ))!;
    final image = (await tester.runAsync(() => _decode(bytes)))!;
    Color? tone;
    var count = 0;
    var failed = false;

    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildImmersiveTheme(),
          home: Scaffold(
            backgroundColor: const Color(AppColors.bg),
            body: Center(
              child: BlurUpImage(
                url: '',
                imageProvider: _OneFrameProvider(image),
                width: 80,
                height: 80,
                onToneExtracted: (value) {
                  tone = value;
                  count++;
                },
                onToneFailed: () => failed = true,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tester.pump();
    });
    await tester.pump();

    expect(failed, isFalse);
    expect(count, 1);
    expect(tone, isNotNull);
    expect((tone!.r * 255).round(), closeTo(192, 2));
    expect((tone!.g * 255).round(), closeTo(57, 2));
    expect((tone!.b * 255).round(), closeTo(43, 2));
  });

  testWidgets('空 URL 回报取色失败', (tester) async {
    var failed = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildImmersiveTheme(),
        home: BlurUpImage(
          url: '',
          width: 80,
          height: 80,
          onToneFailed: () => failed = true,
        ),
      ),
    );
    await tester.pump();
    expect(failed, isTrue);
  });
}
