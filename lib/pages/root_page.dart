/// 主容器：底部导航（复刻音乐 iOS AppTabBar）
/// - 中间位 = 短视频入口（凸起大按钮，等效音乐端"播放控制"在导航中间）
/// - 短视频页沉浸式全屏；切到其他页时返回常规导航
library;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import '../services/notify_bus.dart';
import '../utils/music_bgm.dart';
import 'home/home_page.dart';
import 'message/message_page.dart';
import 'mine/mine_page.dart';
import 'boards/boards_page.dart';
import 'post/post_editor.dart';
import 'shorts/shorts_page.dart';

/// 底部导航内容区高度（不含系统 safeBottom）：图标23+间距2+文字13+内边距12+外Padding10=60
/// 内容区底部留白必须与此一致，否则导航栏上方会露出缝隙或被遮住
const double kTabBarContentH = 60;

class RootPage extends StatefulWidget {
  const RootPage({super.key});

  @override
  State<RootPage> createState() => _RootPageState();
}

class _RootPageState extends State<RootPage> {
  int _tab = 0; // 0 首页 | 1 版块 | 2 短视频(中间) | 3 消息 | 4 我的

  /// 切 tab：离开短视频页时停配乐，避免残留播放
  void _onTabChanged(int i) {
    if (_tab == 2 && i != 2) {
      MusicBgm.I.stop();
    }
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
      // 修复：禁用键盘避让（resizeToAvoidBottomInset: false）
      // iOS 键盘弹出时默认会压缩 Scaffold body（812pt→约430pt），
      // 导致 Positioned(bottom:0) 的底部导航被顶到屏幕中部并盖住内容；
      // RootPage 自身无输入框，键盘避让由 push 出的登录/发布/评论页各自处理。
      resizeToAvoidBottomInset: false,
      body: Stack(
        // 强制所有子组件撑满屏幕，底部导航必然贴底
        fit: StackFit.expand,
        children: [
          // 内容区：五个页面常驻（音乐端三页常驻等价）
          // 不做整体底部抬升：页面背景可延伸至屏幕底部（穿过导航栏区域），
          // 内容本身由各页面滚动容器用「导航栏高度 tabBarBottomInset」动态避让，
          // 既不被导航栏遮挡也不留下空白缝隙
          Stack(
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
          // 底部导航（Positioned 贴底：不吃 StackFit.expand 的 tight 约束，必然贴底；
          // 短视频页沉浸式时保持透明悬浮，透出内容）
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _ShortsSelectionScope(
              selection: _tab,
              onChanged: _onTabChanged,
              child: _AppTabBar(
                selection: _tab,
                onChanged: _onTabChanged,
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
              _tabButton('assets/icons/home.svg', '首页', 0),
              _tabButton('assets/icons/compass.svg', '版块', 1),
              const _ShortsCenterButton(),
              _tabButtonWithBadge('assets/icons/chatbubbles.svg', '消息', 3),
              _tabButton('assets/icons/person.svg', '我的', 4),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tabButton(String asset, String label, int index) {
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
              SvgPicture.asset(
                asset,
                width: 23,
                height: 23,
                colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
              ),
              const SizedBox(height: 2),
              SizedBox(
                height: 13,
                child: Text(
                  label,
                  style: TextStyle(
                    color: color,
                    fontSize: 10.5,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 消息 tab：右上角未读红点（复刻音乐端消息小红点）
  Widget _tabButtonWithBadge(String asset, String label, int index) {
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
                    SvgPicture.asset(
                      asset,
                      width: 23,
                      height: 23,
                      colorFilter:
                          ColorFilter.mode(color, BlendMode.srcIn),
                    ),
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
              SizedBox(
                height: 13,
                child: Text(
                  label,
                  style: TextStyle(
                    color: color,
                    fontSize: 10.5,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
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
    // 读取父级选中态
    final sel = _ShortsSelectionScope.of(context)?.selection ?? 0;
    final isActive = sel == 2;
    return Center(
      child: GestureDetector(
        onTap: () {
          if (isActive) {
            // 短视频页内：中间按钮 = 发布入口（点击跳发布页）
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const PostEditorPage()),
            );
          } else {
            _ShortsSelectionScope.of(context)?.onChanged(2);
          }
        },
        child: Container(
          key: const ValueKey('shortsCenterBtn'),
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
          child: SvgPicture.asset(
            // 短视频页内显示发布 + 号（更小），其他 tab 显示圆形播放键
            isActive ? 'assets/icons/add.svg' : 'assets/icons/play-circle.svg',
            width: isActive ? 16 : 24,
            height: isActive ? 16 : 24,
            colorFilter: const ColorFilter.mode(Colors.white, BlendMode.srcIn),
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
