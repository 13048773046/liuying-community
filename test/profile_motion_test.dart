// 用户主页「夜航档案」重构回归：完整身份字段、两列作品、应用投稿、390/320 适配。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:community_app/api/client.dart';
import 'package:community_app/design/components.dart';
import 'package:community_app/pages/user/user_profile.dart';
import 'package:community_app/pages/user/user_profile_chrome.dart';

http.Response _ok(Map<String, dynamic> body) => http.Response(
  jsonEncode({'ok': true, ...body}),
  200,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

Map<String, dynamic> _post(int i) => {
  'id': 'p$i',
  'type': i == 2 ? 'video' : 'text',
  'content': '夜里第 $i 条动态：把风声收进照片墙，也把还没说完的话留给下一次更新。',
  'likeCount': 20 + i,
  'commentCount': 3 + i,
  'shareCount': 1,
  'duration': i == 2 ? 74 : 0,
  'created': 1763550000,
  'author': {'id': 'u1', 'name': '山栀', 'avatar': '', 'level': 6},
};

Map<String, dynamic> _profilePayload() {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  return {
    'user': {
      'id': 'u1',
      'name': '山栀',
      'avatar': '',
      'background': '',
      'signature': '在花甸收集夜里的风。把沿途的光、旧应用和没说完的话，都放进这份档案。',
      'level': 6,
      'exp': 1200,
      'followers': 1024,
      'followings': 39,
      'following': false,
      'gender': '女',
      'age': 24,
      'city': '杭州',
      'created': now - 201 * 86400,
      'verified': true,
      'verifiedLabel': '社区认证',
      'title': '夜航记录者',
      'adminLevel': 1,
      'adminName': '内容管理员',
      'cMember': 'svip',
      'cMemberExpire': now + 30 * 86400,
      'frameId': '',
      'email': 'private@example.com',
    },
  };
}

Map<String, dynamic> _appsPayload() => {
  'list': [
    {
      'id': 'a1',
      'name': '星轨',
      'icon': '',
      'platform': 'android',
      'packageType': 'apk',
      'packageName': 'com.example.starrail',
      'version': '1.2.0',
      'category': '工具',
      'subCategory': '效率',
      'description': '把每天散落的灵感收进一条可以回看的星轨。',
      'downloadCount': 1200,
      'rating': 4.8,
      'ratingCount': 16,
      'featured': true,
      'publishedAt': 1763550000,
      'downloadUrl': '/community/api/apps/a1/download',
      'author': {'id': 'u1', 'name': '山栀', 'avatar': '', 'level': 6},
    },
  ],
  'page': 1,
  'pageSize': 12,
  'total': 1,
};

Widget _buildApp() {
  final base = buildImmersiveTheme();
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: base.copyWith(
      textTheme: base.textTheme.apply(fontFamily: 'NotoSansSC'),
    ),
    builder: (context, child) => DefaultTextStyle(
      style: const TextStyle(fontFamily: 'NotoSansSC', color: Colors.white),
      child: child!,
    ),
    home: const UserProfilePage(uid: 'u1'),
  );
}

void main() {
  setUpAll(() async {
    final cjk = FontLoader('NotoSansSC')
      ..addFont(rootBundle.load('assets/fonts/NotoSansSC-Regular.otf'));
    await cjk.load();
    final icons = FontLoader('MaterialIcons');
    final iconBytes = await File(
      '/home/user/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    ).readAsBytes();
    icons.addFont(Future.value(ByteData.view(iconBytes.buffer)));
    await icons.load();
  });

  setUp(() {
    ApiClient.token = 'tok';
    ApiClient.httpClient = MockClient((req) async {
      if (req.url.path.endsWith('/user/u1/profile')) {
        return _ok(_profilePayload());
      }
      if (req.url.path.endsWith('/user/u1/posts')) {
        return req.url.queryParameters['type'] == 'video'
            ? _ok({
                'list': [_post(2)],
                'page': 1,
                'hasMore': false,
              })
            : _ok({
                'list': List.generate(9, _post),
                'page': 1,
                'hasMore': false,
              });
      }
      if (req.url.path.endsWith('/apps/by-user/u1')) {
        return _ok(_appsPayload());
      }
      return _ok({'list': []});
    });
  });

  tearDown(() => ApiClient.httpClient = http.Client());

  testWidgets('390 宽：完整身份档案、作品墙、应用投稿与触底不溢出', (tester) async {
    tester.view.physicalSize = const Size(390 * 2, 844 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_buildApp());
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('山栀'), findsWidgets);
    expect(find.text('夜航记录者'), findsOneWidget);
    expect(find.text('内容管理员'), findsOneWidget);
    expect(find.textContaining('SVIP'), findsWidgets);
    expect(find.textContaining('加入 201 天'), findsOneWidget);
    expect(find.text('Lv.6'), findsOneWidget);
    expect(find.byType(ProfileWorkCard), findsWidgets);
    // 认证只在头像右下角出现一枚亮绿 V；昵称旁、身份区不再挂认证文字/勾。
    expect(find.byType(VerifiedBadge), findsOneWidget);
    expect(find.text('社区认证'), findsNothing);
    final badge = tester.widget<VerifiedBadge>(find.byType(VerifiedBadge));
    expect(badge.color, const Color(AppColors.verified));
    final avatarRect = tester.getRect(find.byType(AppAvatar).first);
    final badgeRect = tester.getRect(find.byType(VerifiedBadge));
    // 0.9.37：角标整体放大，圆心压到头像圆弧上，半枚露在头像外。
    expect(badgeRect.width, VerifiedBadge.avatarSizeFor(94));
    expect(badgeRect.overlaps(avatarRect), isTrue);
    final dx = badgeRect.center.dx - avatarRect.center.dx;
    final dy = badgeRect.center.dy - avatarRect.center.dy;
    final d2 = dx * dx + dy * dy;
    final r2 = 47 * 47;
    expect(d2, greaterThan(r2 * .93));
    expect(d2, lessThan(r2 * 1.08));
    expect(tester.takeException(), isNull);

    await expectLater(
      find.byType(UserProfilePage),
      matchesGoldenFile('goldens/profile_motion_390.png'),
    );

    // 应用投稿是独立档案段，不把作者角标/投稿状态再露一遍。
    await tester.tap(find.text('应用'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(ProfileAppCard), findsOneWidget);
    expect(find.text('星轨'), findsOneWidget);
    expect(find.text('1 款已上架'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('帖子'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.scrollUntilVisible(
      find.text('— 档案到底了 —'),
      520,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.takeException(), isNull);
    expect(find.text('— 档案到底了 —'), findsOneWidget);
  });

  testWidgets('320 宽：长签名与四枚身份标签不溢出', (tester) async {
    tester.view.physicalSize = const Size(320 * 2, 700 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_buildApp());
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('山栀'), findsWidgets);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(UserProfilePage),
      matchesGoldenFile('goldens/profile_motion_320.png'),
    );

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -460));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(ProfileWorkCard), findsWidgets);
    expect(tester.takeException(), isNull);
  });
  testWidgets('顶栏：透明态不挂滤镜，滚过阈值后平滑起雾', (tester) async {
    tester.view.physicalSize = const Size(390 * 2, 844 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_buildApp());
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    // 顶部透明态：不创建 BackdropFilter，避免列表滚动白付合成成本。
    expect(find.byType(BackdropFilter), findsNothing);
    final titleOpacity = tester.widget<Opacity>(
      find.byKey(const ValueKey('profile-topbar-title-opacity')),
    );
    expect(titleOpacity.opacity, 0);

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -240));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    // 滚过阈值：毛玻璃与标题都到位，且过程由 Tween 连续推进，不硬切。
    expect(find.byType(BackdropFilter), findsOneWidget);
    final solidTitle = tester.widget<Opacity>(
      find.byKey(const ValueKey('profile-topbar-title-opacity')),
    );
    expect(solidTitle.opacity, 1);
    expect(find.text('个人主页'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await expectLater(
      find.byType(UserProfilePage),
      matchesGoldenFile('goldens/profile_topbar_390.png'),
    );
  });
}
