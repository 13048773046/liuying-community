/// 流萤航线（Petalwake）：把现成的 WebGL2 网页游戏按需搬到手机上。
///
/// 流程：首次进入 → 下载资源包（约 100MB）→ 解压到应用私有目录 → 起一个只监听
/// 127.0.0.1 的本地 HTTP 服务 → WebView 打开 `http://127.0.0.1:<port>/index.html`。
/// 之后每次进入都直接读本地文件，不再走网络，也不占 App 包体。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/material.dart';
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

enum FlightStatus { checking, absent, downloading, extracting, ready, failed }

class PetalwakePage extends StatefulWidget {
  const PetalwakePage({super.key});

  @override
  State<PetalwakePage> createState() => _PetalwakePageState();
}

class _PetalwakePageState extends State<PetalwakePage> {
  FlightStatus _status = FlightStatus.checking;
  String _remoteVersion = '';
  int _remoteSize = kFlightApproxBytes;
  double _progress = 0;
  double _speed = 0; // bytes/s
  String _message = '';

  Directory? _siteDir;
  _LocalSiteServer? _server;
  WebViewController? _web;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _server?.stop();
    super.dispose();
  }

  // ------------------------------------------------------------------ 安装与启动
  Future<void> _bootstrap() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}/flight_site');
    _siteDir = dir;

    final marker = File('${dir.path}/version.json');
    final index = File('${dir.path}/index.html');

    String localVersion = '';
    if (await marker.exists() && await index.exists()) {
      try {
        localVersion = _readVersion(await marker.readAsString());
      } catch (_) {}
    }

    final remote = await _fetchRemoteVersion();
    if (!mounted) return;

    if (localVersion.isNotEmpty && remote['version'] == localVersion) {
      setState(() {
        _remoteVersion = localVersion;
        _remoteSize = (remote['size'] as int?) ?? kFlightApproxBytes;
      });
      await _startGame();
    } else {
      setState(() {
        _status = FlightStatus.absent;
        _remoteVersion = (remote['version'] as String?) ?? '';
        _remoteSize = (remote['size'] as int?) ?? kFlightApproxBytes;
      });
    }
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

  Future<void> _download() async {
    final dir = _siteDir;
    if (dir == null) return;

    setState(() {
      _status = FlightStatus.downloading;
      _progress = 0;
      _speed = 0;
      _message = '正在连接…';
    });

    final tmpDir = await getTemporaryDirectory();
    final zipFile = File('${tmpDir.path}/petalwake.zip');

    try {
      final client = http.Client();
      final req = http.Request('GET', Uri.parse(kFlightZipUrl));
      final resp = await client.send(req).timeout(const Duration(seconds: 30));
      if (resp.statusCode != 200) {
        throw HttpException('资源包不可用（HTTP ${resp.statusCode}）');
      }
      final total = resp.contentLength ?? _remoteSize;
      final sink = zipFile.openWrite();
      var received = 0;
      var lastTick = DateTime.now().millisecondsSinceEpoch;
      var lastBytes = 0;

      await for (final chunk in resp.stream) {
        sink.add(chunk);
        received += chunk.length;
        final now = DateTime.now().millisecondsSinceEpoch;
        if (now - lastTick > 200) {
          final inst = (received - lastBytes) / ((now - lastTick) / 1000.0);
          lastTick = now;
          lastBytes = received;
          if (!mounted) continue;
          setState(() {
            _progress = total > 0 ? (received / total).clamp(0.0, 1.0) : 0;
            _speed = inst;
            _message = '正在下载 ${_fmt(received)} / ${_fmt(total)}';
          });
        }
      }
      await sink.close();
      client.close();

      if (!mounted) return;
      setState(() {
        _status = FlightStatus.extracting;
        _progress = 1;
        _message = '正在解压…';
      });

      await _extractInto(dir, zipFile);
      try {
        await zipFile.delete();
      } catch (_) {}

      final remote = await _fetchRemoteVersion();
      await File('${dir.path}/version.json').writeAsString(
          jsonEncode(remote.isNotEmpty ? remote : {'version': _remoteVersion}));

      if (!mounted) return;
      await _startGame();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = FlightStatus.failed;
        _message = '安装失败：$e';
      });
    }
  }

  Future<void> _extractInto(Directory dir, File zipFile) async {
    if (!await dir.exists()) await dir.create(recursive: true);
    final input = InputFileStream(zipFile.path);
    try {
      final archive = ZipDecoder().decodeBuffer(input, verify: false);
      for (final f in archive) {
        if (!f.isFile) continue;
        final out = File('${dir.path}/${f.name}');
        await out.create(recursive: true);
        final ostream = OutputFileStream(out.path);
        try {
          f.writeContent(ostream);
        } finally {
          ostream.close();
        }
      }
    } finally {
      input.close();
    }
  }

  Future<void> _startGame() async {
    final dir = _siteDir;
    if (dir == null) return;

    final server = _LocalSiteServer(dir);
    await server.start();
    _server = server;

    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF0B0F14));
    if (Platform.isAndroid) {
      await controller.setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: (r) => NavigationDecision.navigate,
      ));
    }
    await controller.loadRequest(Uri.parse('http://127.0.0.1:${server.port}/index.html'));

    if (!mounted) return;
    setState(() {
      _web = controller;
      _status = FlightStatus.ready;
      _message = '';
    });
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
    return Scaffold(
      backgroundColor: const Color(0xFF07090C),
      appBar: AppBar(
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
    if (_status == FlightStatus.ready && _web != null) {
      return WebViewWidget(controller: _web!);
    }
    if (_status == FlightStatus.downloading || _status == FlightStatus.extracting) {
      return _progressView();
    }
    if (_status == FlightStatus.failed) {
      return _errorView();
    }
    return _introView();
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
              '草甸、海崖、灯塔与送信航线。首次进入需要下载约 $sizeMb MB 资源包，'
              '下载并解压后保存在手机本地，以后直接进入，不再消耗流量。',
              style: const TextStyle(
                  fontSize: 13, height: 1.7, color: Color(0xFFA7B0BE)),
            ),
            const SizedBox(height: 18),
            _bullet('建议在 Wi-Fi 下下载，解压后约占 180 MB 空间'),
            _bullet('左侧滑动控制升降与侧倾，右侧按钮控制借风/减速/翻滚'),
            _bullet('社区升级、积分与航线奖励即将接入'),
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
            const Text('下载后可离线游玩；删除本地资源包可释放空间。',
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
    final pct = (_progress * 100).clamp(0, 100).toStringAsFixed(0);
    final speed = _speed > 0 ? '${(_speed / (1024 * 1024)).toStringAsFixed(1)} MB/s' : '';
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 26),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.flight_takeoff, size: 40, color: Color(0xFF4CD9A5)),
            const SizedBox(height: 18),
            Text(_status == FlightStatus.extracting ? '正在解压…' : '正在下载…',
                style: const TextStyle(fontSize: 16, color: Colors.white)),
            const SizedBox(height: 6),
            Text(_message, style: const TextStyle(fontSize: 12, color: Color(0xFF8E97A5))),
            const SizedBox(height: 18),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: _status == FlightStatus.extracting ? null : _progress,
                minHeight: 8,
                backgroundColor: const Color(0xFF1A1F26),
                valueColor: const AlwaysStoppedAnimation(Color(0xFF3DDC97)),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('$pct%', style: const TextStyle(fontSize: 12, color: Color(0xFF8E97A5))),
                Text(speed, style: const TextStyle(fontSize: 12, color: Color(0xFF8E97A5))),
              ],
            ),
            const SizedBox(height: 26),
            const Text('安装过程中请保持页面开启',
                style: TextStyle(fontSize: 11, color: Color(0xFF68717E))),
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
                style: const TextStyle(fontSize: 12.5, height: 1.6, color: Color(0xFF8E97A5))),
            const SizedBox(height: 20),
            FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF3DDC97),
                  foregroundColor: const Color(0xFF05231A)),
              onPressed: _download,
              child: const Text('重试'),
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
        title: const Text('删除本地资源包？', style: TextStyle(fontSize: 15, color: Colors.white)),
        content: const Text('删除后下次进入需要重新下载约 100MB。',
            style: TextStyle(fontSize: 13, color: Color(0xFFA7B0BE))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('删除')),
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
        res.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$total');
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
    if (p.endsWith('.js') || p.endsWith('.mjs')) return 'text/javascript; charset=utf-8';
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
