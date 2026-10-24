/// 主容器：底部导航（复刻音乐 iOS AppTabBar）
/// - 中间位 = 短视频入口（凸起大按钮，等效音乐端"播放控制"在导航中间）
/// - 短视频页沉浸式全屏；切到其他页时返回常规导航
library;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import '../services/notify_bus.dart';
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
  void initState() {
    super.initState();
    _connectWs();
  }

  /// 登录态恢复：拉起 WebSocket 实时通知
  Future<void> _connectWs() async {
    final sp = await SharedPreferences.getInstance();
    final tok = sp.getString('community_token') ?? '';
    if (tok.isNotEmpty) {
      NotifyBus.shared.connect(tok);
    }
  }

  @override
  void dispose() {
    NotifyBus.shared.disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 短视频页：沉浸式全屏（TabBar 半透明悬浮显示，等效音乐端"透明悬浮导航"）
    final isShorts = _tab == 2;
    return Scaffold(
      backgroundColor: const Color(AppTheme.bg),
      body: Stack(
        // 强制所有子组件撑满屏幕，底部导航必然贴底
        fit: StackFit.expand,
        children: [
          // 内容区：五个页面常驻（音乐端三页常驻等价）
          // 非短视频页底部留白，避免悬浮导航遮挡列表最后一项
          Padding(
            padding: EdgeInsets.only(bottom: isShorts ? 0 : 78),
            child: Stack(
              fit: StackFit.expand,
              children: [
                for (var i = 0; i < _pages.length; i++)
                  Offstage(
                    offstage: _tab != i,
                    child: TickerMode(
                      enabled: _tab == i,
                      child: _pages[i],
                    ),
                  ),
              ],
            ),
          ),
          // 底部导航（Positioned 贴底：不吃 StackFit.expand 的 tight 约束，必然贴底；
          // 短视频页沉浸式时保持透明悬浮，透出内容）
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
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
              _tabButtonWithBadge(Icons.notifications_none, Icons.notifications, '消息', 3),
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

  /// 消息 tab：右上角未读红点（复刻音乐端消息小红点）
  Widget _tabButtonWithBadge(
      IconData icon, IconData activeIcon, String label, int index) {
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
              ValueListenableBuilder<int>(
                valueListenable: NotifyBus.shared.unread,
                builder: (_, n, __) => Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Icon(selected ? activeIcon : icon, size: 22, color: color),
                    if (n > 0)
                      Positioned(
                        right: -5,
                        top: -2,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 3, vertical: 1),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFF4D6D),
                            borderRadius: BorderRadius.circular(7),
                          ),
                          constraints: const BoxConstraints(minWidth: 8),
                          child: Text(
                            n > 99 ? '99+' : '$n',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                color: Colors.white, fontSize: 8, height: 1.2),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
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
            // 纯薄荷绿圆钮（复刻音乐 AppTabBar 播放控制钮样式）
            color: const Color(AppTheme.accent),
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: const Color(AppTheme.accent).withOpacity(0.35),
                blurRadius: 12,
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
