/// 流萤社区 · 入口
/// 单代码库 Android/iOS 共用；启动时恢复登录态（token 与音乐互通）
library;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api/client.dart';
import 'config.dart';
import 'pages/root_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
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

/// 启动引导：展示品牌启动页（logo 圆角 + 名称 + 副标题，淡入缩放）→ 恢复 token → 进入主界面
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
    if (!_ready) {
      // 品牌启动页：与流萤音乐 SplashView 一致（深底 + 圆角 logo + 名称副标题）
      return Scaffold(
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
    return const RootPage();
  }
}
