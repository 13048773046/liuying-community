/// 版块页：顶部一级 Tab 横滑 + 二级子版块 Tab，点击二级直接在当前页切换帖子流（不跳转）
/// 数据来自 /boards（含 children 二级分类）
library;

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../config.dart';
import '../../widgets/board_feed_grid.dart';

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
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('版块加载失败：$e')));
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(AppTheme.bg),
      body: SafeArea(
        // 底部导航栏避让由 BoardFeedGrid 用 tabBarBottomInset 动态处理
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Text(
                '社区版块',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            if (!_loading && _boards.isNotEmpty) ...[
              _topTabs(),
              if (_boards[_sel].children.isNotEmpty) _subTabs(_boards[_sel]),
            ],
            Expanded(
              child: _loading
                  ? const Center(
                      child: CircularProgressIndicator(
                          color: Color(AppTheme.accent)))
                  : _boards.isEmpty
                      ? const Center(
                          child: Text('暂无版块',
                              style: TextStyle(
                                  color: Color(AppTheme.textSecondary))))
                      : BoardFeedGrid(boardId: _activeBoardId),
            ),
          ],
        ),
      ),
    );
  }

  /// 顶部一级板块 Tab（横向滑，选中薄荷绿）
  Widget _topTabs() {
    return SizedBox(
      height: 42,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: _boards.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final b = _boards[i];
          final selected = i == _sel;
          return GestureDetector(
            onTap: () => setState(() {
              _sel = i;
              _sub = 0;
            }),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: selected
                    ? const Color(AppTheme.accent).withValues(alpha: 0.16)
                    : const Color(AppTheme.card),
                borderRadius: BorderRadius.circular(AppTheme.radiusPill),
                border: Border.all(
                    color: selected
                        ? const Color(AppTheme.accent)
                        : const Color(AppTheme.border),
                    width: selected ? 1.2 : 0.5),
              ),
              child: Text(
                '${b.icon} ${b.name}',
                style: TextStyle(
                  color: selected
                      ? const Color(AppTheme.accent)
                      : const Color(AppTheme.textSecondary),
                  fontSize: 13,
                  fontWeight:
                      selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// 二级子版块 Tab（选中一级板块下 children，点击直接切换帖子流）
  Widget _subTabs(Board b) {
    return SizedBox(
      height: 36,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: b.children.length,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (_, i) {
          final c = b.children[i];
          final selected = i == _sub;
          return GestureDetector(
            onTap: () => setState(() => _sub = i),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              padding: const EdgeInsets.symmetric(horizontal: 13),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: selected
                    ? const Color(AppTheme.accent)
                    : const Color(AppTheme.card),
                borderRadius: BorderRadius.circular(AppTheme.radiusPill),
                border: Border.all(
                    color: selected
                        ? const Color(AppTheme.accent)
                        : const Color(AppTheme.border),
                    width: selected ? 1.2 : 0.5),
              ),
              child: Text(
                '${c.icon} ${c.name}',
                style: TextStyle(
                  color: selected
                      ? Colors.black
                      : const Color(AppTheme.textSecondary),
                  fontSize: 12,
                  fontWeight:
                      selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
