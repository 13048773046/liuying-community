/// 发帖 / 发短视频页（P0）· 沉浸黑版
///
/// - 图文模式：富文本内容 + 最多 3 图 + 版块 + #话题（服务端自动解析 @与话题）
/// - 视频模式：选本地视频上传（服务端转码）+ 文案/话题/版块 + 封面（auto 首帧或自定义上传）
///
/// 版式：纯黑 + 玻璃顶栏（关闭）→ 图文/短视频分段 → 黑底无边框正文 →
/// 3 列图片网格 / 竖版视频占位 → 配乐条 → 底部固定操作条（图标 + 发布胶囊）。
/// 上传链路 / 状态流逻辑与上一版保持一致，仅重做视觉。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../api/client.dart';
import '../../design/components.dart';
import '../../models/feed_item.dart';
import '../../utils/draft_store.dart';
import '../../utils/responsive.dart';
import 'music_picker_sheet.dart';

/// 统一发布页：图文 / 短视频二合一（页内顶部 Tab 切换，抖音式）
class PostEditorPage extends StatefulWidget {
  const PostEditorPage({super.key});

  @override
  State<PostEditorPage> createState() => _PostEditorPageState();
}

class _PostEditorPageState extends State<PostEditorPage> {
  static const int _maxContent = 2000; // 与服务端 MAX_CONTENT 一致
  static const int _maxImages = 3;
  static const int _maxVideoBytes = 50 * 1024 * 1024; // 50MB
  static const int _maxVideoSeconds = 60;

  final _contentCtrl = TextEditingController();
  final _picker = ImagePicker();
  final List<File> _images = []; // 图文帖图片（≤3）
  File? _videoFile; // 视频文件
  File? _coverFile; // 自定义封面
  bool _coverFromFrame = true; // true=auto 首帧
  String _boardId = '';
  List<Map<String, dynamic>> _boards = [];
  bool _boardsLoaded = false;
  bool _publishing = false;
  // 投票编辑（仅图文模式）：{question, options[]}
  Map<String, dynamic>? _poll;
  double _uploadProgress = 0;

  String _mode = 'text'; // 'text' 图文 | 'video' 短视频（页内切换）
  Map<String, dynamic>? _music; // 配乐 {url,name,cover,durText}

  bool get isVideo => _mode == 'video';

  /// 是否允许点发布：内容非空 + 已选版块 + 不在发布中
  bool get _canPublish =>
      !_publishing &&
      _boardId.isNotEmpty &&
      (_contentCtrl.text.trim().isNotEmpty || _images.isNotEmpty || _videoFile != null);

  // ---------------- 本地草稿（未发布内容自动暂存） ----------------
  Map<String, dynamic>? _draft;
  Timer? _draftTimer;

  @override
  void initState() {
    super.initState();
    _loadBoards();
    _contentCtrl.addListener(_scheduleDraftSave);
    _checkDraft();
  }

  @override
  void dispose() {
    _draftTimer?.cancel();
    // 关闭页面时兜底再存一次（防止输入后 1.2s 内就退出导致丢草稿）
    if (!_publishing) _saveDraftNow();
    _contentCtrl.removeListener(_scheduleDraftSave);
    _contentCtrl.dispose();
    super.dispose();
  }

  /// 进入页面时检查是否有上次未发布的草稿（不自动覆盖，给用户选）
  Future<void> _checkDraft() async {
    final d = await DraftStore.load();
    if (!mounted || d == null) return;
    // 用户已经开始输入就不打扰
    if (_contentCtrl.text.trim().isNotEmpty) return;
    setState(() => _draft = d);
  }

  /// 输入/选择变化后延迟保存，避免每个字符都写盘
  void _scheduleDraftSave() {
    _draftTimer?.cancel();
    _draftTimer = Timer(const Duration(milliseconds: 1200), _saveDraftNow);
  }

  void _saveDraftNow() {
    if (_publishing) return;
    DraftStore.save(
      content: _contentCtrl.text,
      boardId: _boardId,
      boardName: _boardId.isEmpty ? '' : _boardName(_boardId),
      mode: _mode,
      musicName: (_music?['name'] ?? '').toString(),
    );
  }

  /// 从草稿恢复正文/版块/模式
  void _restoreDraft() {
    final d = _draft;
    if (d == null) return;
    setState(() {
      _contentCtrl.text = (d['content'] ?? '').toString();
      _boardId = (d['boardId'] ?? '').toString();
      _mode = (d['mode'] ?? 'text').toString() == 'video' ? 'video' : 'text';
      _draft = null;
    });
    showAppToast(context, '已恢复上次编辑的内容');
  }

  /// 丢弃草稿
  Future<void> _discardDraft() async {
    await DraftStore.clear();
    if (!mounted) return;
    setState(() => _draft = null);
  }

  /// 草稿恢复提示条
  Widget _draftBanner() {
    final d = _draft;
    if (d == null) return const SizedBox.shrink();
    final savedAt = ((d['savedAt'] ?? 0) as num).toInt();
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpace.x3),
      padding: const EdgeInsets.fromLTRB(
          AppSpace.x3, AppSpace.x3, AppSpace.x2, AppSpace.x3),
      decoration: BoxDecoration(
        color: const Color(AppColors.accent).withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(
            color: const Color(AppColors.accent).withValues(alpha: 0.45)),
      ),
      child: Row(
        children: [
          const Icon(Icons.history_rounded,
              size: 18, color: Color(AppColors.accent)),
          const SizedBox(width: AppSpace.x2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('有未发布的草稿', style: AppType.label),
                const SizedBox(height: 2),
                Text(
                  savedAt > 0 ? '保存于 ${timeAgo(savedAt)}' : '未发布的内容还留着',
                  style: AppType.micro,
                ),
              ],
            ),
          ),
          PillButton(
            label: '恢复',
            size: PillSize.sm,
            onTap: _restoreDraft,
          ),
          const SizedBox(width: AppSpace.x1),
          PressableScale(
            onTap: _discardDraft,
            child: const Padding(
              padding: EdgeInsets.all(AppSpace.x2),
              child: Icon(Icons.close_rounded,
                  size: 16, color: Color(AppColors.textTertiary)),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _loadBoards() async {
    try {
      final j = await ApiClient.boards();
      if (!mounted) return;
      // 平铺树为可选列表
      final flat = <Map<String, dynamic>>[];
      void walk(List l, int depth) {
        for (final n in l) {
          final item = Map<String, dynamic>.from(n as Map);
          item['_depth'] = depth;
          flat.add(item);
          final ch = (n['children'] ?? []) as List;
          if (ch.isNotEmpty) walk(ch, depth + 1);
        }
      }

      walk((j['list'] ?? []) as List, 0);
      setState(() {
        _boards = flat;
        _boardsLoaded = true;
      });
    } catch (_) {
      if (mounted) setState(() => _boardsLoaded = true);
    }
  }

  // ---------------- 素材选择 ----------------

  Future<void> _pickImages() async {
    if (_images.length >= _maxImages) {
      _toast('最多 $_maxImages 张图片');
      return;
    }
    final picked = await _picker.pickMultiImage(limit: _maxImages - _images.length);
    if (picked.isEmpty) return;
    setState(() {
      _images.addAll(picked.map((e) => File(e.path)));
    });
  }

  Future<void> _pickVideo() async {
    final v = await _picker.pickVideo(
        source: ImageSource.gallery, maxDuration: const Duration(seconds: _maxVideoSeconds));
    if (v == null) return;
    final f = File(v.path);
    if (!f.existsSync()) {
      _toast('视频文件不存在', error: true);
      return;
    }
    final size = f.lengthSync();
    if (size > _maxVideoBytes) {
      _toast('视频过大（≤50MB），请压缩后重试', error: true);
      return;
    }
    setState(() => _videoFile = f);
  }

  Future<void> _pickCover() async {
    final v = await _picker.pickImage(source: ImageSource.gallery);
    if (v == null) return;
    setState(() {
      _coverFile = File(v.path);
      _coverFromFrame = false;
    });
  }

  // ---------------- 发布 ----------------

  bool _validate() {
    final content = _contentCtrl.text.trim();
    if (content.isEmpty && _images.isEmpty && _videoFile == null) {
      _toast('写点什么再发布吧');
      return false;
    }
    if (_boardId.isEmpty) {
      _toast('请选择版块');
      return false;
    }
    if (isVideo && _videoFile == null) {
      _toast('请先选择视频');
      return false;
    }
    return true;
  }

  Future<void> _publish() async {
    if (_publishing) return;
    if (!_validate()) return;
    setState(() => _publishing = true);
    _uploadProgress = 0;
    try {
      final content = _contentCtrl.text.trim();
      if (!isVideo) {
        // 图文帖：先传图
        final names = <String>[];
        for (var i = 0; i < _images.length; i++) {
          setState(() {
            _uploadProgress = (i + 1) / (_images.length + 1);
          });
          final j = await ApiClient.uploadImage(_images[i].path);
          names.add(j['name'] as String);
        }
        await ApiClient.post('/post', body: {
          'content': content,
          'images': names,
          'boardId': _boardId,
          if (_poll != null) 'poll': _poll,
          if (_music != null) 'music': _music,
        });
        if (!mounted) return;
        await DraftStore.clear();
    if (!mounted) return;
    Navigator.pop(context, true);
        _toast('发布成功，等待审核');
      } else {
        // 短视频：上传 → 转码 → 发帖
        setState(() => _uploadProgress = 0.1);
        final up = await ApiClient.uploadVideo(_videoFile!.path);
        final vid = up['videoId'] as String;
        // 封面：自定义上传图 / auto 首帧
        var cover = 'auto';
        if (!_coverFromFrame && _coverFile != null) {
          final cj = await ApiClient.uploadImage(_coverFile!.path);
          cover = cj['name'] as String;
        }
        setState(() => _uploadProgress = 0.55);
        // 等待转码完成（最长 4 分钟）
        var ready = false;
        for (var i = 0; i < 24; i++) {
          try {
            final st = await ApiClient.videoStatus(vid);
            final s = (st['status'] ?? '') as String;
            if (s == 'done' || s == 'ready') {
              ready = true;
              break;
            }
            if (s == 'failed') break;
          } catch (_) {}
          await Future.delayed(const Duration(seconds: 10));
        }
        if (!ready) {
          _toast('视频转码较慢，可稍后从草稿继续', error: true);
          if (!mounted) return;
          Navigator.pop(context);
          return;
        }
        setState(() => _uploadProgress = 0.85);
        await ApiClient.post('/video/post', body: {
          'video': vid,
          'cover': cover,
          'duration': (up['duration'] ?? 0) is num ? (up['duration'] as num).toInt() : 0,
          'content': content,
          'boardId': _boardId,
          if (_music != null) 'music': _music,
        });
        if (!mounted) return;
        await DraftStore.clear();
    if (!mounted) return;
    Navigator.pop(context, true);
        _toast('发布成功，等待审核');
      }
    } catch (e) {
      // ApiClient 已把网络异常归类为中文文案；这里兜底格式化
      _toast(e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _publishing = false);
    }
  }

  /// 发布进度阶段文案
  String get _stageLabel {
    if (!isVideo) return '发布中…';
    if (_uploadProgress <= 0.1) return '正在上传视频…';
    if (_uploadProgress < 0.55) return '上传完成，等待转码…';
    if (_uploadProgress < 0.85) return '转码完成，正在发布…';
    return '发布中…';
  }

  void _toast(String s, {bool error = false}) {
    if (!mounted) return;
    showAppToast(context, s);
  }

  // ---------------- UI ----------------

  @override
  Widget build(BuildContext context) {
    return ImmersivePage(
      child: Column(
        children: [
          GlassTopBar(
            title: '发布',
            solid: true,
            showBack: false,
            actions: [
              IconCircleButton(
                icon: Icons.close_rounded,
                size: 34,
                iconSize: 18,
                background: Colors.white.withValues(alpha: 0.06),
                onTap: () => Navigator.pop(context),
              ),
            ],
          ),
          // 图文 / 短视频分段
          FeedTabs(
            labels: const ['发图文', '发短视频'],
            index: isVideo ? 1 : 0,
            onChanged: (i) {
              setState(() => _mode = i == 0 ? 'text' : 'video');
              _scheduleDraftSave();
            },
          ),
          Expanded(
            child: AbsorbPointer(
              // 发布中锁定输入区，防重复操作
              absorbing: _publishing,
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(
                    AppSpace.gutter, AppSpace.x2, AppSpace.gutter, AppSpace.x6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _draftBanner(),
                    _boardRow(),
                    const SizedBox(height: AppSpace.x4),
                    _contentField(),
                    if (_poll != null) ...[
                      const SizedBox(height: AppSpace.x3),
                      _pollSummary(),
                    ],
                    const SizedBox(height: AppSpace.x4),
                    if (!isVideo) _imageGrid() else _videoSection(),
                    const SizedBox(height: AppSpace.x4),
                    _musicBar(),
                    const SizedBox(height: AppSpace.x4),
                    Text(
                      isVideo
                          ? '支持 #话题 / @好友，视频 ≤60s / ≤50MB'
                          : '支持 #话题 / @好友，图片最多 $_maxImages 张',
                      style: AppType.caption,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_publishing) _progressPanel(),
          _bottomBar(),
        ],
      ),
    );
  }

  // ---------- 底部固定操作条：图标 + 发布胶囊 ----------
  Widget _bottomBar() {
    return Container(
      decoration: const BoxDecoration(
        color: Color(AppColors.canvas),
        border: Border(top: BorderSide(color: Color(AppColors.hairline), width: 0.5)),
      ),
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpace.x3, vertical: AppSpace.x2),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            _barIcon(
              icon: isVideo ? Icons.videocam_outlined : Icons.image_outlined,
              active: isVideo ? _videoFile != null : _images.isNotEmpty,
              badge: isVideo ? (_videoFile != null ? 1 : 0) : _images.length,
              onTap: isVideo ? _pickVideo : _pickImages,
            ),
            _barIcon(
              icon: Icons.tag_rounded,
              onTap: _pickTopic,
            ),
            _barIcon(
              icon: Icons.music_note_rounded,
              active: _music != null,
              onTap: _pickMusic,
            ),
            if (!isVideo)
              _barIcon(
                icon: Icons.how_to_vote_outlined,
                active: _poll != null,
                onTap: _editPoll,
              ),
            _barIcon(
              icon: Icons.dashboard_outlined,
              active: _boardId.isNotEmpty,
              onTap: _openBoardSheet,
            ),
            const SizedBox(width: AppSpace.x2),
            Expanded(
              child: PillButton(
                label: isVideo ? '发布视频' : '发布',
                expand: true,
                glow: true,
                loading: _publishing,
                enabled: _canPublish,
                onTap: _publish,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _barIcon({
    required IconData icon,
    required VoidCallback onTap,
    bool active = false,
    int badge = 0,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: AppSpace.x1),
      child: IconCircleButton(
        icon: icon,
        size: 36,
        iconSize: 19,
        badge: badge,
        background: Colors.white.withValues(alpha: 0.06),
        color: active
            ? const Color(AppColors.accent)
            : const Color(AppColors.textPrimary),
        onTap: onTap,
      ),
    );
  }

  // ---------- 版块：一行已选状态 + SheetShell 选择面板 ----------
  Widget _boardRow() {
    final name = _boardId.isEmpty ? '选择版块' : _boardName(_boardId);
    return PressableScale(
      onTap: _openBoardSheet,
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpace.x4, vertical: AppSpace.x3),
        decoration: BoxDecoration(
          color: const Color(AppColors.card),
          borderRadius: AppRadius.rMd,
          border: Border.all(
            color: _boardId.isEmpty
                ? const Color(AppColors.border)
                : const Color(AppColors.accent).withValues(alpha: 0.45),
          ),
        ),
        child: Row(
          children: [
            Icon(
              Icons.dashboard_outlined,
              size: 17,
              color: _boardId.isEmpty
                  ? const Color(AppColors.textTertiary)
                  : const Color(AppColors.accent),
            ),
            const SizedBox(width: AppSpace.x2),
            Expanded(
              child: Text(
                _boardsLoaded ? name : '加载版块中…',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppType.body.copyWith(
                  color: _boardId.isEmpty
                      ? const Color(AppColors.textTertiary)
                      : const Color(AppColors.textPrimary),
                  fontWeight:
                      _boardId.isEmpty ? FontWeight.w400 : FontWeight.w600,
                ),
              ),
            ),
            const Icon(Icons.chevron_right_rounded,
                size: 18, color: Color(AppColors.textTertiary)),
          ],
        ),
      ),
    );
  }

  /// 版块显示名（含图标）
  String _boardName(String id) {
    for (final b in _boards) {
      if (b['id'] == id) return '${b['icon'] ?? '📌'} ${b['name']}';
    }
    return '选择版块';
  }

  Future<void> _openBoardSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (bc) => SheetShell(
        title: '选择版块',
        subtitle: '发布后内容归入所选版块',
        heightFactor: 0.62,
        padding: EdgeInsets.zero,
        child: !_boardsLoaded
            ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
            : _boards.isEmpty
                ? const Center(
                    child: EmptyState(
                      compact: true,
                      icon: Icons.dashboard_outlined,
                      title: '暂无版块',
                      message: '稍后再试',
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.only(bottom: AppSpace.x4),
                    itemCount: _boards.length,
                    separatorBuilder: (_, _) =>
                        const Hairline(indent: AppSpace.gutter),
                    itemBuilder: (_, i) {
                      final b = _boards[i];
                      final sel = b['id'] == _boardId;
                      final depth = ((b['_depth'] ?? 0) as num).toInt();
                      return PressableScale(
                        onTap: () {
                          Navigator.of(bc).pop();
                          setState(() => _boardId = b['id'] as String);
    _scheduleDraftSave();
                        },
                        child: Padding(
                          padding: EdgeInsets.fromLTRB(
                            AppSpace.gutter + depth * AppSpace.x3,
                            AppSpace.x3,
                            AppSpace.gutter,
                            AppSpace.x3,
                          ),
                          child: Row(
                            children: [
                              Text(b['icon'] ?? '📌', style: AppType.body),
                              const SizedBox(width: AppSpace.x2),
                              Expanded(
                                child: Text(
                                  '${b['name']}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppType.body.copyWith(
                                    color: sel
                                        ? const Color(AppColors.accent)
                                        : const Color(AppColors.textPrimary),
                                    fontWeight: sel
                                        ? FontWeight.w600
                                        : FontWeight.w400,
                                  ),
                                ),
                              ),
                              if (sel)
                                const Icon(Icons.check_rounded,
                                    size: 18, color: Color(AppColors.accent)),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
      ),
    );
  }

  // ---------- 正文：黑底无边框 ----------
  Widget _contentField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _contentCtrl,
          maxLines: 8,
          minLines: 4,
          maxLength: _maxContent,
          onChanged: (_) => setState(() {}), // 驱动发布按钮状态与字数
          cursorColor: const Color(AppColors.accent),
          style: AppType.body.copyWith(height: 1.5),
          decoration: InputDecoration(
            hintText: isVideo
                ? '写一句视频文案，带 #话题 可以上热门'
                : '分享此刻… 支持 #话题 与 @好友',
            hintStyle:
                AppType.body.copyWith(color: const Color(AppColors.textTertiary)),
            filled: false,
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            counterText: '',
            isDense: true,
            contentPadding: EdgeInsets.zero,
          ),
        ),
        const SizedBox(height: AppSpace.x2),
        Row(
          children: [
            TagPill(
              label: '@好友',
              compact: true,
              onTap: () => _insertAt(' @'),
            ),
            const Spacer(),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _contentCtrl,
              builder: (_, v, _) => Text(
                '${v.text.length}/$_maxContent',
                style: AppType.micro.copyWith(
                  color: v.text.length >= _maxContent
                      ? const Color(AppColors.danger)
                      : const Color(AppColors.textTertiary),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ---------- 投票摘要（编辑/清除） ----------
  Widget _pollSummary() {
    return PressableScale(
      onTap: _editPoll,
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpace.x3, vertical: AppSpace.x3),
        decoration: BoxDecoration(
          color: const Color(AppColors.card),
          borderRadius: AppRadius.rMd,
          border: Border.all(color: const Color(AppColors.border)),
        ),
        child: Row(
          children: [
            const Icon(Icons.how_to_vote_rounded,
                size: 16, color: Color(AppColors.accent)),
            const SizedBox(width: AppSpace.x2),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    (_poll!['question'] ?? '') as String,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.bodySm
                        .copyWith(color: const Color(AppColors.textPrimary)),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    (((_poll!['options'] ?? []) as List)
                        .map((e) => e.toString())
                        .join(' / ')),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.micro,
                  ),
                ],
              ),
            ),
            PressableScale(
              onTap: () => setState(() => _poll = null),
              scale: 0.9,
              child: const Padding(
                padding: EdgeInsets.all(AppSpace.x1),
                child: Icon(Icons.close_rounded,
                    size: 16, color: Color(AppColors.textTertiary)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------- 配乐条 ----------
  Widget _musicBar() {
    final m = _music;
    return PressableScale(
      onTap: _pickMusic,
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpace.x3, vertical: AppSpace.x3),
        decoration: BoxDecoration(
          color: const Color(AppColors.card),
          borderRadius: AppRadius.rMd,
          border: Border.all(color: const Color(AppColors.border)),
        ),
        child: Row(
          children: [
            Container(
              width: 30,
              height: 30,
              decoration: const BoxDecoration(
                color: Color(AppColors.accentSoft),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.music_note_rounded,
                  size: 17, color: Color(AppColors.accent)),
            ),
            const SizedBox(width: AppSpace.x3),
            Expanded(
              child: m == null
                  ? Text('添加配乐',
                      style: AppType.bodySm
                          .copyWith(color: const Color(AppColors.textSecondary)))
                  : Row(
                      children: [
                        Expanded(
                          child: Text(
                            m['name'] as String,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppType.bodySm.copyWith(
                              color: const Color(AppColors.textPrimary),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(width: AppSpace.x2),
                        const Icon(Icons.graphic_eq_rounded,
                            size: 14, color: Color(AppColors.accent)),
                      ],
                    ),
            ),
            if (m != null)
              PressableScale(
                onTap: () => setState(() => _music = null),
                scale: 0.9,
                child: const Padding(
                  padding: EdgeInsets.all(AppSpace.x1),
                  child: Icon(Icons.close_rounded,
                      size: 16, color: Color(AppColors.textTertiary)),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickMusic() async {
    final picked = await showMusicPicker(context);
    if (picked != null && mounted) setState(() => _music = picked);
  }

  void _insertAt(String s) {
    final t = _contentCtrl.text;
    final sel = _contentCtrl.selection;
    final start = sel.isValid ? sel.start : t.length;
    final end = sel.isValid ? sel.end : t.length;
    final next = t.replaceRange(start, end, s);
    _contentCtrl.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: start + s.length),
    );
    setState(() {});
  }

  /// 话题选择器：从热门话题列表选一个插入 #话题
  Future<void> _pickTopic() async {
    List<Map<String, dynamic>> topics;
    try {
      topics = await ApiClient.topicsHot();
    } catch (_) {
      topics = [];
    }
    if (!mounted) return;
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (bc) => SheetShell(
        title: '选择话题',
        subtitle: '热门话题 · 选中即插入正文',
        heightFactor: 0.5,
        padding: EdgeInsets.zero,
        child: topics.isEmpty
            ? const Center(
                child: EmptyState(
                  compact: true,
                  icon: Icons.tag_rounded,
                  title: '暂无话题',
                  message: '可手动输入 #话题#',
                ),
              )
            : ListView.separated(
                padding: const EdgeInsets.only(bottom: AppSpace.x4),
                itemCount: topics.length,
                separatorBuilder: (_, _) =>
                    const Hairline(indent: AppSpace.gutter),
                itemBuilder: (_, i) {
                  final t = topics[i];
                  final name = (t['name'] ?? '') as String;
                  return ListRow(
                    leading: const Icon(Icons.tag_rounded,
                        size: 18, color: Color(AppColors.accent)),
                    title: '#$name',
                    subtitle: '${(t['count'] ?? 0)} 帖参与',
                    showChevron: false,
                    onTap: () => Navigator.pop(bc, name),
                  );
                },
              ),
      ),
    );
    if (picked != null && picked.isNotEmpty) {
      _insertAt(' #$picked# ');
    }
  }

  /// 投票编辑器：问题 + 2~4 选项
  Future<void> _editPoll() async {
    final qCtrl = TextEditingController(
        text: (_poll?['question'] ?? '') as String);
    final opts = List<String>.from(
        ((_poll?['options'] ?? []) as List).map((e) => e.toString()));
    if (opts.isEmpty) {
      opts.addAll(['', '']);
    }
    final optCtrls = [for (final o in opts) TextEditingController(text: o)];
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (bc) => SheetShell(
        title: '发起投票',
        subtitle: '问题 + 2~4 个选项',
        child: StatefulBuilder(
          builder: (bc, setB) {
            Widget btn() {
              final q = qCtrl.text.trim();
              final os = optCtrls
                  .map((c) => c.text.trim())
                  .where((x) => x.isNotEmpty)
                  .toList();
              final valid = q.isNotEmpty && os.length >= 2;
              return PillButton(
                label: valid ? '完成' : '问题与至少 2 个选项',
                expand: true,
                enabled: valid,
                onTap: () {
                  setState(() {
                    _poll = {
                      'question': q,
                      'options': os,
                    };
                  });
                  Navigator.pop(bc, true);
                },
              );
            }

            Widget optField(int i) {
              return Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: optCtrls[i],
                      maxLength: 40,
                      onChanged: (_) => setB(() {}),
                      style: AppType.bodySm
                          .copyWith(color: const Color(AppColors.textPrimary)),
                      cursorColor: const Color(AppColors.accent),
                      decoration: InputDecoration(
                        counterText: '',
                        hintText: '选项 ${i + 1}',
                        isDense: true,
                      ),
                    ),
                  ),
                  if (optCtrls.length > 2)
                    PressableScale(
                      onTap: () => setB(() {
                        optCtrls.removeAt(i).dispose();
                      }),
                      scale: 0.9,
                      child: const Padding(
                        padding: EdgeInsets.all(AppSpace.x2),
                        child: Icon(Icons.close_rounded,
                            size: 16, color: Color(AppColors.textTertiary)),
                      ),
                    ),
                ],
              );
            }

            return SingleChildScrollView(
              padding: const EdgeInsets.only(bottom: AppSpace.x2),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: qCtrl,
                    maxLength: 60,
                    onChanged: (_) => setB(() {}),
                    style: AppType.body
                        .copyWith(color: const Color(AppColors.textPrimary)),
                    cursorColor: const Color(AppColors.accent),
                    decoration: const InputDecoration(
                      counterText: '',
                      hintText: '投票问题',
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: AppSpace.x3),
                  for (var i = 0; i < optCtrls.length; i++) ...[
                    optField(i),
                    const SizedBox(height: AppSpace.x2),
                  ],
                  if (optCtrls.length < 4)
                    PressableScale(
                      onTap: () => setB(() {
                        optCtrls.add(TextEditingController());
                      }),
                      child: Padding(
                        padding:
                            const EdgeInsets.symmetric(vertical: AppSpace.x1),
                        child: Row(
                          children: [
                            const Icon(Icons.add_circle_outline,
                                size: 16, color: Color(AppColors.accent)),
                            const SizedBox(width: AppSpace.x2),
                            Text('添加选项',
                                style: AppType.caption.copyWith(
                                    color: const Color(AppColors.accent))),
                          ],
                        ),
                      ),
                    ),
                  const SizedBox(height: AppSpace.x4),
                  btn(),
                ],
              ),
            );
          },
        ),
      ),
    );
    // 清理控制器（本轮局部创建，直接释放）
    for (final c in optCtrls) {
      c.dispose();
    }
    qCtrl.dispose();
    if (saved == true && mounted) setState(() {});
  }

  // ---------- 图文图片区：3 列圆角网格 ----------
  Widget _imageGrid() {
    final showAdd = _images.length < _maxImages;
    final total = _images.length + (showAdd ? 1 : 0);
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: AppSpace.x2,
        crossAxisSpacing: AppSpace.x2,
      ),
      itemCount: total,
      itemBuilder: (_, i) {
        if (showAdd && i == _images.length) {
          return PressableScale(
            onTap: _pickImages,
            child: Container(
              decoration: BoxDecoration(
                color: const Color(AppColors.card),
                borderRadius: AppRadius.rMd,
                border: Border.all(color: const Color(AppColors.border)),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.add_photo_alternate_outlined,
                      color: Color(AppColors.textSecondary), size: 26),
                  const SizedBox(height: AppSpace.x1),
                  Text('${_maxImages - _images.length} 图',
                      style: AppType.micro),
                ],
              ),
            ),
          );
        }
        final f = _images[i];
        return Stack(
          children: [
            Positioned.fill(
              child: ClipRRect(
                borderRadius: AppRadius.rMd,
                child: Image.file(f, fit: BoxFit.cover),
              ),
            ),
            Positioned(
              right: AppSpace.x1,
              top: AppSpace.x1,
              child: PressableScale(
                onTap: () => setState(() => _images.remove(f)),
                scale: 0.9,
                child: Container(
                  padding: const EdgeInsets.all(AppSpace.x1),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.close_rounded,
                      size: 14, color: Colors.white),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  // ---------- 视频选择区 ----------
  Widget _videoSection() {
    return Container(
      padding: const EdgeInsets.all(AppSpace.x3),
      decoration: BoxDecoration(
        color: const Color(AppColors.card),
        borderRadius: AppRadius.rLg,
        border: Border.all(color: const Color(AppColors.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_videoFile == null) _videoPlaceholder() else _videoPreview(),
          const SizedBox(height: AppSpace.x4),
          const Text('封面', style: AppType.label),
          const SizedBox(height: AppSpace.x2),
          Row(
            children: [
              _coverChip('auto', '自动首帧', _coverFromFrame, () {
                setState(() {
                  _coverFromFrame = true;
                  _coverFile = null;
                });
              }),
              const SizedBox(width: AppSpace.x2),
              _coverChip('custom', '自定义上传', !_coverFromFrame, _pickCover),
            ],
          ),
          if (_coverFile != null) ...[
            const SizedBox(height: AppSpace.x3),
            ClipRRect(
              borderRadius: AppRadius.rSm,
              child: Image.file(_coverFile!,
                  width: 80, height: 80, fit: BoxFit.cover),
            ),
          ],
        ],
      ),
    );
  }

  /// 未选视频：竖版占位卡
  Widget _videoPlaceholder() {
    return PressableScale(
      onTap: _pickVideo,
      child: Container(
        height: rw(context, 220),
        width: double.infinity,
        decoration: BoxDecoration(
          color: const Color(AppColors.elevated),
          borderRadius: AppRadius.rMd,
          border: Border.all(color: const Color(AppColors.border)),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: const BoxDecoration(
                color: Color(AppColors.accentSoft),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.video_library_outlined,
                  color: Color(AppColors.accent), size: 28),
            ),
            const SizedBox(height: AppSpace.x3),
            Text('选择本地视频',
                style: AppType.body.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: AppSpace.x1),
            Text('≤ 60 秒 · ≤ 50MB · 竖版更佳', style: AppType.caption),
          ],
        ),
      ),
    );
  }

  Widget _videoPreview() {
    final f = _videoFile!;
    final sizeMb = (f.lengthSync() / (1024 * 1024)).toStringAsFixed(1);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 预览（取文件作为封面帧展示；非视频首帧时为图标兜底）
        ClipRRect(
          borderRadius: AppRadius.rMd,
          child: Image.file(
            f,
            width: 96,
            height: 128,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => Container(
              width: 96,
              height: 128,
              color: const Color(AppColors.elevated),
              child: const Icon(Icons.movie_outlined,
                  color: Color(AppColors.textSecondary)),
            ),
          ),
        ),
        const SizedBox(width: AppSpace.x3),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                f.path.split('/').last,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppType.bodySm
                    .copyWith(color: const Color(AppColors.textPrimary)),
              ),
              const SizedBox(height: AppSpace.x2),
              // 时长/大小徽标
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: AppSpace.x2, vertical: AppSpace.x1),
                decoration: BoxDecoration(
                  color: const Color(AppColors.elevated),
                  borderRadius: AppRadius.rXs,
                ),
                child: Text('$_maxVideoSeconds 秒 · $sizeMb MB',
                    style: AppType.micro),
              ),
              const SizedBox(height: AppSpace.x3),
              Row(
                children: [
                  _miniAction(Icons.refresh_rounded, '重新选择', _pickVideo),
                  const SizedBox(width: AppSpace.x2),
                  _miniAction(Icons.delete_outline_rounded, '删除', () {
                    setState(() => _videoFile = null);
                  }),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _miniAction(IconData icon, String label, VoidCallback onTap) {
    return PressableScale(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpace.x3, vertical: AppSpace.x1),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.07),
          borderRadius: AppRadius.rPill,
          border: Border.all(color: const Color(AppColors.border)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: const Color(AppColors.accent)),
            const SizedBox(width: AppSpace.x1),
            Text(label,
                style: AppType.caption
                    .copyWith(color: const Color(AppColors.accent))),
          ],
        ),
      ),
    );
  }

  Widget _coverChip(String id, String label, bool sel, VoidCallback onTap) {
    return PressableScale(
      onTap: onTap,
      child: AnimatedContainer(
        duration: AppMotion.base,
        curve: AppMotion.standard,
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpace.x4, vertical: AppSpace.x2),
        decoration: BoxDecoration(
          color: sel
              ? const Color(AppColors.accent).withValues(alpha: 0.14)
              : Colors.white.withValues(alpha: 0.05),
          borderRadius: AppRadius.rPill,
          border: Border.all(
            color: sel
                ? const Color(AppColors.accent).withValues(alpha: 0.55)
                : const Color(AppColors.border),
          ),
        ),
        child: Text(
          label,
          style: AppType.caption.copyWith(
            color: sel
                ? const Color(AppColors.accent)
                : const Color(AppColors.textSecondary),
            fontWeight: sel ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  // ---------- 发布进度面板 ----------
  Widget _progressPanel() {
    return Container(
      padding: const EdgeInsets.fromLTRB(
          AppSpace.x4, AppSpace.x3, AppSpace.x4, AppSpace.x2),
      decoration: const BoxDecoration(
        color: Color(AppColors.canvas),
        border: Border(top: BorderSide(color: Color(AppColors.hairline), width: 0.5)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text(_stageLabel, style: AppType.caption),
              const Spacer(),
              Text('${(_uploadProgress * 100).round()}%',
                  style: AppType.numeric
                      .copyWith(color: const Color(AppColors.accent))),
            ],
          ),
          const SizedBox(height: AppSpace.x2),
          ClipRRect(
            borderRadius: AppRadius.rPill,
            child: LinearProgressIndicator(
              value: _uploadProgress.clamp(0.0, 1.0),
              minHeight: 4,
              backgroundColor: const Color(AppColors.hairline),
              color: const Color(AppColors.accent),
            ),
          ),
        ],
      ),
    );
  }
}
