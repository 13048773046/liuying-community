import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'secure_links.dart';

/// 本机轻执行器：在手机私有目录里做文件、网络、文本、图片处理。
/// 不需要 root、不需要服务器，iOS / Android 通用。
class LocalTools {
  static const _maxReadBytes = 2 * 1024 * 1024;
  static const _maxWriteBytes = 4 * 1024 * 1024;

  /// 工作区根目录：应用文档目录 / af_workspace
  static Future<String> baseDir() async {
    final d = await getApplicationDocumentsDirectory();
    final w = Directory('${d.path}/af_workspace');
    if (!await w.exists()) {
      await w.create(recursive: true);
    }
    return w.path;
  }

  static String _safe(String rel) {
    final cleaned = rel.replaceAll('\\', '/').replaceAll(RegExp(r'^/+'), '');
    if (cleaned.contains('..')) {
      throw '路径不允许包含 ..';
    }
    return cleaned;
  }

  static Future<String> _abs(String rel) async {
    final base = await baseDir();
    return '$base/${_safe(rel)}';
  }

  /// 工具清单（给 Agent 的系统提示用）
  static const List<Map<String, dynamic>> specs = [
    {'name': 'fs_list', 'desc': '列出工作区目录', 'args': {'path': '相对路径，默认根目录'}},
    {'name': 'fs_read', 'desc': '读取文本文件', 'args': {'path': '相对路径'}},
    {'name': 'fs_write', 'desc': '写入文本文件', 'args': {'path': '相对路径', 'content': '内容'}},
    {'name': 'fs_mkdir', 'desc': '创建目录', 'args': {'path': '相对路径'}},
    {'name': 'fs_delete', 'desc': '删除文件或目录', 'args': {'path': '相对路径'}},
    {'name': 'http_get', 'desc': '抓取网页/接口（返回文本，自动截断）', 'args': {'url': '地址', 'limit': '字符上限，默认 4000'}},
    {'name': 'http_download', 'desc': '下载文件到工作区', 'args': {'url': '地址', 'path': '保存路径'}},
    {'name': 'text_regex', 'desc': '正则替换/提取', 'args': {'text': '文本', 'pattern': '正则', 'replace': '替换串，不传则只提取'}},
    {'name': 'json_query', 'desc': 'JSON 取值（点号路径）', 'args': {'json': 'JSON 文本', 'path': '如 data.items.0.name'}},
    {'name': 'csv_parse', 'desc': 'CSV 转 JSON 行', 'args': {'text': 'CSV 文本', 'max_rows': '行数上限'}},
    {'name': 'file_info', 'desc': '文件大小/类型', 'args': {'path': '相对路径'}},
  ];

  static Future<Map<String, dynamic>> run(String name, Map<String, dynamic> args) async {
    try {
      switch (name) {
        case 'fs_list':
          return await _list(args);
        case 'fs_read':
          return await _read(args);
        case 'fs_write':
          return await _write(args);
        case 'fs_mkdir':
          return await _mkdir(args);
        case 'fs_delete':
          return await _delete(args);
        case 'http_get':
          return await _httpGet(args);
        case 'http_download':
          return await _download(args);
        case 'text_regex':
          return _regex(args);
        case 'json_query':
          return _jsonQuery(args);
        case 'csv_parse':
          return _csv(args);
        case 'file_info':
          return await _info(args);
        default:
          return {'ok': false, 'error': '未知工具: $name'};
      }
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  static Future<Map<String, dynamic>> _list(Map a) async {
    final dir = Directory(await _abs((a['path'] ?? '').toString()));
    if (!await dir.exists()) {
      return {'ok': false, 'error': '目录不存在'};
    }
    final items = <Map<String, dynamic>>[];
    await for (final e in dir.list(followLinks: false)) {
      final st = await e.stat();
      items.add({
        'name': e.path.split('/').last,
        'dir': e is Directory,
        'size': st.size,
        'mtime': st.modified.millisecondsSinceEpoch,
      });
      if (items.length >= 500) break;
    }
    items.sort((x, y) => (y['dir'] == true ? 1 : 0) - (x['dir'] == true ? 1 : 0));
    return {'ok': true, 'items': items};
  }

  static Future<Map<String, dynamic>> _read(Map a) async {
    final f = File(await _abs((a['path'] ?? '').toString()));
    if (!await f.exists()) {
      return {'ok': false, 'error': '文件不存在'};
    }
    final size = await f.length();
    if (size > _maxReadBytes) {
      return {'ok': false, 'error': '文件过大（${(size / 1024).toStringAsFixed(0)}KB），上限 2MB'};
    }
    return {'ok': true, 'content': await f.readAsString(), 'size': size};
  }

  static Future<Map<String, dynamic>> _write(Map a) async {
    final content = (a['content'] ?? '').toString();
    if (content.length > _maxWriteBytes) {
      return {'ok': false, 'error': '内容过大，上限 4MB'};
    }
    final f = File(await _abs((a['path'] ?? '').toString()));
    final parent = f.parent;
    if (!await parent.exists()) {
      await parent.create(recursive: true);
    }
    await f.writeAsString(content);
    return {'ok': true, 'path': (a['path'] ?? '').toString(), 'bytes': content.length};
  }

  static Future<Map<String, dynamic>> _mkdir(Map a) async {
    final d = Directory(await _abs((a['path'] ?? '').toString()));
    await d.create(recursive: true);
    return {'ok': true};
  }

  static Future<Map<String, dynamic>> _delete(Map a) async {
    final p = await _abs((a['path'] ?? '').toString());
    final d = Directory(p);
    if (await d.exists()) {
      await d.delete(recursive: true);
      return {'ok': true};
    }
    final f = File(p);
    if (await f.exists()) {
      await f.delete();
      return {'ok': true};
    }
    return {'ok': false, 'error': '不存在'};
  }

  static HttpClient _newClient() {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..findProxy = ((_) => 'DIRECT');
    // 连接前固定到已验证的公网 IP，避免 DNS 校验与实际连接之间被重绑定。
    client.connectionFactory = SecureLinks.connectPublic;
    return client;
  }

  /// 发起一次公网请求；每一跳重定向都重新做 SSRF 校验。
  static Future<HttpClientResponse> _openPublic(
    HttpClient client,
    Uri start,
  ) async {
    var uri = start;
    for (var hop = 0; hop < 5; hop++) {
      if (!await SecureLinks.isPublicHttpUrl(uri.toString())) {
        throw '目标地址不是公网 HTTP(S)，已阻断';
      }
      final req = await client.getUrl(uri);
      req.followRedirects = false;
      req.headers.set('User-Agent', 'Mozilla/5.0 (LiuyingCommunity)');
      final resp = await req.close().timeout(const Duration(seconds: 20));
      final location = resp.headers.value(HttpHeaders.locationHeader);
      if (resp.statusCode >= 300 &&
          resp.statusCode < 400 &&
          location != null &&
          location.isNotEmpty) {
        await resp.drain();
        uri = uri.resolve(location);
        continue;
      }
      return resp;
    }
    throw '重定向次数过多，已阻断';
  }

  static Future<Map<String, dynamic>> _httpGet(Map a) async {
    final limit = int.tryParse('${a['limit'] ?? 4000}') ?? 4000;
    final client = _newClient();
    try {
      final url = (a['url'] ?? '').toString();
      final resp = await _openPublic(client, Uri.parse(url));
      final body = await resp.transform(utf8.decoder).join();
      client.close();
      return {
        'ok': true,
        'status': resp.statusCode,
        'content': body.length > limit ? '${body.substring(0, limit)}…(已截断)' : body,
        'length': body.length,
      };
    } catch (e) {
      client.close();
      return {'ok': false, 'error': e.toString()};
    }
  }

  static Future<Map<String, dynamic>> _download(Map a) async {
    final path = await _abs((a['path'] ?? 'download.bin').toString());
    final client = _newClient();
    try {
      final url = (a['url'] ?? '').toString();
      final resp = await _openPublic(client, Uri.parse(url))
          .timeout(const Duration(seconds: 30));
      final f = File(path);
      final parent = f.parent;
      if (!await parent.exists()) {
        await parent.create(recursive: true);
      }
      final sink = f.openWrite();
      await resp.pipe(sink);
      await sink.close();
      client.close();
      return {'ok': true, 'path': (a['path'] ?? '').toString(), 'bytes': await f.length()};
    } catch (e) {
      client.close();
      return {'ok': false, 'error': e.toString()};
    }
  }

  static Map<String, dynamic> _regex(Map a) {
    final text = (a['text'] ?? '').toString();
    final pat = (a['pattern'] ?? '').toString();
    final rep = a['replace'];
    final re = RegExp(pat);
    if (rep == null) {
      final m = re.allMatches(text).take(200).map((e) => e.group(0)).toList();
      return {'ok': true, 'matches': m, 'count': m.length};
    }
    return {'ok': true, 'result': text.replaceAll(re, rep.toString())};
  }

  static Map<String, dynamic> _jsonQuery(Map a) {
    var cur = jsonDecode((a['json'] ?? 'null').toString());
    final path = (a['path'] ?? '').toString();
    if (path.isNotEmpty) {
      for (final seg in path.split('.')) {
        if (cur is Map) {
          cur = cur[seg];
        } else if (cur is List) {
          final i = int.tryParse(seg);
          if (i == null || i < 0 || i >= cur.length) {
            return {'ok': false, 'error': '路径越界: $seg'};
          }
          cur = cur[i];
        } else {
          return {'ok': false, 'error': '路径无法继续: $seg'};
        }
      }
    }
    final s = jsonEncode(cur);
    return {'ok': true, 'value': s.length > 8000 ? '${s.substring(0, 8000)}…' : s};
  }

  static Map<String, dynamic> _csv(Map a) {
    final maxRows = int.tryParse('${a['max_rows'] ?? 200}') ?? 200;
    final lines = const LineSplitter().convert((a['text'] ?? '').toString());
    if (lines.isEmpty) {
      return {'ok': true, 'rows': []};
    }
    final head = _splitCsv(lines.first);
    final rows = <Map<String, String>>[];
    for (var i = 1; i < lines.length && rows.length < maxRows; i++) {
      if (lines[i].trim().isEmpty) continue;
      final cells = _splitCsv(lines[i]);
      final m = <String, String>{};
      for (var c = 0; c < head.length; c++) {
        m[head[c]] = c < cells.length ? cells[c] : '';
      }
      rows.add(m);
    }
    return {'ok': true, 'columns': head, 'rows': rows};
  }

  static List<String> _splitCsv(String line) {
    final out = <String>[];
    final buf = StringBuffer();
    var inQ = false;
    for (var i = 0; i < line.length; i++) {
      final ch = line[i];
      if (ch == '"') {
        if (inQ && i + 1 < line.length && line[i + 1] == '"') {
          buf.write('"');
          i++;
        } else {
          inQ = !inQ;
        }
      } else if (ch == ',' && !inQ) {
        out.add(buf.toString());
        buf.clear();
      } else {
        buf.write(ch);
      }
    }
    out.add(buf.toString());
    return out;
  }

  static Future<Map<String, dynamic>> _info(Map a) async {
    final f = File(await _abs((a['path'] ?? '').toString()));
    if (!await f.exists()) {
      return {'ok': false, 'error': '文件不存在'};
    }
    final st = await f.stat();
    final name = f.path.split('/').last;
    final dot = name.lastIndexOf('.');
    return {
      'ok': true,
      'size': st.size,
      'ext': dot > 0 ? name.substring(dot + 1).toLowerCase() : '',
      'mtime': st.modified.millisecondsSinceEpoch,
    };
  }
}
