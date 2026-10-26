/// 版块页：顶部一级 Tab 横滑 + 下方二级子版块列表（类抖音/QQ 频道式）
/// 数据来自 /boards（含 children 二级分类）
library;

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../config.dart';
import 'board_feed_page.dart';

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(AppTheme.bg),
      body: SafeArea(
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
            if (!_loading && _boards.isNotEmpty) _topTabs(),
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
                      : _subList(_boards[_sel]),
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
            onTap: () => setState(() => _sel = i),
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

  /// 二级子版块列表（选中一级下的 children）
  Widget _subList(Board b) {
    final color = _parseColor(b.color);
    if (b.children.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('${b.icon} ${b.name} 暂无子版块',
                style: const TextStyle(
                    color: Color(AppTheme.textSecondary), fontSize: 13)),
            const SizedBox(height: 16),
            GestureDetector(
              onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) =>
                          BoardFeedPage(boardId: b.id, title: b.name))),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
                decoration: BoxDecoration(
                  color: const Color(AppTheme.accent),
                  borderRadius: BorderRadius.circular(AppTheme.radiusPill),
                ),
                child: const Text('进入板块',
                    style: TextStyle(
                        color: Colors.black,
                        fontSize: 14,
                        fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 20),
      itemCount: b.children.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (_, i) {
        final c = b.children[i];
        return GestureDetector(
          onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) =>
                      BoardFeedPage(boardId: c.id, title: c.name))),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(AppTheme.card),
              borderRadius: BorderRadius.circular(AppTheme.radiusCard),
            ),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  alignment: Alignment.center,
                  child: Text(c.icon,
                      style: const TextStyle(fontSize: 19)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(c.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14.5,
                              fontWeight: FontWeight.w600)),
                      const SizedBox(height: 2),
                      Text(
                        c.postCount > 0
                            ? '${_fmt(c.postCount)} 帖子'
                            : '新板块',
                        style: const TextStyle(
                            color: Color(AppTheme.textTertiary),
                            fontSize: 11),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded,
                    color: Color(AppTheme.textTertiary), size: 20),
              ],
            ),
          ),
        );
      },
    );
  }

  String _fmt(int n) {
    if (n >= 10000) {
      final w = n / 10000;
      return w >= 100
          ? '${w.toStringAsFixed(0)}万'
          : '${w.toStringAsFixed(1)}万';
    }
    return '$n';
  }

  Color _parseColor(String hex) {
    final h = hex.replaceAll('#', '');
    if (h.length == 6) {
      return Color(int.parse(h, radix: 16) | 0xFF000000);
    }
    return const Color(AppTheme.accent);
  }
}
