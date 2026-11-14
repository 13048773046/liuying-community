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
import '../design/components.dart';
import 'image_box.dart';

/// 打开独立表情面板（弹层），返回选中的 {id, image}；取消返回 null
Future<Map<String, dynamic>?> showEmojiPanel(BuildContext context) {
  return showModalBottomSheet<Map<String, dynamic>>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => SheetShell(
      heightFactor: 0.62,
      padding: EdgeInsets.zero,
      child: EmojiPanel(
        onPick: (e) => Navigator.of(context).pop(e),
      ),
    ),
  );
}

/// 内嵌表情面板：官方分类 + 我的收藏 + 上传。选中时回调 [onPick]
class EmojiPanel extends StatefulWidget {
  const EmojiPanel({
    super.key,
    this.onPick,
    this.initialFav = false,
    this.compact = false,
  });

  final ValueChanged<Map<String, dynamic>>? onPick;
  final bool initialFav;

  /// 紧凑内嵌形态：无大标题，分类行右侧留上传小按钮，网格更密（私信底栏用）
  final bool compact;

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
        // 内嵌私信面板：收藏为空时默认落到官方第一类，别让用户开门见到空态
        if (widget.compact && _favTab && favs.isEmpty && cats.isNotEmpty) {
          _favTab = false;
          _cat = cats.first;
        }
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
      showAppToast(context, '表情已添加');
    } catch (err) {
      if (!mounted) return;
      setState(() => _uploading = false);
      showAppToast(context, '上传失败：$err');
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

  /// 当前分类在 TagRail 中的位置：0 = 我的收藏，其余为官方分类
  int get _catIndex {
    if (_favTab) return 0;
    final i = _cats.indexOf(_cat);
    return i < 0 ? 0 : i + 1;
  }

  void _onCatChanged(int i) {
    if (i == 0) {
      setState(() => _favTab = true);
      return;
    }
    setState(() {
      _favTab = false;
      _cat = _cats[i - 1];
    });
  }

  @override
  Widget build(BuildContext context) {
    final labels = <String>['我的收藏', ..._cats];
    if (widget.compact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 44,
            child: Row(
              children: [
                Expanded(
                  child: TagRail(
                    labels: labels,
                    index: _catIndex,
                    padding: const EdgeInsets.symmetric(
                        horizontal: AppSpace.x4),
                    onChanged: _onCatChanged,
                  ),
                ),
                PressableScale(
                  onTap: _upload,
                  child: Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: const Color(AppColors.elevated),
                      shape: BoxShape.circle,
                      border: Border.all(color: const Color(AppColors.border)),
                    ),
                    child: _uploading
                        ? const Center(
                            child: SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Color(AppColors.accent),
                              ),
                            ),
                          )
                        : const Icon(Icons.add_rounded,
                            size: 17, color: Color(AppColors.accent)),
                  ),
                ),
                const SizedBox(width: AppSpace.x3),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: _loading
                ? const Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Color(AppColors.accent),
                      ),
                    ),
                  )
                : _buildGrid(),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // 头部：标题 + 上传
        Padding(
          padding: const EdgeInsets.fromLTRB(
              AppSpace.x4, AppSpace.x1, AppSpace.x4, AppSpace.x2),
          child: Row(
            children: [
              const Expanded(
                child: Text('表情包', style: AppType.title),
              ),
              PillButton(
                label: '上传表情',
                icon: Icons.add_photo_alternate_outlined,
                size: PillSize.sm,
                variant: PillVariant.tonal,
                loading: _uploading,
                onTap: _upload,
              ),
            ],
          ),
        ),
        // 分类：横向标签行
        TagRail(
          labels: labels,
          index: _catIndex,
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.x4),
          onChanged: _onCatChanged,
        ),
        const SizedBox(height: AppSpace.x2),
        // 网格
        Flexible(
          child: _loading
              ? const Center(
                  child: CircularProgressIndicator(strokeWidth: 2))
              : _buildGrid(),
        ),
      ],
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
        child: EmptyState(
          compact: true,
          icon: Icons.emoji_emotions_outlined,
          title: _favTab ? '还没有收藏表情' : '暂无表情包',
          message: widget.compact
              ? '点右上角 + 添加你自己的表情'
              : (_favTab ? '点右上角上传你自己的表情' : null),
        ),
      );
    }
    return GridView.builder(
      padding: EdgeInsets.fromLTRB(widget.compact ? 12 : AppSpace.x4,
          AppSpace.x1, widget.compact ? 12 : AppSpace.x4, AppSpace.x4),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: widget.compact ? 5 : 4,
        mainAxisSpacing: AppSpace.x2,
        crossAxisSpacing: AppSpace.x2,
      ),
      itemCount: list.length,
      itemBuilder: (_, i) {
        final e = list[i];
        final img = (e['image'] ?? '') as String;
        final faved = _favs.any((x) => x['id'] == e['id']);
        return PressableScale(
          onTap: () => widget.onPick?.call(e),
          scale: 0.94,
          child: Stack(
            children: [
              Positioned.fill(
                child: ClipRRect(
                  borderRadius: AppRadius.rSm,
                  child: img.isEmpty
                      ? const ImagePlaceholder(radius: AppRadius.sm)
                      : CachedNetworkImageCompat(
                          url: mediaUrl(img), fit: BoxFit.cover),
                ),
              ),
              Positioned(
                right: AppSpace.x1,
                top: AppSpace.x1,
                child: PressableScale(
                  onTap: () => _toggleFav(e, !faved),
                  scale: 0.9,
                  child: Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.45),
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      faved ? Icons.star_rounded : Icons.star_border_rounded,
                      size: 13,
                      color: faved
                          ? const Color(AppColors.warning)
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
