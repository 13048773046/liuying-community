/// 配乐选择弹窗：拉音乐项目本地可播曲库，可试听，选中即用。
library;

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import '../../api/client.dart';
import '../../config.dart';
import '../../design/components.dart';

/// 返回选中配乐 {url,name,cover,durText,artist,title}；取消返回 null
Future<Map<String, dynamic>?> showMusicPicker(BuildContext context) async {
  return showModalBottomSheet<Map<String, dynamic>>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const _MusicPickerSheet(),
  );
}

class _MusicPickerSheet extends StatefulWidget {
  const _MusicPickerSheet();
  @override
  State<_MusicPickerSheet> createState() => _MusicPickerSheetState();
}

class _MusicPickerSheetState extends State<_MusicPickerSheet> {
  List<Map<String, dynamic>>? _tracks;
  String? _err;
  final AudioPlayer _prev = AudioPlayer(); // 试听
  int? _playingId;
  final TextEditingController _qCtrl = TextEditingController();
  String _q = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _qCtrl.dispose();
    _prev.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final t = await ApiClient.musicTracks();
      if (mounted) setState(() => _tracks = t);
    } catch (e) {
      if (mounted) setState(() => _err = e.toString());
    }
  }

  Future<void> _toggle(int? trackId, String url) async {
    if (_playingId == trackId) {
      await _prev.pause();
      if (mounted) setState(() => _playingId = null);
      return;
    }
    try {
      await _prev.stop();
      await _prev.setUrl(url);
      await _prev.play();
      if (mounted) setState(() => _playingId = trackId);
    } catch (_) {}
  }

  /// 客户端过滤（不改接口）：歌名 / 歌手
  List<Map<String, dynamic>> _filtered(List<Map<String, dynamic>> all) {
    final q = _q.trim().toLowerCase();
    if (q.isEmpty) return all;
    return all
        .where((t) => '${t['title'] ?? ''} ${t['artist'] ?? ''}'
            .toLowerCase()
            .contains(q))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    return SheetShell(
      title: '选择配乐',
      subtitle: '来自流萤音乐 · 可试听后使用',
      heightFactor: 0.75,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 搜索
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.x3),
            child: TextField(
              controller: _qCtrl,
              onChanged: (v) => setState(() => _q = v),
              style: AppType.bodySm.copyWith(color: const Color(AppColors.textPrimary)),
              cursorColor: const Color(AppColors.accent),
              decoration: const InputDecoration(
                hintText: '搜索歌曲 / 歌手',
                prefixIcon: Icon(Icons.search_rounded,
                    size: 18, color: Color(AppColors.textTertiary)),
                prefixIconConstraints: BoxConstraints(minWidth: 38),
                isDense: true,
                contentPadding:
                    EdgeInsets.symmetric(horizontal: AppSpace.x3, vertical: 10),
              ),
            ),
          ),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _body() {
    if (_err != null) {
      return Center(
        child: ErrorState(
          message: '配乐加载失败：$_err',
          onRetry: () {
            setState(() => _err = null);
            _load();
          },
        ),
      );
    }
    final tracks = _tracks;
    if (tracks == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (tracks.isEmpty) {
      return const Center(
        child: EmptyState(
          compact: true,
          icon: Icons.music_off_rounded,
          title: '曲库暂空',
          message: '稍后再来试试',
        ),
      );
    }
    final list = _filtered(tracks);
    if (list.isEmpty) {
      return const Center(
        child: EmptyState(
          compact: true,
          icon: Icons.search_off_rounded,
          title: '没有找到配乐',
          message: '换个关键词试试',
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: AppSpace.x4),
      itemCount: list.length,
      separatorBuilder: (_, _) => const Hairline(),
      itemBuilder: (_, i) => _trackRow(list[i], i),
    );
  }

  Widget _trackRow(Map<String, dynamic> t, int i) {
    final tid = (t['id'] ?? i).toString();
    final title = (t['title'] ?? '') as String;
    final artist = (t['artist'] ?? '') as String;
    final dur = (t['durText'] ?? '') as String;
    final fname = (t['fname'] ?? '') as String;
    final cover = (t['cover'] ?? '') as String;
    final url = '$kMusicBase/files/$fname';
    final playing = _playingId?.toString() == tid;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpace.x2),
      child: Row(
        children: [
          Expanded(
            child: PressableScale(
              onTap: () => _toggle(int.tryParse(tid), url),
              scale: 0.98,
              child: Row(
                children: [
                  // 封面
                  ClipRRect(
                    borderRadius: AppRadius.rSm,
                    child: SizedBox(
                      width: 44,
                      height: 44,
                      child: cover.isEmpty
                          ? const ImagePlaceholder(
                              icon: Icons.music_note_rounded,
                              radius: AppRadius.sm,
                            )
                          : Image.network(
                              '$kMusicBase/api/cover/$cover',
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) => const ImagePlaceholder(
                                icon: Icons.music_note_rounded,
                                radius: AppRadius.sm,
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(width: AppSpace.x3),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppType.label,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          artist.isEmpty ? dur : '$artist · $dur',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppType.caption,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSpace.x2),
                ],
              ),
            ),
          ),
          // 试听
          IconCircleButton(
            icon: playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
            size: 32,
            iconSize: 18,
            color: const Color(AppColors.accent),
            background: playing
                ? const Color(AppColors.accent).withValues(alpha: 0.16)
                : Colors.white.withValues(alpha: 0.06),
            onTap: () => _toggle(int.tryParse(tid), url),
          ),
          const SizedBox(width: AppSpace.x2),
          // 使用
          PillButton(
            label: '使用',
            size: PillSize.sm,
            onTap: () => Navigator.pop(context, {
              'url': url,
              'name': '$title - $artist',
              'cover': cover,
              'trackId': tid,
              'durText': dur,
            }),
          ),
        ],
      ),
    );
  }
}
