/// 发帖 / 发短视频页（P0）
///
/// - 图文模式：富文本内容 + 最多 3 图 + 版块 + #话题（服务端自动解析 @与话题）
/// - 视频模式：选本地视频上传（服务端转码）+ 文案/话题/版块 + 封面（auto 首帧或自定义上传）
library;

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
  final _contentCtrl = TextEditingController();
  final _picker = ImagePicker();
  List<File> _images = []; // 图文帖图片（≤3）
  File? _videoFile; // 视频文件
  File? _coverFile; // 自定义封面
  bool _coverFromFrame = true; // true=auto 首帧
  String _boardId = '';
  List<Map<String, dynamic>> _boards = [];
  bool _publishing = false;
  double _uploadProgress = 0;

  bool get isVideo => widget.mode == 'video';

  @override
  void initState() {
    super.initState();
    _loadBoards();
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
      setState(() => _boards = flat);
    } catch (_) {}
  }

  Future<void> _pickImages() async {
    if (_images.length >= 3) {
      _toast('最多 3 张图片');
      return;
    }
    final picked = await _picker.pickMultiImage(limit: 3 - _images.length);
    if (picked.isEmpty) return;
    setState(() {
      _images.addAll(picked.map((e) => File(e.path)));
    });
  }

  Future<void> _pickVideo() async {
    final v = await _picker.pickVideo(source: ImageSource.gallery, maxDuration: const Duration(seconds: 60));
    if (v == null) return;
    setState(() => _videoFile = File(v.path));
  }

  Future<void> _pickCover() async {
    final v = await _picker.pickImage(source: ImageSource.gallery);
    if (v == null) return;
    setState(() {
      _coverFile = File(v.path);
      _coverFromFrame = false;
    });
  }

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
    return true;
  }

  Future<void> _publish() async {
    if (_publishing) return;
    if (!_validate()) return;
    setState(() => _publishing = true);
    try {
      final content = _contentCtrl.text.trim();
      if (!isVideo) {
        // 图文帖：先传图
        final names = <String>[];
        for (var i = 0; i < _images.length; i++) {
          setState(() => _uploadProgress = (i + 1) / (_images.length + 1));
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
        setState(() => _uploadProgress = 0.15);
        if (_videoFile == null) {
          _toast('请先选择视频');
          setState(() => _publishing = false);
          return;
        }
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
          _toast('视频转码较慢，可稍后从草稿继续');
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
      _toast('发布失败：$e');
    } finally {
      if (mounted) setState(() => _publishing = false);
    }
  }

  void _toast(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(s), backgroundColor: const Color(AppTheme.card)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(AppTheme.bg),
      appBar: AppBar(
        backgroundColor: const Color(AppTheme.bg),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close, color: Color(AppTheme.textPrimary)),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(isVideo ? '发布短视频' : '发布帖子',
            style: const TextStyle(
                color: Color(AppTheme.textPrimary),
                fontSize: 17,
                fontWeight: FontWeight.w600)),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: _publishing
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Color(AppTheme.accent)))
                : ElevatedButton(
                    onPressed: _publish,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(AppTheme.accent),
                      foregroundColor: Colors.black,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20)),
                    ),
                    child: const Text('发布',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                  ),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 版块选择
                    _boardBar(),
                    const SizedBox(height: 14),
                    // 内容输入
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(AppTheme.card),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: TextField(
                        controller: _contentCtrl,
                        maxLines: 6,
                        minLines: 3,
                        maxLength: 1000,
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
                    const SizedBox(height: 12),
                    // 图片/视频选择区
                    if (!isVideo) _imageGrid() else _videoPicker(),
                    const SizedBox(height: 8),
                    Text(isVideo ? '支持 #话题 / @好友（与服务端解析一致）'
                            : '支持 #话题 / @好友，图片最多 3 张',
                        style: const TextStyle(
                            color: Color(AppTheme.textTertiary), fontSize: 12)),
                  ],
                ),
              ),
            ),
            if (_publishing)
              Padding(
                padding: const EdgeInsets.all(8),
                child: LinearProgressIndicator(
                  value: _uploadProgress,
                  backgroundColor: const Color(AppTheme.border),
                  color: const Color(AppTheme.accent),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _boardBar() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('选择版块',
            style: TextStyle(
                color: Color(AppTheme.textSecondary), fontSize: 13)),
        const SizedBox(height: 8),
        _boards.isEmpty
            ? const Text('加载版块中…',
                style: TextStyle(color: Color(AppTheme.textTertiary), fontSize: 12))
            : SizedBox(
                height: 38,
                child: ListView.builder(
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
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          alignment: Alignment.center,
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
                          child: Text(
                            '${depth > 0 ? '·' * depth : ''}${b['name']}',
                            style: TextStyle(
                              color: sel
                                  ? const Color(AppTheme.accent)
                                  : const Color(AppTheme.textSecondary),
                              fontSize: 13,
                            ),
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
              decoration: const BoxDecoration(
                color: Colors.black54,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.close, size: 14, color: Colors.white),
            ),
          ),
        ),
      ]));
    }
    if (cells.length < 3) {
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
              Text('${3 - _images.length} 图',
                  style: TextStyle(
                      color: Color(AppTheme.textTertiary), fontSize: 11)),
            ],
          ),
        ),
      ));
    }
    return Wrap(spacing: 8, runSpacing: 8, children: cells);
  }

  Widget _videoPicker() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(AppTheme.card),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_videoFile == null)
            GestureDetector(
              onTap: _pickVideo,
              child: Container(
                height: 140,
                decoration: BoxDecoration(
                  color: const Color(AppTheme.bg),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(AppTheme.border)),
                ),
                child: const Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.video_library_outlined,
                        color: Color(AppTheme.accent), size: 34),
                    SizedBox(height: 8),
                    Text('选择本地视频（≤60s）',
                        style: TextStyle(
                            color: Color(AppTheme.textSecondary), fontSize: 13)),
                  ],
                ),
              ),
            )
          else
            Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.file(_videoFile!,
                      width: 96,
                      height: 128,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                        width: 96,
                        height: 128,
                        color: const Color(AppTheme.bg),
                        child: const Icon(Icons.movie, color: Color(AppTheme.textSecondary)),
                      )),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_videoFile!.path.split('/').last,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Color(AppTheme.textPrimary), fontSize: 13)),
                      const SizedBox(height: 8),
                      TextButton.icon(
                        onPressed: _pickVideo,
                        icon: const Icon(Icons.refresh,
                            size: 16, color: Color(AppTheme.accent)),
                        label: const Text('重新选择',
                            style: TextStyle(
                                color: Color(AppTheme.accent), fontSize: 12)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          const SizedBox(height: 12),
          const Text('封面',
              style: TextStyle(
                  color: Color(AppTheme.textSecondary), fontSize: 13)),
          const SizedBox(height: 8),
          Row(
            children: [
              _coverOption('auto', '自动首帧', _coverFromFrame, () {
                setState(() {
                  _coverFromFrame = true;
                  _coverFile = null;
                });
              }),
              const SizedBox(width: 8),
              _coverOption('custom', '自定义上传', !_coverFromFrame, _pickCover),
            ],
          ),
          if (_coverFile != null) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.file(_coverFile!,
                  width: 80, height: 80, fit: BoxFit.cover),
            ),
          ],
        ],
      ),
    );
  }

  Widget _coverOption(String id, String label, bool sel, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: sel ? const Color(AppTheme.accentSoft) : const Color(AppTheme.bg),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
              color: sel ? const Color(AppTheme.accent) : const Color(AppTheme.border)),
        ),
        child: Text(label,
            style: TextStyle(
              color:
                  sel ? const Color(AppTheme.accent) : const Color(AppTheme.textSecondary),
              fontSize: 12,
            )),
      ),
    );
  }
}
