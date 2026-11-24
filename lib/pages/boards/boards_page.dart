/// 版块页：频道矩阵 + 当前频道 + 双列内容现场
///
/// 重做后的结构不再是「应用大卡 → 航线卡 → 标签行 → 帖子」的纵向堆叠：
/// 顶部是一张可横向浏览的频道矩阵（2 行频道卡），选中哪个频道，下面就是它的现场；
/// 应用橱窗与流萤航线压成两张等高的入口卡，不再抢内容的位置。
library;

import 'package:flutter/material.dart';

import '../../api/app_market_api.dart';
import '../../api/client.dart';
import '../../design/components.dart';
import '../../models/app_market.dart';
import '../../widgets/board_feed_grid.dart';
import '../apps/app_market_page.dart';
import '../apps/app_widgets.dart';
import '../game/petalwake_page.dart';

class Board {
  final String id;
  final String name;
  final String icon;
  final String color;
  final int postCount;
  final List<Board> children;
  Board.fromJson(Map<String, dynamic> j)
    : id = (j['id'] ?? '') as String,
      name = (j['name'] ?? '') as String,
      icon = (j['icon'] ?? '') as String,
      color = (j['color'] ?? '#4CD9A5') as String,
      postCount = ((j['post_count'] ?? j['postCount'] ?? 0) as num).toInt(),
      children = ((j['children'] ?? []) as List)
          .whereType<Map<String, dynamic>>()
          .map(Board.fromJson)
          .toList();
}

class BoardsPage extends StatefulWidget {
  const BoardsPage({super.key});

  @override
  State<BoardsPage> createState() => _BoardsPageState();
}

class _BoardsPageState extends State<BoardsPage> {
  List<Board> _boards = [];
  bool _loading = true;
  int _sel = 0;
  int _sub = -1;

  List<MarketApp> _apps = const [];
  bool _appsLoading = true;
  String? _appsError;
  int _appsRequest = 0;

  @override
  void initState() {
    super.initState();
    _load();
    _loadApps();
  }

  Future<void> _load() async {
    try {
      final j = await ApiClient.get('/boards');
      if (!mounted) return;
      setState(() {
        _boards = ((j['list'] ?? []) as List)
            .whereType<Map<String, dynamic>>()
            .map(Board.fromJson)
            .toList();
        _loading = false;
        if (_sel >= _boards.length) _sel = 0;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      showAppToast(context, '版块加载失败：$e');
    }
  }

  Future<void> _loadApps() async {
    final id = ++_appsRequest;
    if (!mounted) return;
    setState(() {
      _appsLoading = true;
      _appsError = null;
    });
    try {
      final page = await AppMarketApi.list(page: 1, pageSize: 20, sort: 'hot');
      if (!mounted || id != _appsRequest) return;
      setState(() {
        _apps = page.list;
        _appsLoading = false;
        _appsError = null;
      });
    } catch (e) {
      if (!mounted || id != _appsRequest) return;
      setState(() {
        _appsLoading = false;
        _appsError = e.toString();
      });
    }
  }

  Board? get _selectedBoard =>
      _boards.isEmpty ? null : _boards[_sel.clamp(0, _boards.length - 1)];

  String get _activeBoardId {
    final b = _selectedBoard;
    if (b == null) return '';
    if (_sub >= 0 && b.children.isNotEmpty) {
      final idx = _sub.clamp(0, b.children.length - 1);
      return b.children[idx].id;
    }
    return b.id;
  }

  String get _activeBoardName {
    final b = _selectedBoard;
    if (b == null) return '版块';
    if (_sub >= 0 && b.children.isNotEmpty) {
      final idx = _sub.clamp(0, b.children.length - 1);
      return b.children[idx].name;
    }
    return b.name;
  }

  static String _label(Board b) =>
      b.icon.isEmpty ? b.name : '${b.icon} ${b.name}';

  void _openMarket() {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const AppMarketPage()));
  }

  void _openFlight() {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const PetalwakePage()));
  }

  @override
  Widget build(BuildContext context) {
    return ImmersivePage(
      child: SafeArea(
        bottom: false,
        child: NestedScrollView(
          headerSliverBuilder: (context, innerScrolled) => [
            SliverToBoxAdapter(child: _header()),
            SliverToBoxAdapter(child: _hero()),
            SliverToBoxAdapter(child: _channelRail()),
            SliverToBoxAdapter(child: _subRail()),
            SliverToBoxAdapter(child: _wings()),
            SliverToBoxAdapter(child: _feedHeader()),
          ],
          body: _content(),
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ 标题
  Widget _header() {
    final boardCount = _loading ? '—' : '${_boards.length}';
    final appCount = _appsLoading ? '—' : '${_apps.length}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '版块',
                style: TextStyle(
                  fontSize: 32,
                  height: 1,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -1.3,
                  color: Color(AppColors.textPrimary),
                ),
              ),
              const SizedBox(width: 7),
              const Padding(
                padding: EdgeInsets.only(top: 2),
                child: Text(
                  'BOARD INDEX',
                  style: TextStyle(
                    fontSize: 8.5,
                    height: 1.45,
                    letterSpacing: 1.1,
                    fontWeight: FontWeight.w600,
                    color: Color(AppColors.textTertiary),
                  ),
                ),
              ),
              const Spacer(),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _stat(boardCount, '频道'),
                  const SizedBox(width: 12),
                  _stat(appCount, '应用'),
                ],
              ),
            ],
          ),
          const SizedBox(height: 9),
          Text(
            _loading
                ? '正在整理频道，选一个直接落到内容现场。'
                : '${_boards.length} 个频道，按兴趣切，内容就在下方。',
            style: const TextStyle(
              fontSize: 11.5,
              height: 1.35,
              color: Color(AppColors.textTertiary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _stat(String value, String label) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          value,
          style: const TextStyle(
            fontSize: 17,
            height: 1,
            fontWeight: FontWeight.w800,
            color: Color(AppColors.textPrimary),
          ),
        ),
        const SizedBox(height: 3),
        Text(
          label,
          style: const TextStyle(
            fontSize: 9,
            height: 1,
            letterSpacing: 0.6,
            color: Color(AppColors.textTertiary),
          ),
        ),
      ],
    );
  }

  // -------------------------------------------------------------- 频道主视觉

  Color _tint(Board b) {
    var raw = b.color.trim().replaceFirst('#', '');
    if (raw.length == 6) raw = 'FF$raw';
    final v = int.tryParse(raw, radix: 16);
    return v == null ? const Color(AppColors.accent) : Color(v);
  }

  String _iconText(Board b) {
    final icon = b.icon.trim();
    if (icon.isEmpty) return '#';
    final cp = icon.runes.first;
    // 测试/部分设备没有彩色 emoji 字体，emoji 会渲染成空白；用版块首字做单色字标。
    if (cp >= 0x1F000 && cp <= 0x1FAFF) {
      return b.name.isEmpty ? '#' : b.name.substring(0, 1);
    }
    return icon;
  }

  Widget _hero() {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(16, 14, 16, 0),
        child: SkeletonBox(height: 150, radius: 18),
      );
    }
    final b = _selectedBoard;
    if (b == null) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(16, 14, 16, 0),
        child: SkeletonBox(height: 104, radius: 18),
      );
    }
    final tint = _tint(b);
    final index = (_sel + 1).toString().padLeft(2, '0');
    final meta = b.children.isEmpty
        ? '${formatCount(b.postCount)} 篇讨论'
        : '${b.children.length} 个子版块 · ${formatCount(b.postCount)} 帖';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
      child: Container(
        height: 150,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              tint.withValues(alpha: 0.20),
              const Color(0xFF0C1112),
              const Color(0xFF080B0C),
            ],
            stops: const [0, 0.58, 1],
          ),
          border: Border.all(color: tint.withValues(alpha: 0.30)),
        ),
        child: Stack(
          children: [
            Positioned(
              left: -36,
              top: -64,
              child: Container(
                width: 180,
                height: 180,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [tint.withValues(alpha: 0.22), Colors.transparent],
                  ),
                ),
              ),
            ),
            Positioned(
              right: 12,
              bottom: 2,
              child: Text(
                index,
                style: TextStyle(
                  fontSize: 42,
                  height: 0.9,
                  letterSpacing: -2,
                  fontWeight: FontWeight.w900,
                  color: Colors.white.withValues(alpha: 0.07),
                ),
              ),
            ),
            Positioned(
              right: 18,
              top: 18,
              child: Container(
                width: 54,
                height: 54,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.045),
                  shape: BoxShape.circle,
                  border: Border.all(color: tint.withValues(alpha: 0.22)),
                ),
                child: Text(
                  _iconText(b),
                  style: TextStyle(fontSize: 28, height: 1, color: tint),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        height: 22,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: tint.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: tint.withValues(alpha: 0.40),
                          ),
                        ),
                        child: Text(
                          'ON AIR',
                          style: TextStyle(
                            fontSize: 8,
                            height: 1,
                            letterSpacing: 1.2,
                            fontWeight: FontWeight.w700,
                            color: tint,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '频道 $index',
                        style: const TextStyle(
                          fontSize: 8.5,
                          height: 1,
                          letterSpacing: 0.6,
                          color: Color(AppColors.textTertiary),
                        ),
                      ),
                    ],
                  ),
                  const Spacer(),
                  Text(
                    b.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 29,
                      height: 1.04,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -1.1,
                      color: Color(AppColors.textPrimary),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Container(
                        width: 16,
                        height: 2,
                        decoration: BoxDecoration(
                          color: tint,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(width: 7),
                      Text(
                        meta,
                        style: const TextStyle(
                          fontSize: 10.5,
                          height: 1.2,
                          color: Color(AppColors.textSecondary),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _channelRail() {
    if (_loading) {
      return SizedBox(
        height: 42,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          itemCount: 3,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (_, _) =>
              const SkeletonBox(width: 98, height: 34, radius: 11),
        ),
      );
    }
    if (_boards.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 42,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        itemCount: _boards.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final b = _boards[i];
          final on = i == _sel;
          final tint = _tint(b);
          return PressableScale(
            onTap: () => setState(() {
              _sel = i;
              _sub = -1;
            }),
            scale: 0.97,
            child: AnimatedContainer(
              duration: AppMotion.base,
              curve: AppMotion.standard,
              padding: const EdgeInsets.symmetric(horizontal: 11),
              decoration: BoxDecoration(
                color: on
                    ? tint.withValues(alpha: 0.13)
                    : const Color(AppColors.card).withValues(alpha: 0.50),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: on
                      ? tint.withValues(alpha: 0.55)
                      : const Color(AppColors.hairline),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _iconText(b),
                    style: TextStyle(
                      fontSize: 13,
                      height: 1,
                      color: on ? tint : const Color(AppColors.textSecondary),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    b.name,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1,
                      fontWeight: on ? FontWeight.w700 : FontWeight.w500,
                      color: on ? tint : const Color(AppColors.textPrimary),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    formatCount(b.postCount),
                    style: TextStyle(
                      fontSize: 9,
                      height: 1,
                      color: on
                          ? tint.withValues(alpha: 0.75)
                          : const Color(AppColors.textTertiary),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // ------------------------------------------------------------ 二级子版块
  Widget _subRail() {
    final b = _selectedBoard;
    if (b == null || b.children.isEmpty) return const SizedBox.shrink();
    final options = <String>[
      '全部',
      for (final child in b.children) _label(child),
    ];
    return SizedBox(
      height: 43,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 7, 16, 4),
        itemCount: options.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          // i = 0 展示父版块及其全部子版块；i > 0 才是单个子版块。
          final sub = i - 1;
          final on = sub == _sub;
          return PressableScale(
            onTap: () => setState(() => _sub = sub),
            scale: 0.97,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 11),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: on
                    ? const Color(AppColors.accent).withValues(alpha: 0.14)
                    : const Color(AppColors.card).withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: on
                      ? const Color(AppColors.accent).withValues(alpha: 0.35)
                      : const Color(AppColors.hairline),
                ),
              ),
              child: Text(
                options[i],
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.1,
                  fontWeight: on ? FontWeight.w600 : FontWeight.w400,
                  color: on
                      ? const Color(AppColors.accent)
                      : const Color(AppColors.textSecondary),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  // ------------------------------------------------------- 应用 / 航线入口
  Widget _wings() {
    final firstApp = _apps.isEmpty ? null : _apps.first;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Container(
        height: 58,
        decoration: BoxDecoration(
          color: const Color(AppColors.card).withValues(alpha: 0.42),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(AppColors.hairline)),
        ),
        child: Row(
          children: [
            Expanded(
              child: _wingLink(
                onTap: _openMarket,
                leading: firstApp == null
                    ? const Icon(
                        Icons.grid_view_rounded,
                        size: 17,
                        color: Color(AppColors.accent),
                      )
                    : AppIconTile(app: firstApp, size: 26, radius: 8),
                title: '应用橱窗',
                subtitle: _appsLoading
                    ? '正在同步'
                    : _appsError != null
                    ? '暂时没连上'
                    : '${_apps.length} 款社区应用',
                tint: const Color(AppColors.accent),
              ),
            ),
            Container(
              width: 1,
              height: 24,
              color: const Color(AppColors.hairline),
            ),
            Expanded(
              child: _wingLink(
                onTap: _openFlight,
                leading: const Icon(
                  Icons.flight_takeoff_rounded,
                  size: 16,
                  color: Color(0xFF8E9BFF),
                ),
                title: '流萤航线',
                subtitle: '花甸飞行',
                tint: const Color(0xFF8E9BFF),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _wingLink({
    required VoidCallback onTap,
    required Widget leading,
    required String title,
    required String subtitle,
    required Color tint,
  }) {
    return PressableScale(
      onTap: onTap,
      scale: 0.98,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(11, 8, 6, 8),
        child: Row(
          children: [
            Container(
              width: 26,
              height: 26,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: tint.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(8),
              ),
              child: leading,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12.5,
                      height: 1.05,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.2,
                      color: Color(AppColors.textPrimary),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 8.5,
                      height: 1.05,
                      color: Color(AppColors.textTertiary),
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              size: 13,
              color: tint.withValues(alpha: 0.75),
            ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ 内容头
  Widget _feedHeader() {
    final b = _selectedBoard;
    final tint = b == null ? const Color(AppColors.accent) : _tint(b);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 14,
                      height: 2,
                      decoration: BoxDecoration(
                        color: tint,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'ON AIR / 正在讨论',
                      style: TextStyle(
                        fontSize: 8.5,
                        height: 1.2,
                        letterSpacing: 1.0,
                        fontWeight: FontWeight.w700,
                        color: tint,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 5),
                Text(
                  _activeBoardName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 21,
                    height: 1.05,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -0.6,
                    color: Color(AppColors.textPrimary),
                  ),
                ),
              ],
            ),
          ),
          Text(
            b == null ? '' : '${formatCount(b.postCount)} 帖',
            style: const TextStyle(
              fontSize: 10.5,
              height: 1.1,
              color: Color(AppColors.textTertiary),
            ),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ 内容
  Widget _content() {
    if (_loading) return const _BoardsSkeleton();
    if (_boards.isEmpty) {
      return const Center(
        child: EmptyState(
          icon: Icons.dashboard_outlined,
          title: '暂无版块',
          message: '版块正在整理中，稍后再来看看',
        ),
      );
    }
    return BoardFeedGrid(boardId: _activeBoardId);
  }
}

/// 首屏骨架：双列频道矩阵 + 两列入场卡。
class _BoardsSkeleton extends StatelessWidget {
  const _BoardsSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      physics: const NeverScrollableScrollPhysics(),
      children: [
        for (var i = 0; i < 4; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              children: const [
                SkeletonBox(width: 86, height: 56, radius: 12),
                SizedBox(width: 10),
                Expanded(child: SkeletonBox(height: 56, radius: 12)),
              ],
            ),
          ),
      ],
    );
  }
}
