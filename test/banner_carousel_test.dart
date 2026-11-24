// 首页轮播行为回归：后台真实 Banner 优先、空态卡只兜底、坏链接不落任务中心。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:community_app/api/client.dart';
import 'package:community_app/design/tokens.dart';
import 'package:community_app/widgets/banner_carousel.dart';
import 'package:community_app/widgets/image_box.dart';

Map<String, dynamic> _payload({
  List<Map<String, dynamic>> list = const [],
  Map<String, dynamic>? fallback,
}) => {
  'ok': true,
  'list': list,
  'fallback': fallback ?? {'enabled': false},
};

void _usePayload(Map<String, dynamic> payload) {
  ApiClient.httpClient = MockClient((request) async {
    return http.Response(
      jsonEncode(payload),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  });
}

Future<void> _pumpBanner(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildImmersiveTheme(),
      home: Scaffold(body: BannerCarousel()),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 80));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    ApiClient.httpClient = http.Client();
  });

  testWidgets('有真实 Banner 时不显示空态运营卡，标题可来自后台', (tester) async {
    _usePayload(
      _payload(
        list: [
          {
            'id': 'b1',
            'image': 'https://example.invalid/banner.jpg',
            'title': '后台配置的左下角文字',
            'linkType': 'none',
            'linkId': '',
          },
        ],
      ),
    );
    await _pumpBanner(tester);
    expect(find.text('后台配置的左下角文字'), findsWidgets);
    expect(find.byType(BlurUpImage), findsWidgets);
    expect(find.text('社区活动进行中'), findsNothing);
  });

  testWidgets('没有 Banner 时才显示后台空态卡', (tester) async {
    _usePayload(
      _payload(
        fallback: {
          'enabled': true,
          'title': '后台开启的运营卡',
          'subtitle': '副标题由后台控制',
          'linkType': 'none',
          'linkId': '',
        },
      ),
    );
    await _pumpBanner(tester);
    expect(find.text('后台开启的运营卡'), findsOneWidget);
    expect(find.text('副标题由后台控制'), findsOneWidget);
  });

  testWidgets('坏外链只提示，不默认跳到任务中心', (tester) async {
    _usePayload(
      _payload(
        list: [
          {
            'id': 'b2',
            'image': '',
            'title': '坏链接测试',
            'linkType': 'url',
            'linkId': '305751692',
          },
        ],
      ),
    );
    await _pumpBanner(tester);
    await tester.tap(find.text('坏链接测试').first);
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('这条运营位只允许 HTTPS 安全链接'), findsOneWidget);
  });
}
