import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:community_app/services/app_update.dart';

AppUpdateInfo _info({bool force = false}) => AppUpdateInfo(
  platform: 'android',
  version: '0.9.42',
  build: 113,
  downloadUrl: 'https://example.com/community-0.9.42.apk',
  packageSize: '64.8 MB',
  notes: '1. 新增版本更新\n2. 修复若干问题',
  publishedAtText: '2026-11-22 03:00',
  force: force,
  hasUpdate: true,
);

void main() {
  test('parses update response including latest metadata', () {
    final info = AppUpdateInfo.fromJson({
      'ok': true,
      'platform': 'ios',
      'hasUpdate': true,
      'force': true,
      'downloadUrl': 'https://example.com/app.ipa',
      'latest': {
        'version': '0.9.42',
        'build': 113,
        'packageSize': '50 MB',
        'notes': 'test',
        'publishedAtText': '2026-11-22',
      },
    });
    expect(info.hasUpdate, isTrue);
    expect(info.force, isTrue);
    expect(info.versionLabel, 'v0.9.42 · build 113');
    expect(info.downloadUrl, 'https://example.com/app.ipa');
    expect(info.packageSize, '50 MB');
  });

  testWidgets('optional update sheet shows notes, download and later action', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => AppUpdateService.showUpdateSheet(context, _info()),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('发现新版本'), findsOneWidget);
    expect(find.textContaining('新增版本更新'), findsOneWidget);
    expect(find.text('立即更新'), findsOneWidget);
    expect(find.text('复制下载链接'), findsOneWidget);
    expect(find.text('稍后再说'), findsOneWidget);
  });

  testWidgets('force update has no close/later escape', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  AppUpdateService.showUpdateSheet(context, _info(force: true)),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('需要更新'), findsOneWidget);
    expect(find.text('稍后再说'), findsNothing);
    expect(find.byIcon(Icons.close_rounded), findsNothing);
    expect(find.text('下载并更新'), findsOneWidget);
    expect(find.text('复制下载链接'), findsOneWidget);
  });
}
