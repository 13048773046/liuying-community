/// 流萤社区 · 入口
/// 单代码库 Android/iOS 共用；启动时恢复登录态（token 与音乐互通）
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api/client.dart';
import 'design/components.dart';
import 'pages/feedback/feedback_page.dart';
import 'pages/root_page.dart';
import 'services/app_route_observer.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // 沉浸式：内容延伸到系统栏下方，状态栏/导航栏全透明
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    statusBarBrightness: Brightness.dark,
    systemNavigationBarColor: Color(AppColors.bg),
    systemNavigationBarIconBrightness: Brightness.light,
    systemNavigationBarDividerColor: Colors.transparent,
  ));
  // 全局渲染兜底：任何页面渲染异常都显示可读错误页（深色+文案），
  // 杜绝"白屏/空白无反馈"。错误页自身必须极简，避免二次异常。
  ErrorWidget.builder = (FlutterErrorDetails details) {
    final msg = details.exceptionAsString();
    return ImmersivePage(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.x6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(AppColors.danger).withValues(alpha: 0.12),
                ),
                child: const Icon(Icons.error_outline_rounded,
                    color: Color(AppColors.danger), size: 30),
              ),
              const SizedBox(height: AppSpace.x4),
              Text('页面渲染异常，请重启 App',
                  style: AppType.title.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Text('若仍出现请联系开发者反馈', style: AppType.caption),
              if (msg.trim().isNotEmpty) ...[
                const SizedBox(height: AppSpace.x4),
                Container(
                  padding: const EdgeInsets.all(AppSpace.x3),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.05),
                    borderRadius: AppRadius.rSm,
                    border: Border.all(color: const Color(AppColors.border)),
                  ),
                  child: Text(
                    msg.trim(),
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: AppType.micro.copyWith(
                        color: const Color(AppColors.danger), height: 1.4),
                  ),
                ),
              ],
              const SizedBox(height: AppSpace.x5),
              PillButton(
                label: '反馈此问题',
                icon: Icons.feedback_outlined,
                size: PillSize.sm,
                variant: PillVariant.ghost,
                onTap: () {
                  final ctx = AppRouterHolder.context;
                  if (ctx == null) return;
                  Navigator.of(ctx).push(
                    MaterialPageRoute(
                      builder: (_) => FeedbackPage(
                          initialContent:
                              '【页面渲染异常】${msg.trim()}\n请帮我定位修复'),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  };
  runApp(const CommunityApp());
}

/// 全局 context 持有（ErrorWidget 里没有 Scaffold/context，用它兜底导航）。
class AppRouterHolder {
  static BuildContext? context;
}

class CommunityApp extends StatelessWidget {
  const CommunityApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '流萤社区',
      debugShowCheckedModeBanner: false,
      theme: buildImmersiveTheme(),
      // 路由观察者：短视频页被详情页盖住时暂停播放/配音（见 VideoCard）
      navigatorObservers: [appRouteObserver],
      builder: (ctx, child) {
        AppRouterHolder.context = ctx;
        // 锁定系统字号缩放上限，避免超大字号撑破沉浸式版式
        final scale = MediaQuery.textScalerOf(ctx).clamp(
          minScaleFactor: 0.9,
          maxScaleFactor: 1.15,
        );
        return MediaQuery(
          data: MediaQuery.of(ctx).copyWith(textScaler: scale),
          child: child ?? const SizedBox.shrink(),
        );
      },
      home: const _Bootstrap(),
    );
  }
}

/// 启动引导：品牌启动页 → 恢复 token → 交叉淡化进入主界面。
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
    // 最短展示 420ms，避免闪屏
    await Future<void>.delayed(const Duration(milliseconds: 420));
    if (!mounted) return;
    setState(() => _ready = true);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 380),
      switchInCurve: AppMotion.enter,
      switchOutCurve: AppMotion.exit,
      child: _ready
          ? const RootPage(key: ValueKey('root'))
          : const SplashScreen(key: ValueKey('splash')),
    );
  }
}

/// 品牌启动页：纯黑 + 薄荷光晕 + 圆角 Logo + 名称标语。
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  )..forward();

  late final Animation<double> _fade =
      CurvedAnimation(parent: _c, curve: Curves.easeOut);
  late final Animation<double> _rise = Tween<double>(begin: 14, end: 0)
      .animate(CurvedAnimation(parent: _c, curve: AppMotion.emphasized));
  late final Animation<double> _scale = Tween<double>(begin: 0.92, end: 1)
      .animate(CurvedAnimation(parent: _c, curve: Curves.easeOutBack));

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ImmersivePage(
      child: Stack(
        children: [
          // 顶部薄荷光晕
          Positioned(
            top: -140,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: Container(
                height: 320,
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: Alignment.topCenter,
                    radius: 0.9,
                    colors: [
                      const Color(AppColors.accent).withValues(alpha: 0.18),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
          ),
          Center(
            child: AnimatedBuilder(
              animation: _c,
              builder: (_, _) => Opacity(
                opacity: _fade.value,
                child: Transform.translate(
                  offset: Offset(0, _rise.value),
                  child: Transform.scale(
                    scale: _scale.value,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(26),
                            boxShadow: [
                              BoxShadow(
                                color: const Color(AppColors.accent)
                                    .withValues(alpha: 0.25),
                                blurRadius: 40,
                                spreadRadius: 2,
                              ),
                            ],
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(26),
                            child: Image.asset(
                              'assets/logo.png',
                              width: 92,
                              height: 92,
                              fit: BoxFit.cover,
                              gaplessPlayback: true,
                            ),
                          ),
                        ),
                        const SizedBox(height: AppSpace.x6),
                        const Text('流萤社区',
                            style: TextStyle(
                              fontSize: 28,
                              height: 1.1,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 2,
                              color: Color(AppColors.textPrimary),
                            )),
                        const SizedBox(height: AppSpace.x2),
                        Text(
                          '让每一份热爱，如流萤般点亮夜晚',
                          style: AppType.caption.copyWith(letterSpacing: 1.2),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 40 + MediaQuery.paddingOf(context).bottom,
            child: AnimatedBuilder(
              animation: _fade,
              builder: (_, _) => Opacity(
                opacity: _fade.value * 0.6,
                child: Center(
                  child: Text('LIUYING COMMUNITY',
                      style: AppType.micro.copyWith(letterSpacing: 3)),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
