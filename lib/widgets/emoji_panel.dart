/// 官方表情包面板（P0 框架）：分类 tab + 网格选择
///
/// 素材由运营在 H5 后台导入（community_emojis / emoji_official/ 目录），
/// 客户端只消费 /emojis 接口；素材未导入时优雅提示。
library;

import 'package:flutter/material.dart';

import '../api/client.dart';
import '../config.dart';
import 'image_box.dart';

/// 打开表情面板，返回选中的表情 {id, image}；取消返回 null
Future<Map<String, dynamic>?> showEmojiPanel(BuildContext context) {
  return showModalBottomSheet<Map<String, dynamic>>(
    context: context,
    backgroundColor: const Color(AppTheme.card),
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    builder: (_) => const _EmojiPanel(),
  );
}

class _EmojiPanel extends StatefulWidget {
  const _EmojiPanel();

  @override
  State<_EmojiPanel> createState() => _EmojiPanelState();
}

class _EmojiPanelState extends State<_EmojiPanel> {
  List<Map<String, dynamic>> _emojis = [];
  List<String> _cats = [];
  String _cat = '';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final j = await ApiClient.get('/emojis');
      if (!mounted) return;
      final list = ((j['list'] ?? []) as List)
          .whereType<Map<String, dynamic>>()
          .toList();
      final cats = <String>[];
      for (final e in list) {
        final c = (e['category'] ?? '') as String;
        if (c.isNotEmpty && !cats.contains(c)) cats.add(c);
      }
      setState(() {
        _emojis = list;
        _cats = cats;
        _cat = cats.isNotEmpty ? cats.first : '';
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.of(context).size.height * 0.42;
    return SafeArea(
      child: SizedBox(
        height: h,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Text('官方表情包',
                  style: TextStyle(
                      color: Color(AppTheme.textPrimary),
                      fontSize: 15,
                      fontWeight: FontWeight.bold)),
            ),
            if (_cats.isNotEmpty)
              SizedBox(
                height: 34,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  itemCount: _cats.length,
                  itemBuilder: (_, i) {
                    final sel = _cats[i] == _cat;
                    return GestureDetector(
                      onTap: () => setState(() => _cat = _cats[i]),
                      child: Container(
                        margin: const EdgeInsets.symmetric(horizontal: 4),
                        padding:
                            const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                        decoration: BoxDecoration(
                          color: sel
                              ? const Color(AppTheme.accentSoft)
                              : const Color(AppTheme.bg),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: sel
                                ? const Color(AppTheme.accent)
                                : const Color(AppTheme.border),
                          ),
                        ),
                        child: Text(_cats[i],
                            style: TextStyle(
                              color: sel
                                  ? const Color(AppTheme.accent)
                                  : const Color(AppTheme.textSecondary),
                              fontSize: 12,
                            )),
                      ),
                    );
                  },
                ),
              ),
            const SizedBox(height: 4),
            Expanded(
              child: _loading
                  ? const Center(
                      child: CircularProgressIndicator(
                          color: Color(AppTheme.accent), strokeWidth: 2))
                  : _emojis.isEmpty
                      ? const Center(
                          child: Padding(
                            padding: EdgeInsets.symmetric(horizontal: 30),
                            child: Text(
                              '官方表情包制作中\n素材到位后这里会自动出现表情',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  color: Color(AppTheme.textTertiary),
                                  fontSize: 13,
                                  height: 1.6),
                            ),
                          ),
                        )
                      : GridView.builder(
                          padding: const EdgeInsets.all(12),
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 5,
                            mainAxisSpacing: 10,
                            crossAxisSpacing: 10,
                          ),
                          itemCount: _emojis.length,
                          itemBuilder: (_, i) {
                            final e = _emojis[i];
                            if (_cat.isNotEmpty &&
                                (e['category'] ?? '') != _cat) {
                              return const SizedBox.shrink();
                            }
                            return GestureDetector(
                              onTap: () => Navigator.pop(context, e),
                              child: CachedNetworkImageCompat(
                                  url: mediaUrl(e['image'] as String),
                                  fit: BoxFit.contain),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }
}
