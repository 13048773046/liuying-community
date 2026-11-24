import 'package:flutter_test/flutter_test.dart';

import 'package:community_app/pages/home/af_workbench_page.dart';

void main() {
  group('贴底跟随判定', () {
    test('程序滚动（动画/流式追加）不改变跟随状态', () {
      // 正在动画途中、离底部还很远，但这是程序滚动 -> 保持原状态
      expect(
        afStickAfterScroll(maxExtent: 2000, pixels: 200, userScrolling: false, current: true),
        isTrue,
      );
      expect(
        afStickAfterScroll(maxExtent: 2000, pixels: 2000, userScrolling: false, current: false),
        isFalse,
      );
    });

    test('用户上滑离开底部 -> 不再跟随', () {
      expect(
        afStickAfterScroll(maxExtent: 2000, pixels: 1200, userScrolling: true, current: true),
        isFalse,
      );
    });

    test('用户滑回底部附近 -> 恢复跟随', () {
      expect(
        afStickAfterScroll(maxExtent: 2000, pixels: 1950, userScrolling: true, current: false),
        isTrue,
      );
    });

    test('56px 阈值边界', () {
      expect(
        afStickAfterScroll(maxExtent: 1000, pixels: 944, userScrolling: true, current: false),
        isTrue,
      );
      expect(
        afStickAfterScroll(maxExtent: 1000, pixels: 940, userScrolling: true, current: true),
        isFalse,
      );
    });
  });
}
