/// 应用内断点下载的服务层测试。
///
/// 本地 HTTP 服务模拟服务端 302 + 支持 Range 的网关，验证：
/// 1. 暂停后保留 .part；2. 继续时携带 Range；3. 206 拼接后文件内容完整。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:community_app/api/app_market_api.dart';
import 'package:community_app/models/app_market.dart';
import 'package:community_app/services/app_download_manager.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _totalBytes = 2 * 1024 * 1024;
final _expected = List<int>.generate(_totalBytes, (i) => (i * 31 + 7) % 251);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late HttpServer server;
  late Directory temp;
  var rangeRequests = 0;

  setUpAll(() async {
    temp = await Directory.systemTemp.createTemp('liuying_download_test_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => temp.path,
        );
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 8798);
    server.listen((req) async {
      final res = req.response;
      res.persistentConnection = false;
      if (req.uri.path == '/start/app_test') {
        res.statusCode = 302;
        res.headers.set('location', 'http://127.0.0.1:8798/file/app_test');
        await res.close();
        return;
      }
      if (req.uri.path == '/head501/app_head501') {
        if (req.method == 'HEAD') {
          res.statusCode = 501;
          await res.close();
          return;
        }
        res.statusCode = 302;
        res.headers.set('location', 'http://127.0.0.1:8798/file/app_head501');
        await res.close();
        return;
      }
      if (req.uri.path == '/file/app_head501') {
        final range = req.headers.value(HttpHeaders.rangeHeader);
        var start = 0;
        if (range != null && range.startsWith('bytes=')) {
          start = int.tryParse(range.substring(6).split('-').first) ?? 0;
        }
        final chunk = _expected.sublist(start);
        res.statusCode = range == null ? 200 : 206;
        if (range != null) {
          res.headers.set(
            'content-range',
            'bytes $start-${_totalBytes - 1}/$_totalBytes',
          );
        }
        res.headers.contentType = ContentType.binary;
        res.headers.set('accept-ranges', 'bytes');
        res.headers.set(
          'content-disposition',
          'attachment; filename="head501.apk"',
        );
        res.contentLength = chunk.length;
        res.add(chunk);
        await res.close();
        return;
      }
      if (req.uri.path == '/file/app_test') {
        final range = req.headers.value(HttpHeaders.rangeHeader);
        var start = 0;
        var end = _totalBytes - 1;
        if (range != null && range.startsWith('bytes=')) {
          rangeRequests++;
          final spec = range.substring(6).split('-').first;
          start = int.tryParse(spec) ?? 0;
          if (start < 0 || start >= _totalBytes) {
            res.statusCode = 416;
            res.headers.set('content-range', 'bytes */$_totalBytes');
            await res.close();
            return;
          }
        }
        final chunk = _expected.sublist(start, end + 1);
        if (range != null) {
          res.statusCode = 206;
          res.headers.set('content-range', 'bytes $start-$end/$_totalBytes');
        } else {
          res.statusCode = 200;
        }
        res.headers.contentType = ContentType.binary;
        res.headers.set('accept-ranges', 'bytes');
        res.headers.set(
          'content-disposition',
          'attachment; filename="liuying-test.apk"',
        );
        res.contentLength = chunk.length;
        for (var i = 0; i < chunk.length; i += 65536) {
          final slice = chunk.sublist(i, (i + 65536).clamp(0, chunk.length));
          res.add(slice);
          await res.flush();
          await Future<void>.delayed(const Duration(milliseconds: 45));
        }
        await res.close();
        return;
      }
      res.statusCode = 404;
      res.write(jsonEncode({'ok': false, 'error': 'not found'}));
      await res.close();
    });
  });

  tearDownAll(() async {
    await server.close(force: true);
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('暂停后用 Range 续传并得到完整文件', () async {
    final app = const MarketApp(
      id: 'app_test',
      name: '断点测试应用',
      packageType: 'apk',
      versionId: 'ver_1',
    );
    AppDownloadManager.endpointBuilder = (id) =>
        Uri.parse('http://127.0.0.1:8798/start/$id');

    final notifier = AppDownloadManager.I.notifierFor(app);
    final done = Completer<void>();
    var pausedFirst = false;
    notifier.addListener(() {
      if (notifier.value.status == AppDownloadStatus.downloading &&
          !pausedFirst) {
        pausedFirst = true;
        // 首包已开始，等一小会儿再暂停，确保已写入部分 .part。
        Future<void>.delayed(const Duration(milliseconds: 160), () {
          AppDownloadManager.I.pause(app.id);
        });
      }
      if (notifier.value.status == AppDownloadStatus.completed &&
          !done.isCompleted) {
        done.complete();
      }
    });

    final first = AppDownloadManager.I.start(app);
    await first.timeout(const Duration(seconds: 8));
    expect(notifier.value.status, AppDownloadStatus.paused);
    expect(notifier.value.receivedBytes, greaterThan(0));
    expect(notifier.value.receivedBytes, lessThan(_totalBytes));

    final second = AppDownloadManager.I.start(app);
    await done.future.timeout(const Duration(seconds: 8));
    await second.timeout(const Duration(seconds: 8));
    expect(notifier.value.status, AppDownloadStatus.completed);
    expect(rangeRequests, greaterThanOrEqualTo(1));

    final path = notifier.value.filePath;
    expect(path.endsWith('liuying-test.apk'), isTrue);
    final bytes = await File(path).readAsBytes();
    expect(bytes.length, _totalBytes);
    expect(
      const ListEquality<int>().equals(bytes, _expected),
      isTrue,
      reason: '断点续传后的文件必须与源文件逐字节一致',
    );

    await AppDownloadManager.I.cancel(app.id);
    AppDownloadManager.endpointBuilder = AppMarketApi.downloadEndpoint;
  });

  test('本地下载记录能被列表读取，包含应用信息与文件大小', () async {
    final root = Directory('${temp.path}/app_market/app_list_test');
    await root.create(recursive: true);
    final file = File('${root.path}/demo.apk');
    final bytes = List<int>.generate(1024, (i) => i % 251);
    await file.writeAsBytes(bytes);
    await File('${root.path}/download.meta.json').writeAsString(
      jsonEncode({
        'versionId': 'ver_list',
        'appName': '列表测试应用',
        'appIcon': 'community_img_demo.jpg',
        'appVersion': '1.2.0',
        'platform': 'android',
        'packageType': 'apk',
        'fileName': 'demo.apk',
        'totalBytes': bytes.length,
        'finalPath': file.path,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      }),
    );
    final records = await AppDownloadManager.I.listRecords();
    final record = records.firstWhere((e) => e.appId == 'app_list_test');
    expect(record.appName, '列表测试应用');
    expect(record.status, AppDownloadStatus.completed);
    expect(record.receivedBytes, bytes.length);
    expect(record.filePath, file.path);
    await AppDownloadManager.I.deleteRecord('app_list_test');
  });

  test('同一时间戳的下载记录按名称稳定排序', () async {
    final names = ['丙应用', '甲应用', '乙应用'];
    for (var i = 0; i < names.length; i++) {
      final dir = Directory('${temp.path}/app_market/tie_$i');
      await dir.create(recursive: true);
      final file = File('${dir.path}/tie.apk');
      await file.writeAsBytes([i]);
      await File('${dir.path}/download.meta.json').writeAsString(
        jsonEncode({
          'versionId': 'ver_tie_$i',
          'appName': names[i],
          'appVersion': '1.0',
          'platform': 'android',
          'packageType': 'apk',
          'fileName': 'tie.apk',
          'totalBytes': 1,
          'finalPath': file.path,
          'updatedAt': 1700000000000,
        }),
      );
    }
    final records = await AppDownloadManager.I.listRecords();
    final tied = records
        .where((e) => e.appId.startsWith('tie_'))
        .map((e) => e.appName)
        .toList();
    expect(tied, ['丙应用', '乙应用', '甲应用']);
    for (var i = 0; i < names.length; i++) {
      await AppDownloadManager.I.deleteRecord('tie_$i');
    }
  });

  test('HEAD 501 时自动用 GET Range 探测并完成下载', () async {
    final app = const MarketApp(
      id: 'app_head501',
      name: 'HEAD 兼容测试',
      packageType: 'apk',
      versionId: 'ver_head501',
    );
    AppDownloadManager.endpointBuilder = (id) =>
        Uri.parse('http://127.0.0.1:8798/head501/$id');
    final notifier = AppDownloadManager.I.notifierFor(app);
    final done = Completer<void>();
    notifier.addListener(() {
      if (notifier.value.status == AppDownloadStatus.completed &&
          !done.isCompleted) {
        done.complete();
      }
      if (notifier.value.status == AppDownloadStatus.failed &&
          !done.isCompleted) {
        done.completeError(notifier.value.error);
      }
    });
    await AppDownloadManager.I.start(app).timeout(const Duration(seconds: 8));
    await done.future.timeout(const Duration(seconds: 8));
    expect(notifier.value.status, AppDownloadStatus.completed);
    final bytes = await File(notifier.value.filePath).readAsBytes();
    expect(bytes.length, _totalBytes);
    expect(const ListEquality<int>().equals(bytes, _expected), isTrue);
    await AppDownloadManager.I.cancel(app.id);
    AppDownloadManager.endpointBuilder = AppMarketApi.downloadEndpoint;
  });
}

/// 避免额外依赖 collection：测试里只需要最简单的逐字节比较。
class ListEquality<T> {
  const ListEquality();

  bool equals(List<T> a, List<T> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
