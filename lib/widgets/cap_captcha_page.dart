import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../api/client.dart';
import '../design/tokens.dart';

/// Cap 自托管人机验证容器。
///
/// 页面由社区服务端 `/captcha/cap-page` 同源输出，WebView 内运行
/// PoW + instrumentation；通过 `CapCaptchaBridge` 只回传一次性 token。
/// 浏览器/无头自动化在服务端会被 instrumentation 拒绝，客户端不参与判定。
class CapCaptchaPage extends StatefulWidget {
  const CapCaptchaPage({super.key});

  @override
  State<CapCaptchaPage> createState() => _CapCaptchaPageState();
}

class _CapCaptchaPageState extends State<CapCaptchaPage> {
  late final WebViewController _controller;
  bool _loading = true;
  String? _error;
  bool _finished = false;

  String get _pageUrl => '${ApiClient.baseUrl}/captcha/cap-page';

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFFF7F4E9))
      ..addJavaScriptChannel(
        'CapCaptchaBridge',
        onMessageReceived: _onJsMessage,
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) {
            if (!mounted) return;
            setState(() => _loading = true);
          },
          onPageFinished: (_) {
            if (!mounted) return;
            setState(() => _loading = false);
          },
          onWebResourceError: (error) {
            if (!mounted) return;
            if (error.isForMainFrame == false) return;
            setState(() {
              _loading = false;
              _error = '安全验证页面加载失败，请检查网络后重试';
            });
          },
          onNavigationRequest: _onNavigation,
        ),
      )
      ..loadRequest(Uri.parse(_pageUrl));
  }

  NavigationDecision _onNavigation(NavigationRequest request) {
    final uri = Uri.tryParse(request.url);
    if (uri == null) return NavigationDecision.prevent;
    if (uri.scheme == 'about') return NavigationDecision.navigate;
    final allowedHost = Uri.parse(ApiClient.baseUrl).host.toLowerCase();
    return uri.host.toLowerCase() == allowedHost
        ? NavigationDecision.navigate
        : NavigationDecision.prevent;
  }

  void _onJsMessage(JavaScriptMessage message) {
    if (_finished || !mounted) return;
    Map<String, dynamic> data;
    try {
      data = jsonDecode(message.message) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final token = (data['token'] ?? '').toString().trim();
    if (token.isNotEmpty) {
      _finished = true;
      Navigator.of(context).pop(CaptchaAnswer.cap(capToken: token));
      return;
    }
    final error = (data['error'] ?? '').toString().trim();
    if (error.isNotEmpty) {
      setState(() => _error = error);
    }
  }

  void _retry() {
    setState(() {
      _error = null;
      _loading = true;
    });
    _controller.reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F4E9),
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: WebViewWidget(controller: _controller),
            ),
            if (_loading)
              const Positioned.fill(
                child: ColoredBox(
                  color: Color(0xFFF7F4E9),
                  child: Center(
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Color(AppColors.accent),
                      ),
                    ),
                  ),
                ),
              ),
            if (_error != null)
              Positioned.fill(
                child: ColoredBox(
                  color: const Color(0xFFF7F4E9),
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(28),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.wifi_off_rounded, size: 34, color: Color(AppColors.textTertiary)),
                          const SizedBox(height: 12),
                          Text(
                            _error!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Color(AppColors.textSecondary), height: 1.5),
                          ),
                          const SizedBox(height: 14),
                          FilledButton(
                            onPressed: _retry,
                            style: FilledButton.styleFrom(
                              backgroundColor: const Color(AppColors.accent),
                              foregroundColor: const Color(AppColors.onAccent),
                            ),
                            child: const Text('重试'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            Positioned(
              top: 8,
              right: 8,
              child: Material(
                color: Colors.transparent,
                child: IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded),
                  color: const Color(AppColors.textPrimary),
                  style: IconButton.styleFrom(
                    backgroundColor: const Color(0xCCFFFFFF),
                    shape: const CircleBorder(),
                  ),
                  tooltip: '取消',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
