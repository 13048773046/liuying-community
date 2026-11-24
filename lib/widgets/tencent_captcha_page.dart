import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../api/client.dart';
import '../design/tokens.dart';

/// 腾讯云验证码（滑动拼图）容器。
///
/// 腾讯官方要求 App 端通过 WebView 加载 H5 接入；页面由社区服务端
/// `/captcha/page` 输出，域名与 H5 同源，避免 about:blank 的域名校验问题。
/// JS 回调通过 `TencentCaptchaBridge` 回传 ticket / randstr。
class TencentCaptchaPage extends StatefulWidget {
  const TencentCaptchaPage({super.key});

  @override
  State<TencentCaptchaPage> createState() => _TencentCaptchaPageState();
}

class _TencentCaptchaPageState extends State<TencentCaptchaPage> {
  late final WebViewController _controller;
  bool _loading = true;
  String? _error;
  bool _finished = false;

  String get _pageUrl => '${ApiClient.baseUrl}/captcha/page';

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF0B0B0C))
      ..addJavaScriptChannel(
        'TencentCaptchaBridge',
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
              _error = '验证码页面加载失败，请检查网络后重试';
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
    final host = uri.host.toLowerCase();
    final allowed = host == 'captcha.qq.com' ||
        host.endsWith('.captcha.qq.com') ||
        host == 'ssl.captcha.qq.com' ||
        host == Uri.parse(ApiClient.baseUrl).host.toLowerCase();
    return allowed ? NavigationDecision.navigate : NavigationDecision.prevent;
  }

  void _onJsMessage(JavaScriptMessage message) {
    if (_finished || !mounted) return;
    Map<String, dynamic> data;
    try {
      data = jsonDecode(message.message) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final ret = int.tryParse('${data['ret']}') ?? -1;
    if (ret == 0) {
      final ticket = (data['ticket'] ?? '').toString();
      final randstr = (data['randstr'] ?? '').toString();
      if (ticket.isEmpty || randstr.isEmpty) {
        setState(() => _error = '验证结果异常，请重试');
        return;
      }
      _finished = true;
      Navigator.of(context).pop(
        CaptchaAnswer.tencent(ticket: ticket, randstr: randstr),
      );
      return;
    }
    if (ret == 2) {
      // 用户主动关闭验证码，不当作错误。
      return;
    }
    setState(() {
      _error = (data['errorMessage'] ?? '验证未通过，请重试').toString();
    });
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
      backgroundColor: const Color(0xFF0B0B0C),
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: WebViewWidget(controller: _controller),
            ),
            if (_loading)
              const Positioned.fill(
                child: IgnorePointer(
                  child: ColoredBox(
                    color: Color(0xFF0B0B0C),
                    child: Center(
                      child: SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Color(AppColors.accent),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            if (_error != null)
              Positioned.fill(
                child: ColoredBox(
                  color: const Color(0xE6000000),
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.cloud_off_rounded,
                            color: Color(AppColors.textTertiary),
                            size: 34,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            _error!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Color(AppColors.textSecondary),
                              fontSize: 13,
                              height: 1.6,
                            ),
                          ),
                          const SizedBox(height: 16),
                          FilledButton(
                            onPressed: _retry,
                            style: FilledButton.styleFrom(
                              backgroundColor: const Color(AppColors.accent),
                              foregroundColor: const Color(AppColors.onAccent),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            child: const Text('重新加载'),
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
                color: const Color(0x99000000),
                shape: const CircleBorder(),
                child: IconButton(
                  tooltip: '关闭',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(
                    Icons.close_rounded,
                    color: Colors.white,
                    size: 20,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
