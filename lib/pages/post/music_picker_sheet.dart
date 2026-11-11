/// 配乐选择弹窗：分页拉取社区「配乐曲库」接口，可试听，选中即用。
///
/// 数据源 `GET /music/tracks?offset&limit&q`（社区后端只读音乐 tracks 表）：
/// - 一页 20 首，滚到接近底部自动加载下一页（往下滑就继续加载）；
/// - 搜索交给服务端全库匹配（歌名/歌手/专辑/上传者），跨页也搜得到；
/// - 试听/落库只依赖 `fname`，拼音乐站 `/music/files/<fname>`（支持 Range 206）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import '../../api/client.dart';
import '../../config.dart';
import '../../design/components.dart';

/// 返回选中配乐 {url,name,cover,durText,artist,title,trackId}；取消返回 null
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
  static const int _pageSize = 20;

  final List<Map<String, dynamic>> _items = [];
  final ScrollController _scroll = ScrollController();
  final AudioPlayer _prev = AudioPlayer(); // 试听
  final TextEditingController _qCtrl = TextEditingController();

  String _q = '';
  Timer? _debounce;
  bool _firstLoading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  int _total = 0;
  String? _err;
  int? _playingId;

  /// 递增请求号：搜索词变化后，旧请求的结果不再上屏（防串页）
  int _reqSeq = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _load(reset: true);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _qCtrl.dispose();
    _prev.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final remain = _scroll.position.maxScrollExtent - _scroll.position.pixels;
    // 距底部不足一屏多 → 预加载下一页，滑动不断档
    if (remain < 360) _load(reset: false);
  }

  Future<void> _load({required bool reset}) async {
    if (reset) {
      _hasMore = true;
      _err = null;
    }
    if (!_hasMore) return;
    if (!reset && (_loadingMore || _firstLoading)) return;
    final seq = ++_reqSeq;
    setState(() {
      if (reset) {
        _firstLoading = true;
      } else {
        _loadingMore = true;
      }
    });
    try {
      final r = await ApiClient.musicTracksPage(
        offset: reset ? 0 : _items.length,
        limit: _pageSize,
        q: _q,
      );
      if (!mounted || seq != _reqSeq) return;
      final list = ((r['list'] ?? []) as List)
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      setState(() {
        if (reset) _items.clear();
        _items.addAll(list);
        _total = ((r['total'] ?? 0) as num).toInt();
        _hasMore = r['hasMore'] == true && list.isNotEmpty;
        _firstLoading = false;
        _loadingMore = false;
        _err = null;
      });
    } catch (e) {
      if (!mounted || seq != _reqSeq) return;
      setState(() {
        _firstLoading = false;
        _loadingMore = false;
        if (reset && _items.isEmpty) _err = e.toString();
      });
    }
  }

  void _onQueryChanged(String v) {
    setState(() => _q = v);
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      setState(() {
        _items.clear();
        _total = 0;
        _firstLoading = true;
        _hasMore = true;
      });
      if (_scroll.hasClients) _scroll.jumpTo(0);
      _load(reset: true);
    });
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
    return SheetShell(
      title: '选择配乐',
      subtitle: _total > 0 ? '来自流萤音乐 · 共 $_total 首，下滑继续加载' : '来自流萤音乐 · 可试听后使用',
      heightFactor: 0.75,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.x3),
            child: TextField(
              controller: _qCtrl,
              onChanged: _onQueryChanged,
              style: AppType.bodySm.copyWith(
                color: const Color(AppColors.textPrimary),
              ),
              cursorColor: const Color(AppColors.accent),
              decoration: const InputDecoration(
                hintText: '搜索歌名 / 歌手 / 专辑',
                prefixIcon: Icon(
                  Icons.search_rounded,
                  size: 18,
                  color: Color(AppColors.textTertiary),
                ),
                prefixIconConstraints: BoxConstraints(minWidth: 38),
                isDense: true,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: AppSpace.x3,
                  vertical: 10,
                ),
              ),
            ),
          ),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _body() {
    if (_err != null && _items.isEmpty) {
      return Center(
        child: ErrorState(
          message: '配乐加载失败：$_err',
          onRetry: () => _load(reset: true),
        ),
      );
    }
    if (_items.isEmpty && _firstLoading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_items.isEmpty) {
      final searching = _q.trim().isNotEmpty;
      return Center(
        child: EmptyState(
          compact: true,
          icon: searching ? Icons.search_off_rounded : Icons.music_off_rounded,
          title: searching ? '没有找到配乐' : '曲库暂空',
          message: searching ? '换个关键词试试' : '稍后再来试试',
        ),
      );
    }
    return ListView.separated(
      controller: _scroll,
      padding: const EdgeInsets.only(bottom: AppSpace.x4),
      itemCount: _items.length + 1, // 末尾：加载状态 / 到底提示
      separatorBuilder: (_, _) => const Hairline(),
      itemBuilder: (_, i) =>
          i == _items.length ? _footer() : _trackRow(_items[i], i),
    );
  }

  Widget _footer() {
    if (_loadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: AppSpace.x3),
        child: Center(
          child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (_hasMore) {
      // 兜底：正常情况下滚到这里已触发预加载，留一个可点入口
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpace.x1),
        child: Center(
          child: TextButton(
            onPressed: () => _load(reset: false),
            child: const Text('加载更多'),
          ),
        ),
      );
    }
    if (_items.length >= 6) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpace.x3),
        child: Center(
          child: Text(
            '已加载全部 $_total 首',
            style: AppType.caption.copyWith(
              color: const Color(AppColors.textTertiary),
            ),
          ),
        ),
      );
    }
    return const SizedBox(height: AppSpace.x2);
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
          PillButton(
            label: '使用',
            size: PillSize.sm,
            onTap: () => Navigator.pop(context, {
              'url': url,
              'name': artist.isEmpty ? title : '$title - $artist',
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
