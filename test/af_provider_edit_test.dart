import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:community_app/pages/home/af_providers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget host() => MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showAfAddProviderSheet(
                  ctx,
                  edit: const AfProvider(
                    id: 'p1',
                    name: '我的 Gemini',
                    base: 'https://generativelanguage.googleapis.com/v1beta/openai',
                    keyHint: 'sk-4****cf53',
                    models: [
                      AfProviderModel(id: 'm1', model: 'gemini-2.5-pro', enabled: true),
                      AfProviderModel(id: 'm2', model: 'gemini-2.5-flash', enabled: true),
                    ],
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );

  testWidgets('编辑 API 复用添加弹窗：预填信息、保留获取模型与删除', (tester) async {
    await tester.pumpWidget(host());
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 同一个弹窗，标题切到「编辑 API」
    expect(find.text('编辑 API'), findsOneWidget);
    expect(find.text('添加 API'), findsNothing);

    // 已有信息预填
    expect(find.text('我的 Gemini'), findsOneWidget);
    expect(find.text('https://generativelanguage.googleapis.com/v1beta/openai'), findsOneWidget);
    expect(find.text('已保存 sk-4****cf53 · 留空不改'), findsOneWidget);

    // 获取可用模型的能力保留（已有模型时显示「重新获取」）
    expect(find.text('重新获取'), findsOneWidget);
    expect(find.textContaining('拉到 2 个模型'), findsOneWidget);

    // 编辑态多出删除、保存
    expect(find.text('删除'), findsOneWidget);
    expect(find.text('保存'), findsOneWidget);
  });

  testWidgets('编辑弹窗可以只改名字（Key 留空不改）', (tester) async {
    await tester.pumpWidget(host());
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 名称输入框可编辑
    final nameField = find.byType(TextField).first;
    await tester.enterText(nameField, '我的新名字');
    await tester.pump();
    expect(find.text('我的新名字'), findsOneWidget);

    // 保存按钮可点（有选中模型）
    final save = find.widgetWithText(ElevatedButton, '保存');
    expect(tester.widget<ElevatedButton>(save).onPressed, isNotNull);
  });
}
