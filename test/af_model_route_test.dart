import 'package:flutter_test/flutter_test.dart';

import 'package:community_app/pages/home/af_providers.dart';

void main() {
  test('带图的强力模型自动切到视觉模型', () {
    expect(afModelForTurn('deepseek-v4-pro', hasImage: true), 'deepseek-flash');
  });

  test('不带图仍然保留强力模型', () {
    expect(
      afModelForTurn('deepseek-v4-pro', hasImage: false),
      'deepseek-v4-pro',
    );
  });

  test('快速模型和自建模型不被改写', () {
    expect(afModelForTurn('deepseek-flash', hasImage: true), 'deepseek-flash');
    expect(
      afModelForTurn('p:provider:vision-model', hasImage: true),
      'p:provider:vision-model',
    );
  });

  test('只有带图的强力会显示切换说明', () {
    expect(
      afVisionRouteNote('deepseek-v4-pro', hasImage: true),
      contains('快速'),
    );
    expect(afVisionRouteNote('deepseek-v4-pro', hasImage: false), isEmpty);
    expect(afVisionRouteNote('deepseek-flash', hasImage: true), isEmpty);
  });
}
