import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:community_app/design/tokens.dart';
import 'package:community_app/models/feed_item.dart';
import 'package:community_app/widgets/post_card.dart';

void main() {
  testWidgets('正在流动卡片：点赞图标和数量落在右下角', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final item = FeedItem.fromJson({
      'id': 'p_corner_like',
      'type': 'text',
      'content': '一张用来验收卡片底部排布的文字帖。',
      'likeCount': 64,
      'created': 1763550000,
      'author': {'id': 'u_nanzhi', 'name': '南枝', 'avatar': ''},
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: buildImmersiveTheme(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 174,
              height: 236,
              child: PostGridTile(item: item, onTap: () {}, onAuthorTap: () {}),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final card = tester.getRect(find.byType(PostGridTile));
    final likeIcon = tester.getRect(
      find.descendant(
        of: find.byType(PostGridTile),
        matching: find.byIcon(Icons.favorite_rounded),
      ),
    );
    final likeCount = tester.getRect(
      find.descendant(of: find.byType(PostGridTile), matching: find.text('64')),
    );
    final author = tester.getRect(
      find.descendant(of: find.byType(PostGridTile), matching: find.text('南枝')),
    );

    // 作者仍在左下角。
    expect(author.left, lessThan(card.left + 40));
    expect(author.bottom, greaterThan(card.bottom - 18));

    // 点赞图标和数量贴住卡片的右下角，而不是跟在作者名后面。
    expect(likeIcon.center.dx, greaterThan(card.right - 45));
    expect(likeCount.right, greaterThan(card.right - 10));
    expect(likeCount.right, lessThanOrEqualTo(card.right - 4));
    expect(likeCount.bottom, greaterThan(card.bottom - 12));
    expect(tester.takeException(), isNull);
  });
}
