import 'package:community_app/services/hot_update.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:community_app/widgets/hot_maintenance_page.dart';

void main() {
  group('HotConfig 远程配置解析', () {
    test('维护模式、公告、功能开关', () {
      final cfg = HotConfig.fromMap({
        'revision': 12,
        'master': true,
        'platform': 'ios',
        'channel': 'stable',
        'configs': {
          'maintenance': {
            'enabled': true,
            'title': '升级中',
            'message': '十分钟后回来',
            'eta': '预计 22:30',
          },
          'home_announcement': {
            'enabled': true,
            'id': 'ann-1',
            'badge': '公告',
            'title': '新版本',
            'body': '远程配置已上线',
            'actionText': '看看',
            'actionUrl': 'https://example.com',
            'dismissible': true,
          },
          'feature_flags': {'shorts': false, 'apps': true, 'post': false},
        },
      });
      expect(cfg.revision, 12);
      expect(cfg.maintenanceEnabled, isTrue);
      expect(cfg.maintenanceTitle, '升级中');
      expect(cfg.maintenanceEta, '预计 22:30');
      // 维护模式优先于公告，避免两套遮罩同时出现。
      expect(cfg.announcement, isNull);
      expect(cfg.featureEnabled('shorts'), isFalse);
      expect(cfg.featureEnabled('apps'), isTrue);
      expect(cfg.featureEnabled('post'), isFalse);
      // 未配置的开关默认开启，不能让旧配置误伤功能。
      expect(cfg.featureEnabled('unknown'), isTrue);
      // 文字表情混排是“默认关闭”的安全例外。
      expect(cfg.inlineTextEmojiEnabled, isFalse);
    });

    test('文字表情混排只接受远端显式开启', () {
      final off = HotConfig.fromMap({
        'master': true,
        'configs': {
          'feature_flags': {'inline_text_emoji': false},
        },
      });
      expect(off.inlineTextEmojiEnabled, isFalse);

      final on = HotConfig.fromMap({
        'master': true,
        'configs': {
          'feature_flags': {'inline_text_emoji': true},
        },
      });
      expect(on.inlineTextEmojiEnabled, isTrue);

      // 总开关关闭时，远程显式开启也不能生效。
      final masterOff = HotConfig.fromMap({
        'master': false,
        'configs': {
          'feature_flags': {'inline_text_emoji': true},
        },
      });
      expect(masterOff.inlineTextEmojiEnabled, isFalse);
    });

    test('总开关关闭时所有远程能力失效', () {
      final cfg = HotConfig.fromMap({
        'revision': 9,
        'master': false,
        'configs': {
          'maintenance': {'enabled': true},
          'feature_flags': {'shorts': false},
          'home_announcement': {'enabled': true, 'title': 'x'},
        },
      });
      expect(cfg.maintenanceEnabled, isFalse);
      expect(cfg.announcement, isNull);
      expect(cfg.featureEnabled('shorts', fallback: false), isFalse);
      expect(cfg.featureEnabled('shorts', fallback: true), isTrue);
    });

    test('公告关闭、内容为空时不展示', () {
      final off = HotConfig.fromMap({
        'configs': {
          'home_announcement': {'enabled': false, 'title': 'x'},
        },
      });
      expect(off.announcement, isNull);
      final blank = HotConfig.fromMap({
        'configs': {
          'home_announcement': {'enabled': true, 'title': '', 'body': ''},
        },
      });
      expect(blank.announcement, isNull);
    });

    test('自定义 key 原样保留', () {
      final cfg = HotConfig.fromMap({
        'configs': {
          'experiment.home_feed': {'variant': 'b', 'percent': 10},
        },
      });
      expect(cfg.remote('experiment.home_feed'), isA<Map>());
      expect((cfg.remote('experiment.home_feed') as Map)['variant'], 'b');
      expect(cfg.remote('missing', fallback: 7), 7);
    });
  });

  testWidgets('维护页展示后台标题/正文/预计恢复', (tester) async {
    const cfg = HotConfig(
      revision: 1,
      configs: {
        'maintenance': {
          'enabled': true,
          'title': '流萤社区升级中',
          'message': '正在迁移数据，请稍后回来。',
          'eta': '预计 15 分钟',
        },
      },
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: HotMaintenancePage(config: cfg),
      ),
    );
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.text('流萤社区升级中'), findsOneWidget);
    expect(find.text('正在迁移数据，请稍后回来。'), findsOneWidget);
    expect(find.text('预计 15 分钟'), findsOneWidget);
    expect(find.text('检查是否恢复'), findsOneWidget);
  });
}
