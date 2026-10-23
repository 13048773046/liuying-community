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

/// 启动引导：恢复本地 token → 进入主界面
class _Bootstrap extends StatefulWidget {
  const _Bootstrap();

  @override
  State<_Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<_Bootstrap> {
  bool _ready = false;

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
      return const Scaffold(
        backgroundColor: Color(AppTheme.bg),
        body: Center(
          child: SizedBox(
            width: 26,
            height: 26,
            child: CircularProgressIndicator(
                strokeWidth: 2.5, color: Color(AppTheme.accent)),
          ),
        ),
      );
    }
    return const RootPage();
  }
}
