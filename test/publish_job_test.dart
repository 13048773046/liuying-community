/// 发布任务的合同测试：文本发布完成、失败状态与请求体。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:community_app/api/client.dart';
import 'package:community_app/services/publish_job.dart';

http.Response _json(int code, Map<String, dynamic> body) => http.Response(
  jsonEncode(body),
  code,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

PublishPreview _preview() =>
    const PublishPreview(kind: PublishKind.text, content: '今天的光');

PublishPayload _payload() => PublishPayload(
  kind: PublishKind.text,
  content: '今天的光',
  images: const [],
  video: null,
  coverFile: null,
  coverFromFrame: true,
  coverTime: null,
  boardId: 'b_life',
  poll: null,
  music: null,
  topics: const [],
  audioVolume: 100,
  musicVolume: 50,
  preview: _preview(),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('文本发布：请求体正确、进度到 100、状态为已发布', () async {
    SharedPreferences.setMockInitialValues({});
    final calls = <http.Request>[];
    ApiClient.httpClient = MockClient((req) async {
      calls.add(req);
      return _json(200, {'ok': true});
    });
    addTearDown(() => ApiClient.httpClient = http.Client());

    final job = PublishJob.start(_payload());
    final ok = await job.done.timeout(const Duration(seconds: 5));

    expect(ok, isTrue);
    expect(job.progress.value, 1);
    expect(job.stage.value, '已发布');
    expect(job.error.value, isNull);
    expect(calls, hasLength(1));
    expect(calls.single.url.path, endsWith('/post'));
    final body = jsonDecode(calls.single.body) as Map<String, dynamic>;
    expect(body['content'], '今天的光');
    expect(body['boardId'], 'b_life');
    expect(body['images'], isEmpty);
    expect(body['audioVolume'], 100);
    expect(body['musicVolume'], 50);
  });

  test('文本发布失败：保留错误，不伪装成功', () async {
    SharedPreferences.setMockInitialValues({});
    ApiClient.httpClient = MockClient(
      (_) async => _json(500, {'ok': false, 'error': '审核队列繁忙'}),
    );
    addTearDown(() => ApiClient.httpClient = http.Client());

    final job = PublishJob.start(_payload());
    final ok = await job.done.timeout(const Duration(seconds: 5));

    expect(ok, isFalse);
    expect(job.progress.value, lessThan(1));
    expect(job.error.value, contains('审核队列繁忙'));
    expect(job.stage.value, '发布未完成');
    expect(job.preview.content, '今天的光');
  });

  test('待审发布：状态明确为审核中且仅自己可见', () async {
    SharedPreferences.setMockInitialValues({});
    ApiClient.httpClient = MockClient(
      (_) async => _json(200, {
        'ok': true,
        'post': {'id': 'p1', 'auditStatus': 0},
      }),
    );
    addTearDown(() => ApiClient.httpClient = http.Client());

    final job = PublishJob.start(_payload());
    final ok = await job.done.timeout(const Duration(seconds: 5));

    expect(ok, isTrue);
    expect(job.auditPending, isTrue);
    expect(job.stage.value, '审核中 · 仅自己可见');
  });
}
