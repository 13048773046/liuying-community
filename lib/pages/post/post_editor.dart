/// 发帖 / 发短视频页（P0）· UI v2
///
/// - 图文模式：富文本内容 + 最多 3 图 + 版块 + #话题（服务端自动解析 @与话题）
/// - 视频模式：选本地视频上传（服务端转码）+ 文案/话题/版块 + 封面（auto 首帧或自定义上传）
///
/// v2 变化：
/// - 上传链路加固：本地 ≤50MB/≤60s 校验、错误中文浮层、失败自动重试（见 ApiClient.uploadVideo）
/// - 状态流加固：发布中全局防重复提交、按钮 loading、阶段进度文案
/// - UI 重做：自定义顶部导航（渐变发布钮）、带图标版块胶囊、字数统计 + 快捷插入、竖版媒体占位卡
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../api/client.dart';
import '../../config.dart';

/// mode: text=发图文帖，video=发短视频
class PostEditorPage extends StatefulWidget {
  final String mode;
  const PostEditorPage({super.key, this.mode = 'text'});

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
  double _uploadProgress = 0;

  bool get isVideo => widget.mode == 'video';

  /// 是否允许点发布：内容非空 + 已选版块 + 不在发布中
  bool get _canPublish =>
      !_publishing &&
      _boardId.isNotEmpty &&
      (_contentCtrl.text.trim().isNotEmpty || _images.isNotEmpty || _videoFile != null);

  @override
  void initState() {
    super.initState();
    _loadBoards();
  }

  @override
  void dispose() {
    _contentCtrl.dispose();
    super.dispose();
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
        });
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
        });
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
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(s, style: const TextStyle(fontSize: 13)),
        backgroundColor: error ? const Color(0xFFC62828) : const Color(AppTheme.card),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        duration: const Duration(seconds: 2),
      ));
  }

  // ---------------- UI ----------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(AppTheme.bg),
      body: SafeArea(
        child: Column(
          children: [
            _topBar(),
            Expanded(
              child: AbsorbPointer(
                // 发布中锁定输入区，防重复操作
                absorbing: _publishing,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _boardBar(),
                      const SizedBox(height: 14),
                      _contentCard(),
                      const SizedBox(height: 12),
                      if (!isVideo) _imageGrid() else _videoSection(),
                      const SizedBox(height: 10),
                      Text(
                        isVideo
                            ? '支持 #话题 / @好友，视频 ≤60s / ≤50MB'
                            : '支持 #话题 / @好友，图片最多 $_maxImages 张',
                        style: const TextStyle(
                            color: Color(AppTheme.textTertiary), fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (_publishing) _progressPanel(),
          ],
        ),
      ),
    );
  }

  // ---------- 顶部导航：关闭 + 标题 + 渐变发布按钮 ----------
  Widget _topBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Row(
        children: [
          // 关闭
          _roundIconBtn(
            icon: Icons.close,
            onTap: () => Navigator.pop(context),
          ),
          // 标题
          Expanded(
            child: Center(
              child: Text(
                isVideo ? '发布短视频' : '发布帖子',
                style: const TextStyle(
                    color: Color(AppTheme.textPrimary),
                    fontSize: 17,
                    fontWeight: FontWeight.w600),
              ),
            ),
          ),
          // 发布按钮（固定宽度保标题居中）
          SizedBox(
            width: 88,
            child: Align(alignment: Alignment.centerRight, child: _publishButton()),
          ),
        ],
      ),
    );
  }

  Widget _roundIconBtn({required IconData icon, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: const Color(AppTheme.card),
          shape: BoxShape.circle,
          border: Border.all(color: const Color(AppTheme.border)),
        ),
        child: Icon(icon, size: 18, color: const Color(AppTheme.textPrimary)),
      ),
    );
  }

  Widget _publishButton() {
    if (_publishing) {
      return Container(
        width: 76,
        height: 36,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: const Color(AppTheme.card),
          borderRadius: BorderRadius.circular(18),
        ),
        child: const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2, color: Color(AppTheme.accent)),
        ),
      );
    }
    final enabled = _canPublish;
    return GestureDetector(
      onTap: enabled ? _publish : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 76,
        height: 36,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          gradient: enabled
              ? const LinearGradient(colors: [Color(AppTheme.gradStart), Color(AppTheme.gradEnd)])
              : null,
          color: enabled ? null : const Color(0xFF2A2A2E),
          borderRadius: BorderRadius.circular(18),
          boxShadow: enabled
              ? [
                  BoxShadow(
                      color: const Color(AppTheme.accent).withValues(alpha: 0.35),
                      blurRadius: 10,
                      offset: const Offset(0, 3)),
                ]
              : null,
        ),
        child: Text(
          '发布',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            color: enabled ? Colors.white : const Color(AppTheme.textTertiary),
          ),
        ),
      ),
    );
  }

  // ---------- 版块选择：带图标胶囊 ----------
  Widget _boardBar() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('选择版块',
            style: TextStyle(color: Color(AppTheme.textSecondary), fontSize: 13)),
        const SizedBox(height: 8),
        if (!_boardsLoaded)
          const Text('加载版块中…',
              style: TextStyle(color: Color(AppTheme.textTertiary), fontSize: 12))
        else
          SizedBox(
            height: 36,
            child: _boards.isEmpty
                ? const Text('暂无版块',
                    style: TextStyle(color: Color(AppTheme.textTertiary), fontSize: 12))
                : ListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: _boards.length,
                    itemBuilder: (_, i) {
                      final b = _boards[i];
                      final sel = b['id'] == _boardId;
                      final depth = ((b['_depth'] ?? 0) as num).toInt();
                      return Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: GestureDetector(
                          onTap: () => setState(() => _boardId = b['id'] as String),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            padding: const EdgeInsets.symmetric(horizontal: 13),
                            decoration: BoxDecoration(
                              color: sel
                                  ? const Color(AppTheme.accentSoft)
                                  : const Color(AppTheme.card),
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(
                                  color: sel
                                      ? const Color(AppTheme.accent)
                                      : const Color(AppTheme.border)),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(b['icon'] ?? '📌',
                                    style: const TextStyle(fontSize: 12)),
                                const SizedBox(width: 4),
                                Text(
                                  '${depth > 0 ? '·' * depth : ''}${b['name']}',
                                  style: TextStyle(
                                    color: sel
                                        ? const Color(AppTheme.accent)
                                        : const Color(AppTheme.textSecondary),
                                    fontSize: 13,
                                    fontWeight: sel ? FontWeight.w600 : FontWeight.w400,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
      ],
    );
  }

  // ---------- 内容输入：卡片 + 快捷插入 + 字数 ----------
  Widget _contentCard() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(AppTheme.card),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(AppTheme.border)),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
            child: TextField(
              controller: _contentCtrl,
              maxLines: 6,
              minLines: 3,
              maxLength: _maxContent,
              onChanged: (_) => setState(() {}), // 驱动发布按钮状态与字数
              style: const TextStyle(
                  color: Color(AppTheme.textPrimary), fontSize: 15, height: 1.5),
              decoration: InputDecoration(
                hintText: isVideo
                    ? '写一句视频文案，带 #话题 可以上热门'
                    : '分享此刻…支持 #话题 与 @好友',
                hintStyle: const TextStyle(color: Color(AppTheme.textTertiary)),
                border: InputBorder.none,
                counterText: '',
              ),
            ),
          ),
          Container(
            height: 1,
            color: const Color(AppTheme.border),
            margin: const EdgeInsets.symmetric(horizontal: 14),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              children: [
                _toolChip('#话题', () => _insertAt(' #')),
                const SizedBox(width: 6),
                _toolChip('@好友', () => _insertAt(' @')),
                const Spacer(),
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _contentCtrl,
                  builder: (_, v, _) => Text(
                    '${v.text.length}/$_maxContent',
                    style: TextStyle(
                      color: v.text.length >= _maxContent
                          ? const Color(0xFFFF6B6B)
                          : const Color(AppTheme.textTertiary),
                      fontSize: 11,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _toolChip(String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: const Color(AppTheme.bg),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(AppTheme.border)),
        ),
        child: Text(label,
            style: const TextStyle(color: Color(AppTheme.lilac), fontSize: 12)),
      ),
    );
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

  // ---------- 图文图片区 ----------
  Widget _imageGrid() {
    final cells = <Widget>[];
    for (final f in _images) {
      cells.add(Stack(children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image.file(f, width: 96, height: 96, fit: BoxFit.cover),
        ),
        Positioned(
          top: 2,
          right: 2,
          child: GestureDetector(
            onTap: () => setState(() => _images.remove(f)),
            child: Container(
              padding: const EdgeInsets.all(3),
              decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
              child: const Icon(Icons.close, size: 14, color: Colors.white),
            ),
          ),
        ),
      ]));
    }
    if (cells.length < _maxImages) {
      cells.add(GestureDetector(
        onTap: _pickImages,
        child: Container(
          width: 96,
          height: 96,
          decoration: BoxDecoration(
            color: const Color(AppTheme.card),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(AppTheme.border)),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.add_photo_alternate_outlined,
                  color: Color(AppTheme.textSecondary), size: 26),
              const SizedBox(height: 4),
              Text('${_maxImages - _images.length} 图',
                  style: TextStyle(color: Color(AppTheme.textTertiary), fontSize: 11)),
            ],
          ),
        ),
      ));
    }
    return Wrap(spacing: 8, runSpacing: 8, children: cells);
  }

  // ---------- 视频选择区 ----------
  Widget _videoSection() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(AppTheme.card),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(AppTheme.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_videoFile == null) _videoPlaceholder() else _videoPreview(),
          const SizedBox(height: 12),
          const Text('封面',
              style: TextStyle(color: Color(AppTheme.textSecondary), fontSize: 13)),
          const SizedBox(height: 8),
          Row(
            children: [
              _coverChip('auto', '自动首帧', _coverFromFrame, () {
                setState(() {
                  _coverFromFrame = true;
                  _coverFile = null;
                });
              }),
              const SizedBox(width: 8),
              _coverChip('custom', '自定义上传', !_coverFromFrame, _pickCover),
            ],
          ),
          if (_coverFile != null) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.file(_coverFile!, width: 80, height: 80, fit: BoxFit.cover),
            ),
          ],
        ],
      ),
    );
  }

  /// 未选视频：竖版虚线占位卡
  Widget _videoPlaceholder() {
    return GestureDetector(
      onTap: _pickVideo,
      child: Container(
        height: 220,
        width: double.infinity,
        decoration: BoxDecoration(
          color: const Color(AppTheme.bg),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(AppTheme.border), width: 1),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: const Color(AppTheme.accentSoft),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.video_library_outlined,
                  color: Color(AppTheme.accent), size: 28),
            ),
            const SizedBox(height: 12),
            const Text('选择本地视频',
                style: TextStyle(color: Color(AppTheme.textPrimary), fontSize: 14, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            const Text('≤ 60 秒 · ≤ 50MB · 竖版更佳',
                style: TextStyle(color: Color(AppTheme.textTertiary), fontSize: 12)),
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
          borderRadius: BorderRadius.circular(10),
          child: Image.file(
            f,
            width: 96,
            height: 128,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => Container(
              width: 96,
              height: 128,
              color: const Color(AppTheme.bg),
              child: const Icon(Icons.movie, color: Color(AppTheme.textSecondary)),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                f.path.split('/').last,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Color(AppTheme.textPrimary), fontSize: 13),
              ),
              const SizedBox(height: 6),
              // 时长/大小徽标
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(AppTheme.bg),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '$_maxVideoSeconds 秒 · $sizeMb MB',
                  style: const TextStyle(color: Color(AppTheme.textSecondary), fontSize: 11),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  _miniAction(Icons.refresh, '重新选择', _pickVideo),
                  const SizedBox(width: 8),
                  _miniAction(Icons.delete_outline, '删除', () {
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
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: const Color(AppTheme.bg),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(AppTheme.border)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: const Color(AppTheme.accent)),
            const SizedBox(width: 3),
            Text(label,
                style: const TextStyle(color: Color(AppTheme.accent), fontSize: 11)),
          ],
        ),
      ),
    );
  }

  Widget _coverChip(String id, String label, bool sel, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: sel ? const Color(AppTheme.accentSoft) : const Color(AppTheme.bg),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
              color: sel ? const Color(AppTheme.accent) : const Color(AppTheme.border)),
        ),
        child: Text(label,
            style: TextStyle(
              color: sel ? const Color(AppTheme.accent) : const Color(AppTheme.textSecondary),
              fontSize: 12,
              fontWeight: sel ? FontWeight.w600 : FontWeight.w400,
            )),
      ),
    );
  }

  // ---------- 发布进度面板 ----------
  Widget _progressPanel() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      decoration: const BoxDecoration(
        color: Color(AppTheme.card),
        border: Border(top: BorderSide(color: Color(AppTheme.border))),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text(_stageLabel,
                  style: const TextStyle(color: Color(AppTheme.textSecondary), fontSize: 12)),
              const Spacer(),
              Text('${(_uploadProgress * 100).round()}%',
                  style: const TextStyle(color: Color(AppTheme.accent), fontSize: 12)),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: _uploadProgress.clamp(0.0, 1.0),
              minHeight: 5,
              backgroundColor: const Color(AppTheme.border),
              color: const Color(AppTheme.accent),
            ),
          ),
        ],
      ),
    );
  }
}
