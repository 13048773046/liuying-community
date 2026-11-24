/// 流萤社区 · 外链与出站请求安全边界
///
/// 客户端所有“把服务端/用户内容里的 URL 交给系统或网络层”的入口都应经过这里：
/// - 外链只允许 HTTPS，阻断 file/javascript/intent/content 等危险 scheme；
/// - 禁止 userinfo（`https://user:pass@host`）与空 host；
/// - 本地工具出站请求解析 DNS 后拒绝 loopback/内网/链路本地/元数据地址。
library;

import 'dart:async';
import 'dart:io';

import 'package:url_launcher/url_launcher.dart';

class SecureLinks {
  SecureLinks._();

  static const trustedHosts = <String>{
    'www.dbmt999.asia',
    'dbmt999.asia',
    'www.yosar.cloud',
    'yosar.cloud',
  };

  /// 把外部字符串解析成仅 HTTPS 的 Uri；不符合返回 null。
  static Uri? httpsUri(String raw, {Set<String>? allowedHosts}) {
    final text = raw.trim();
    if (text.isEmpty) return null;
    final uri = Uri.tryParse(text);
    if (uri == null) return null;
    if (uri.scheme.toLowerCase() != 'https') return null;
    if (!uri.hasAuthority || uri.host.isEmpty) return null;
    if (uri.userInfo.isNotEmpty) return null;
    final host = uri.host.toLowerCase();
    if (allowedHosts != null && allowedHosts.isNotEmpty) {
      final allowed = allowedHosts.any(
        (h) => host == h.toLowerCase() || host.endsWith('.${h.toLowerCase()}'),
      );
      if (!allowed) return null;
    }
    return uri;
  }

  /// 只允许 HTTPS 的字符串入口；用于富文本链接等只需要校验的场景。
  static String? httpsUrl(String raw, {Set<String>? allowedHosts}) =>
      httpsUri(raw, allowedHosts: allowedHosts)?.toString();

  /// 系统浏览器打开外链。返回 false 可能是被安全策略拦截，也可能是系统无可用 App。
  static Future<bool> openExternal(
    String raw, {
    Set<String>? allowedHosts,
  }) async {
    final uri = httpsUri(raw, allowedHosts: allowedHosts);
    if (uri == null) return false;
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }

  /// 是否属于社区 API 的受信任 origin（用于附件、清单等必须同源的下载）。
  static bool isTrustedApiOrigin(Uri uri) {
    if (uri.scheme.toLowerCase() != 'https') return false;
    if (uri.userInfo.isNotEmpty) return false;
    final host = uri.host.toLowerCase();
    final api = Uri.tryParse(_apiBase());
    if (api != null && host == api.host.toLowerCase()) return true;
    return trustedHosts.contains(host);
  }

  /// 本地工具 HTTP 出站的准入：仅公网 HTTPS/HTTP，拒绝内网、回环、链路本地与元数据。
  static Future<bool> isPublicHttpUrl(String raw) async {
    final text = raw.trim();
    if (text.isEmpty) return false;
    final uri = Uri.tryParse(text);
    if (uri == null || !uri.hasAuthority || uri.host.isEmpty) return false;
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'https' && scheme != 'http') return false;
    if (uri.userInfo.isNotEmpty) return false;
    if (_isPrivateHostLiteral(uri.host)) return false;
    if (uri.host.toLowerCase() == 'localhost') return false;

    // 域名必须解析后再判断，防止 `public.example` 实际解析到 127.0.0.1。
    try {
      final addresses = await resolvePublic(uri.host);
      if (addresses.isEmpty) return false;
    } catch (_) {
      return false;
    }
    return true;
  }

  /// 解析域名并只返回公网地址；调用方可用它做 DNS pin，避免解析后重绑定。
  static Future<List<InternetAddress>> resolvePublic(String host) async {
    final addresses = await InternetAddress.lookup(host)
        .timeout(const Duration(seconds: 8));
    final public = addresses.where((a) => !_isPrivateAddress(a)).toList();
    if (public.length != addresses.length) {
      throw const FormatException('目标域名解析到非公网地址');
    }
    return public;
  }

  /// HttpClient 的连接工厂：连接前重新解析并固定到已验证的公网 IP，
  /// 这样请求层不会在 DNS 校验之后被重新解析到内网。
  static Future<ConnectionTask<Socket>> connectPublic(
    Uri url,
    String? proxyHost,
    int? proxyPort,
  ) async {
    if (proxyHost != null || proxyPort != null) {
      throw const SocketException('不允许通过代理访问公网工具目标');
    }
    final addresses = await resolvePublic(url.host);
    if (addresses.isEmpty) {
      throw const SocketException('没有可用的公网地址');
    }
    final port = url.hasPort
        ? url.port
        : (url.scheme.toLowerCase() == 'https' ? 443 : 80);
    return Socket.startConnect(addresses.first, port);
  }

  static bool _isPrivateHostLiteral(String host) {
    final h = host.toLowerCase();
    if (h == 'localhost' || h == '0.0.0.0' || h == '::1' || h == '[::1]') {
      return true;
    }
    final ip = InternetAddress.tryParse(host);
    return ip != null && _isPrivateAddress(ip);
  }

  static bool _isPrivateAddress(InternetAddress address) {
    if (address.type == InternetAddressType.IPv6) {
      final h = address.address.toLowerCase();
      if (h == '::' || h == '::1') return true;
      if (h.startsWith('fe80:') || h.startsWith('fec0:')) return true;
      if (h.startsWith('fc') || h.startsWith('fd')) return true;
      if (h.startsWith('ff')) return true;
      if (h.startsWith('::ffff:')) {
        final v4 = InternetAddress.tryParse(h.substring(7));
        return v4 == null || _isPrivateAddress(v4);
      }
      return false;
    }
    final parts = address.address.split('.').map(int.tryParse).toList();
    if (parts.length != 4 || parts.any((p) => p == null)) return true;
    final a = parts[0]!;
    final b = parts[1]!;
    if (a == 0 || a == 127 || a == 169 && b == 254) return true;
    if (a == 10) return true;
    if (a == 172 && b >= 16 && b <= 31) return true;
    if (a == 192 && b == 168) return true;
    if (a == 100 && b >= 64 && b <= 127) return true;
    if (a >= 224) return true;
    return false;
  }

  static String _apiBase() {
    // 不在这个文件里直接 import ApiClient，避免循环依赖；生产基址是公开常量。
    const base = String.fromEnvironment(
      'API_BASE',
      defaultValue: 'https://www.dbmt999.asia/community/api',
    );
    return base;
  }
}
