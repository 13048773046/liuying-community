/// 主容器：底部导航（复刻音乐 iOS AppTabBar）
/// - 中间位 = 短视频入口（凸起大按钮，等效音乐端"播放控制"在导航中间）
/// - 短视频页沉浸式全屏；切到其他页时返回常规导航
library;

import 'package:flutter/material.dart';

import '../config.dart';
import 'home/home_page.dart';
import 'message/message_page.dart';
import 'mine/mine_page.dart';
import 'boards/boards_page.dart';
import 'shorts/shorts_page.dart';

class RootPage extends StatefulWidget {
  const RootPage({super.key});

  @override
  State<RootPage> createState() => _RootPageState();
}

class _RootPageState extends State<RootPage> {
  int _tab = 0; // 0 首页 | 1 版块 | 2 短视频(中间) | 3 消息 | 4 我的

  static const _pages = <Widget>[
    HomePage(),
    BoardsPage(),
    ShortsPage(),
    MessagePage(),
    MinePage(),
  ];

  @override
  Widget build(BuildContext context) {
    // 短视频页：沉浸式全屏（TabBar 半透明悬浮显示，等效音乐端"透明悬浮导航"）
    final isShorts = _tab == 2;
    return Scaffold(
      backgroundColor: isShorts ? const Color(AppTheme.bg) : const Color(AppTheme.bg),
      body: Stack(
        children: [
          // 内容区：五个页面常驻（音乐端三页常驻等价）
          for (var i = 0; i < _pages.length; i++)
            Offstage(
              offstage: _tab != i,
              child: TickerMode(
                enabled: _tab == i,
                child: _pages[i],
              ),
            ),
          // 底部导航（透明悬浮，短视频页透出内容）
          Align(
            alignment: Alignment.bottomCenter,
            child: _ShortsSelectionScope(
              selection: _tab,
              onChanged: (i) => setState(() => _tab = i),
              child: _AppTabBar(
                selection: _tab,
                onChanged: (i) => setState(() => _tab = i),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 底部导航：5 格，中间凸起短视频按钮
class _AppTabBar extends StatelessWidget {
  final int selection;
  final ValueChanged<int> onChanged;
  const _AppTabBar({required this.selection, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: selection == 2
            ? Colors.transparent
            : const Color(AppTheme.card).withOpacity(0.98),
        border: selection == 2
            ? null
            : const Border(top: BorderSide(color: Color(AppTheme.border), width: 0.5)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 4),
          child: Row(
            children: [
              _tabButton(Icons.home_outlined, Icons.home, '首页', 0),
              _tabButton(Icons.grid_view_outlined, Icons.grid_view, '版块', 1),
              const _ShortsCenterButton(),
              _tabButton(Icons.notifications_none, Icons.notifications, '消息', 3),
              _tabButton(Icons.person_outline, Icons.person, '我的', 4),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tabButton(IconData icon, IconData activeIcon, String label, int index) {
    final selected = selection == index;
    final color = selected
        ? const Color(AppTheme.accent)
        : const Color(AppTheme.textSecondary);
    return Expanded(
      child: InkWell(
        onTap: () => onChanged(index),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(selected ? activeIcon : icon, size: 22, color: color),
              const SizedBox(height: 2),
              Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 10.5,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 中间短视频按钮：凸起圆钮（复刻音乐端播放控制圆钮）
class _ShortsCenterButton extends StatelessWidget {
  const _ShortsCenterButton();

  @override
  Widget build(BuildContext context) {
    // 中间凸起按钮：样式固定，选中态由父级重建驱动
    return const SizedBox(width: 64, child: _ShortsButtonInner());
  }
}

class _ShortsButtonInner extends StatelessWidget {
  const _ShortsButtonInner();

  @override
  Widget build(BuildContext context) {
    // 读取父级选中态（通过自定义 Inherited 不可靠，用静态通道）
    final sel = _ShortsSelectionScope.of(context)?.selection ?? 0;
    final isActive = sel == 2;
    return Center(
      child: GestureDetector(
        onTap: () {
          _ShortsSelectionScope.of(context)?.onChanged(2);
        },
        child: Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(AppTheme.gradStart), Color(AppTheme.gradEnd)],
            ),
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: const Color(AppTheme.accent).withOpacity(0.45),
                blurRadius: 14,
                spreadRadius: 1,
              ),
            ],
          ),
          child: Icon(
            isActive ? Icons.ondemand_video : Icons.play_arrow_rounded,
            color: Colors.white,
            size: isActive ? 22 : 26,
          ),
        ),
      ),
    );
  }
}

/// 轻量 InheritedWidget：中间按钮读取选中态并触发切换
class _ShortsSelectionScope extends InheritedWidget {
  final int selection;
  final ValueChanged<int> onChanged;
  const _ShortsSelectionScope({
    required this.selection,
    required this.onChanged,
    required super.child,
  });

  static _ShortsSelectionScope? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_ShortsSelectionScope>();

  @override
  bool updateShouldNotify(_ShortsSelectionScope old) =>
      old.selection != selection;
}
