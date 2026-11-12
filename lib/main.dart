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

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 全站默认竖屏；进入「流萤航线」时由该页强制切横屏，退出时恢复竖屏
  await SystemChrome.setPreferredOrientations(
      const [DeviceOrientation.portraitUp]);
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
  // runApp 前恢复登录态（原生启动屏已覆盖这段等待），首帧即主界面，不再有 Flutter 启动页
  try {
    final sp = await SharedPreferences.getInstance();
    final tok = sp.getString('community_token') ?? '';
    if (tok.isNotEmpty) ApiClient.token = tok;
  } catch (_) {}
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
      home: const RootPage(),
    );
  }
}
