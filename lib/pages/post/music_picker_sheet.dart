/// 配乐选择弹窗：拉音乐项目本地可播曲库，可试听，选中即用。
library;

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import '../../api/client.dart';
import '../../config.dart';

/// 返回选中配乐 {url,name,cover,durText,artist,title}；取消返回 null
Future<Map<String, dynamic>?> showMusicPicker(BuildContext context) async {
  return showModalBottomSheet<Map<String, dynamic>>(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(AppTheme.card),
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
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

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
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

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.of(context).size.height;
    return SafeArea(
      child: SizedBox(
        height: h * 0.62,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Row(
                children: [
                  Icon(Icons.music_note_rounded,
                      color: Color(AppTheme.accent), size: 20),
                  SizedBox(width: 6),
                  Text('选择配乐',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w600)),
                  Spacer(),
                  Text('来自音乐库',
                      style: TextStyle(
                          color: Color(AppTheme.textTertiary), fontSize: 11)),
                ],
              ),
            ),
            const Divider(height: 1, color: Color(AppTheme.border)),
            Expanded(
              child: _err != null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Text('配乐加载失败：$_err',
                            style: const TextStyle(
                                color: Color(AppTheme.textSecondary),
                                fontSize: 12.5)),
                      ),
                    )
                  : _tracks == null
                      ? const Center(
                          child: CircularProgressIndicator(
                              strokeWidth: 2.5, color: Color(AppTheme.accent)))
                      : _tracks!.isEmpty
                          ? const Center(
                              child: Text('曲库暂空',
                                  style: TextStyle(
                                      color: Color(AppTheme.textSecondary),
                                      fontSize: 12.5)))
                          : ListView.builder(
                              padding: const EdgeInsets.only(bottom: 10),
                              itemCount: _tracks!.length,
                              itemBuilder: (_, i) {
                                final t = _tracks![i];
                                final tid = (t['id'] ?? i).toString();
                                final title = (t['title'] ?? '') as String;
                                final artist = (t['artist'] ?? '') as String;
                                final dur = (t['durText'] ?? '') as String;
                                final fname = (t['fname'] ?? '') as String;
                                final cover = (t['cover'] ?? '') as String;
                                final url = '$kMusicBase/files/$fname';
                                final playing = _playingId?.toString() == tid;
                                return ListTile(
                                  dense: true,
                                  leading: Stack(
                                    alignment: Alignment.center,
                                    children: [
                                      ClipRRect(
                                        borderRadius: BorderRadius.circular(6),
                                        child: cover.isEmpty
                                            ? Container(
                                                width: 38, height: 38,
                                                color: const Color(AppTheme.bg),
                                                child: const Icon(
                                                    Icons.music_note_rounded,
                                                    size: 18,
                                                    color: Color(AppTheme.textTertiary)))
                                            : Image.network(
                                                '$kMusicBase/api/cover/$cover',
                                                width: 38, height: 38,
                                                fit: BoxFit.cover,
                                                errorBuilder: (_, _, _) =>
                                                    Container(
                                                      width: 38, height: 38,
                                                      color: const Color(AppTheme.bg),
                                                      child: const Icon(
                                                          Icons.music_note_rounded,
                                                          size: 18,
                                                          color: Color(
                                                              AppTheme.textTertiary)),
                                                    )),
                                      ),
                                      if (playing)
                                        const Positioned(
                                          bottom: 0, right: 0,
                                          child: Icon(Icons.graphic_eq_rounded,
                                              size: 12,
                                              color: Color(AppTheme.accent)),
                                        ),
                                    ],
                                  ),
                                  title: Text(title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          color: Color(AppTheme.textPrimary),
                                          fontSize: 13.5,
                                          fontWeight: FontWeight.w600)),
                                  subtitle: Text('$artist · $dur',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          color: Color(AppTheme.textTertiary),
                                          fontSize: 11.5)),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      GestureDetector(
                                        onTap: () => _toggle(int.tryParse(tid), url),
                                        child: Container(
                                          width: 32, height: 32,
                                          decoration: const BoxDecoration(
                                              color: Color(AppTheme.bg),
                                              shape: BoxShape.circle),
                                          child: Icon(
                                            playing
                                                ? Icons.pause_rounded
                                                : Icons.play_arrow_rounded,
                                            size: 18,
                                            color: const Color(AppTheme.accent)),
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      GestureDetector(
                                        onTap: () => Navigator.pop(context, {
                                          'url': url,
                                          'name': '$title - $artist',
                                          'cover': cover,
                                          'trackId': tid,
                                          'durText': dur,
                                        }),
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 10, vertical: 5),
                                          decoration: BoxDecoration(
                                            color: const Color(AppTheme.accent),
                                            borderRadius: BorderRadius.circular(12),
                                          ),
                                          child: const Text('使用',
                                              style: TextStyle(
                                                  color: Colors.black,
                                                  fontSize: 11.5,
                                                  fontWeight: FontWeight.w700)),
                                        ),
                                      ),
                                    ],
                                  ),
                                  onTap: () => _toggle(int.tryParse(tid), url),
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
