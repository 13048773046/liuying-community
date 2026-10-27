/// 表情包面板组件（P0 框架）：官方分类 + 我的收藏 + 自定义上传（图片/GIF）
///
/// 素材：官方表情包（community_emojis / emoji_official/ 目录，H5 后台导入）、
/// 用户自定义上传（/emojis/custom，自动收藏）。动图 GIF 以图片形式展示。
/// 两种用法：
///  - `EmojiPanel`：内嵌组件（评论弹窗/私信面板占位用），通过 onPick 回调选择
///  - `showEmojiPanel`：独立底部弹层，返回选中的 {id, image}；取消返回 null
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../api/client.dart';
import '../config.dart';
import 'image_box.dart';

/// 打开独立表情面板（弹层），返回选中的 {id, image}；取消返回 null
Future<Map<String, dynamic>?> showEmojiPanel(BuildContext context) {
  return showModalBottomSheet<Map<String, dynamic>>(
    context: context,
    backgroundColor: const Color(AppTheme.card),
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    builder: (_) => EmojiPanel(
      onPick: (e) => Navigator.of(context).pop(e),
    ),
  );
}

/// 内嵌表情面板：官方分类 + 我的收藏 + 上传。选中时回调 [onPick]
class EmojiPanel extends StatefulWidget {
  const EmojiPanel({super.key, this.onPick, this.initialFav = false});

  final ValueChanged<Map<String, dynamic>>? onPick;
  final bool initialFav;

  @override
  State<EmojiPanel> createState() => _EmojiPanelState();
}

class _EmojiPanelState extends State<EmojiPanel> {
  List<Map<String, dynamic>> _emojis = [];
  List<Map<String, dynamic>> _favs = [];
  List<String> _cats = [];
  String _cat = '';
  late bool _favTab = widget.initialFav;
  bool _loading = true;
  bool _uploading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final j = await ApiClient.emojis();
      final list = ((j['list'] ?? []) as List)
          .whereType<Map<String, dynamic>>()
          .toList();
      final cats = <String>[];
      for (final e in list) {
        final c = (e['category'] ?? '') as String;
        if (c.isNotEmpty && !cats.contains(c)) cats.add(c);
      }
      List<Map<String, dynamic>> favs = [];
      if (ApiClient.token != null) {
        try {
          final fj = await ApiClient.emojiFavs();
          favs = ((fj['list'] ?? []) as List)
              .whereType<Map<String, dynamic>>()
              .toList();
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() {
        _emojis = list;
        _favs = favs;
        _cats = cats;
        if (!_favTab) {
          _cat = _cats.contains(_cat) ? _cat : (cats.isNotEmpty ? cats.first : '');
        }
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _upload() async {
    final picked = await ImagePicker()
        .pickImage(source: ImageSource.gallery, maxWidth: 800);
    if (picked == null || !mounted) return;
    setState(() => _uploading = true);
    try {
      final j = await ApiClient.uploadCustomEmoji(File(picked.path));
      if (!mounted) return;
      final e = Map<String, dynamic>.from(j);
      setState(() {
        _favs.insert(0, e);
        _emojis.insert(0, e);
        _uploading = false;
        _favTab = true;
      });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('表情已添加'),
          backgroundColor: Color(AppTheme.bg)));
    } catch (err) {
      if (!mounted) return;
      setState(() => _uploading = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('上传失败：$err'),
          backgroundColor: const Color(AppTheme.bg)));
    }
  }

  Future<void> _toggleFav(Map<String, dynamic> e, bool fav) async {
    final id = (e['id'] ?? '') as String;
    if (id.isEmpty) return;
    try {
      await ApiClient.emojiFav(id, fav: fav);
      if (!mounted) return;
      setState(() {
        if (fav) {
          if (!_favs.any((x) => x['id'] == id)) _favs.insert(0, e);
        } else {
          _favs.removeWhere((x) => x['id'] == id);
          _emojis.removeWhere((x) => x['id'] == id);
        }
      });
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // 头部：标题 + 上传
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 6),
          child: Row(
            children: [
              const Text('表情包',
                  style: TextStyle(
                      color: Color(AppTheme.textPrimary),
                      fontSize: 16,
                      fontWeight: FontWeight.w600)),
              const Spacer(),
              GestureDetector(
                onTap: _uploading ? null : _upload,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: const Color(AppTheme.accent).withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Row(
                    children: [
                      _uploading
                          ? const SizedBox(
                              width: 12,
                              height: 12,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Color(AppTheme.accent)))
                          : const Icon(Icons.add_photo_alternate_outlined,
                              color: Color(AppTheme.accent), size: 15),
                      const SizedBox(width: 4),
                      const Text('上传表情',
                          style: TextStyle(
                              color: Color(AppTheme.accent),
                              fontSize: 12,
                              fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        // 分类 Tab
        SizedBox(
          height: 34,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              _catTab('我的收藏', _favTab, () {
                setState(() => _favTab = true);
              }),
              for (final c in _cats)
                _catTab(c, !_favTab && _cat == c, () {
                  setState(() {
                    _favTab = false;
                    _cat = c;
                  });
                }),
            ],
          ),
        ),
        const SizedBox(height: 4),
        // 网格
        Flexible(
          child: _loading
              ? const Center(
                  child: CircularProgressIndicator(
                      color: Color(AppTheme.accent), strokeWidth: 2))
              : _buildGrid(),
        ),
      ],
    );
  }

  Widget _catTab(String label, bool sel, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 13),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: sel
              ? const Color(AppTheme.accent)
              : const Color(AppTheme.elevated),
          borderRadius: BorderRadius.circular(15),
        ),
        child: Text(label,
            style: TextStyle(
                color: sel ? Colors.black : const Color(AppTheme.textSecondary),
                fontSize: 12,
                fontWeight: sel ? FontWeight.w600 : FontWeight.w400)),
      ),
    );
  }

  Widget _buildGrid() {
    final list = _favTab
        ? _favs
        : _emojis
            .where((e) {
              final c = (e['category'] ?? '') as String;
              return _cat.isEmpty || c == _cat;
            })
            .toList();
    if (list.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.emoji_emotions_outlined,
                size: 40, color: Color(AppTheme.textTertiary)),
            const SizedBox(height: 8),
            Text(_favTab ? '还没有收藏表情，点击右上角上传' : '暂无表情包',
                style: const TextStyle(
                    color: Color(AppTheme.textTertiary), fontSize: 12)),
          ],
        ),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
      ),
      itemCount: list.length,
      itemBuilder: (_, i) {
        final e = list[i];
        final img = (e['image'] ?? '') as String;
        final faved = _favs.any((x) => x['id'] == e['id']);
        return GestureDetector(
          onTap: () => widget.onPick?.call(e),
          child: Stack(
            children: [
              Positioned.fill(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: img.isEmpty
                      ? Container(color: const Color(AppTheme.elevated))
                      : CachedNetworkImageCompat(url: mediaUrl(img), fit: BoxFit.cover),
                ),
              ),
              Positioned(
                right: 2,
                top: 2,
                child: GestureDetector(
                  onTap: () => _toggleFav(e, !faved),
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      color: Colors.black45,
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      faved ? Icons.star : Icons.star_border,
                      size: 12,
                      color: faved
                          ? const Color(AppTheme.accent)
                          : Colors.white,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
