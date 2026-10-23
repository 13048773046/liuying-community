/// 版块页：多级版块 + 话题入口（板列表来自 /boards）
library;

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../config.dart';

class Board {
  final String id;
  final String name;
  final String icon;
  final String color;
  final List<Board> children;
  Board.fromJson(Map<String, dynamic> j)
      : id = (j['id'] ?? '') as String,
        name = (j['name'] ?? '') as String,
        icon = (j['icon'] ?? '') as String,
        color = (j['color'] ?? '#4CD9A5') as String,
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
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
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
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 5),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(AppTheme.card),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: color.withOpacity(0.16),
                  borderRadius: BorderRadius.circular(10),
                ),
                alignment: Alignment.center,
                child: Text(b.icon,
                    style: const TextStyle(fontSize: 20)),
              ),
              const SizedBox(width: 10),
              Text(
                b.name,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          if (b.children.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in b.children)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: color.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '${c.icon} ${c.name}',
                      style: const TextStyle(
                          color: Colors.white, fontSize: 12),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Color _parseColor(String hex) {
    final h = hex.replaceAll('#', '');
    if (h.length == 6) {
      return Color(int.parse(h, radix: 16) | 0xFF000000);
    }
    return const Color(AppTheme.accent);
  }
}
