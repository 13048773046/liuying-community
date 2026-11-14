/// 版块页：一级版块标签横滑（[TagRail]）+ 二级子版块胶囊（[TagPill]），
/// 内容为三列作品网格（[BoardFeedGrid]），点击二级直接在当前页切换帖子流（不跳转）
/// 数据来自 /boards（含 children 二级分类）
library;

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../design/components.dart';
import '../../widgets/board_feed_grid.dart';
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
  int _sel = 0; // 选中的一级板块下标
  int _sub = 0; // 选中的二级子版块下标

  @override
  void initState() {
    super.initState();
    _load();
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
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      showAppToast(context, '版块加载失败：$e');
    }
  }

  /// 当前展示的目标版块 id：有子版块时取选中的子版块，否则用一级
  String get _activeBoardId {
    final b = _boards[_sel];
    if (b.children.isNotEmpty) {
      final idx = _sub.clamp(0, b.children.length - 1);
      return b.children[idx].id;
    }
    return b.id;
  }

  static String _label(Board b) => b.icon.isEmpty ? b.name : '${b.icon} ${b.name}';

  @override
  Widget build(BuildContext context) {
    return ImmersivePage(
      child: SafeArea(
        // 底部导航栏避让由 BoardFeedGrid 用 tabBarBottomInset 动态处理
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _header(),
            _flightCard(context),
            if (!_loading && _boards.isNotEmpty) ...[
              TagRail(
                labels: _boards.map(_label).toList(),
                index: _sel,
                onChanged: (i) => setState(() {
                  _sel = i;
                  _sub = 0;
                }),
              ),
              if (_boards[_sel].children.isNotEmpty) _subRail(_boards[_sel]),
            ],
            Expanded(child: _content()),
          ],
        ),
      ),
    );
  }


  /// 「流萤航线」入口：现成的 WebGL 网页游戏，首次点进去才下载资源包，之后本地离线运行。
  Widget _flightCard(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 10),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const PetalwakePage())),
          child: Container(
            height: 62,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              gradient: const LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [Color(0xFF112B23), Color(0xFF0B1116)],
              ),
              border: Border.all(color: const Color(0x444CD9A5)),
            ),
            child: Row(
              children: [
                const Icon(Icons.flight_takeoff,
                    size: 22, color: Color(0xFF4CD9A5)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: const [
                      Text('流萤航线',
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: Colors.white)),
                      SizedBox(height: 3),
                      Text('骑上扫帚飞过花甸 · 首次进入需下载',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 11, color: Color(0xFF8E97A5))),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: const Color(0x1F4CD9A5),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Text('进入',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF4CD9A5))),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ 标题
  Widget _header() {
    return const Padding(
      padding: EdgeInsets.fromLTRB(
          AppSpace.gutter, AppSpace.x3, AppSpace.gutter, AppSpace.x2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('社区版块', style: AppType.h1),
          SizedBox(height: 3),
          Text('按版块找到同好', style: AppType.micro),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ 二级子版块
  Widget _subRail(Board b) {
    return SizedBox(
      height: 42,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpace.gutter, vertical: AppSpace.x1),
        itemCount: b.children.length,
        separatorBuilder: (_, _) => const SizedBox(width: AppSpace.x2),
        itemBuilder: (_, i) => Center(
          child: TagPill(
            label: _label(b.children[i]),
            active: i == _sub,
            compact: true,
            onTap: () => setState(() => _sub = i),
          ),
        ),
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

/// 首屏骨架：版块行占位。
class _BoardsSkeleton extends StatelessWidget {
  const _BoardsSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
          AppSpace.gutter, AppSpace.x4, AppSpace.gutter, 0),
      physics: const NeverScrollableScrollPhysics(),
      children: [
        for (var i = 0; i < 4; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.x3),
            child: Row(
              children: const [
                SkeletonBox(width: 56, height: 56, radius: AppRadius.sm),
                SizedBox(width: AppSpace.x3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SkeletonBox(height: 13),
                      SizedBox(height: AppSpace.x2),
                      SkeletonBox(width: 140, height: 11),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
