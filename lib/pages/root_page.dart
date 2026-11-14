/// 主容器：沉浸式底部导航（纯黑透明浮层 + 中间凸起短视频/发布按钮）
/// - 短视频页全屏沉浸，导航栏浮在内容之上（底部渐变遮罩保证可读）
/// - 其余页面导航栏为半透明玻璃条，顶部 0.5 描边
library;

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../design/components.dart';
import '../services/notify_bus.dart';
import '../utils/music_bgm.dart';
import 'boards/boards_page.dart';
import 'home/home_page.dart';
import 'message/message_page.dart';
import 'mine/mine_page.dart';
import 'post/post_editor.dart';
import 'shorts/shorts_page.dart';

/// 底部导航占用高度（不含系统安全区）：图标 24 + 间距 4 + 文字 12 + 上下内边距
const double kTabBarContentH = 58;

class RootPage extends StatefulWidget {
  const RootPage({super.key});

  @override
  State<RootPage> createState() => _RootPageState();
}

class _RootPageState extends State<RootPage> {
  int _tab = 0; // 0 首页 | 1 版块 | 2 短视频 | 3 消息 | 4 我的

  void _onTabChanged(int i) {
    if (i == _tab) return;
    // 离开短视频页时停配乐，避免残留播放
    if (_tab == 2) MusicBgm.I.stop();
    setState(() => _tab = i);
  }

  static const _pages = <Widget>[
    HomePage(),
    BoardsPage(),
    ShortsPage(),
    MessagePage(),
    MinePage(),
  ];

  @override
  void initState() {
    super.initState();
    _connectWs();
  }

  /// 登录态恢复：拉起 WebSocket 实时通知
  Future<void> _connectWs() async {
    final sp = await SharedPreferences.getInstance();
    final tok = sp.getString('community_token') ?? '';
    if (tok.isNotEmpty) NotifyBus.shared.connect(tok);
  }

  @override
  void dispose() {
    NotifyBus.shared.disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isShorts = _tab == 2;
    return ImmersivePage(
      resizeToAvoidBottomInset: false,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 五个页面常驻（保活），只切可见性
          for (var i = 0; i < _pages.length; i++)
            Offstage(
              offstage: _tab != i,
              child: TickerMode(enabled: _tab == i, child: _pages[i]),
            ),
          // 底部导航浮层
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _BottomNav(
              index: _tab,
              immersive: isShorts,
              onChanged: _onTabChanged,
              onPublish: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const PostEditorPage()),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// 沉浸式底部导航：非短视频页为毛玻璃条，短视频页全透明只留渐变。
class _BottomNav extends StatelessWidget {
  const _BottomNav({
    required this.index,
    required this.immersive,
    required this.onChanged,
    required this.onPublish,
  });

  final int index;
  final bool immersive;
  final ValueChanged<int> onChanged;
  final VoidCallback onPublish;

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;

    final bar = Container(
      height: kTabBarContentH,
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.x2),
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
          Expanded(
            child: Center(
              child: _CenterButton(
                active: immersive,
                onTap: immersive ? onPublish : () => onChanged(2),
              ),
            ),
          ),
          _NavItem(
            icon: Icons.chat_bubble_outline_rounded,
            activeIcon: Icons.chat_bubble_rounded,
            label: '消息',
            active: index == 3,
            onTap: () => onChanged(3),
            badge: NotifyBus.shared.unread,
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

    return Container(
      decoration: BoxDecoration(
        gradient: immersive
            ? AppEffects.navScrimDark
            : const LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [Color(0xF7FAF8F4), Color(0xE6FAF8F4)],
              ),
        border: immersive
            ? null
            : const Border(top: BorderSide(color: Color(AppColors.hairline))),
      ),
      child: ClipRect(
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(
            sigmaX: immersive ? 0.001 : 22,
            sigmaY: immersive ? 0.001 : 22,
          ),
          child: Padding(
            padding: EdgeInsets.only(bottom: bottom),
            child: bar,
          ),
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

    Widget iconWidget = Icon(active ? activeIcon : icon, size: 23, color: color);

    if (badge != null) {
      iconWidget = ValueListenableBuilder<int>(
        valueListenable: badge!,
        builder: (_, n, child) => Stack(
          clipBehavior: Clip.none,
          children: [
            child!,
            if (n > 0)
              Positioned(right: -7, top: -4, child: CountBadge(count: n)),
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
              AnimatedSwitcher(
                duration: AppMotion.fast,
                child: iconWidget,
              ),
              const SizedBox(height: 3),
              AnimatedDefaultTextStyle(
                duration: AppMotion.fast,
                style: TextStyle(
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

/// 中间按钮：薄荷绿圆钮（短视频入口 / 页内变「发布」）。
class _CenterButton extends StatelessWidget {
  const _CenterButton({required this.active, required this.onTap});

  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return PressableScale(
      onTap: onTap,
      scale: 0.9,
      child: AnimatedContainer(
        key: const ValueKey('shortsCenterBtn'),
        duration: AppMotion.base,
        width: 52,
        height: 34,
        decoration: BoxDecoration(
          color: const Color(AppColors.accent),
          borderRadius: BorderRadius.circular(12),
          boxShadow: AppEffects.accentGlow(opacity: 0.35),
        ),
        child: AnimatedSwitcher(
          duration: AppMotion.fast,
          child: Icon(
            active ? Icons.add_rounded : Icons.play_arrow_rounded,
            key: ValueKey(active),
            color: const Color(AppColors.onAccent),
            size: active ? 22 : 26,
          ),
        ),
      ),
    );
  }
}
