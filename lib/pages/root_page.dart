/// 主容器：贴底通栏导航（96% 黑 + 顶部发丝线 + 中间圆角矩形发布键）
/// - 不再使用悬浮岛：左右贴到屏幕边缘、底边压到屏幕最下方，圆角归零
/// - 中间按钮 74×44、圆角 12、只留「＋」，与四个 tab 同线居中，不上浮
library;

// 底栏改为贴底通栏后不再需要 BackdropFilter

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../api/client.dart';
import '../design/components.dart';
import '../models/feed_item.dart';
import '../services/app_update.dart';
import '../services/hot_update.dart';
import '../services/notify_bus.dart';
import '../services/publish_bus.dart';
import '../services/secure_store.dart';
import '../utils/music_bgm.dart';
import 'boards/boards_page.dart';
import 'home/home_page.dart';
import 'message/message_page.dart';
import 'mine/mine_page.dart';
import 'post/post_editor.dart';
import 'shorts/shorts_page.dart';
import '../widgets/hot_maintenance_page.dart';

/// 底部导航占用高度（不含系统安全区）：图标 24 + 间距 4 + 文字 12 + 上下内边距
const double kTabBarContentH = 58;

class RootPage extends StatefulWidget {
  const RootPage({super.key});

  @override
  State<RootPage> createState() => _RootPageState();
}

class _RootPageState extends State<RootPage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  int _tab = 0; // 0 首页 | 1 版块 | 2 短视频 | 3 消息 | 4 我的
  int? _prevTab; // 切页时上一页保留 180ms，做交叉淡入而不是硬切
  bool _floorOpen = false; // 首页二楼是否展开（展开时隐藏底栏）
  Timer? _startupUpdateTimer;

  late final AnimationController _tabFade =
      AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 180),
      )..addStatusListener((status) {
        if (status == AnimationStatus.completed &&
            mounted &&
            _prevTab != null) {
          setState(() => _prevTab = null);
        }
      });

  void _onTabChanged(int i) {
    if (i == _tab) return;
    // 离开短视频页时停配乐，避免残留播放
    if (_tab == 2) MusicBgm.I.stop();
    setState(() {
      _prevTab = _tab;
      _tab = i;
    });
    _tabFade.forward(from: 0);
  }

  /// 五页懒加载：冷启动只建首页，首次切到某 tab 时才初始化；
  /// 已建过的页面继续保留在 Offstage 中，滚动位置/输入/播放状态不丢。
  final List<Widget?> _pages = List<Widget?>.filled(5, null);

  Widget _buildPage(int i) {
    switch (i) {
      case 0:
        return HomePage(
          onFloorOpenChanged: (v) {
            if (mounted && _floorOpen != v) setState(() => _floorOpen = v);
          },
        );
      case 1:
        return const BoardsPage();
      case 2:
        return const ShortsPage();
      case 3:
        return const MessagePage();
      default:
        return const MinePage();
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 热更新先读本地缓存，再静默拉一次；不阻塞首帧。
    unawaited(HotUpdateService.instance.start());
    HotUpdateService.instance.config.addListener(_onHotConfig);
    _connectWs();
    PublishBus.goHome.addListener(_onPublishGoHome);
    // 首帧后延迟检查更新，避免和启动动画/首屏请求抢资源。
    // 用可取消的 Timer，页面销毁后不能留下一个还在走的 2 秒任务。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _startupUpdateTimer?.cancel();
      _startupUpdateTimer = Timer(const Duration(seconds: 2), () {
        if (!mounted) return;
        AppUpdateService.checkForUpdate(context, startup: true);
      });
    });
  }

  void _onPublishGoHome() {
    if (!mounted) return;
    if (_floorOpen) setState(() => _floorOpen = false);
    _onTabChanged(0);
  }

  /// 远程配置变化：维护模式关掉短视频与配乐，功能开关关掉时把当前页退回首页。
  void _onHotConfig() {
    if (!mounted) return;
    final cfg = HotUpdateService.instance.config.value;
    if (cfg.maintenanceEnabled) {
      MusicBgm.I.stop();
      if (_floorOpen) setState(() => _floorOpen = false);
    }
    if (_tab == 2 && !cfg.featureEnabled('shorts')) {
      _onTabChanged(0);
    }
  }

  /// 登录态恢复：拉起 WebSocket 实时通知
  Future<void> _connectWs() async {
    final tok = await SecureStore.read(SecureStore.tokenKey) ?? '';
    // 读偏好期间用户可能已经退出/切换账号；只允许“当前内存 token”
    // 与磁盘 token 一致时连接，避免退出后又被旧异步任务连回来。
    if (!mounted || tok.isEmpty || ApiClient.token != tok) return;
    NotifyBus.shared.connect(tok);
    unawaited(_syncUnread());
  }

  /// WS 握手现在带互动/私信/官方三类未读；启动时再补一次 REST 兜底，
  /// 避免 WS 尚未建连或断线时底部「消息」总红点漏数。
  Future<void> _syncUnread() async {
    try {
      final n = await ApiClient.notificationsUnread();
      NotifyBus.shared.setUnread(intOf(n['unread']));
      NotifyBus.shared.setOfficialUnread(intOf(n['officialUnread']));
    } catch (_) {}
    try {
      final d = await ApiClient.dmUnread();
      NotifyBus.shared.setDmUnread(intOf(d['unread'] ?? d['count']));
    } catch (_) {}
  }

  @override
  void dispose() {
    _startupUpdateTimer?.cancel();
    PublishBus.goHome.removeListener(_onPublishGoHome);
    HotUpdateService.instance.config.removeListener(_onHotConfig);
    NotifyBus.shared.disconnect();
    _tabFade.dispose();
    super.dispose();
  }

  Widget _pageLayer(
    int i, {
    required bool active,
    required bool interactive,
    double opacity = 1,
  }) {
    final page = TickerMode(
      key: ValueKey('tab_page_$i'),
      enabled: active,
      // 切页淡入淡出只重新合成，不重绘整页内容。
      child: RepaintBoundary(child: _pages[i]!),
    );
    return Offstage(
      offstage: !active,
      child: IgnorePointer(
        ignoring: !interactive,
        // 始终保留同一层 Opacity，不要“透明度到 1 就换成裸 page”。
        // 换父级会让整个页面 Element 重建：首页 feed、滚动位置、输入框、
        // 播放进度全部重来，表现就是切个 tab 页面“重新加载”。
        child: Opacity(
          key: ValueKey('tab_fade_$i'),
          opacity: opacity.clamp(0.0, 1.0),
          child: page,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isShorts = _tab == 2;
    // 当前页首次显示时才初始化；冷启动只打首页一个接口。
    _pages[_tab] ??= _buildPage(_tab);
    final page = ImmersivePage(
      resizeToAvoidBottomInset: false,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 五个页面常驻（保活）。切页时上一页垫在下面淡出，新页淡入，
          // 不是 Offstage 硬切；动画结束后恢复单页可见，避免多层持续合成。
          AnimatedBuilder(
            animation: _tabFade,
            builder: (context, _) {
              final t = Curves.easeOutCubic.transform(_tabFade.value);
              final transitioning = _prevTab != null;
              return Stack(
                fit: StackFit.expand,
                children: [
                  for (var i = 0; i < _pages.length; i++)
                    if (i == _tab)
                      // 新旧两页同时淡：新页 0→1、旧页 1→0，两层叠在一起
                      // 才是交叉溶解；只淡旧页会被不透明的新页整块盖住。
                      _pageLayer(
                        i,
                        active: true,
                        interactive: !transitioning || t > 0.45,
                        opacity: transitioning ? t : 1,
                      )
                    else if (i == _prevTab && _pages[i] != null)
                      _pageLayer(
                        i,
                        active: true,
                        interactive: false,
                        opacity: 1 - t,
                      )
                    else if (_pages[i] != null)
                      _pageLayer(i, active: false, interactive: false),
                ],
              );
            },
          ),
          // 底部导航浮层
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _BottomNav(
              hidden: _floorOpen,
              index: _tab,
              immersive: isShorts,
              onChanged: _onTabChanged,
              onPublish: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const PostEditorPage()),
                );
              },
              onShorts: () => _onTabChanged(2),
            ),
          ),
        ],
      ),
    );
    return ValueListenableBuilder<HotConfig>(
      valueListenable: HotUpdateService.instance.config,
      builder: (context, cfg, child) {
        if (cfg.maintenanceEnabled) return HotMaintenancePage(config: cfg);
        return child!;
      },
      child: page,
    );
  }
}

/// 贴底通栏导航：96% 黑 + 顶部一条发丝线，中间是圆角矩形发布键。
class _BottomNav extends StatelessWidget {
  const _BottomNav({
    this.hidden = false,
    required this.index,
    required this.immersive,
    required this.onChanged,
    required this.onPublish,
    required this.onShorts,
  });

  final bool hidden;
  final int index;
  final bool immersive;
  final ValueChanged<int> onChanged;
  final VoidCallback onPublish;
  final VoidCallback onShorts;

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;

    final bar = SizedBox(
      height: kTabBarContentH,
      child: Row(
        children: [
          _NavItem(
            icon: Icons.home_outlined,
            activeIcon: Icons.home_rounded,
            label: '首页',
            active: index == 0,
            onTap: () => onChanged(0),
          ),
          _NavItem(
            icon: Icons.dashboard_outlined,
            activeIcon: Icons.dashboard_rounded,
            label: '版块',
            active: index == 1,
            onTap: () => onChanged(1),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpace.x2),
            child: _CenterButton(onTap: () => _openCreateMenu(context)),
          ),
          _NavItem(
            icon: Icons.chat_bubble_outline_rounded,
            activeIcon: Icons.chat_bubble_rounded,
            label: '消息',
            active: index == 3,
            onTap: () => onChanged(3),
            badge: NotifyBus.shared.totalUnread,
          ),
          _NavItem(
            icon: Icons.person_outline_rounded,
            activeIcon: Icons.person_rounded,
            label: '我的',
            active: index == 4,
            onTap: () => onChanged(4),
          ),
        ],
      ),
    );

    return IgnorePointer(
      ignoring: hidden,
      child: AnimatedOpacity(
        duration: AppMotion.base,
        opacity: hidden ? 0 : 1,
        child: Container(
          key: const ValueKey('bottom_nav_shell'),
          // 短视频页切到更深的沉浸态：去掉发丝线，画面与导航之间不再有
          // 一条突兀的灰色分隔；其它页保持原来的通栏样式。
          decoration: BoxDecoration(
            color: immersive
                ? const Color(0xF0000000)
                : const Color(0xF5000000),
            border: immersive
                ? null
                : const Border(
                    top: BorderSide(color: Color(AppColors.border), width: 1),
                  ),
          ),
          child: Padding(
            padding: EdgeInsets.only(bottom: bottom),
            child: bar,
          ),
        ),
      ),
    );
  }

  /// 「＋」展开创作入口：发一帖 / 刷短视频，避免静默丢掉短视频入口。
  void _openCreateMenu(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(AppColors.canvas),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(top: 10, bottom: 6),
              decoration: BoxDecoration(
                color: const Color(0xFF313136),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            if (HotUpdateService.instance.config.value.featureEnabled('post'))
              _CreateEntry(
                icon: Icons.edit_rounded,
                title: '发一帖',
                subtitle: '图文或视频，发布到社区',
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  onPublish();
                },
              ),
            if (HotUpdateService.instance.config.value.featureEnabled('post') &&
                HotUpdateService.instance.config.value.featureEnabled('shorts'))
              const Divider(height: 1, color: Color(AppColors.hairline)),
            if (HotUpdateService.instance.config.value.featureEnabled('shorts'))
              _CreateEntry(
                icon: Icons.play_circle_outline_rounded,
                title: '刷短视频',
                subtitle: '沉浸播放，上滑切换',
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  onShorts();
                },
              ),
            if (!HotUpdateService.instance.config.value.featureEnabled(
                  'post',
                ) &&
                !HotUpdateService.instance.config.value.featureEnabled(
                  'shorts',
                ))
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 22),
                child: Text(
                  '创作入口暂时关闭，稍后再来看看。',
                  style: AppType.caption.copyWith(
                    color: const Color(AppColors.textTertiary),
                  ),
                ),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

/// 创作面板里的一行。
class _CreateEntry extends StatelessWidget {
  const _CreateEntry({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return PressableScale(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(AppSpace.x5, 14, AppSpace.x5, 14),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: const Color(AppColors.accentSoft),
                borderRadius: AppRadius.rMd,
              ),
              child: Icon(icon, size: 20, color: const Color(AppColors.accent)),
            ),
            const SizedBox(width: AppSpace.x3),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: AppType.body.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: AppType.micro.copyWith(
                    color: const Color(AppColors.textTertiary),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.active,
    required this.onTap,
    this.badge,
  });

  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool active;
  final VoidCallback onTap;
  final ValueListenable<int>? badge;

  @override
  Widget build(BuildContext context) {
    final color = active
        ? const Color(AppColors.textPrimary)
        : const Color(AppColors.textTertiary);

    Widget iconWidget = Icon(
      active ? activeIcon : icon,
      size: 23,
      color: color,
    );

    if (badge != null) {
      iconWidget = ValueListenableBuilder<int>(
        valueListenable: badge!,
        builder: (_, n, child) => Stack(
          clipBehavior: Clip.none,
          children: [
            child!,
            if (n > 0)
              Positioned(
                right: -9,
                top: -6,
                child: CountBadge(count: n, large: true),
              ),
          ],
        ),
        child: iconWidget,
      );
    }

    return Expanded(
      child: PressableScale(
        onTap: onTap,
        scale: 0.9,
        child: SizedBox(
          height: kTabBarContentH,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedScale(
                scale: active ? 1.06 : 1.0,
                duration: AppMotion.base,
                curve: AppMotion.emphasized,
                child: AnimatedSwitcher(
                  duration: AppMotion.fast,
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  // Icon 本身没有 key 时 AnimatedSwitcher 会原地换图标、硬切；
                  // 用 active 作为 key，实心/描边两枚图标才会真正交叉淡入。
                  child: KeyedSubtree(
                    key: ValueKey('nav_icon_${label}_$active'),
                    child: iconWidget,
                  ),
                ),
              ),
              const SizedBox(height: 3),
              AnimatedDefaultTextStyle(
                duration: AppMotion.fast,
                style: TextStyle(
                  // AnimatedDefaultTextStyle 不会自动继承外层 DefaultTextStyle 的
                  // 字体回退链；显式带上，中文 tab 名在自定义字体/测试字体下也不会变方框。
                  fontFamily: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.fontFamily,
                  fontFamilyFallback: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.fontFamilyFallback,
                  fontSize: 10,
                  height: 1.1,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                  color: color,
                  letterSpacing: 0.2,
                ),
                child: Text(label),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 中间按钮：74×44 圆角矩形，只留「＋」，与四个 tab 同线居中、不上浮。
class _CenterButton extends StatelessWidget {
  const _CenterButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return PressableScale(
      onTap: onTap,
      scale: 0.94,
      child: Container(
        width: 74,
        height: 44,
        decoration: BoxDecoration(
          color: const Color(AppColors.accent),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(
          Icons.add_rounded,
          color: Color(AppColors.onAccent),
          size: 22,
        ),
      ),
    );
  }
}
