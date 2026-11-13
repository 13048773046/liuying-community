/// 流萤航线（Petalwake）：把现成的 WebGL2 网页游戏按需搬到手机上。
///
/// 流程：首次进入 → 分段下载资源包（支持断点续传）→ 解压安装（带进度）→
/// 起一个只监听 127.0.0.1 的本地 HTTP 服务 → WebView 打开 `index.html`。
/// 之后每次进入都直接读本地文件，不再走网络，也不占 App 包体。
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

/// 站点根（nginx 上已配好限速，不抢占社区接口带宽）
const String kFlightSite = 'https://www.dbmt999.asia/petalwake';

/// 资源包与版本清单
const String kFlightZipUrl = '$kFlightSite/petalwake.zip';
const String kFlightVersionUrl = '$kFlightSite/version.json';

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

    // 已经装好就直接进游戏：不再去比对远端版本，避免“装好了又让你重下一遍”。
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

  Future<Map<String, dynamic>> _fetchRemoteVersion() async {
    try {
      final r = await http
          .get(Uri.parse(kFlightVersionUrl))
          .timeout(const Duration(seconds: 12));
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
      final saved = await _loadSegments(metaFile, size);
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
        await _saveSegments(metaFile, size, segs);
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
              throw HttpException('服务器不支持断点续传（HTTP ${resp.statusCode}）');
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

      await Future.wait([for (var i = 0; i < segs.length; i++) pull(segs[i], i)]);

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

  Future<List<_Seg>?> _loadSegments(File meta, int size) async {
    if (!await meta.exists()) return null;
    try {
      final m = jsonDecode(await meta.readAsString()) as Map<String, dynamic>;
      if (m['url'] != kFlightZipUrl || (m['size'] as int?) != size) return null;
      final list = (m['segs'] as List)
          .whereType<Map<String, dynamic>>()
          .map((e) => _Seg((e['start'] as num).toInt(), (e['end'] as num).toInt()))
          .toList();
      return list.isEmpty ? null : list;
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveSegments(File meta, int size, List<_Seg> segs) async {
    await meta.writeAsString(jsonEncode({
      'url': kFlightZipUrl,
      'size': size,
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
      await marker.writeAsString(jsonEncode(
          remote.isNotEmpty ? remote : {'version': _remoteVersion}));

      try {
        await zipFile.delete();
      } catch (_) {}

      if (!mounted) return;
      setState(() {
        _install = 1;
        _message = '安装完成';
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

      if (Platform.isAndroid) {
        await controller.setNavigationDelegate(NavigationDelegate(
          onNavigationRequest: (r) => NavigationDecision.navigate,
          onWebResourceError: (e) {
            if (e.isForMainFrame == true) {
              _onJsText('err:${e.description}');
            }
          },
        ));
      }

      // 直接带参数进入：?play 跳过 "Take off" 点击门槛，低画质 + 限制 dpr 降低移动端显存压力
      final url = 'http://127.0.0.1:${server.port}/index.html?play&q=low&dpr=1.25';
      await controller.loadRequest(Uri.parse(url));

      // 注入探针：游戏进入主循环 / WebGL 上下文丢失 / JS 报错，都回报给原生层
      await controller.runJavaScript('''
(function(){
  if (window.__pwProbe) return; window.__pwProbe = 1;
  var n = 0;
  var iv = setInterval(function(){
    n++;
    try {
      if (window.PW && window.PW.ready) {
        clearInterval(iv);
        window.pw.postMessage('ready');
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
''');

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

  void _onJsText(String v) {
    if (!mounted) return;
    if (v == 'ready') {
      setState(() {
        _webReady = true;
        _webError = null;
      });
      return;
    }
    if (v == 'lost') {
      setState(() => _webError = '图形上下文丢失，点“重新加载”再试');
      return;
    }
    if (v == 'timeout') {
      setState(() => _webError = '进入超时，点“重新加载”再试');
      return;
    }
    if (v.startsWith('err:')) {
      setState(() => _webError = v.substring(4));
    }
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
              Text(_webError == null ? '正在进入航线…' : '加载中断',
                  style: const TextStyle(fontSize: 13, color: Colors.white)),
              if (_webError != null) ...[
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 40),
                  child: Text(
                    _webError!,
                    textAlign: TextAlign.center,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 11, height: 1.5, color: Color(0xFF8E97A5)),
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF3DDC97),
                    foregroundColor: const Color(0xFF05231A),
                  ),
                  onPressed: _reloadGame,
                  child: const Text('重新加载'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _gameMenu() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF12161C),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
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
            _bullet('建议在 Wi-Fi 下下载，安装后约占用 180 MB 空间'),
            _bullet('左侧滑动控制升降与侧倾，右侧按钮控制借风/减速/翻滚'),
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
            const Text('已下载的部分会被保留，不会重复下载。',
                style: TextStyle(fontSize: 11, color: Color(0xFF68717E))),
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
            Text(installing ? '正在安装' : '正在下载',
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
            Text(installing ? '安装完成后自动进入游戏' : '可以随时离开，下次会续传',
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
        res.headers.set(
            HttpHeaders.contentRangeHeader, 'bytes $start-$end/$total');
        res.headers.set(HttpHeaders.contentLengthHeader, '${end - start + 1}');
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
