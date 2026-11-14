/// 主容器：贴底通栏导航（96% 黑 + 顶部发丝线 + 中间圆角矩形发布键）
/// - 不再使用悬浮岛：左右贴到屏幕边缘、底边压到屏幕最下方，圆角归零
/// - 中间按钮 74×44、圆角 12、只留「＋」，与四个 tab 同线居中，不上浮
library;

// 底栏改为贴底通栏后不再需要 BackdropFilter

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
              onShorts: () => _onTabChanged(2),
            ),
          ),
        ],
      ),
    );
  }
}

/// 贴底通栏导航：96% 黑 + 顶部一条发丝线，中间是圆角矩形发布键。
class _BottomNav extends StatelessWidget {
  const _BottomNav({
    required this.index,
    required this.immersive,
    required this.onChanged,
    required this.onPublish,
    required this.onShorts,
  });

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
            child: _CenterButton(
              onTap: () => _openCreateMenu(context),
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
      decoration: const BoxDecoration(
        color: Color(0xF5000000),
        border: Border(top: BorderSide(color: Color(AppColors.border), width: 1)),
      ),
      child: Padding(
        padding: EdgeInsets.only(bottom: bottom),
        child: bar,
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
            _CreateEntry(
              icon: Icons.edit_rounded,
              title: '发一帖',
              subtitle: '图文或视频，发布到社区',
              onTap: () {
                Navigator.of(sheetContext).pop();
                onPublish();
              },
            ),
            const Divider(height: 1, color: Color(AppColors.hairline)),
            _CreateEntry(
              icon: Icons.play_circle_outline_rounded,
              title: '刷短视频',
              subtitle: '沉浸播放，上滑切换',
              onTap: () {
                Navigator.of(sheetContext).pop();
                onShorts();
              },
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
                Text(title, style: AppType.body.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 3),
                Text(subtitle, style: AppType.micro.copyWith(color: const Color(AppColors.textTertiary))),
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
              AnimatedScale(
                scale: active ? 1.06 : 1.0,
                duration: AppMotion.base,
                curve: AppMotion.emphasized,
                child: AnimatedSwitcher(
                  duration: AppMotion.fast,
                  child: iconWidget,
                ),
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
