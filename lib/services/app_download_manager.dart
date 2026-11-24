/// 应用市场 · 应用内断点下载
///
/// 设计约束：
/// - 页面加载只读详情，不解析下载地址；用户点击下载后才请求
///   `/community/api/apps/{id}/download`，服务端 302 到 ticket 网关。
/// - 客户端直接对网关按 Range 写入临时文件，暂停保留 `.part`，恢复时从文件长度续传。
/// - 不把下载任务塞进页面：任务放在单例管理器中，页面只订阅进度，退页不中断。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../api/app_market_api.dart';
import '../api/client.dart';
import 'apk_inspector.dart';
import 'secure_links.dart';
import '../models/app_market.dart';

enum AppDownloadStatus {
  idle,
  resolving,
  downloading,
  paused,
  completed,
  failed,
  /// iOS OTA：安装请求已交给系统，客户端无法再观测真实安装结果。
  installing,
}

@immutable
class AppDownloadTask {
  final String appId;
  final String appName;
  final String versionId;
  final AppDownloadStatus status;
  final int receivedBytes;
  final int totalBytes;
  final int speedBytesPerSecond;
  final String filePath;
  final String fileName;
  final String error;

  const AppDownloadTask({
    required this.appId,
    required this.appName,
    this.versionId = '',
    this.status = AppDownloadStatus.idle,
    this.receivedBytes = 0,
    this.totalBytes = 0,
    this.speedBytesPerSecond = 0,
    this.filePath = '',
    this.fileName = '',
    this.error = '',
  });

  double get progress =>
      totalBytes > 0 ? (receivedBytes / totalBytes).clamp(0.0, 1.0) : 0.0;

  bool get hasKnownTotal => totalBytes > 0;

  String get statusLabel => switch (status) {
    AppDownloadStatus.idle => '点击下载',
    AppDownloadStatus.resolving => '正在解析下载地址…',
    AppDownloadStatus.downloading => '下载中',
    AppDownloadStatus.paused => '已暂停',
    AppDownloadStatus.completed => '下载完成',
    AppDownloadStatus.failed => '下载失败',
    AppDownloadStatus.installing => '已交给系统安装',
  };

  AppDownloadTask copyWith({
    AppDownloadStatus? status,
    int? receivedBytes,
    int? totalBytes,
    int? speedBytesPerSecond,
    String? filePath,
    String? fileName,
    String? error,
  }) => AppDownloadTask(
    appId: appId,
    appName: appName,
    versionId: versionId,
    status: status ?? this.status,
    receivedBytes: receivedBytes ?? this.receivedBytes,
    totalBytes: totalBytes ?? this.totalBytes,
    speedBytesPerSecond: speedBytesPerSecond ?? this.speedBytesPerSecond,
    filePath: filePath ?? this.filePath,
    fileName: fileName ?? this.fileName,
    error: error ?? this.error,
  );
}

/// 一个已经落盘/正在下载的应用记录。页面只在本地读取，不需要后端接口。
@immutable
class AppDownloadRecord {
  final String appId;
  final String appName;
  final String appIcon;
  final String versionName;
  final String versionId;
  final String platform;
  final String packageType;
  final String fileName;
  final String filePath;
  final int receivedBytes;
  final int totalBytes;
  final int updatedAt;
  final AppDownloadStatus status;
  final String error;

  const AppDownloadRecord({
    required this.appId,
    required this.appName,
    this.appIcon = '',
    this.versionName = '',
    this.versionId = '',
    this.platform = '',
    this.packageType = '',
    this.fileName = '',
    this.filePath = '',
    this.receivedBytes = 0,
    this.totalBytes = 0,
    this.updatedAt = 0,
    this.status = AppDownloadStatus.idle,
    this.error = '',
  });

  double get progress =>
      totalBytes > 0 ? (receivedBytes / totalBytes).clamp(0.0, 1.0) : 0.0;

  bool get isActive =>
      status == AppDownloadStatus.downloading ||
      status == AppDownloadStatus.resolving;

  bool get isDone => status == AppDownloadStatus.completed;
}

class _DownloadJob {
  _DownloadJob({required this.epoch});

  final int epoch;
  bool pauseRequested = false;
  bool cancelRequested = false;
  http.Client? client;
  Duration lastTick = Duration.zero;
  int lastBytes = 0;
}

class AppDownloadException implements Exception {
  final String message;
  const AppDownloadException(this.message);
  @override
  String toString() => message;
}

/// 单例下载管理器。一个应用同时只允许一个下载任务；不同应用可并行。
class AppDownloadManager {
  AppDownloadManager._();

  static final AppDownloadManager I = AppDownloadManager._();

  /// 状态门铃：开始/暂停/完成/删除时 +1；下载进度由页面轮询落盘文件读取。
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  void _bump() => revision.value++;

  /// 仅测试使用：替换下载入口生成器，生产默认走 [AppMarketApi.downloadEndpoint]。
  @visibleForTesting
  static Uri Function(String appId) endpointBuilder =
      AppMarketApi.downloadEndpoint;

  final Map<String, ValueNotifier<AppDownloadTask>> _notifiers = {};
  final Map<String, _DownloadJob> _jobs = {};
  final Map<String, int> _epochs = {};

  ValueNotifier<AppDownloadTask> notifierFor(MarketApp app) {
    final id = app.id;
    final existing = _notifiers[id];
    if (existing != null) {
      // 版本变化时清空旧任务，避免把上一版本的文件当成当前版本。
      if (existing.value.versionId != app.versionId &&
          app.versionId.isNotEmpty) {
        final old = existing.value;
        existing.value = AppDownloadTask(
          appId: id,
          appName: app.name,
          versionId: app.versionId,
          status: AppDownloadStatus.idle,
          filePath: old.filePath,
        );
      }
      return existing;
    }
    final n = ValueNotifier<AppDownloadTask>(
      AppDownloadTask(appId: id, appName: app.name, versionId: app.versionId),
    );
    _notifiers[id] = n;
    return n;
  }

  Future<AppDownloadTask> restore(MarketApp app) async {
    final n = notifierFor(app);
    final dir = await _appDir(app.id);
    final part = File('${dir.path}/download.part');
    final meta = File('${dir.path}/download.meta.json');
    final metaData = await _readMeta(meta);
    if (metaData['versionId'] != null &&
        app.versionId.isNotEmpty &&
        metaData['versionId'] != app.versionId) {
      await _deleteIfExists(part);
      await _deleteIfExists(meta);
      n.value = n.value.copyWith(
        status: AppDownloadStatus.idle,
        receivedBytes: 0,
        totalBytes: 0,
        filePath: '',
        fileName: '',
        error: '',
      );
      return n.value;
    }
    final fileName = (metaData['fileName'] ?? '').toString();
    final finalPath = (metaData['finalPath'] ?? '').toString();
    if (finalPath.isNotEmpty) {
      final f = File(finalPath);
      if (await f.exists() && await f.length() > 0) {
        n.value = n.value.copyWith(
          status: AppDownloadStatus.completed,
          receivedBytes: await f.length(),
          totalBytes: await f.length(),
          filePath: finalPath,
          fileName: fileName.isEmpty ? f.uri.pathSegments.last : fileName,
          error: '',
        );
        return n.value;
      }
    }
    if (await part.exists()) {
      final length = await part.length();
      if (length > 0) {
        n.value = n.value.copyWith(
          status: AppDownloadStatus.paused,
          receivedBytes: length,
          totalBytes: ((metaData['totalBytes'] ?? 0) as num).toInt(),
          filePath: finalPath,
          fileName: fileName,
        );
        return n.value;
      }
    }
    if (n.value.status == AppDownloadStatus.completed ||
        n.value.status == AppDownloadStatus.failed ||
        n.value.status == AppDownloadStatus.installing) {
      n.value = n.value.copyWith(
        status: AppDownloadStatus.idle,
        receivedBytes: 0,
        totalBytes: 0,
        speedBytesPerSecond: 0,
        error: '',
      );
    }
    return n.value;
  }

  /// 扫描本地应用下载目录：完成文件、断点临时文件、未完成的元信息都会出现在列表。
  Future<List<AppDownloadRecord>> listRecords() async {
    final docs = await getApplicationDocumentsDirectory();
    final root = Directory('${docs.path}${Platform.pathSeparator}app_market');
    if (!root.existsSync()) return const [];
    final out = <AppDownloadRecord>[];
    // 下载列表只扫描少量元信息；同步读可避免页面在文件系统事件上等待，
    // 也避免后台每 2 秒刷新时产生额外的异步队列。
    for (final entity in root.listSync(followLinks: false)) {
      if (entity is! Directory) continue;
      // Directory.uri usually ends with a trailing slash, so its last
      // pathSegments entry is empty; use the filesystem path instead.
      final appId = _basename(entity.path);
      if (appId.isEmpty) continue;
      final meta = _readMetaSync(File('${entity.path}/download.meta.json'));
      final part = File('${entity.path}/download.part');
      final finalPath = (meta['finalPath'] ?? '').toString();
      final finalFile = finalPath.isEmpty ? null : File(finalPath);
      final hasFinal =
          finalFile != null &&
          finalFile.existsSync() &&
          finalFile.lengthSync() > 0;
      final hasPart = part.existsSync();
      if (!hasFinal && !hasPart && meta.isEmpty) continue;
      final fileName = (meta['fileName'] ?? '').toString();
      final name = (meta['appName'] ?? '').toString().trim();
      final live = _notifiers[appId]?.value;
      final partBytes = hasPart ? part.lengthSync() : 0;
      final finalBytes = hasFinal ? finalFile.lengthSync() : 0;
      AppDownloadStatus status;
      if (hasFinal) {
        status = AppDownloadStatus.completed;
      } else if (hasPart) {
        status = AppDownloadStatus.paused;
      } else {
        status = AppDownloadStatus.idle;
      }
      var received = hasFinal ? finalBytes : partBytes;
      var total = ((meta['totalBytes'] ?? 0) as num).toInt();
      var error = '';
      if (live != null &&
          (live.status == AppDownloadStatus.downloading ||
              live.status == AppDownloadStatus.resolving ||
              live.status == AppDownloadStatus.failed ||
              live.status == AppDownloadStatus.paused ||
              live.status == AppDownloadStatus.completed)) {
        status = live.status;
        received = live.receivedBytes;
        total = live.totalBytes > 0 ? live.totalBytes : total;
        error = live.error;
      }
      final updated = ((meta['updatedAt'] ?? 0) as num).toInt();
      out.add(
        AppDownloadRecord(
          appId: appId,
          appName: name.isEmpty
              ? (fileName.isEmpty ? appId : _stripExt(fileName))
              : name,
          appIcon: (meta['appIcon'] ?? '').toString(),
          versionName: (meta['appVersion'] ?? '').toString(),
          versionId: (meta['versionId'] ?? '').toString(),
          platform: (meta['platform'] ?? '').toString(),
          packageType: (meta['packageType'] ?? '').toString(),
          fileName: fileName.isEmpty
              ? (hasFinal ? _basename(finalPath) : '')
              : fileName,
          filePath: hasFinal ? finalPath : '',
          receivedBytes: received,
          totalBytes: total,
          updatedAt: updated,
          status: status,
          error: error,
        ),
      );
    }
    out.sort((a, b) {
      final byTime = b.updatedAt.compareTo(a.updatedAt);
      if (byTime != 0) return byTime;
      // 同一秒完成的多条记录不能靠目录枚举顺序，否则每 2 秒刷新会跳序。
      final byName = a.appName.compareTo(b.appName);
      return byName != 0 ? byName : a.appId.compareTo(b.appId);
    });
    return out;
  }

  ValueNotifier<AppDownloadTask>? notifierOf(String appId) => _notifiers[appId];

  AppDownloadTask taskOf(AppDownloadRecord r) {
    final current = _notifiers[r.appId]?.value;
    if (current != null) return current;
    return AppDownloadTask(
      appId: r.appId,
      appName: r.appName,
      versionId: r.versionId,
      status: r.status,
      receivedBytes: r.receivedBytes,
      totalBytes: r.totalBytes,
      filePath: r.filePath,
      fileName: r.fileName,
      error: r.error,
    );
  }

  /// 继续/重试：用落盘元信息还原一个最小 MarketApp，不依赖详情页是否打开。
  Future<void> resumeRecord(AppDownloadRecord r) async {
    await start(
      MarketApp(
        id: r.appId,
        name: r.appName,
        icon: r.appIcon,
        platform: r.platform,
        packageType: r.packageType,
        version: r.versionName,
        versionId: r.versionId,
      ),
    );
  }

  Future<String?> openRecord(AppDownloadRecord r) => openFile(taskOf(r));

  Future<void> shareRecord(AppDownloadRecord r) => shareFile(taskOf(r));

  /// 删除整个应用的本地下载目录（完成文件、临时文件、元信息一起清掉）。
  Future<void> deleteRecord(String appId) async {
    final job = _jobs[appId];
    if (job != null) {
      job.cancelRequested = true;
      job.client?.close();
      _jobs.remove(appId);
    }
    _epochs[appId] = (_epochs[appId] ?? 0) + 1;
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory(
        '${docs.path}${Platform.pathSeparator}app_market'
        '${Platform.pathSeparator}$appId',
      );
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
    final old = _notifiers.remove(appId);
    old?.dispose();
    _bump();
  }

  String _stripExt(String name) {
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  /// iOS OTA 已交给系统安装：清掉下载任务的数字，避免界面把旧进度当成安装进度。
  void markInstalling(MarketApp app) {
    final n = notifierFor(app);
    n.value = n.value.copyWith(
      status: AppDownloadStatus.installing,
      receivedBytes: 0,
      totalBytes: 0,
      speedBytesPerSecond: 0,
      error: '',
    );
    _bump();
  }

  String _basename(String path) {
    final normalized = path.replaceAll('\\', '/');
    final i = normalized.lastIndexOf('/');
    return i >= 0 ? normalized.substring(i + 1) : path;
  }

  Future<void> start(MarketApp app) async {
    final n = notifierFor(app);
    final current = n.value;
    if (current.status == AppDownloadStatus.resolving ||
        current.status == AppDownloadStatus.downloading) {
      return;
    }
    if (current.status == AppDownloadStatus.completed) return;

    final epoch = (_epochs[app.id] ?? 0) + 1;
    _epochs[app.id] = epoch;
    final job = _DownloadJob(epoch: epoch);
    _jobs[app.id] = job;
    n.value = n.value.copyWith(
      status: AppDownloadStatus.resolving,
      error: '',
      speedBytesPerSecond: 0,
    );
    _bump();
    try {
      await _run(app, n, job);
    } catch (e) {
      if (!_isCurrent(app.id, job) || job.cancelRequested) return;
      final msg = e is AppDownloadException
          ? e.message
          : e is TimeoutException
          ? '下载超时，请检查网络后继续'
          : '下载失败：$e';
      n.value = n.value.copyWith(
        status: AppDownloadStatus.failed,
        error: msg,
        speedBytesPerSecond: 0,
      );
      _bump();
    } finally {
      job.client?.close();
      if (identical(_jobs[app.id], job)) _jobs.remove(app.id);
    }
  }

  void pause(String appId) {
    final job = _jobs[appId];
    if (job == null) return;
    job.pauseRequested = true;
    final n = _notifiers[appId];
    if (n != null &&
        (n.value.status == AppDownloadStatus.downloading ||
            n.value.status == AppDownloadStatus.resolving)) {
      n.value = n.value.copyWith(
        status: AppDownloadStatus.paused,
        speedBytesPerSecond: 0,
      );
      _bump();
    }
  }

  Future<void> cancel(String appId) async {
    final job = _jobs[appId];
    if (job != null) {
      job.cancelRequested = true;
      job.client?.close();
    }
    _epochs[appId] = (_epochs[appId] ?? 0) + 1;
    _jobs.remove(appId);
    final dir = await _appDir(appId);
    await _deleteIfExists(File('${dir.path}/download.part'));
    await _deleteIfExists(File('${dir.path}/download.meta.json'));
    final n = _notifiers[appId];
    if (n != null) {
      n.value = n.value.copyWith(
        status: AppDownloadStatus.idle,
        receivedBytes: 0,
        totalBytes: 0,
        speedBytesPerSecond: 0,
        filePath: '',
        fileName: '',
        error: '',
      );
    }
  }

  Future<String?> openFile(AppDownloadTask task) async {
    final path = task.filePath;
    if (path.isEmpty || !await File(path).exists()) return '文件不存在，请重新下载';
    try {
      final result = await OpenFilex.open(path);
      return switch (result.type) {
        ResultType.done => null,
        ResultType.fileNotFound => '文件不存在，请重新下载',
        ResultType.noAppToOpen => '没有可打开此文件的应用，请使用“分享文件”',
        ResultType.permissionDenied => '没有文件访问权限，请到系统设置中开启',
        ResultType.error => '打开失败：${result.message}',
      };
    } catch (e) {
      return '打开失败：$e';
    }
  }

  Future<void> shareFile(AppDownloadTask task) async {
    final path = task.filePath;
    if (path.isEmpty) return;
    try {
      await Share.shareXFiles([XFile(path)], text: '${task.appName}（流萤社区应用市场）');
    } catch (_) {
      // 系统分享不可用时静默，文件仍保存在本地。
    }
  }

  Future<void> _run(
    MarketApp app,
    ValueNotifier<AppDownloadTask> n,
    _DownloadJob job,
  ) async {
    final dir = await _appDir(app.id);
    final part = File('${dir.path}/download.part');
    final meta = File('${dir.path}/download.meta.json');
    final metaData = await _readMeta(meta);
    if (metaData['versionId'] != null &&
        app.versionId.isNotEmpty &&
        metaData['versionId'] != app.versionId) {
      await _deleteIfExists(part);
      await _deleteIfExists(meta);
    }
    if (job.cancelRequested) return;
    var offset = await part.exists() ? await part.length() : 0;
    var totalBytes = ((metaData['totalBytes'] ?? 0) as num).toInt();
    n.value = n.value.copyWith(
      status: AppDownloadStatus.resolving,
      receivedBytes: offset,
      totalBytes: totalBytes,
      error: '',
    );

    final client = http.Client();
    job.client = client;
    job.lastTick = Duration.zero;
    job.lastBytes = offset;

    final endpoint = endpointBuilder(app.id);
    var target = await _resolveTarget(client, endpoint);
    if (job.cancelRequested) return;
    if (job.pauseRequested) {
      n.value = n.value.copyWith(status: AppDownloadStatus.paused);
      return;
    }

    n.value = n.value.copyWith(
      status: AppDownloadStatus.downloading,
      receivedBytes: offset,
      totalBytes: totalBytes,
    );

    var restarted = false;
    while (true) {
      if (job.cancelRequested) return;
      if (job.pauseRequested) {
        n.value = n.value.copyWith(
          status: AppDownloadStatus.paused,
          speedBytesPerSecond: 0,
        );
        return;
      }

      final request = http.Request('GET', target);
      // 不自动跟 302：跨域 CDN 不能收到 Bearer，手动每一跳校验后重发。
      request.followRedirects = false;
      request.headers['Accept'] = '*/*';
      request.headers['Accept-Encoding'] = 'identity';
      if (offset > 0) request.headers['Range'] = 'bytes=$offset-';
      _attachAuth(request);
      final resp = await client
          .send(request)
          .timeout(const Duration(seconds: 30));

      if (resp.statusCode >= 300 && resp.statusCode < 400) {
        final location = resp.headers['location'] ?? '';
        await resp.stream.drain();
        if (location.isEmpty) {
          throw const AppDownloadException('下载地址跳转无效');
        }
        target = await _secureDownloadUrl(target.resolve(location));
        continue;
      }
      if (resp.statusCode == 416) {
        // 本地临时文件已经覆盖完整文件，直接收尾；否则说明偏移异常。
        final cr = _parseContentRange(resp.headers['content-range']);
        final remoteTotal = cr?.total ?? totalBytes;
        if (remoteTotal > 0 && offset >= remoteTotal) {
          totalBytes = remoteTotal;
          await _finish(app, n, part, meta, totalBytes, resp.headers);
          return;
        }
        throw AppDownloadException(
          await _errorFromResponse(resp, '下载范围无效，请重新开始下载'),
        );
      }

      if (resp.statusCode == 200 && offset > 0 && !restarted) {
        // 上游不支持 Range：不能把全量追加到已有片段，否则文件损坏。
        await resp.stream.drain();
        await _deleteIfExists(part);
        offset = 0;
        totalBytes = resp.contentLength ?? 0;
        restarted = true;
        n.value = n.value.copyWith(
          status: AppDownloadStatus.downloading,
          receivedBytes: 0,
          totalBytes: totalBytes,
          speedBytesPerSecond: 0,
          error: '源文件不支持断点，已从头开始下载',
        );
        continue;
      }

      if (resp.statusCode != 200 && resp.statusCode != 206) {
        throw AppDownloadException(
          await _errorFromResponse(resp, '下载源暂时不可用（${resp.statusCode}）'),
        );
      }

      final contentRange = _parseContentRange(resp.headers['content-range']);
      if (contentRange?.total != null) {
        totalBytes = contentRange!.total!;
      } else if (resp.statusCode == 200 && resp.contentLength != null) {
        totalBytes = resp.contentLength!;
      } else if (totalBytes == 0 && resp.contentLength != null) {
        totalBytes = offset + resp.contentLength!;
      }
      final fileName = _fileNameFromHeaders(
        resp.headers,
        fallback: '${app.name}.${app.extension}',
      );
      await _writeMeta(meta, app, fileName, totalBytes, '');
      n.value = n.value.copyWith(
        status: AppDownloadStatus.downloading,
        totalBytes: totalBytes,
        fileName: fileName,
      );

      final raf = await part.open(mode: FileMode.append);
      try {
        await for (final chunk in resp.stream.timeout(
          const Duration(seconds: 30),
          onTimeout: (sink) => sink.addError(TimeoutException('下载流中断，请继续下载')),
        )) {
          if (job.cancelRequested) return;
          if (job.pauseRequested) break;
          await raf.writeFrom(chunk);
          offset += chunk.length;
          final tick = DateTime.now().microsecondsSinceEpoch;
          if (job.lastTick == Duration.zero ||
              tick - job.lastTick.inMicroseconds >= 550000) {
            final seconds = job.lastTick == Duration.zero
                ? 0
                : (tick - job.lastTick.inMicroseconds) / 1000000.0;
            final speed = seconds <= 0
                ? 0
                : ((offset - job.lastBytes) / seconds).round();
            job.lastTick = Duration(microseconds: tick);
            job.lastBytes = offset;
            n.value = n.value.copyWith(
              receivedBytes: offset,
              totalBytes: totalBytes,
              speedBytesPerSecond: speed < 0 ? 0 : speed,
            );
          }
        }
      } finally {
        await raf.close();
      }

      if (job.cancelRequested) return;
      if (job.pauseRequested) {
        n.value = n.value.copyWith(
          status: AppDownloadStatus.paused,
          receivedBytes: offset,
          totalBytes: totalBytes,
          speedBytesPerSecond: 0,
        );
        return;
      }

      if (totalBytes > 0 && offset < totalBytes) {
        throw AppDownloadException(
          '下载连接提前结束（已保存 ${_formatBytes(offset)}），可点击继续下载',
        );
      }
      await _finish(app, n, part, meta, totalBytes, resp.headers);
      return;
    }
  }

  Future<Uri> _resolveTarget(http.Client client, Uri endpoint) async {
    // 用 HEAD 只取 302 临时入口，避免每次重试都把 GET 计成一次下载。
    final req = http.Request('HEAD', endpoint);
    req.followRedirects = false;
    _attachAuth(req);
    final resp = await client.send(req).timeout(const Duration(seconds: 20));
    if (resp.statusCode >= 300 && resp.statusCode < 400) {
      final location = resp.headers['location'] ?? '';
      await resp.stream.drain();
      if (location.isEmpty) {
        throw const AppDownloadException('下载入口没有返回有效地址');
      }
      return await _secureDownloadUrl(endpoint.resolve(location));
    }
    if (resp.statusCode == 200) {
      // 极少数部署可能直接把入口反代到文件；此时当前响应就是数据流，
      // 但调用方已关闭响应，不适合继续，明确提示重新点击。
      await resp.stream.drain();
      throw const AppDownloadException('下载入口返回了文件流，请稍后重试');
    }
    if (resp.statusCode == 405 || resp.statusCode == 501) {
      // 部分 nginx / Python 部署没有实现 HEAD，但 GET 的 302 入口是正常的。
      // 用 Range: bytes=0-0 发一次探测 GET，拿到临时地址后立刻丢弃 body，
      // 不依赖 HEAD 也能下载；不要把探测请求当成正式文件下载。
      await resp.stream.drain();
      final probe = http.Request('GET', endpoint)
        ..followRedirects = false
        ..headers['Range'] = 'bytes=0-0';
      _attachAuth(probe);
      final probeResp = await client
          .send(probe)
          .timeout(const Duration(seconds: 20));
      if (probeResp.statusCode >= 300 && probeResp.statusCode < 400) {
        final location = probeResp.headers['location'] ?? '';
        await probeResp.stream.drain();
        if (location.isEmpty) {
          throw const AppDownloadException('下载入口没有返回有效地址');
        }
        return await _secureDownloadUrl(endpoint.resolve(location));
      }
      throw AppDownloadException(
        await _errorFromResponse(probeResp, '无法获取下载地址'),
      );
    }
    throw AppDownloadException(await _errorFromResponse(resp, '无法获取下载地址'));
  }

  Future<void> _finish(
    MarketApp app,
    ValueNotifier<AppDownloadTask> n,
    File part,
    File meta,
    int totalBytes,
    Map<String, String> headers,
  ) async {
    final dir = part.parent;
    final fileName = _fileNameFromHeaders(
      headers,
      fallback: '${app.name}.${app.extension}',
    );
    final finalFile = File('${dir.path}/$fileName');
    if (await finalFile.exists()) await finalFile.delete();
    await part.rename(finalFile.path);
    // Android 安装包在交给系统安装器前先校验：能解析、有签名、包名与投稿一致。
    // 这能拦住“任意文件改后缀 .apk”和包名冒充，系统安装器再负责签名升级校验。
    if (Platform.isAndroid && app.extension == 'apk') {
      try {
        await ApkInspector.verify(
          finalFile.path,
          expectedPackage: app.packageName,
        );
      } catch (e) {
        try {
          await finalFile.delete();
        } catch (_) {}
        throw AppDownloadException('安装包校验失败：$e');
      }
    }
    final size = await finalFile.length();
    await _writeMeta(meta, app, fileName, size, finalFile.path);
    _bump();
    n.value = n.value.copyWith(
      status: AppDownloadStatus.completed,
      receivedBytes: size,
      totalBytes: size,
      speedBytesPerSecond: 0,
      filePath: finalFile.path,
      fileName: fileName,
      error: '',
    );
  }

  Future<String> _errorFromResponse(
    http.StreamedResponse resp,
    String fallback,
  ) async {
    try {
      final body = await resp.stream.bytesToString();
      final json = jsonDecode(body);
      if (json is Map) {
        final msg = (json['error'] ?? json['msg'] ?? '').toString().trim();
        if (msg.isNotEmpty) return msg;
      }
    } catch (_) {
      // 非 JSON 错误体，使用调用方提供的可读兜底。
    }
    return fallback;
  }

  Future<Uri> _secureDownloadUrl(Uri uri) async {
    if (uri.userInfo.isNotEmpty || uri.host.isEmpty) {
      throw const AppDownloadException('下载地址包含非法主机信息，已阻断');
    }
    if (kDebugMode &&
        (uri.host == '127.0.0.1' || uri.host == 'localhost')) {
      return uri;
    }
    if (uri.scheme != 'https') {
      throw const AppDownloadException('下载地址不是 HTTPS，已阻断');
    }
    // 应用市场投稿者可填下载地址，不能让客户端替他访问内网/元数据地址。
    if (!await SecureLinks.isPublicHttpUrl(uri.toString())) {
      throw const AppDownloadException('下载地址不是公网 HTTPS，已阻断');
    }
    return uri;
  }

  void _attachAuth(http.Request req) {
    final token = ApiClient.token;
    if (token == null || token.isEmpty) return;
    final api = Uri.tryParse(ApiClient.baseUrl);
    if (api == null) return;
    // Authorization 只发给社区 API 自己，绝不跟随 302 发给 CDN/第三方。
    if (req.url.scheme == api.scheme &&
        req.url.host == api.host &&
        req.url.port == api.port) {
      req.headers['Authorization'] = 'Bearer $token';
    }
  }

  bool _isCurrent(String appId, _DownloadJob job) =>
      _epochs[appId] == job.epoch && identical(_jobs[appId], job);

  Future<Directory> _appDir(String appId) async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(
      '${docs.path}${Platform.pathSeparator}app_market'
      '${Platform.pathSeparator}$appId',
    );
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Map<String, dynamic> _readMetaSync(File f) {
    try {
      if (!f.existsSync()) return <String, dynamic>{};
      final value = jsonDecode(f.readAsStringSync());
      return value is Map ? Map<String, dynamic>.from(value) : {};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  Future<Map<String, dynamic>> _readMeta(File f) async {
    try {
      if (!await f.exists()) return <String, dynamic>{};
      final value = jsonDecode(await f.readAsString());
      return value is Map ? Map<String, dynamic>.from(value) : {};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  Future<void> _writeMeta(
    File f,
    MarketApp app,
    String fileName,
    int totalBytes,
    String finalPath,
  ) async {
    try {
      await f.writeAsString(
        jsonEncode({
          'versionId': app.versionId,
          'appName': app.name,
          'appIcon': app.icon,
          'appVersion': app.version,
          'platform': app.platform,
          'packageType': app.packageType,
          'fileName': fileName,
          'totalBytes': totalBytes,
          'finalPath': finalPath,
          'updatedAt': DateTime.now().millisecondsSinceEpoch,
        }),
      );
    } catch (_) {}
  }

  Future<void> _deleteIfExists(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  String _fileNameFromHeaders(
    Map<String, String> headers, {
    required String fallback,
  }) {
    final cd = headers['content-disposition'] ?? '';
    if (cd.isEmpty) return fallback;
    final utf8Match = RegExp(
      r"filename\*\s*=\s*UTF-8''([^;]+)",
      caseSensitive: false,
    ).firstMatch(cd);
    if (utf8Match != null) {
      final raw = utf8Match.group(1)!.trim();
      final decoded = Uri.decodeComponent(raw).trim();
      if (decoded.isNotEmpty) return _safeFileName(decoded, fallback);
    }
    final quoted = RegExp(
      r'filename\s*=\s*"([^"]+)"',
      caseSensitive: false,
    ).firstMatch(cd);
    if (quoted != null) {
      return _safeFileName(quoted.group(1)!, fallback);
    }
    final plain = RegExp(
      r'filename\s*=\s*([^;]+)',
      caseSensitive: false,
    ).firstMatch(cd);
    if (plain != null) {
      return _safeFileName(plain.group(1)!, fallback);
    }
    return fallback;
  }

  String _safeFileName(String raw, String fallback) {
    final cleaned = raw
        .replaceAll(RegExp(r'[\\/:*?"<>|\r\n]'), '_')
        .trim()
        .replaceAll(RegExp(r'^\.+'), '');
    if (cleaned.isEmpty || cleaned.length > 180) return fallback;
    return cleaned;
  }

  _ContentRange? _parseContentRange(String? value) {
    if (value == null) return null;
    final m = RegExp(
      r'bytes\s+(\d+)-(\d+)/(\d+|\*)',
      caseSensitive: false,
    ).firstMatch(value);
    if (m == null) return null;
    final total = m.group(3) == '*' ? null : int.tryParse(m.group(3)!);
    return _ContentRange(
      start: int.tryParse(m.group(1)!) ?? 0,
      end: int.tryParse(m.group(2)!) ?? 0,
      total: total,
    );
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }
}

class _ContentRange {
  final int start;
  final int end;
  final int? total;
  const _ContentRange({required this.start, required this.end, this.total});
}
