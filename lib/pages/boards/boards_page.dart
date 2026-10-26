/// 版块页：多级版块 + 话题入口（板列表来自 /boards）
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
                      : GridView.builder(
                          padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            mainAxisSpacing: 12,
                            crossAxisSpacing: 12,
                            childAspectRatio: 1.25,
                          ),
                          itemCount: _boards.length,
                          itemBuilder: (_, i) => _boardCard(_boards[i]),
                        ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _boardCard(Board b) {
    final color = _parseColor(b.color);
    final shown = b.children.take(2).toList();
    final more = b.children.length - shown.length;
    return GestureDetector(
      onTap: () => _openBoard(b),
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(AppTheme.card),
          borderRadius: BorderRadius.circular(AppTheme.radiusCard),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(11),
                  ),
                  alignment: Alignment.center,
                  child: Text(b.icon,
                      style: const TextStyle(fontSize: 18)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    b.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const Spacer(),
            if (b.children.isNotEmpty)
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final c in shown)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(
                            AppTheme.radiusPill),
                      ),
                      child: Text(
                        '${c.icon} ${c.name}',
                        style: const TextStyle(
                            color: Colors.white, fontSize: 10.5),
                      ),
                    ),
                  if (more > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: const Color(AppTheme.elevated),
                        borderRadius: BorderRadius.circular(
                            AppTheme.radiusPill),
                      ),
                      child: Text('+$more',
                          style: const TextStyle(
                              color: Color(AppTheme.textSecondary),
                              fontSize: 10.5)),
                    ),
                ],
            ),
            if (b.children.isEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  b.postCount > 0 ? '${_fmt(b.postCount)} 帖子' : '新板块',
                  style: const TextStyle(
                      color: Color(AppTheme.textTertiary), fontSize: 11),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _openBoard(Board b) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(AppTheme.card),
      shape: const RoundedRectangleBorder(
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(AppTheme.radiusSheet))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
              child: Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: _parseColor(b.color).withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    alignment: Alignment.center,
                    child: Text(b.icon,
                        style: const TextStyle(fontSize: 16)),
                  ),
                  const SizedBox(width: 10),
                  Text(b.name,
                      style: const TextStyle(
                          color: Color(AppTheme.textPrimary),
                          fontSize: 16,
                          fontWeight: FontWeight.bold)),
                ],
              ),
            ),
            if (b.children.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 4, 16, 20),
                child: Text('该版块暂无子版块',
                    style: TextStyle(
                        color: Color(AppTheme.textSecondary),
                        fontSize: 13)),
              )
            else
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final c in b.children)
                      GestureDetector(
                        onTap: () {
                          Navigator.pop(ctx);
                          Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => BoardFeedPage(
                                      boardId: c.id, title: c.name)));
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color: _parseColor(b.color).withValues(alpha: 0.12),
                            borderRadius:
                                BorderRadius.circular(AppTheme.radiusPill),
                          ),
                          child: Text(
                            '${c.icon} ${c.name}',
                            style: const TextStyle(
                                color: Colors.white, fontSize: 12.5),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            // 进入板块
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
              child: GestureDetector(
                onTap: () {
                  Navigator.pop(ctx);
                  Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) =>
                              BoardFeedPage(boardId: b.id, title: b.name)));
                },
                child: Container(
                  height: 42,
                  alignment: Alignment.center,
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
            ),
          ],
        ),
      ),
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
