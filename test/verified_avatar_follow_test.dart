import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:community_app/config.dart';
import 'package:community_app/design/components.dart';
import 'package:community_app/models/feed_item.dart';
import 'package:community_app/services/follow_bus.dart';
import 'package:community_app/widgets/user_avatar.dart';

void main() {
  test('AI 带时间戳头像文件名解析到 uid 代理', () {
    expect(
      avatarUrl('ai_liuying_comment_avatar_1795056518.png'),
      '$kApiBase/music/avatar/ai_liuying_comment',
    );
    expect(
      avatarUrl('normal_user_avatar.jpg'),
      '$kApiBase/music/avatar/normal_user',
    );
    // 无法识别的相对文件名不能原样交给网络层，有 uid 时走代理兜底。
    expect(avatarUrlFor('weird_name.webp', '42'), '$kApiBase/music/avatar/42');
    expect(
      avatarUrlFor('https://cdn.example.com/a.png', '42'),
      'https://cdn.example.com/a.png',
    );
    expect(avatarUrlFor('', '42'), '$kApiBase/music/avatar/42');
  });

  test('作者 JSON 解析认证、AI 与关注状态', () {
    final author = Author.fromJson({
      'id': 'ai_liuying_comment',
      'name': '流小萤',
      'avatar': 'ai_liuying_comment_avatar_1795056518.png',
      'verified': '1',
      'verifiedLabel': 'AI',
      'following': true,
    });
    expect(author.verified, isTrue);
    expect(author.verifiedLabel, 'AI');
    expect(author.isAi, isTrue);
    expect(author.following, isTrue);
    expect(author.followingKnown, isTrue);
    expect(
      author.avatarUrlResolved,
      '$kApiBase/music/avatar/ai_liuying_comment',
    );
  });

  testWidgets('认证角标整体放大，V 字尺寸不变，压在头像边缘露出一半', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppAvatar(size: 48, name: '流', verified: true),
                VerifiedBadge(),
              ],
            ),
          ),
        ),
      ),
    );
    final badges = tester.widgetList<VerifiedBadge>(find.byType(VerifiedBadge));
    expect(badges.length, 2);
    final avatarBadge = badges.first;
    expect(avatarBadge.size, VerifiedBadge.avatarSizeFor(48));
    expect(avatarBadge.size, greaterThan(11));
    expect(avatarBadge.glyphSize, VerifiedBadge.avatarGlyphSizeFor(48));
    expect(avatarBadge.glyphSize, lessThan(avatarBadge.size));
    expect(badges.last.size, 16);
    expect(badges.last.glyphSize, isNull);

    // 视觉契约：亮绿底、V 笔画保持小尺寸、圆底整体变大；圆心压到头像圆弧上。
    for (final badge in badges) {
      expect(badge.color, const Color(AppColors.verified));
    }
    final avatarRect = tester.getRect(find.byType(AppAvatar).first);
    final badgeRect = tester.getRect(find.byType(VerifiedBadge).first);
    expect(badgeRect.width, greaterThan(11));
    expect(badgeRect.overlaps(avatarRect), isTrue);
    expect(badgeRect.right, greaterThan(avatarRect.right));
    expect(badgeRect.bottom, greaterThan(avatarRect.bottom));
    final dx = badgeRect.center.dx - avatarRect.center.dx;
    final dy = badgeRect.center.dy - avatarRect.center.dy;
    final centerDistance = dx * dx + dy * dy;
    final radiusSquared = 24 * 24;
    // 圆心落在头像半径附近：约一半在头像内、一半在外。
    expect(centerDistance, greaterThan(radiusSquared * .93));
    expect(centerDistance, lessThan(radiusSquared * 1.08));
  });

  testWidgets('认证角标在 24–96 全尺寸头像上都半露且不脱离圆弧', (tester) async {
    const sizes = [24.0, 30.0, 32.0, 40.0, 48.0, 68.0, 94.0, 96.0];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Wrap(
            spacing: 24,
            runSpacing: 24,
            children: [
              for (final s in sizes)
                SizedBox(
                  width: s + 8,
                  height: s + 8,
                  child: Center(
                    child: AppAvatar(size: s, name: '萤', verified: true),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    final avatars = tester.widgetList<AppAvatar>(find.byType(AppAvatar));
    final badges = tester.widgetList<VerifiedBadge>(find.byType(VerifiedBadge));
    expect(avatars.length, sizes.length);
    expect(badges.length, sizes.length);
    for (var i = 0; i < sizes.length; i++) {
      final size = sizes[i];
      final badge = badges.elementAt(i);
      expect(badge.size, VerifiedBadge.avatarSizeFor(size));
      expect(badge.glyphSize, VerifiedBadge.avatarGlyphSizeFor(size));
      expect(badge.size, greaterThan(VerifiedBadge.avatarGlyphSizeFor(size)));
      final a = tester.getRect(find.byType(AppAvatar).at(i));
      final b = tester.getRect(find.byType(VerifiedBadge).at(i));
      expect(b.overlaps(a), isTrue, reason: 'size $size 角标必须压住头像');
      final dx = b.center.dx - a.center.dx;
      final dy = b.center.dy - a.center.dy;
      final d2 = dx * dx + dy * dy;
      final r2 = (size / 2) * (size / 2);
      expect(d2, greaterThan(r2 * .93), reason: 'size $size 角标圆心不能缩进头像');
      expect(d2, lessThan(r2 * 1.08), reason: 'size $size 角标圆心不能飘离圆弧');
    }
  });

  testWidgets('UserAvatar 认证标签与 AI 空头像兜底', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                UserAvatar(
                  url: '',
                  uid: '',
                  name: '流小萤',
                  size: 40,
                  verifiedLabel: 'AI',
                  isAi: true,
                ),
                UserAvatar(
                  url: '',
                  uid: 'u1',
                  name: '普通用户',
                  size: 40,
                  verified: true,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    expect(find.byType(VerifiedBadge), findsNWidgets(2));
    final images = tester.widgetList<Image>(find.byType(Image));
    expect(
      images.any(
        (i) =>
            i.image is AssetImage &&
            (i.image as AssetImage).assetName == 'assets/ai/xiaoying.png',
      ),
      isTrue,
    );
  });

  test('FollowBus 共享关注关系并通知页面', () {
    FollowBus.clear();
    var notifications = 0;
    void listener() => notifications++;
    FollowBus.relations.addListener(listener);
    addTearDown(() {
      FollowBus.relations.removeListener(listener);
      FollowBus.clear();
    });
    FollowBus.setRelation('u1', true);
    expect(FollowBus.relationOf('u1'), isTrue);
    expect(notifications, 1);
    FollowBus.setRelation('u1', true);
    expect(notifications, 1);
    FollowBus.setRelation('u1', false);
    expect(FollowBus.relationOf('u1'), isFalse);
    expect(notifications, 2);
  });
}
