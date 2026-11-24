import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:community_app/pages/home/af_workbench_page.dart';

const _png1x1 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9ZQmcAAAAASUVORK5CYII=';

Uint8List _png() => base64Decode(_png1x1);

void main() {
  test('工坊：图片附件扩展名统一小写', () {
    expect(afImageName('测试图片.PNG', _png()), '测试图片.png');
    expect(afImageName('IMG_0001.JPEG', _png()), 'IMG_0001.jpeg');
    expect(afImageName('封面.WebP', _png()), '封面.webp');
    expect(afImageName('测试图片.png', _png()), '测试图片.png');
  });

  test('工坊：无扩展名 JPEG 自动补 .jpg', () {
    final jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0]);
    expect(afImageName('相机照片', jpeg), '相机照片.jpg');
  });
}
