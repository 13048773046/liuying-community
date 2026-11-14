/// 流萤航线（Petalwake）：把现成的 WebGL2 网页游戏按需搬到手机上。
///
/// 流程：首次进入 → 分段下载资源包（支持断点续传）→ 解压安装（带进度）→
/// 起一个只监听 127.0.0.1 的本地 HTTP 服务 → WebView 打开 `index.html`。
/// 之后每次进入都直接读本地文件，并在服务端版本号变化时按差异更新资源包。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:archive/archive_io.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../design/tokens.dart';

/// 站点根（nginx 上已配好限速，不抢占社区接口带宽）
const String kFlightSite = 'https://www.dbmt999.asia/petalwake';

/// 资源包与版本清单
const String kFlightZipUrl = '$kFlightSite/petalwake.zip';
const String kFlightVersionUrl = '$kFlightSite/version.json';

/// 增量清单：逐文件 path/size/sha256，更新时只下载有变化的文件
const String kFlightManifestUrl = '$kFlightSite/manifest.json';

/// 资源包按 100MB 量级估算，用于文案提示（真实大小以 version.json 为准）
const int kFlightApproxBytes = 105 * 1024 * 1024;

/// 分段下载的段数：服务器限速是按连接计的，几段并行能把 105MB 压到一两分钟。
const int kSegments = 4;

enum FlightStatus { checking, absent, downloading, installing, ready, failed }

class PetalwakePage extends StatefulWidget {
  const PetalwakePage({super.key});

  @override
  State<PetalwakePage> createState() => _PetalwakePageState();
}

class _PetalwakePageState extends State<PetalwakePage> {
  FlightStatus _status = FlightStatus.checking;
  String _remoteVersion = '';
  int _remoteSize = kFlightApproxBytes;

  /// 下载进度 0..1
  double _progress = 0;

  /// 安装（解压）进度 0..1
  double _install = 0;
  double _speed = 0; // bytes/s
  String _message = '';

  Directory? _siteDir;
  _LocalSiteServer? _server;
  WebViewController? _web;

  /// 页面加载完但游戏还没进入主循环时，显示覆盖层，避免“白屏什么都不显示”
  bool _webReady = false;
  bool _starting = false;
  String? _webError;
  String _diag = '';
  String _softTip = '';
  bool _autoRetried = false;
  bool _pixBlack = false;
  String _gameUrlBase = '';
  int _waitSec = 0;

  /// 正在按服务端版本号更新资源包
  bool _updating = false;
  String _pendingVersion = '';
  Timer? _enterTimer;
  Timer? _retryTimer;
  Timer? _tipTimer;

  @override
  void initState() {
    super.initState();
    // 下载 / 安装阶段保持竖屏（与社区其他页面一致），横屏留给真正进游戏那一刻
    SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _bootstrap();
  }

  @override
  void dispose() {
    _enterTimer?.cancel();
    _retryTimer?.cancel();
    _tipTimer?.cancel();
    _server?.stop();
    // 离开游戏：恢复竖屏 + 正常系统栏，避免影响社区其他页面
    SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  // ------------------------------------------------------------------ 安装与启动
  Future<void> _bootstrap() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}/flight_site');
    _siteDir = dir;

    final marker = File('${dir.path}/version.json');
    final index = File('${dir.path}/index.html');

    // 本地已装好：先比一次服务端版本号，版本没变就直接进，变了就更新
    if (await marker.exists() && await index.exists()) {
      String version = '';
      try {
        version = _readVersion(await marker.readAsString());
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _remoteVersion = version;
        if (version.isNotEmpty) _remoteSize = kFlightApproxBytes;
      });

      // 每次进入前比对一次服务端版本号：服务端发过新版就自动更新资源包，
      // 网络不通 / 清单拿不到时不做任何事，直接用本地这份进游戏。
      final remote = await _fetchRemoteVersion(timeoutSec: 6);
      final latest = remote['version'] as String?;
      if (latest != null && latest.isNotEmpty && latest != version) {
        if (!mounted) return;
        setState(() {
          _updating = true;
          _pendingVersion = latest;
          _remoteSize = (remote['size'] as int?) ?? _remoteSize;
        });
        await _deltaUpdate(latest);
        return;
      }
      await _startGame();
      return;
    }

    final remote = await _fetchRemoteVersion();
    if (!mounted) return;
    setState(() {
      _status = FlightStatus.absent;
      _remoteVersion = (remote['version'] as String?) ?? '';
      _remoteSize = (remote['size'] as int?) ?? kFlightApproxBytes;
    });
  }

  Future<Map<String, dynamic>> _fetchRemoteVersion(
      {int timeoutSec = 12}) async {
    try {
      final r = await http
          .get(Uri.parse(kFlightVersionUrl))
          .timeout(Duration(seconds: timeoutSec));
      if (r.statusCode == 200) {
        final j = _decodeJson(r.body);
        if (j != null) return j;
      }
    } catch (_) {}
    return <String, dynamic>{};
  }

  Map<String, dynamic>? _decodeJson(String body) {
    try {
      final v = jsonDecode(body);
      return v is Map<String, dynamic> ? v : null;
    } catch (_) {
      return null;
    }
  }

  String _readVersion(String body) {
    final j = _decodeJson(body);
    final v = j?['version'];
    return v is String ? v : '';
  }

  Future<String> _downloadDir() async {
    final support = await getApplicationSupportDirectory();
    final d = Directory('${support.path}/flight_download');
    if (!await d.exists()) await d.create(recursive: true);
    return d.path;
  }

  String _partPath(String dl, int i) => '$dl/part_$i.bin';

  // ------------------------------------------------------------------ 增量更新（只下改动的文件）
  /// 服务端每次发版都会生成 manifest.json（逐文件 size/sha256）。
  /// 版本号变了以后先比清单：只有内容真的变的文件才下载，改动占大头（>40%）才退回整包下载。
  Future<void> _deltaUpdate(String latest) async {
    final dir = _siteDir;
    if (dir == null) return;

    final remote = await _fetchManifest(latest);
    if (remote == null || remote['version'] != latest) {
      await _download();
      return;
    }

    final localFile = File('${dir.path}/manifest.json');
    final local = <String, String>{};
    final localSize = <String, int>{};
    var haveLocal = false;
    if (await localFile.exists()) {
      try {
        final lm =
            jsonDecode(await localFile.readAsString()) as Map<String, dynamic>;
        for (final f
            in (lm['files'] as List).whereType<Map<String, dynamic>>()) {
          final p = f['path'] as String?;
          if (p == null) continue;
          local[p] = (f['sha256'] as String?) ?? '';
          localSize[p] = (f['size'] as num?)?.toInt() ?? -1;
        }
        haveLocal = local.isNotEmpty;
      } catch (_) {}
    }
    if (!haveLocal) {
      await _download();
      return;
    }

    final files = (remote['files'] as List)
        .whereType<Map<String, dynamic>>()
        .toList();
    final total = (remote['total'] as num?)?.toInt() ?? 0;
    final changed = <Map<String, dynamic>>[];
    var changedBytes = 0;
    final paths = <String>{};
    for (final f in files) {
      final p = f['path'] as String;
      paths.add(p);
      final size = (f['size'] as num?)?.toInt() ?? -1;
      final sha = (f['sha256'] as String?) ?? '';
      if (local[p] != sha || localSize[p] != size) {
        changed.add(f);
        changedBytes += size < 0 ? 0 : size;
      }
    }
    final removed = local.keys.where((p) => !paths.contains(p)).toList();

    // 改得太多就不值得逐文件拉，直接整包更快
    if (total > 0 && changedBytes > total * 0.4) {
      await _download();
      return;
    }

    if (mounted) {
      setState(() {
        _status = FlightStatus.installing;
        _install = 0;
        _speed = 0;
        _message = changed.isEmpty
            ? '资源包已是最新，正在整理…'
            : '正在更新 ${changed.length} 个文件（共 ${_fmt(changedBytes)}）';
      });
    }

    var doneBytes = 0;
    var lastTick = DateTime.now().millisecondsSinceEpoch;
    var lastBytes = 0;

    for (var i = 0; i < changed.length; i++) {
      final f = changed[i];
      final path = f['path'] as String;
      final target = File('${dir.path}/$path');
      final part = File('${target.path}.part');
      try {
        if (!await target.parent.exists()) {
          await target.parent.create(recursive: true);
        }
        final client = http.Client();
        try {
          final req = http.Request('GET', Uri.parse('$kFlightSite/$path'));
          final resp =
              await client.send(req).timeout(const Duration(seconds: 30));
          if (resp.statusCode != 200) {
            throw HttpException('$path HTTP ${resp.statusCode}');
          }
          final sink = part.openWrite();
          try {
            await for (final chunk in resp.stream) {
              sink.add(chunk);
              doneBytes += chunk.length;
              final now = DateTime.now().millisecondsSinceEpoch;
              if (now - lastTick > 250 && mounted) {
                final inst =
                    (doneBytes - lastBytes) / ((now - lastTick) / 1000.0);
                lastTick = now;
                lastBytes = doneBytes;
                setState(() {
                  _install = changedBytes > 0
                      ? (doneBytes / changedBytes).clamp(0.0, 1.0)
                      : (i + 0.5) / changed.length;
                  _speed = inst;
                  _message = '正在下载 $path';
                });
              }
            }
          } finally {
            await sink.close();
          }
        } finally {
          client.close();
        }
        if (await target.exists()) {
          try {
            await target.delete();
          } catch (_) {}
        }
        await part.rename(target.path);
      } catch (e) {
        try {
          if (await part.exists()) await part.delete();
        } catch (_) {}
        // 单个文件失败就退回整包，别让用户卡在半新半旧的状态
        if (mounted) setState(() => _message = '增量下载失败，改为整包更新…');
        await _download();
        return;
      }
      if (mounted && changedBytes > 0) {
        setState(() => _install = (doneBytes / changedBytes).clamp(0.0, 1.0));
      }
    }

    for (final p in removed) {
      final f = File('${dir.path}/$p');
      try {
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }

    try {
      await localFile.writeAsString(jsonEncode(remote));
    } catch (_) {}
    try {
      final marker = File('${dir.path}/version.json');
      await marker.writeAsString(jsonEncode({
        'version': latest,
        'updated_at': remote['generated_at'],
      }));
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _remoteVersion = latest;
      _install = 1;
      _updating = false;
      _pendingVersion = '';
      _message =
          changed.isEmpty ? '资源包已是最新' : '已更新 ${changed.length} 个文件';
    });
    await _startGame();
  }

  Future<Map<String, dynamic>?> _fetchManifest(String version) async {
    try {
      final r = await http
          .get(Uri.parse(kFlightManifestUrl))
          .timeout(const Duration(seconds: 20));
      if (r.statusCode == 200) {
        final j = jsonDecode(r.body);
        if (j is Map<String, dynamic>) return j;
      }
    } catch (_) {}
    return null;
  }

  // ------------------------------------------------------------------ 下载（分段 + 续传）
  Future<void> _download() async {
    final dir = _siteDir;
    if (dir == null) return;

    setState(() {
      _status = FlightStatus.downloading;
      _progress = 0;
      _install = 0;
      _speed = 0;
      _message = '正在连接…';
    });

    try {
      final remote = await _fetchRemoteVersion();
      final latest = (remote['version'] as String?) ?? _remoteVersion;
      if (mounted && latest.isNotEmpty) {
        setState(() => _remoteVersion = latest);
      }
      final size = (remote['size'] as int?) ?? _remoteSize;
      final dlPath = await _downloadDir();
      final metaFile = File('$dlPath/meta.json');
      final zipFile = File('$dlPath/petalwake.zip');

      // 上次已经拼好的包：直接进安装，不再重下。
      if (await zipFile.exists() && await zipFile.length() == size) {
        await _installFrom(zipFile);
        return;
      }

      List<_Seg> segs;
      final saved = await _loadSegments(metaFile, size, latest);
      if (saved != null) {
        segs = saved;
        // 续传：每段的实际进度以磁盘上的 part 文件长度为准
        for (var i = 0; i < segs.length; i++) {
          final f = File(_partPath(dlPath, i));
          segs[i].done = await f.exists()
              ? math.min(await f.length(), segs[i].length)
              : 0;
        }
      } else {
        for (var i = 0; i < kSegments; i++) {
          try {
            final f = File(_partPath(dlPath, i));
            if (await f.exists()) await f.delete();
          } catch (_) {}
        }
        final chunk = (size / kSegments).ceil();
        segs = [];
        for (var i = 0; i < kSegments; i++) {
          final start = i * chunk;
          final end = math.min(size - 1, start + chunk - 1);
          if (start > end) break;
          segs.add(_Seg(start, end));
        }
        await _saveSegments(metaFile, size, segs, latest);
      }

      final done0 = segs.fold<int>(0, (p, s) => p + s.done);
      if (done0 > 0) {
        setState(() {
          _progress = size > 0 ? done0 / size : 0;
          _message = '继续上次的下载…';
        });
      }

      var lastTick = DateTime.now().millisecondsSinceEpoch;
      var lastBytes = done0;

      Future<void> pull(_Seg s, int idx) async {
        final part = File(_partPath(dlPath, idx));
        if (s.done >= s.length) return;
        final client = http.Client();
        try {
          while (s.done < s.length) {
            final from = s.start + s.done;
            final req = http.Request('GET', Uri.parse(kFlightZipUrl))
              ..headers['Range'] = 'bytes=$from-${s.end}';
            final resp =
                await client.send(req).timeout(const Duration(seconds: 30));
            if (resp.statusCode != 206) {
              throw HttpException(
                  '服务器不支持断点续传（HTTP ${resp.statusCode}）');
            }
            final sink = part.openWrite(mode: FileMode.append);
            await for (final chunk in resp.stream) {
              sink.add(chunk);
              s.done += chunk.length;
              final now = DateTime.now().millisecondsSinceEpoch;
              if (now - lastTick > 200 && mounted) {
                final total = segs.fold<int>(0, (p, x) => p + x.done);
                final inst = (total - lastBytes) / ((now - lastTick) / 1000.0);
                lastTick = now;
                lastBytes = total;
                setState(() {
                  _progress = size > 0 ? (total / size).clamp(0.0, 1.0) : 0;
                  _speed = inst;
                  _message = '正在下载 ${_fmt(total)} / ${_fmt(size)}';
                });
              }
            }
            await sink.close();
          }
        } finally {
          client.close();
        }
      }

      await Future.wait(
          [for (var i = 0; i < segs.length; i++) pull(segs[i], i)]);

      final total = segs.fold<int>(0, (p, s) => p + s.done);
      if (total != size) {
        throw HttpException('下载不完整（${_fmt(total)} / ${_fmt(size)}）');
      }

      if (!mounted) return;
      setState(() {
        _message = '正在合并文件…';
        _progress = 1;
      });

      final sink = zipFile.openWrite();
      for (var i = 0; i < segs.length; i++) {
        await sink.addStream(File(_partPath(dlPath, i)).openRead());
      }
      await sink.close();

      for (var i = 0; i < segs.length; i++) {
        try {
          await File(_partPath(dlPath, i)).delete();
        } catch (_) {}
      }
      try {
        await metaFile.delete();
      } catch (_) {}

      await _installFrom(zipFile);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = FlightStatus.failed;
        _message = '下载失败：$e';
      });
    }
  }

  Future<List<_Seg>?> _loadSegments(File meta, int size, String version) async {
    if (!await meta.exists()) return null;
    try {
      final m = jsonDecode(await meta.readAsString()) as Map<String, dynamic>;
      if (m['url'] != kFlightZipUrl ||
          (m['size'] as int?) != size ||
          (m['version'] as String?) != version) {
        return null;
      }
      final list = (m['segs'] as List)
          .whereType<Map<String, dynamic>>()
          .map((e) =>
              _Seg((e['start'] as num).toInt(), (e['end'] as num).toInt()))
          .toList();
      return list.isEmpty ? null : list;
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveSegments(
      File meta, int size, List<_Seg> segs, String version) async {
    await meta.writeAsString(jsonEncode({
      'url': kFlightZipUrl,
      'size': size,
      'version': version,
      'segs': [
        for (final s in segs) {'start': s.start, 'end': s.end}
      ],
    }));
  }

  // ------------------------------------------------------------------ 安装（解压）+ 进度
  Future<void> _installFrom(File zipFile) async {
    final dir = _siteDir;
    if (dir == null) return;

    if (mounted) {
      setState(() {
        _status = FlightStatus.installing;
        _install = 0;
        _speed = 0;
        _message = '正在安装…';
      });
    }

    // 安装前先摘掉标记，避免半装状态被当成已完成
    final marker = File('${dir.path}/version.json');
    try {
      if (await marker.exists()) await marker.delete();
    } catch (_) {}

    try {
      if (_updating && await dir.exists()) {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      }
      if (!await dir.exists()) await dir.create(recursive: true);
      final input = InputFileStream(zipFile.path);
      try {
        final archive = ZipDecoder().decodeBuffer(input, verify: false);
        final totalFiles = archive.files.where((f) => f.isFile).length;
        var done = 0;
        for (final f in archive) {
          if (!f.isFile) continue;
          final out = File('${dir.path}/${f.name}');
          final parent = out.parent;
          if (!await parent.exists()) await parent.create(recursive: true);
          final ostream = OutputFileStream(out.path);
          try {
            f.writeContent(ostream);
          } finally {
            ostream.close();
          }
          done++;
          if (mounted && (done % 10 == 0 || done == totalFiles)) {
            setState(() {
              _install = totalFiles > 0 ? done / totalFiles : 0;
              _message = '正在安装 $done/$totalFiles 个文件';
            });
          }
        }
      } finally {
        input.close();
      }

      final remote = await _fetchRemoteVersion();
      final v = _remoteVersion.isNotEmpty
          ? _remoteVersion
          : (remote['version'] as String?) ?? '';
      await marker.writeAsString(jsonEncode(remote.isNotEmpty
          ? {...remote, 'version': v.isEmpty ? remote['version'] : v}
          : {'version': v}));

      // 装完把这一版的清单存到本地：下次比对只认清单里的 hash，不用扫 173MB 文件
      try {
        final man = await _fetchManifest(v);
        if (man != null) {
          await File('${dir.path}/manifest.json')
              .writeAsString(jsonEncode(man));
        }
      } catch (_) {}

      try {
        await zipFile.delete();
      } catch (_) {}

      if (!mounted) return;
      setState(() {
        _install = 1;
        _message = '安装完成';
        _updating = false;
        _pendingVersion = '';
      });
      await _startGame();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = FlightStatus.failed;
        _message = '安装失败：$e';
      });
    }
  }

  Future<void> _startGame() async {
    final dir = _siteDir;
    if (dir == null || _starting) return;
    if (_status == FlightStatus.ready && _web != null) return;
    _starting = true;

    try {
      // 到这一步才切横屏：加载游戏页面前先摆好屏幕，避免画面先竖后横
      await SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      // edgeToEdge 而非隐藏系统栏：背景可以铺到状态栏/刘海/手势条，内容仍按安全区排布
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.light,
      ));

      await _server?.stop();
      final server = _LocalSiteServer(dir);
      await server.start();
      _server = server;

      final controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(const Color(0xFF07090C))
        ..addJavaScriptChannel('pw',
            onMessageReceived: (m) => _onJsText(m.message));

      await controller.setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: (r) => NavigationDecision.navigate,
        onWebResourceError: (e) {
          if (e.isForMainFrame == true) {
            _onJsText('err:${e.description}');
          }
        },
        // 关键：必须等页面 load 完成后再注入探针，否则 runJavaScript 打在旧文档上，
        // 永远收不到 ready，界面就会一直停在“正在进入航线”。
        onPageFinished: (url) => _injectProbe(controller),
      ));

      // 直接带参数进入：?play 跳过 "Take off" 点击门槛，低画质 + 限制 dpr 降低移动端显存压力
      final url = 'http://127.0.0.1:${server.port}/index.html?play&q=low&dpr=1.25';
      _gameUrlBase = 'http://127.0.0.1:${server.port}/index.html?play&q=low';
      await controller.loadRequest(Uri.parse(url));

      _autoRetried = false;
      _pixBlack = false;
      _waitSec = 0;
      _enterTimer?.cancel();
      // 不再 10 秒就撤掉覆盖层：引擎在 iOS 上首次初始化要几十秒，
      // 提前撤掉只会让用户对着黑屏发愣，还会误判成“加载完成”。
      _enterTimer = Timer.periodic(const Duration(seconds: 1), (t) {
        if (!mounted) {
          t.cancel();
          return;
        }
        if (_webReady) {
          t.cancel();
          return;
        }
        setState(() => _waitSec++);
        // 之前 22 秒就 reload，会把快到头的初始化打断重来，越等越不出画；改到 90 秒才算真卡死。
        if (_waitSec >= 90 && !_autoRetried) {
          _autoRetried = true;
          t.cancel();
          _web?.reload();
        }
      });
      _retryTimer?.cancel();
      _retryTimer = null;

      if (!mounted) return;
      setState(() {
        _web = controller;
        _status = FlightStatus.ready;
        _webReady = false;
        _webError = null;
        _message = '';
      });
    } catch (e) {
      await SystemChrome.setPreferredOrientations(
          const [DeviceOrientation.portraitUp]);
      if (!mounted) return;
      setState(() {
        _status = FlightStatus.failed;
        _message = '启动失败：$e';
      });
    } finally {
      _starting = false;
    }
  }

  /// 页面加载完成后注入探针（进入层不再靠探针兜底，统一由 _startGame 的计时器负责）
  Future<void> _injectProbe(WebViewController c) async {
    try {
      await c.runJavaScript(_probeJs);
    } catch (_) {}
  }

  static const String _probeJs = """
(function(){
  if (window.__pwProbe) return; window.__pwProbe = 1;
  var n = 0;
  function glOf(){ try { var c = document.querySelector('canvas'); return c ? (c.getContext('webgl2') || c.getContext('webgl')) : null; } catch(e){ return null; } }
  function desc(){
    try {
      var g = glOf(); if (!g) return 'nogl';
      var dbg = g.getExtension('WEBGL_debug_renderer_info');
      var r = dbg ? g.getParameter(dbg.UNMASKED_RENDERER_WEBGL) : 'gl-ok';
      var f = g.getExtension('EXT_color_buffer_float') || g.getExtension('EXT_color_buffer_half_float');
      return r + ' | ' + (f ? 'float-rt' : 'no-float-rt');
    } catch(e){ return 'gl-err'; }
  }
  // 真正的黑屏判定：把 canvas 缩到 64×64 采样亮度。HUD 是 DOM，显示正常不代表 3D 出画了。
  // 不用 readPixels：preserveDrawingBuffer=false 时读默认帧缓冲永远是 0，会误判成黑屏。
  function lumNow(){
    try {
      var c = document.querySelector('canvas');
      if (!c || !c.width || !c.height) return -2;
      var cv = document.createElement('canvas'); cv.width = 64; cv.height = 64;
      var ctx2 = cv.getContext('2d');
      ctx2.drawImage(c, 0, 0, 64, 64);
      var d = ctx2.getImageData(0, 0, 64, 64).data;
      var best = 0, sum = 0, cnt = 0;
      for (var i = 0; i < d.length; i += 4) {
        var l = Math.max(d[i], Math.max(d[i+1], d[i+2]));
        if (l > best) best = l; sum += l; cnt++;
      }
      return best;
    } catch(e){ return -3; }
  }
  function samplePixels(){
    var best = 0, calls = -1, lost = 0, frames = 0;
    function step(){
      frames++;
      try {
        var r = window.PW && window.PW.renderer;
        if (r && r.info) { calls = r.info.render.calls; }
        var g = r && r.getContext && r.getContext();
        if (g && g.isContextLost) lost = g.isContextLost() ? 1 : 0;
        best = lumNow();
      } catch(e) {}
      if (frames < 10) { requestAnimationFrame(step); }
      else {
        try { window.pw.postMessage('pix:' + best + '|calls:' + calls + '|lost:' + lost); } catch(e) {}
      }
    }
    requestAnimationFrame(step);
  }
  var iv = setInterval(function(){
    n++;
    try {
      if (window.PW && window.PW.ready) {
        clearInterval(iv);
        window.pw.postMessage('ready');
        try {
          var c = document.querySelector('canvas');
          window.pw.postMessage('diag:' + (c ? (c.width + 'x' + c.height) : 'nocanvas')
            + ' | ' + desc());
        } catch (e) {}
        samplePixels();
      } else if (n > 240) {
        clearInterval(iv);
        window.pw.postMessage('timeout');
      }
    } catch (e) {}
  }, 500);
  window.addEventListener('webglcontextlost', function(){
    try { window.pw.postMessage('lost'); } catch (e) {}
  }, true);
  window.onerror = function(m, s, l, c, e){
    try { window.pw.postMessage('err:' + m + ' @' + s + ':' + l); } catch (_) {}
  };
})();
""";

  void _onJsText(String v) {
    if (!mounted) return;
    if (v == 'ready') {
      _enterTimer?.cancel();
      _retryTimer?.cancel();
      setState(() {
        _webReady = true;
        _webError = null;
      });
      return;
    }
    if (v == 'lost') {
      // 图形上下文丢失不阻塞界面：记录 + 自动重载一次，让页面自己重建 WebGL
      setState(() => _diag = 'WebGL 上下文丢失');
      if (!_autoRetried) {
        _autoRetried = true;
        _web?.reload();
      } else {
        _forceEnter('图形上下文反复丢失，已保留当前画面');
      }
      return;
    }
    if (v == 'timeout') {
      setState(() => _diag = '探针超时（120s 未进入主循环）');
      if (!_webReady) _forceEnter('页面主循环未启动');
      return;
    }
    if (v.startsWith('diag:')) {
      setState(() => _diag = v.substring(5));
      return;
    }
    // 页面内 diag.js 每隔一段时间回报：draws=绘制次数、lum=画面亮度、ready=引擎是否完成初始化
    if (v.startsWith('d|')) {
      final draws = RegExp(r'draws=(-?\d+)').firstMatch(v)?.group(1);
      final ready = RegExp(r'ready=(\d)').firstMatch(v)?.group(1);
      if (ready == '1' && !_webReady) {
        _enterTimer?.cancel();
        setState(() {
          _webReady = true;
          _webError = null;
        });
      }
      setState(() {
        _diag = '绘制${draws ?? '?'}次 · 引擎${ready == '1' ? '已就绪' : '初始化中'}';
      });
      return;
    }
    if (v.startsWith('pix:')) {
      final parts = v.substring(4).split('|');
      final lum = int.tryParse(parts.first) ?? 0;
      final calls =
          parts.length > 1 ? int.tryParse(parts[1].split(':').last) ?? -1 : -1;
      final lost =
          parts.length > 2 ? int.tryParse(parts[2].split(':').last) ?? 0 : 0;
      final black = lum <= 3;
      _reportDiag('lum=$lum,calls=$calls,lost=$lost');
      setState(() {
        _pixBlack = black;
        _diag = '$_diag · 亮度$lum/255 · 绘制${calls < 0 ? '未知' : calls}次'
            '${lost == 1 ? ' · 上下文丢失' : ''}';
      });
      if (black) {
        // 有上下文但画面全黑：要么没提交绘制，要么帧缓冲/图层没进合成。
        // 先自动换更保守的参数重载一次，仍然黑就把诊断摊到屏幕上，方便截图定位。
        if (!_autoRetried) {
          _autoRetried = true;
          _showTip('3D 画面未出画，正在改用保守渲染参数重试…', seconds: 12);
          _webReady = true;
          _web?.loadRequest(Uri.parse('$_gameUrlBase&dpr=1'));
        } else {
          _showTip('3D 画面未出画：$_diag', seconds: 12);
        }
      }
      return;
    }
    if (v.startsWith('err:')) {
      // 页面内 JS 报错或资源加载失败：只记录诊断，2s 后照常进入，
      // 用户可在“⋯”菜单里看到具体原因，而不是被弹回“加载中断”。
      final msg = v.substring(4);
      setState(() => _webError = msg);
      if (!_webReady) {
        Timer(const Duration(seconds: 2), () {
          if (mounted && !_webReady) _forceEnter('页面报错：$msg');
        });
      }
    }
  }

  /// 不再依赖探针：无论页面是否回报，都把进入层收掉，让用户看到真实画面
  void _forceEnter(String tip) {
    if (!mounted || _webReady) return;
    _enterTimer?.cancel();
    _retryTimer?.cancel();
    setState(() {
      _webReady = true;
      _webError = null;
    });
    _showTip(tip);
  }

  /// 把设备上的真实渲染数据打到服务器访问日志里（GET 查询串即可，不需要后端接收）。
  /// 这样用户不用截图，我也能拿到 GPU 名称、帧缓冲亮度、绘制次数，判断是“没出画”还是“没进合成”。
  void _reportDiag(String extra) {
    final gpu = _diag.isEmpty ? 'unknown' : _diag;
    final q = Uri(queryParameters: {
      'os': Platform.isIOS ? 'ios' : 'android',
      'osv': Platform.operatingSystemVersion,
      'app': '0.4.4',
      'pix': extra,
      'gpu': gpu.length > 120 ? gpu.substring(0, 120) : gpu,
    }).query;
    unawaited(http
        .get(Uri.parse('$kFlightSite/_diag?$q'))
        .timeout(const Duration(seconds: 8))
        .catchError((_) => http.Response('', 204)));
  }

  void _showTip(String tip, {int seconds = 6}) {
    if (!mounted) return;
    setState(() => _softTip = tip);
    _tipTimer?.cancel();
    _tipTimer = Timer(Duration(seconds: seconds), () {
      if (mounted) setState(() => _softTip = '');
    });
  }

  Future<void> _checkUpdate() async {
    final remote = await _fetchRemoteVersion(timeoutSec: 8);
    final latest = remote['version'] as String?;
    if (!mounted) return;
    if (latest == null || latest.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('连不上更新服务，稍后再试')),
      );
      return;
    }
    if (latest == _remoteVersion) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已是最新版本 v$latest')),
      );
      return;
    }
    setState(() {
      _updating = true;
      _pendingVersion = latest;
      _remoteSize = (remote['size'] as int?) ?? _remoteSize;
    });
    await _deltaUpdate(latest);
  }

  Future<void> _reloadGame() async {
    _webReady = false;
    _webError = null;
    setState(() {
      _status = FlightStatus.checking;
      _web = null;
    });
    await _startGame();
  }

  Future<void> _reset() async {
    _web = null;
    await _server?.stop();
    _server = null;
    final dir = _siteDir;
    if (dir != null && await dir.exists()) {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    }
    final dl = await _downloadDir();
    final dlDir = Directory(dl);
    if (await dlDir.exists()) {
      try {
        await dlDir.delete(recursive: true);
      } catch (_) {}
    }
    _status = FlightStatus.absent;
    if (mounted) setState(() {});
    await _bootstrap();
  }

  String _fmt(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '$bytes B';
  }

  // ------------------------------------------------------------------ UI
  @override
  Widget build(BuildContext context) {
    final inGame = _status == FlightStatus.ready && _web != null;
    return Scaffold(
      backgroundColor: const Color(0xFF07090C),
      // 进入游戏后标题栏整体隐藏（沉浸式），只留一个很轻的悬浮返回键
      appBar: inGame
          ? null
          : AppBar(
              backgroundColor: const Color(0xFF07090C),
              elevation: 0,
              title: const Text('流萤航线', style: TextStyle(fontSize: 16)),
              actions: [
                if (_status == FlightStatus.ready)
                  IconButton(
                    tooltip: '删除本地资源包',
                    onPressed: _confirmReset,
                    icon: const Icon(Icons.delete_outline, size: 20),
                  ),
              ],
            ),
      body: _body(),
    );
  }

  Widget _body() {
    final inGame = _status == FlightStatus.ready && _web != null;
    if (inGame) {
      return Stack(
        children: [
          // 背景层：铺满到系统栏（状态栏/刘海/手势条）区域
          const Positioned.fill(child: ColoredBox(color: Color(0xFF07090C))),
          // 内容层：WebView 让出状态栏与刘海，不把画面内容压进系统栏
          Positioned.fill(
            child: SafeArea(
              bottom: false,
              child: WebViewWidget(controller: _web!),
            ),
          ),
          if (!_webReady) _enterOverlay(),
          Positioned(
            left: 10,
            top: 10,
            child: SafeArea(
              child: Row(
                children: [
                  _glassButton(
                    icon: Icons.arrow_back_ios_new_rounded,
                    onTap: () async {
                      await SystemChrome.setPreferredOrientations(
                          const [DeviceOrientation.portraitUp]);
                      SystemChrome.setEnabledSystemUIMode(
                          SystemUiMode.edgeToEdge);
                      if (!mounted) return;
                      Navigator.pop(context);
                    },
                  ),
                  const SizedBox(width: 8),
                  if (!_webReady)
                    _glassButton(icon: Icons.refresh, onTap: _reloadGame),
                ],
              ),
            ),
          ),
          if (_webReady && _softTip.isNotEmpty)
            Positioned(
              left: 0,
              right: 0,
              bottom: 24,
              child: SafeArea(
                child: Center(
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xCC0E1319),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: const Color(0x22FFFFFF)),
                    ),
                    child: Text(_softTip,
                        style: const TextStyle(
                            fontSize: 10.5, color: Color(0xFF8E97A5))),
                  ),
                ),
              ),
            ),
          if (_webReady)
            Positioned(
              right: 10,
              top: 10,
              child: SafeArea(
                child: _glassButton(icon: Icons.more_horiz, onTap: _gameMenu),
              ),
            ),
        ],
      );
    }
    if (_status == FlightStatus.downloading ||
        _status == FlightStatus.installing) {
      return _progressView();
    }
    if (_status == FlightStatus.failed) {
      return _errorView();
    }
    return _introView();
  }

  Widget _glassButton({required IconData icon, required VoidCallback onTap}) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(19),
        child: Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: const Color(0xCC0E1319),
            shape: BoxShape.circle,
            border: Border.all(color: const Color(0x33FFFFFF)),
          ),
          child: Icon(icon, size: 17, color: const Color(0xCCFFFFFF)),
        ),
      ),
    );
  }

  Widget _enterOverlay() {
    return Positioned.fill(
      child: Container(
        color: const Color(0xF207090C),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_webError == null)
                const SizedBox(
                  width: 26,
                  height: 26,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor:
                        AlwaysStoppedAnimation<Color>(Color(0xFF3DDC97)),
                  ),
                )
              else
                const Icon(Icons.cloud_off, size: 26, color: Color(0xFF8E97A5)),
              const SizedBox(height: 16),
              Text(
                  _webError == null
                      ? (_waitSec > 0 ? '引擎初始化中 ${_waitSec}s…' : '正在进入航线…')
                      : '页面正在自动重试…',
                  style: const TextStyle(fontSize: 13, color: Colors.white)),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: Text(
                  _webError == null
                      ? (_waitSec >= 20
                          ? '首次进入引擎要铺地形、烘天空，iOS 上通常 30–60 秒，别切走，慢慢等它画出来。'
                          : '正在铺地形、烘天空，稍等一下')
                      : _webError ?? '',
                  textAlign: TextAlign.center,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 11, height: 1.5, color: Color(0xFF8E97A5)),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton(
                    onPressed: () => setState(() => _webReady = true),
                    child: const Text('先看看当前画面',
                        style: TextStyle(fontSize: 12, color: Color(0xFF8E97A5))),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: _reloadGame,
                    child: const Text('重新加载',
                        style: TextStyle(fontSize: 12, color: Color(0xFF3DDC97))),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _gameMenu() async {
    await showModalBottomSheet<void>(
      context: context,
      sheetAnimationStyle: const AnimationStyle(
        duration: AppMotion.page,
        curve: AppMotion.standard,
        reverseCurve: AppMotion.exit,
      ),
            backgroundColor: const Color(0xFF12161C),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_diag.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Text(
                    '渲染诊断：$_diag\n画面状态：${_pixBlack ? '全黑（3D 未出画）' : '已出画'}',
                    style: const TextStyle(
                        fontSize: 10.5, height: 1.5, color: Color(0xFF6E7784))),
              ),
            ListTile(
              leading: const Icon(Icons.system_update_alt_rounded, size: 19),
              title: const Text('检查资源包更新', style: TextStyle(fontSize: 13)),
              subtitle: Text('本地版本 v${_remoteVersion.isEmpty ? '未知' : _remoteVersion}',
                  style: const TextStyle(fontSize: 11)),
              onTap: () {
                Navigator.pop(c);
                _checkUpdate();
              },
            ),
            ListTile(
              leading: const Icon(Icons.refresh, size: 19),
              title: const Text('重新加载游戏', style: TextStyle(fontSize: 13)),
              onTap: () {
                Navigator.pop(c);
                _reloadGame();
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, size: 19),
              title: const Text('删除本地资源包', style: TextStyle(fontSize: 13)),
              onTap: () {
                Navigator.pop(c);
                _confirmReset();
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _introView() {
    final sizeMb = (_remoteSize / (1024 * 1024)).toStringAsFixed(0);
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 10, 22, 26),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: const Color(0xFF14342A),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text('WebGL2 · 需一次性下载',
                  style: TextStyle(fontSize: 11, color: Color(0xFF4CD9A5))),
            ),
            const SizedBox(height: 14),
            const Text('骑上扫帚，飞过花甸',
                style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    color: Colors.white)),
            const SizedBox(height: 10),
            Text(
              '草甸、海崖、灯塔与送信航线。首次进入下载约 $sizeMb MB 资源包，'
              '下载并安装后保存在手机本地，以后直接进入，不再消耗流量。',
              style: const TextStyle(
                  fontSize: 13, height: 1.7, color: Color(0xFFA7B0BE)),
            ),
            const SizedBox(height: 18),
            _bullet('分段下载，支持断点续传；网络中断后再点会接着下'),
            _bullet('服务端更新资源包时只下载变化的文件，不再整包重下'),
            _bullet('建议在 Wi-Fi 下下载，安装后约占用 180 MB 空间'),
            const Spacer(),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF3DDC97),
                  foregroundColor: const Color(0xFF05231A),
                  padding: const EdgeInsets.symmetric(vertical: 15),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                onPressed: _download,
                child: Text('下载并安装（约 $sizeMb MB）',
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w700)),
              ),
            ),
            const SizedBox(height: 10),
            Text(
                '已下载的部分会被保留，不会重复下载。${_remoteVersion.isEmpty ? '' : ' 当前版本 v$_remoteVersion'}',
                style: const TextStyle(fontSize: 11, color: Color(0xFF68717E))),
          ],
        ),
      ),
    );
  }

  Widget _bullet(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('·',
              style: TextStyle(fontSize: 13, color: Color(0xFF4CD9A5))),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text,
                style: const TextStyle(
                    fontSize: 12.5, height: 1.55, color: Color(0xFF8E97A5))),
          ),
        ],
      ),
    );
  }

  Widget _progressView() {
    final installing = _status == FlightStatus.installing;
    final value = installing ? _install : _progress;
    final pct = (value * 100).clamp(0, 100).toStringAsFixed(0);
    final speed = (!installing && _speed > 0)
        ? '${(_speed / (1024 * 1024)).toStringAsFixed(1)} MB/s'
        : '';
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 26),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(installing ? Icons.inventory_2_outlined : Icons.flight_takeoff,
                size: 40, color: const Color(0xFF4CD9A5)),
            const SizedBox(height: 18),
            Text(
                installing
                    ? (_updating ? '正在安装新版本' : '正在安装')
                    : (_updating ? '正在增量更新资源包' : '正在下载'),
                style: const TextStyle(fontSize: 16, color: Colors.white)),
            const SizedBox(height: 6),
            Text(_message,
                style: const TextStyle(fontSize: 12, color: Color(0xFF8E97A5))),
            const SizedBox(height: 18),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: value,
                minHeight: 8,
                backgroundColor: const Color(0xFF1A1F26),
                valueColor: const AlwaysStoppedAnimation(Color(0xFF3DDC97)),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('$pct%',
                    style: const TextStyle(
                        fontSize: 12, color: Color(0xFF8E97A5))),
                Text(speed,
                    style: const TextStyle(
                        fontSize: 12, color: Color(0xFF8E97A5))),
              ],
            ),
            const SizedBox(height: 26),
            Text(
                installing
                    ? '安装完成后自动进入游戏'
                    : (_updating && _pendingVersion.isNotEmpty
                        ? '更新到 v$_pendingVersion · 只下载有变化的文件'
                        : '可以随时离开，下次会续传'),
                style: const TextStyle(fontSize: 11, color: Color(0xFF68717E))),
          ],
        ),
      ),
    );
  }

  Widget _errorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 26),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.cloud_off, size: 36, color: Color(0xFF8E97A5)),
            const SizedBox(height: 14),
            Text(_message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 12.5, height: 1.6, color: Color(0xFF8E97A5))),
            const SizedBox(height: 20),
            FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF3DDC97),
                  foregroundColor: const Color(0xFF05231A)),
              onPressed: _download,
              child: const Text('继续'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmReset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: const Color(0xFF12161C),
        title: const Text('删除本地资源包？',
            style: TextStyle(fontSize: 15, color: Colors.white)),
        content: const Text('删除后下次进入需要重新下载约 100MB。',
            style: TextStyle(fontSize: 13, color: Color(0xFFA7B0BE))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok == true) {
      if (!mounted) return;
      Navigator.pop(context);
      unawaited(_reset());
    }
  }
}

/// 一个下载分段：闭区间 [start, end]，done 为已落盘字节数。
class _Seg {
  _Seg(this.start, this.end);
  final int start;
  final int end;
  int done = 0;
  int get length => end - start + 1;
}

/// 只监听 127.0.0.1 的静态文件服务：让 ES module / importmap / fetch 在原生 Origin 下正常工作。
class _LocalSiteServer {
  _LocalSiteServer(this.root);
  final Directory root;
  HttpServer? _http;

  int get port => _http?.port ?? 0;

  Future<void> start() async {
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _http = s;
    s.listen(_handle);
  }

  Future<void> stop() async {
    try {
      await _http?.close(force: true);
    } catch (_) {}
    _http = null;
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    try {
      var path = req.uri.path;
      if (path == '/' || path.isEmpty) path = '/index.html';
      final file = File('${root.path}$path');
      if (!await file.exists()) {
        res.statusCode = HttpStatus.notFound;
        await res.close();
        return;
      }
      final total = await file.length();
      res.headers.set('Content-Type', _mime(path));
      res.headers.set('Accept-Ranges', 'bytes');
      res.headers.set('Cache-Control', 'public, max-age=604800');

      final range = req.headers.value(HttpHeaders.rangeHeader);
      if (range != null && range.startsWith('bytes=')) {
        final spec = range.substring(6).split('-');
        var start = int.tryParse(spec.first) ?? 0;
        var end = spec.length > 1 && spec[1].isNotEmpty
            ? (int.tryParse(spec[1]) ?? total - 1)
            : total - 1;
        if (start < 0) start = 0;
        if (end >= total) end = total - 1;
        if (start > end) {
          res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          res.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$total');
          await res.close();
          return;
        }
        res.statusCode = HttpStatus.partialContent;
        res.headers
            .set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$total');
        res.headers
            .set(HttpHeaders.contentLengthHeader, '${end - start + 1}');
        await res.addStream(file.openRead(start, end + 1));
      } else {
        res.headers.set(HttpHeaders.contentLengthHeader, '$total');
        await res.addStream(file.openRead());
      }
      await res.close();
    } catch (_) {
      try {
        res.statusCode = HttpStatus.internalServerError;
        await res.close();
      } catch (_) {}
    }
  }

  String _mime(String path) {
    final p = path.toLowerCase();
    if (p.endsWith('.html')) return 'text/html; charset=utf-8';
    if (p.endsWith('.js') || p.endsWith('.mjs')) {
      return 'text/javascript; charset=utf-8';
    }
    if (p.endsWith('.css')) return 'text/css; charset=utf-8';
    if (p.endsWith('.json')) return 'application/json; charset=utf-8';
    if (p.endsWith('.webp')) return 'image/webp';
    if (p.endsWith('.png')) return 'image/png';
    if (p.endsWith('.jpg') || p.endsWith('.jpeg')) return 'image/jpeg';
    if (p.endsWith('.svg')) return 'image/svg+xml';
    if (p.endsWith('.glb')) return 'model/gltf-binary';
    if (p.endsWith('.gltf')) return 'model/gltf+json';
    if (p.endsWith('.wasm')) return 'application/wasm';
    if (p.endsWith('.wav')) return 'audio/wav';
    if (p.endsWith('.mp3')) return 'audio/mpeg';
    return 'application/octet-stream';
  }
}
