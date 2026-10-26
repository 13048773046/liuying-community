/// 流萤社区 · 入口
/// 单代码库 Android/iOS 共用；启动时恢复登录态（token 与音乐互通）
library;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api/client.dart';
import 'config.dart';
import 'pages/feedback/feedback_page.dart';
import 'pages/root_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // 全局渲染兜底：任何页面渲染异常都显示可读错误页（深色+文案），
  // 杜绝"白屏/空白无反馈"。错误页自身必须极简，避免二次异常。
  ErrorWidget.builder = (FlutterErrorDetails details) {
    final msg = details.exceptionAsString();
    return Scaffold(
      backgroundColor: const Color(AppTheme.bg),
      body: Builder(
        builder: (ctx) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline_rounded,
                    color: Color(0xFFFF6B6B), size: 44),
                const SizedBox(height: 14),
                const Text('页面渲染异常，请重启 App',
                    style: TextStyle(
                        color: Color(AppTheme.textPrimary),
                        fontSize: 15,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                const Text('若仍出现请联系开发者反馈',
                    style: TextStyle(
                        color: Color(AppTheme.textTertiary), fontSize: 12)),
                // 显示异常摘要（最多 4 行），便于用户截图反馈、快速定位
                if (msg.trim().isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0x1AFFFFFF),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      msg.trim(),
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: Color(0xFFFF8A8A),
                          fontSize: 11,
                          height: 1.4),
                    ),
                  ),
                ],
                // 一键反馈：把异常摘要预填进意见反馈页，提交后开发者后台可见
                const SizedBox(height: 18),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(AppTheme.accent),
                    side: const BorderSide(color: Color(AppTheme.accent)),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(22)),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 22, vertical: 10),
                  ),
                  onPressed: () {
                    Navigator.of(ctx).push(
                      MaterialPageRoute(
                        builder: (_) => FeedbackPage(
                            initialContent:
                                '【页面渲染异常】${msg.trim()}\n请帮我定位修复'),
                      ),
                    );
                  },
                  icon: const Icon(Icons.feedback_outlined, size: 16),
                  label: const Text('反馈此问题',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  };
  runApp(const CommunityApp());
}

class CommunityApp extends StatelessWidget {
  const CommunityApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '流萤社区',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(AppTheme.bg),
        colorScheme: ColorScheme.dark(
          primary: const Color(AppTheme.accent),
          surface: const Color(AppTheme.bg),
        ),
        fontFamily: null,
      ),
      home: const _Bootstrap(),
    );
  }
}

/// 启动引导：品牌启动页（logo 圆角 + 名称 + 标语，淡入缩放）
/// → 恢复 token → 叠加渐变退出（启动页淡出 + 主界面淡入交叉过渡）
class _Bootstrap extends StatefulWidget {
  const _Bootstrap();

  @override
  State<_Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<_Bootstrap> {
  bool _ready = false;
  bool _appeared = false;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final tok = sp.getString('community_token') ?? '';
      if (tok.isNotEmpty) ApiClient.token = tok;
    } catch (_) {}
    if (!mounted) return;
    setState(() => _ready = true);
  }

  @override
  Widget build(BuildContext context) {
    // 叠加渐变退出：启动页与主界面交叉淡化（启动页淡出 + 主界面淡入重叠）
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 450),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      child: _ready
          ? const RootPage(key: ValueKey('root'))
          : _splash(key: const ValueKey('splash')),
    );
  }

  /// 品牌启动页：与流萤音乐 SplashView 一致（深底 + 圆角 logo + 名称 + 标语）
  Widget _splash({Key? key}) {
    return Scaffold(
      key: key,
      backgroundColor: const Color(AppTheme.bg),
      body: Center(
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0.85, end: 1),
          duration: const Duration(milliseconds: 600),
          curve: Curves.easeOut,
          onEnd: () => setState(() => _appeared = true),
          builder: (_, scale, child) =>
              Opacity(opacity: _appeared ? 1 : 0, child: child),
          child: Transform.scale(
            scale: _appeared ? 1 : 0.85,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 圆角 Logo：缩小版（96，圆角 24），风格与 iOS SplashView 一致
                ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: Image.asset(
                    'assets/logo.png',
                    width: 96,
                    height: 96,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                  ),
                ),
                const SizedBox(height: 22),
                // 名称 + 标语：与 iOS 一致，淡入 + 上浮 10pt
                Opacity(
                  opacity: _appeared ? 1 : 0,
                  child: Transform.translate(
                    offset: Offset(0, _appeared ? 0 : 10),
                    child: Column(
                      children: const [
                        Text('流萤社区',
                            style: TextStyle(
                                color: Color(AppTheme.textPrimary),
                                fontSize: 34,
                                fontWeight: FontWeight.bold)),
                        SizedBox(height: 8),
                        Text('让每一份热爱，如流萤般点亮夜晚',
                            style: TextStyle(
                                color: Color(AppTheme.textSecondary),
                                fontSize: 14)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
