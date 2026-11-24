/// 创作台（发布图文 / 短视频）
///
/// 视觉结构：
/// - 顶部身份栏 + 紧凑模式切换，不做「两张大卡片选类型」
/// - 一个媒体舞台：图文是首图封面 + 首图胶片条；视频是 9:16 海报 + 环境底
/// - 文案不套卡，像编辑台一样直接落在画布上
/// - 发布设置收成一组行，工具条 5 项等宽不横向滚动
/// - 点击发布后立即关闭页面、回到首页；发布任务独立在后台跑，由根 Overlay
///   上的竖版小卡展示预览、白色圆环进度与百分比
///
/// 业务链路保持不变：草稿、版块、话题、投票、配乐、双音量、视频上传轮询。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';

import '../../api/client.dart';
import '../../design/components.dart';
import '../../features/emoji/text_emoji.dart';
import '../../widgets/emoji_panel.dart';
import '../../models/feed_item.dart';
import '../../services/publish_bus.dart';
import '../../services/publish_job.dart';
import '../../services/hot_update.dart';
import '../../utils/draft_store.dart';
import 'topic_picker_sheet.dart';
import 'music_picker_sheet.dart';
import 'publish_overlay.dart';
import 'video_cover_picker.dart';

/// 统一创作台：图文 / 短视频。
class PostEditorPage extends StatefulWidget {
  const PostEditorPage({
    super.key,
    this.initialMode = 'text',
    this.initialTopics = const [],
    @visibleForTesting this.debugVideo,
    @visibleForTesting this.debugVideoThumb,
    @visibleForTesting this.debugImagePaths,
    @visibleForTesting this.debugImageBytes,
    @visibleForTesting this.debugAttachment,
    @visibleForTesting this.debugAttachmentLabel,
  });

  /// 'text' | 'video'
  final String initialMode;

  /// 从活动/话题入口进入时预置的话题，发布时随帖提交。
  final List<String> initialTopics;

  /// 测试注入：让无原生视频插件的 widget test 也能验收视频态 UI。
  final File? debugVideo;
  final Uint8List? debugVideoThumb;
  final List<String>? debugImagePaths;
  final List<Uint8List>? debugImageBytes;
  final File? debugAttachment;
  final String? debugAttachmentLabel;

  @override
  State<PostEditorPage> createState() => _PostEditorPageState();
}

class _PostEditorPageState extends State<PostEditorPage> {
  static const int _maxContent = 2000;
  static const int _maxImages = 3;
  static const int _maxVideoBytes = 50 * 1024 * 1024;
  static const int _maxVideoSeconds = 60;
  static const int _maxAttachmentBytes = 20 * 1024 * 1024;
  static const Set<String> _attachmentExts = {
    'pdf',
    'doc',
    'docx',
    'xls',
    'xlsx',
    'ppt',
    'pptx',
    'txt',
    'md',
    'csv',
    'zip',
    'rar',
    '7z',
  };

  final _contentCtrl = TextEmojiEditingController();
  final _picker = ImagePicker();
  final List<File> _images = [];
  final List<Uint8List?> _imageBytes = [];
  File? _videoFile;
  File? _attachment;
  String _attachmentLabel = '';
  File? _coverFile;
  bool _coverFromFrame = true; // 未手动选帧/上传时走自动首帧
  double? _coverTime;
  Uint8List? _coverThumb;
  Uint8List? _videoThumb;
  bool _thumbBusy = false;

  String _boardId = '';
  List<Map<String, dynamic>> _boards = [];
  bool _boardsLoaded = false;
  bool _publishing = false;
  final List<String> _topics = [];
  Map<String, dynamic>? _poll;
  Map<String, dynamic>? _music;

  String _mode = 'text';
  int _audioVolume = 100;
  int _musicVolume = 50;

  Map<String, dynamic>? _draft;
  Timer? _draftTimer;
  bool _draftDirty = false;

  bool get isVideo => _mode == 'video';

  /// 发帖页的“表情”只提供文字混排；开关关闭时连入口一起收起，
  /// 避免点开面板却无法落字的死按钮。图片表情在私信/评论使用。
  bool get _inlineEmojiEnabled =>
      HotUpdateService.instance.config.value.inlineTextEmojiEnabled;

  bool get _canPublish {
    if (_publishing || _boardId.isEmpty) return false;
    if (isVideo) return _videoFile != null;
    return _contentCtrl.text.trim().isNotEmpty ||
        _images.isNotEmpty ||
        _attachment != null;
  }

  @override
  void initState() {
    super.initState();
    _mode = widget.initialMode == 'video' ? 'video' : 'text';
    _topics.addAll(
      widget.initialTopics.map((e) => e.trim()).where((e) => e.isNotEmpty),
    );
    if (widget.debugVideo != null) {
      _videoFile = widget.debugVideo;
      _videoThumb = widget.debugVideoThumb;
    }
    if (widget.debugAttachment != null) {
      _attachment = widget.debugAttachment;
      _attachmentLabel =
          widget.debugAttachmentLabel ??
          _baseName(widget.debugAttachment!.path);
    }
    for (final path in widget.debugImagePaths ?? const <String>[]) {
      final f = File(path);
      if (f.existsSync()) {
        _images.add(f);
        final i = _images.length - 1;
        _imageBytes.add(
          i < (widget.debugImageBytes?.length ?? 0)
              ? widget.debugImageBytes![i]
              : null,
        );
      }
    }
    _loadBoards();
    _contentCtrl.addListener(_scheduleDraftSave);
    HotUpdateService.instance.config.addListener(_onHotConfig);
    _checkDraft();
  }

  void _onHotConfig() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    HotUpdateService.instance.config.removeListener(_onHotConfig);
    _draftTimer?.cancel();
    if (!_publishing) _saveDraftNow();
    _contentCtrl.removeListener(_scheduleDraftSave);
    _contentCtrl.dispose();
    super.dispose();
  }

  // ---------------- 草稿 ----------------

  Future<void> _checkDraft() async {
    final d = await DraftStore.load();
    if (!mounted || d == null) return;
    if (_contentCtrl.text.trim().isNotEmpty) return;
    setState(() => _draft = d);
  }

  void _scheduleDraftSave() {
    _draftDirty = true;
    _draftTimer?.cancel();
    _draftTimer = Timer(const Duration(milliseconds: 1200), _saveDraftNow);
  }

  void _saveDraftNow() {
    if (_publishing) return;
    // 用户只是打开发布页、看到「恢复草稿」提示就退出时，不能把旧草稿当成空内容清掉。
    if (!_draftDirty && _contentCtrl.text.trim().isEmpty && _boardId.isEmpty) {
      return;
    }
    _draftDirty = false;
    DraftStore.save(
      content: _contentCtrl.text,
      boardId: _boardId,
      boardName: _boardId.isEmpty ? '' : _boardName(_boardId),
      mode: _mode,
      musicName: (_music?['name'] ?? '').toString(),
      topics: _topics,
    );
  }

  void _restoreDraft() {
    final d = _draft;
    if (d == null) return;
    setState(() {
      _contentCtrl.text = (d['content'] ?? '').toString();
      _boardId = (d['boardId'] ?? '').toString();
      _mode = (d['mode'] ?? 'text').toString() == 'video' ? 'video' : 'text';
      _topics
        ..clear()
        ..addAll(((d['topics'] ?? []) as List).map((e) => e.toString()));
      _draft = null;
    });
    showAppToast(context, '已恢复上次编辑的内容');
  }

  Future<void> _discardDraft() async {
    await DraftStore.clear();
    if (!mounted) return;
    setState(() {
      _draft = null;
      _draftDirty = false;
    });
  }

  // ---------------- 版块 / 素材 ----------------

  Future<void> _loadBoards() async {
    try {
      final j = await ApiClient.boards();
      if (!mounted) return;
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

  Future<void> _pickImages() async {
    if (_images.length >= _maxImages) {
      _toast('最多 $_maxImages 张图片');
      return;
    }
    final picked = await _picker.pickMultiImage(
      limit: _maxImages - _images.length,
    );
    if (!mounted || picked.isEmpty) return;
    setState(() {
      for (final e in picked) {
        _images.add(File(e.path));
        _imageBytes.add(null);
      }
    });
    _scheduleDraftSave();
  }

  String _baseName(String path) =>
      path.replaceAll('\\', '/').split('/').last.trim();

  String _attachmentType(String label) {
    final ext = label.contains('.') ? label.split('.').last.toLowerCase() : '';
    return switch (ext) {
      'pdf' => 'PDF 文档',
      'doc' || 'docx' => 'Word 文档',
      'xls' || 'xlsx' => 'Excel 表格',
      'ppt' || 'pptx' => '演示文稿',
      'txt' || 'md' => '文本文件',
      'csv' => 'CSV 表格',
      'zip' || 'rar' || '7z' => '压缩包',
      _ => '文件',
    };
  }

  Future<void> _pickAttachment() async {
    final r = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      withData: false,
    );
    if (!mounted || r == null || r.files.isEmpty) return;
    final pf = r.files.single;
    final path = pf.path;
    if (path == null || path.isEmpty) {
      _toast('无法读取该文件，请从「文件」中重新选择', error: true);
      return;
    }
    final f = File(path);
    if (!f.existsSync()) {
      _toast('文件已失效，请重新选择', error: true);
      return;
    }
    final label = _baseName(pf.name.isNotEmpty ? pf.name : path);
    final ext = label.contains('.') ? label.split('.').last.toLowerCase() : '';
    if (!_attachmentExts.contains(ext)) {
      _toast('仅支持 PDF、Office 文档、文本或压缩包');
      return;
    }
    final size = f.lengthSync();
    if (size <= 0) {
      _toast('文件为空，请重新选择', error: true);
      return;
    }
    if (size > _maxAttachmentBytes) {
      _toast('附件不能超过 20MB');
      return;
    }
    setState(() {
      _attachment = f;
      _attachmentLabel = label;
    });
    _toast('已添加附件：$label');
  }

  void _removeAttachment() {
    setState(() {
      _attachment = null;
      _attachmentLabel = '';
    });
  }

  Future<void> _pickVideo() async {
    final v = await _picker.pickVideo(
      source: ImageSource.gallery,
      maxDuration: const Duration(seconds: _maxVideoSeconds),
    );
    if (!mounted || v == null) return;
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
    setState(() {
      _videoFile = f;
      _videoThumb = null;
      _coverThumb = null;
      _coverTime = null;
      _coverFile = null;
      _coverFromFrame = true;
      _thumbBusy = true;
    });
    Uint8List? thumb;
    try {
      thumb = await videoFrameBytes(f, 0, maxWidth: 720, quality: 80);
    } catch (_) {
      thumb = null;
    }
    if (!mounted || _videoFile?.path != f.path) return;
    setState(() {
      _videoThumb = thumb;
      _thumbBusy = false;
    });
    if (thumb == null) _toast('视频首帧读取失败，可手动选择封面', error: true);
    _scheduleDraftSave();
  }

  void _useAutoCover() {
    setState(() {
      _coverFile = null;
      _coverThumb = null;
      _coverTime = null;
      _coverFromFrame = true;
    });
  }

  Future<void> _openCoverPicker() async {
    final f = _videoFile;
    if (f == null) {
      _toast('请先选择视频');
      return;
    }
    final picked = await Navigator.of(context).push<VideoCoverSelection>(
      PageRouteBuilder(
        fullscreenDialog: true,
        transitionDuration: AppMotion.page,
        pageBuilder: (_, _, _) =>
            VideoCoverPickerPage(video: f, initialTime: _coverTime ?? 0),
        transitionsBuilder: (_, anim, _, child) {
          final curved = CurvedAnimation(
            parent: anim,
            curve: AppMotion.standard,
          );
          return FadeTransition(
            opacity: curved,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.04),
                end: Offset.zero,
              ).animate(curved),
              child: child,
            ),
          );
        },
      ),
    );
    if (picked == null || !mounted) return;
    if (picked.auto) {
      _useAutoCover();
      return;
    }
    setState(() {
      _coverTime = picked.time;
      _coverThumb = picked.bytes;
      _coverFile = null;
      _coverFromFrame = false;
    });
  }

  void _clearVideo() {
    setState(() {
      _videoFile = null;
      _videoThumb = null;
      _coverFile = null;
      _coverThumb = null;
      _coverTime = null;
      _coverFromFrame = true;
      _thumbBusy = false;
    });
  }

  // ---------------- 话题 / 投票 / 配乐 ----------------

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

  Future<void> _pickEmoji() async {
    if (!_inlineEmojiEnabled) return;
    final e = await showEmojiPanel(context);
    final code = (e?['textCode'] ?? '').toString();
    if (code.isEmpty || !kTextEmojiByCode.containsKey(code)) return;
    _contentCtrl.insertEmojiCode(code);
    setState(() {});
  }

  Future<void> _pickTopic() async {
    final picked = await showTopicPicker(
      context,
      selected: List<String>.of(_topics),
      maxCount: 10,
    );
    if (picked == null || !mounted) return;
    setState(() {
      _topics
        ..clear()
        ..addAll(picked);
    });
    _scheduleDraftSave();
  }

  Future<void> _editPoll() async {
    final qCtrl = TextEditingController(
      text: (_poll?['question'] ?? '') as String,
    );
    final opts = List<String>.from(
      ((_poll?['options'] ?? []) as List).map((e) => e.toString()),
    );
    if (opts.isEmpty) opts.addAll(['', '']);
    final optCtrls = [for (final o in opts) TextEditingController(text: o)];

    final saved = await showModalBottomSheet<bool>(
      context: context,
      sheetAnimationStyle: const AnimationStyle(
        duration: AppMotion.page,
        curve: AppMotion.standard,
        reverseCurve: AppMotion.exit,
      ),
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
                    _poll = {'question': q, 'options': os};
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
                      style: AppType.bodySm.copyWith(
                        color: const Color(AppColors.textPrimary),
                      ),
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
                        child: Icon(
                          Icons.close_rounded,
                          size: 16,
                          color: Color(AppColors.textTertiary),
                        ),
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
                    style: AppType.body.copyWith(
                      color: const Color(AppColors.textPrimary),
                    ),
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
                        padding: const EdgeInsets.symmetric(
                          vertical: AppSpace.x1,
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.add_circle_outline,
                              size: 16,
                              color: Color(AppColors.accent),
                            ),
                            const SizedBox(width: AppSpace.x2),
                            Text(
                              '添加选项',
                              style: AppType.caption.copyWith(
                                color: Color(AppColors.accent),
                              ),
                            ),
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

    for (final c in optCtrls) {
      c.dispose();
    }
    qCtrl.dispose();
    if (saved == true && mounted) setState(() {});
  }

  Future<void> _pickMusic() async {
    final picked = await showMusicPicker(context);
    if (picked != null && mounted) setState(() => _music = picked);
  }

  // ---------------- 发布 ----------------

  bool _validate() {
    if (isVideo) {
      if (_videoFile == null) {
        _toast('请先选择视频');
        return false;
      }
    } else if (_contentCtrl.text.trim().isEmpty &&
        _images.isEmpty &&
        _attachment == null) {
      _toast('写点什么，或添加图片 / 附件再发布');
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

    // 先锁住按钮，再 await 草稿落盘。否则用户在磁盘写入期间连点两次，
    // 两次校验都会通过，最后会起两个 PublishJob。
    setState(() => _publishing = true);

    final content = _contentCtrl.text.trim();
    final images = List<File>.of(_images);
    final video = _videoFile;
    final coverFile = _coverFile;
    final coverFromFrame = _coverFromFrame;
    final coverTime = _coverTime;
    final boardId = _boardId;
    final poll = _poll;
    final music = _music;

    try {
      // 页面会立刻关闭，先把文本草稿落盘；后台发布失败时仍可在下次进入时恢复。
      await DraftStore.save(
        content: _contentCtrl.text,
        boardId: boardId,
        boardName: boardId.isEmpty ? '' : _boardName(boardId),
        mode: _mode,
        musicName: (music?['name'] ?? '').toString(),
        topics: _topics,
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _publishing = false);
      _toast('保存草稿失败，请重试', error: true);
      return;
    }
    if (!mounted) return;

    final preview = PublishPreview(
      kind: isVideo ? PublishKind.video : PublishKind.text,
      content: content,
      imagePath: isVideo
          ? (!coverFromFrame ? coverFile?.path : null)
          : (images.isNotEmpty ? images.first.path : null),
      imageBytes: isVideo
          ? (coverFromFrame ? _videoThumb : (_coverThumb ?? _videoThumb))
          : null,
      hasAttachment: _attachment != null,
    );

    final job = PublishJob.start(
      PublishPayload(
        kind: isVideo ? PublishKind.video : PublishKind.text,
        content: content,
        images: images,
        video: video,
        coverFile: coverFile,
        coverFromFrame: coverFromFrame,
        coverTime: coverTime,
        boardId: boardId,
        poll: poll,
        music: music,
        topics: List<String>.of(_topics),
        audioVolume: _audioVolume,
        musicVolume: _musicVolume,
        preview: preview,
        attachment: _attachment,
        attachmentLabel: _attachmentLabel,
      ),
    );

    // 悬浮窗挂在根 Overlay 上：本页 pop 掉之后仍然存在。
    PublishOverlay.show(context, job);
    PublishBus.goHome.value++;
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  void _toast(String s, {bool error = false}) {
    if (!mounted) return;
    showAppToast(context, s);
  }

  // ---------------- 新创作台 UI ----------------

  @override
  Widget build(BuildContext context) {
    final keyboard = MediaQuery.viewInsetsOf(context).bottom > 0;
    return ImmersivePage(
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(-0.35, -0.82),
            radius: 1.18,
            colors: [Color(0xFF0E211C), Color(0xFF070808), Color(AppColors.bg)],
            stops: [0, 0.44, 1],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              _topBar(),
              _modeSwitch(),
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: () => FocusScope.of(context).unfocus(),
                  child: SingleChildScrollView(
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _draftBanner(),
                        if (isVideo) _videoStage() else _imageStage(),
                        const SizedBox(height: 16),
                        _composer(),
                        const SizedBox(height: 16),
                        _settings(),
                        if (isVideo) _soundPanel(),
                        const SizedBox(height: 12),
                        _tipCard(),
                        const SizedBox(height: 12),
                        Center(
                          child: Text(
                            '发布即表示同意《社区规范》与《隐私政策》',
                            style: AppType.micro.copyWith(fontSize: 9.5),
                          ),
                        ),
                        const SizedBox(height: 2),
                      ],
                    ),
                  ),
                ),
              ),
              if (!keyboard) _actionDock(),
              _publishBar(),
            ],
          ),
        ),
      ),
    );
  }

  // ---------- 顶部身份 ----------

  Widget _topBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 2),
      child: Row(
        children: [
          PressableScale(
            onTap: () => Navigator.maybePop(context),
            scale: 0.92,
            child: Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.055),
                shape: BoxShape.circle,
                border: Border.all(color: const Color(AppColors.border)),
              ),
              child: const Icon(
                Icons.close_rounded,
                size: 19,
                color: Color(AppColors.textPrimary),
              ),
            ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '创作台',
                  style: AppType.h2.copyWith(
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  isVideo ? '让画面先说话' : '把此刻放进流萤',
                  style: AppType.micro.copyWith(
                    color: const Color(AppColors.textTertiary),
                  ),
                ),
              ],
            ),
          ),
          PressableScale(
            onTap: _saveDraftFromTopBar,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.035),
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: const Color(AppColors.hairline)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.cloud_done_outlined,
                    size: 13,
                    color: Colors.white.withValues(alpha: 0.54),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '草稿',
                    style: AppType.micro.copyWith(
                      fontSize: 10,
                      color: Colors.white.withValues(alpha: 0.54),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _saveDraftFromTopBar() {
    if (_contentCtrl.text.trim().isEmpty && _boardId.isEmpty) {
      _toast('先写点文案或选择版块');
      return;
    }
    _draftDirty = true;
    _saveDraftNow();
    _toast('已存为草稿');
  }

  Widget _modeSwitch() {
    final video = isVideo;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
      child: Container(
        height: 44,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.04),
          borderRadius: AppRadius.rPill,
          border: Border.all(color: const Color(AppColors.hairline)),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final thumbWidth = constraints.maxWidth / 2;
            return Stack(
              children: [
                AnimatedAlign(
                  alignment: video
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  duration: AppMotion.slow,
                  curve: AppMotion.enter,
                  child: Container(
                    width: thumbWidth,
                    height: 38,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0xFF1A382F), Color(0xFF0C201A)],
                      ),
                      borderRadius: AppRadius.rPill,
                      border: Border.all(
                        color: const Color(AppColors.accent)
                            .withValues(alpha: 0.28),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(AppColors.accent)
                              .withValues(alpha: 0.08),
                          blurRadius: 14,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                  ),
                ),
                Row(
                  children: [
                    Expanded(
                      child: _modeOption('text', '图文', Icons.notes_rounded),
                    ),
                    Expanded(
                      child: _modeOption('video', '短视频', Icons.movie_outlined),
                    ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _modeOption(String mode, String label, IconData icon) {
    final selected = _mode == mode;
    final color = selected
        ? const Color(0xFF7EF0C9)
        : const Color(AppColors.textSecondary);
    final inherited = DefaultTextStyle.of(context).style;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (_mode == mode) return;
          FocusScope.of(context).unfocus();
          setState(() => _mode = mode);
          _scheduleDraftSave();
        },
        child: SizedBox(
          height: 38,
          child: AnimatedDefaultTextStyle(
            duration: AppMotion.fast,
            curve: AppMotion.standard,
            style: inherited.copyWith(
              fontFamily: 'NotoSansSC',
              fontFamilyFallback: const ['PingFang SC', 'Heiti SC'],
              decoration: TextDecoration.none,
              fontSize: 11.5,
              height: 1.25,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: color,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 14.5, color: color),
                const SizedBox(width: 5),
                Text(label),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---------- 草稿提示 ----------

  Widget _draftBanner() {
    final d = _draft;
    if (d == null) return const SizedBox.shrink();
    final preview = (d['content'] ?? '').toString().trim().replaceAll(
      '\n',
      ' ',
    );
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
      decoration: BoxDecoration(
        color: const Color(AppColors.accentSoft).withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(13),
        border: Border.all(
          color: const Color(AppColors.accent).withValues(alpha: 0.16),
        ),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.history_rounded,
            size: 15,
            color: Color(AppColors.accent),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              preview.isEmpty ? '上次编辑的草稿' : '上次编辑：$preview',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppType.micro.copyWith(
                fontSize: 10.5,
                color: const Color(AppColors.textSecondary),
              ),
            ),
          ),
          PressableScale(
            onTap: _restoreDraft,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
              child: Text(
                '恢复',
                style: AppType.micro.copyWith(
                  fontSize: 10.5,
                  color: const Color(AppColors.accent),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          PressableScale(
            onTap: _discardDraft,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(
                Icons.close_rounded,
                size: 15,
                color: Colors.white.withValues(alpha: 0.42),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------- 图文媒体舞台 ----------

  Widget _imageStage() {
    final has = _images.isNotEmpty;
    final width = MediaQuery.sizeOf(context).width;
    final height = has
        ? (width * 0.74).clamp(238.0, 300.0)
        : (width < 350 ? 200.0 : 246.0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: _pickImages,
          behavior: HitTestBehavior.opaque,
          child: Container(
            height: height,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              border: has
                  ? Border.all(color: Colors.white.withValues(alpha: 0.08))
                  : Border.all(color: Colors.transparent),
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (has)
                  _imageWidget(0)
                else ...[
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Color(0xFF101A16), Color(0xFF080A09)],
                      ),
                    ),
                  ),
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: Alignment(0, -0.10),
                        radius: 0.62,
                        colors: [Color(0x1845E0AE), Colors.transparent],
                      ),
                    ),
                  ),
                ],
                if (!has)
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _DashedBorderPainter(
                        color: Colors.white.withValues(alpha: 0.16),
                        radius: 24,
                      ),
                    ),
                  ),
                if (has)
                  const Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    height: 74,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Color(0x66000000), Colors.transparent],
                        ),
                      ),
                    ),
                  ),
                if (has)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    height: 108,
                    child: const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.bottomCenter,
                          end: Alignment.topCenter,
                          colors: [Color(0xCC000000), Colors.transparent],
                        ),
                      ),
                    ),
                  ),
                if (has) ...[
                  Positioned(
                    left: 12,
                    top: 12,
                    child: _stagePill(
                      _images.length == 1 ? '封面' : '封面 · 第 1 张',
                    ),
                  ),
                  Positioned(
                    right: 12,
                    top: 12,
                    child: _images.length < _maxImages
                        ? PressableScale(
                            onTap: _pickImages,
                            scale: 0.92,
                            child: Container(
                              width: 30,
                              height: 30,
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.46),
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.16),
                                ),
                              ),
                              child: const Icon(
                                Icons.add_rounded,
                                size: 17,
                                color: Colors.white,
                              ),
                            ),
                          )
                        : _stagePill('已选满'),
                  ),
                  Positioned(
                    left: 14,
                    bottom: 13,
                    child: Row(
                      children: [
                        Text(
                          '${_images.length}/$_maxImages',
                          style: AppType.micro.copyWith(
                            color: Colors.white,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(width: 7),
                        Container(
                          width: 2,
                          height: 2,
                          color: Colors.white.withValues(alpha: 0.42),
                        ),
                        const SizedBox(width: 7),
                        Text(
                          '首张作为封面',
                          style: AppType.micro.copyWith(
                            color: Colors.white.withValues(alpha: 0.64),
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Positioned(
                    right: 14,
                    bottom: 13,
                    child: Text(
                      _images.length < _maxImages ? '点按添加' : '已达上限',
                      style: AppType.micro.copyWith(
                        color: Colors.white.withValues(alpha: 0.58),
                        fontSize: 9.5,
                      ),
                    ),
                  ),
                ] else
                  Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 54,
                          height: 54,
                          decoration: BoxDecoration(
                            color: const Color(AppColors.accentSoft),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: const Color(AppColors.accent)
                                  .withValues(alpha: 0.22),
                            ),
                          ),
                          child: const Icon(
                            Icons.add_photo_alternate_outlined,
                            size: 25,
                            color: Color(AppColors.accent),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          '添加照片',
                          style: AppType.title.copyWith(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          '最多 $_maxImages 张 · 首张作为封面',
                          style: AppType.micro.copyWith(
                            fontSize: 10.5,
                            color: const Color(AppColors.textTertiary),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (has) ...[const SizedBox(height: 10), _imageStrip()],
      ],
    );
  }

  Widget _mediaFallback({required IconData icon}) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF141816), Color(0xFF070808)],
        ),
      ),
      child: Center(
        child: Icon(
          icon,
          size: 34,
          color: Colors.white.withValues(alpha: 0.22),
        ),
      ),
    );
  }

  Widget _imageStrip() {
    return SizedBox(
      height: 66,
      child: Row(
        children: [
          for (var i = 0; i < _images.length; i++) ...[
            _imageThumb(i),
            const SizedBox(width: 8),
          ],
          if (_images.length < _maxImages) _addImageTile(),
        ],
      ),
    );
  }

  Widget _imageThumb(int index) {
    final first = index == 0;
    return SizedBox(
      width: 64,
      height: 64,
      child: Stack(
        children: [
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: first
                      ? const Color(AppColors.accent).withValues(alpha: 0.55)
                      : Colors.white.withValues(alpha: 0.08),
                  width: first ? 1.4 : 1,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: Image.file(
                _images[index],
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) =>
                    _mediaFallback(icon: Icons.broken_image_outlined),
              ),
            ),
          ),
          if (first)
            Positioned(
              left: 4,
              bottom: 4,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  '封面',
                  style: AppType.micro.copyWith(
                    fontSize: 7.5,
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          Positioned(
            right: 3,
            top: 3,
            child: PressableScale(
              onTap: () => _removeImage(index),
              scale: 0.9,
              child: Container(
                width: 18,
                height: 18,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.62),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.close_rounded,
                  size: 12,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _addImageTile() {
    return PressableScale(
      onTap: _pickImages,
      scale: 0.96,
      child: SizedBox(
        width: 64,
        height: 64,
        child: Stack(
          children: [
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.025),
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            Positioned.fill(
              child: CustomPaint(
                painter: _DashedBorderPainter(
                  color: Colors.white.withValues(alpha: 0.12),
                  radius: 12,
                ),
              ),
            ),
            const Center(
              child: Icon(
                Icons.add_rounded,
                size: 19,
                color: Color(AppColors.textTertiary),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _imageWidget(int index) {
    final bytes = index < _imageBytes.length ? _imageBytes[index] : null;
    if (bytes != null) {
      return Image.memory(
        bytes,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) =>
            _mediaFallback(icon: Icons.broken_image_outlined),
      );
    }
    return Image.file(
      _images[index],
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) =>
          _mediaFallback(icon: Icons.broken_image_outlined),
    );
  }

  void _removeImage(int index) {
    setState(() {
      _images.removeAt(index);
      if (index < _imageBytes.length) _imageBytes.removeAt(index);
    });
    _scheduleDraftSave();
  }

  // ---------- 视频媒体舞台 ----------

  Widget _videoStage() {
    final f = _videoFile;
    final width = MediaQuery.sizeOf(context).width;
    final height = width < 350 ? 280.0 : (width * 0.80).clamp(300.0, 320.0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: f == null ? _pickVideo : _openCoverPicker,
          behavior: HitTestBehavior.opaque,
          child: Container(
            height: height,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              fit: StackFit.expand,
              children: [
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFF0D211C), Color(0xFF070808)],
                    ),
                  ),
                ),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: Alignment(0, -0.08),
                      radius: 0.72,
                      colors: [Color(0x1F45E0AE), Colors.transparent],
                    ),
                  ),
                ),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Color(0x33000000),
                        Color(0x99000000),
                        Color(0xCC000000),
                      ],
                      stops: [0, 0.56, 1],
                    ),
                  ),
                ),
                if (f == null)
                  Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 62,
                          height: 62,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.06),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.10),
                            ),
                          ),
                          child: const Icon(
                            Icons.play_arrow_rounded,
                            size: 32,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 13),
                        Text(
                          '添加短视频',
                          style: AppType.title.copyWith(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          '最长 $_maxVideoSeconds 秒 · 不超过 50MB',
                          style: AppType.micro.copyWith(
                            fontSize: 10.5,
                            color: const Color(AppColors.textTertiary),
                          ),
                        ),
                        const SizedBox(height: 14),
                        PillButton(
                          label: '从相册选择',
                          icon: Icons.video_library_outlined,
                          variant: PillVariant.tonal,
                          size: PillSize.md,
                          onTap: _pickVideo,
                        ),
                      ],
                    ),
                  )
                else ...[
                  Center(
                    child: Container(
                      width: (height * 0.78) * 9 / 16,
                      height: height * 0.78,
                      decoration: BoxDecoration(
                        color: const Color(AppColors.canvas),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.18),
                        ),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x99000000),
                            blurRadius: 24,
                            offset: Offset(0, 10),
                          ),
                        ],
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          _videoCover(f),
                          if (_thumbBusy)
                            ColoredBox(
                              color: Colors.black.withValues(alpha: 0.30),
                              child: const Center(
                                child: SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ),
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            height: 36,
                            child: Container(
                              decoration: const BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.bottomCenter,
                                  end: Alignment.topCenter,
                                  colors: [
                                    Color(0xCC000000),
                                    Colors.transparent,
                                  ],
                                ),
                              ),
                              alignment: Alignment.center,
                              child: Text(
                                _coverFromFrame
                                    ? '点击选封面帧'
                                    : '封面 · $_coverLabel',
                                style: AppType.micro.copyWith(
                                  fontSize: 9.5,
                                  color: Colors.white.withValues(alpha: 0.86),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Positioned(left: 12, top: 12, child: _stagePill('视频已就绪')),
                  Positioned(
                    right: 12,
                    top: 12,
                    child: _stagePill(_videoSizeLabel(f)),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (f != null) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: const Color(AppColors.accentSoft),
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(
                    color: const Color(AppColors.accent)
                        .withValues(alpha: 0.14),
                  ),
                ),
                child: const Icon(
                  Icons.movie_outlined,
                  size: 17,
                  color: Color(AppColors.accent),
                ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      f.uri.pathSegments.last,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.caption.copyWith(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: const Color(AppColors.textPrimary),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${_videoSizeLabel(f)} · $_coverLabel · 9:16',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.micro.copyWith(
                        fontSize: 9.5,
                        color: const Color(AppColors.textTertiary),
                      ),
                    ),
                  ],
                ),
              ),
              PressableScale(
                onTap: _pickVideo,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 4,
                  ),
                  child: Text(
                    '更换',
                    style: AppType.micro.copyWith(
                      fontSize: 10,
                      color: const Color(AppColors.textSecondary),
                    ),
                  ),
                ),
              ),
              PressableScale(
                onTap: _clearVideo,
                child: Padding(
                  padding: const EdgeInsets.all(5),
                  child: Icon(
                    Icons.delete_outline_rounded,
                    size: 18,
                    color: const Color(AppColors.danger)
                        .withValues(alpha: 0.72),
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _videoCover(File f) {
    if (_coverFile != null && _coverFile!.existsSync()) {
      return Image.file(
        _coverFile!,
        fit: BoxFit.cover,
        cacheWidth: 720,
        errorBuilder: (_, _, _) => _mediaFallback(icon: Icons.movie_outlined),
      );
    }
    if (_coverThumb != null) {
      return Image.memory(
        _coverThumb!,
        fit: BoxFit.cover,
        gaplessPlayback: true,
      );
    }
    if (_videoThumb != null) {
      return Image.memory(
        _videoThumb!,
        fit: BoxFit.cover,
        gaplessPlayback: true,
      );
    }
    return _mediaFallback(icon: Icons.movie_creation_outlined);
  }

  // ---------- 文案 ----------

  Widget _composer() {
    final count = _contentCtrl.text.characters.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '文案',
              style: AppType.micro.copyWith(
                fontSize: 10,
                color: const Color(AppColors.accent),
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2,
              ),
            ),
            const Spacer(),
            Text(
              '$count/$_maxContent',
              style: AppType.micro.copyWith(
                fontSize: 9.5,
                color: count > _maxContent * 0.9
                    ? const Color(AppColors.danger)
                    : const Color(AppColors.textTertiary),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        TextField(
          controller: _contentCtrl,
          maxLines: 8,
          minLines: 3,
          maxLength: _maxContent,
          onChanged: (_) => setState(() {}),
          cursorColor: const Color(AppColors.accent),
          style: AppType.body.copyWith(fontSize: 15, height: 1.55),
          decoration: InputDecoration(
            hintText: isVideo ? '给这段画面一句开场…' : '今天发生了什么？\n写下来，让同频的人看到。',
            hintStyle: AppType.body.copyWith(
              fontSize: 15,
              height: 1.55,
              color: const Color(AppColors.textTertiary),
            ),
            filled: false,
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            counterText: '',
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(vertical: 4),
          ),
        ),
        Container(height: 1, color: const Color(AppColors.hairline)),
        const SizedBox(height: 8),
        Row(
          children: [
            _inlineAction(
              icon: Icons.tag_rounded,
              label: '话题',
              onTap: _pickTopic,
            ),
            const SizedBox(width: 7),
            _inlineAction(
              icon: Icons.alternate_email_rounded,
              label: '提及',
              onTap: () => _insertAt(' @'),
            ),
            if (_inlineEmojiEnabled) ...[
              const SizedBox(width: 7),
              _inlineAction(
                icon: Icons.emoji_emotions_outlined,
                label: '表情',
                onTap: _pickEmoji,
              ),
            ],
            const SizedBox(width: 7),
            _inlineAction(
              icon: Icons.attach_file_rounded,
              label: _attachment == null ? '附件' : '换附件',
              onTap: _pickAttachment,
            ),
            const Spacer(),
            Text(
              '内容将同步到所选版块',
              style: AppType.micro.copyWith(
                fontSize: 9,
                color: const Color(AppColors.textTertiary),
              ),
            ),
          ],
        ),
        if (_topics.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final t in _topics)
                InputChip(
                  label: Text('#$t'),
                  labelStyle: AppType.micro.copyWith(
                    fontSize: 10,
                    color: const Color(AppColors.accent),
                    fontWeight: FontWeight.w600,
                  ),
                  backgroundColor: const Color(AppColors.accent)
                      .withValues(alpha: .08),
                  side: BorderSide(
                    color: const Color(AppColors.accent).withValues(alpha: .24),
                  ),
                  deleteIconColor: const Color(AppColors.accent),
                  visualDensity: VisualDensity.compact,
                  onDeleted: () {
                    setState(() => _topics.remove(t));
                    _scheduleDraftSave();
                  },
                ),
            ],
          ),
        ],
        if (_attachment != null) ...[
          const SizedBox(height: 9),
          Container(
            padding: const EdgeInsets.fromLTRB(10, 9, 5, 9),
            decoration: BoxDecoration(
              color: const Color(AppColors.card),
              borderRadius: BorderRadius.circular(AppRadius.md),
              border: Border.all(color: const Color(AppColors.border)),
            ),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: const Color(AppColors.accentSoft),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  alignment: Alignment.center,
                  child: const Icon(
                    Icons.description_outlined,
                    size: 18,
                    color: Color(AppColors.accent),
                  ),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _attachmentLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppType.caption.copyWith(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: const Color(AppColors.textPrimary),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${_attachmentType(_attachmentLabel)} · '
                        '${fileSizeText(_attachment!.lengthSync())}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppType.micro.copyWith(
                          fontSize: 9.5,
                          color: const Color(AppColors.textTertiary),
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: _removeAttachment,
                  visualDensity: VisualDensity.compact,
                  tooltip: '移除附件',
                  icon: const Icon(
                    Icons.close_rounded,
                    size: 17,
                    color: Color(AppColors.textTertiary),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _inlineAction({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return PressableScale(
      onTap: onTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: const Color(AppColors.textSecondary)),
          const SizedBox(width: 3),
          Text(
            label,
            style: AppType.micro.copyWith(
              fontSize: 10,
              color: const Color(AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }

  // ---------- 发布设置 ----------

  Widget _settings() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionLabel('发布设置', trailing: _boardId.isEmpty ? '版块必选' : null),
        const SizedBox(height: 7),
        Container(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.028),
            borderRadius: BorderRadius.circular(17),
            border: Border.all(color: const Color(AppColors.hairline)),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              _settingRow(
                icon: Icons.grid_view_rounded,
                label: '版块',
                value: _boardId.isEmpty ? '选择版块' : _boardName(_boardId),
                accent: _boardId.isEmpty,
                onTap: _openBoardSheet,
              ),
              const _SettingHairline(),
              _settingRow(
                icon: Icons.graphic_eq_rounded,
                label: '配乐',
                value: (_music?['name'] ?? '').toString().isEmpty
                    ? '不加配乐'
                    : (_music!['name'] ?? '').toString(),
                accent: _music != null,
                onTap: _pickMusic,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _tipCard() {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 9, 10, 9),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.022),
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: const Color(AppColors.hairline)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 1),
            child: Icon(
              Icons.lightbulb_outline_rounded,
              size: 15,
              color: Color(AppColors.accent),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              isVideo
                  ? '点海报可选封面帧；发布后自动转码，悬浮卡会在首页显示进度。'
                  : '首张图片会成为封面；发布后自动回到首页，悬浮卡显示发布进度。',
              style: AppType.micro.copyWith(
                fontSize: 9.5,
                height: 1.45,
                color: const Color(AppColors.textTertiary),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(String label, {String? trailing}) {
    return Row(
      children: [
        Text(
          label,
          style: AppType.micro.copyWith(
            fontSize: 10,
            color: const Color(AppColors.textTertiary),
            fontWeight: FontWeight.w600,
            letterSpacing: 0.8,
          ),
        ),
        const Spacer(),
        if (trailing != null)
          Text(
            trailing,
            style: AppType.micro.copyWith(
              fontSize: 9,
              color: const Color(AppColors.danger).withValues(alpha: 0.72),
            ),
          ),
      ],
    );
  }

  Widget _settingRow({
    required IconData icon,
    required String label,
    required String value,
    required VoidCallback onTap,
    bool accent = false,
  }) {
    return PressableScale(
      onTap: onTap,
      scale: 0.99,
      child: Container(
        height: 47,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            Container(
              width: 27,
              height: 27,
              decoration: BoxDecoration(
                color: accent
                    ? const Color(AppColors.accentSoft)
                    : Colors.white.withValues(alpha: 0.035),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                icon,
                size: 14,
                color: accent
                    ? const Color(AppColors.accent)
                    : const Color(AppColors.textSecondary),
              ),
            ),
            const SizedBox(width: 10),
            Text(
              label,
              style: AppType.caption.copyWith(
                fontSize: 11.5,
                color: const Color(AppColors.textSecondary),
              ),
            ),
            const Spacer(),
            Flexible(
              child: Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: AppType.micro.copyWith(
                  fontSize: 10.5,
                  color: accent
                      ? const Color(AppColors.accent)
                      : const Color(AppColors.textPrimary),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            const SizedBox(width: 3),
            Icon(
              Icons.chevron_right_rounded,
              size: 16,
              color: Colors.white.withValues(alpha: 0.30),
            ),
          ],
        ),
      ),
    );
  }

  Widget _soundPanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 14),
        _sectionLabel('声音', trailing: '视频播放时生效'),
        const SizedBox(height: 7),
        Container(
          padding: const EdgeInsets.fromLTRB(12, 9, 12, 7),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.025),
            borderRadius: BorderRadius.circular(15),
            border: Border.all(color: const Color(AppColors.hairline)),
          ),
          child: Column(
            children: [
              _mixerRow(
                icon: Icons.volume_up_outlined,
                label: '原声',
                value: _audioVolume,
                onChanged: (v) => setState(() => _audioVolume = v),
              ),
              if (_music != null)
                _mixerRow(
                  icon: Icons.music_note_outlined,
                  label: '配乐',
                  value: _musicVolume,
                  onChanged: (v) => setState(() => _musicVolume = v),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _mixerRow({
    required IconData icon,
    required String label,
    required int value,
    required ValueChanged<int> onChanged,
  }) {
    return SizedBox(
      height: 34,
      child: Row(
        children: [
          Icon(icon, size: 14, color: const Color(AppColors.textTertiary)),
          const SizedBox(width: 6),
          SizedBox(
            width: 25,
            child: Text(
              label,
              style: AppType.micro.copyWith(
                fontSize: 9.5,
                color: const Color(AppColors.textSecondary),
              ),
            ),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2.5,
                activeTrackColor: const Color(AppColors.accent)
                    .withValues(alpha: 0.72),
                inactiveTrackColor: Colors.white.withValues(alpha: 0.08),
                thumbColor: const Color(AppColors.accent),
                thumbShape: const RoundSliderThumbShape(
                  enabledThumbRadius: 5.5,
                ),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                overlayColor: const Color(AppColors.accent)
                    .withValues(alpha: 0.12),
              ),
              child: Slider(
                value: value.toDouble(),
                min: 0,
                max: 100,
                onChanged: (v) => onChanged(v.round()),
              ),
            ),
          ),
          SizedBox(
            width: 31,
            child: Text(
              '$value%',
              textAlign: TextAlign.right,
              style: AppType.numeric.copyWith(
                fontSize: 9.5,
                color: const Color(AppColors.textSecondary),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------- 工具条 ----------

  Widget _actionDock() {
    final items = <_DockItem>[
      if (isVideo)
        _DockItem(
          icon: Icons.video_library_outlined,
          label: '视频',
          active: _videoFile != null,
          onTap: _pickVideo,
        )
      else
        _DockItem(
          icon: Icons.photo_library_outlined,
          label: '照片',
          active: _images.isNotEmpty,
          onTap: _pickImages,
        ),
      if (isVideo)
        _DockItem(
          icon: Icons.crop_rounded,
          label: '封面帧',
          active: !_coverFromFrame,
          onTap: _openCoverPicker,
        ),
      if (_inlineEmojiEnabled)
        _DockItem(
          icon: Icons.emoji_emotions_outlined,
          label: '表情',
          active: _contentCtrl.text.contains('['),
          onTap: _pickEmoji,
        ),
      _DockItem(
        icon: Icons.tag_rounded,
        label: '话题',
        active: _topics.isNotEmpty || _contentCtrl.text.contains('#'),
        onTap: _pickTopic,
      ),
      if (!isVideo)
        _DockItem(
          icon: Icons.bar_chart_rounded,
          label: '投票',
          active: _poll != null,
          onTap: _editPoll,
        ),
      _DockItem(
        icon: Icons.graphic_eq_rounded,
        label: '配乐',
        active: _music != null,
        onTap: _pickMusic,
      ),
      _DockItem(
        icon: Icons.grid_view_rounded,
        label: '版块',
        active: _boardId.isNotEmpty,
        onTap: _openBoardSheet,
      ),
    ];

    return Container(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 5),
      decoration: BoxDecoration(
        color: const Color(AppColors.bg).withValues(alpha: 0.94),
        border: const Border(top: BorderSide(color: Color(AppColors.hairline))),
      ),
      child: Row(
        children: [for (final item in items) Expanded(child: _dockItem(item))],
      ),
    );
  }

  Widget _dockItem(_DockItem item) {
    final color = item.active
        ? const Color(AppColors.accent)
        : const Color(AppColors.textSecondary);
    return PressableScale(
      onTap: item.onTap,
      scale: 0.94,
      child: SizedBox(
        height: 47,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(item.icon, size: 20, color: color),
            const SizedBox(height: 4),
            Text(
              item.label,
              maxLines: 1,
              style: AppType.micro.copyWith(
                fontSize: 9.5,
                color: item.active
                    ? const Color(AppColors.textPrimary)
                    : const Color(AppColors.textSecondary),
                fontWeight: item.active ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
            const SizedBox(height: 2),
            AnimatedContainer(
              duration: AppMotion.fast,
              width: item.active ? 10 : 3,
              height: 2,
              decoration: BoxDecoration(
                color: item.active
                    ? const Color(AppColors.accent)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------- 发布栏 ----------

  Widget _publishBar() {
    final bottom = MediaQuery.paddingOf(context).bottom;
    final width = MediaQuery.sizeOf(context).width;
    final board = _boardId.isEmpty ? '待选择' : _boardName(_boardId);
    final summary = isVideo
        ? (_videoFile == null
              ? '视频 · 尚未选择'
              : '视频 · ${_videoSizeLabel(_videoFile!)}')
        : (_images.isEmpty ? '纯文字' : '图文 · ${_images.length} 张');
    final hint = !_canPublish
        ? (_boardId.isEmpty
              ? '点此选择版块'
              : isVideo
              ? '先选择视频'
              : '写点内容或选张图')
        : summary;

    return Container(
      padding: EdgeInsets.fromLTRB(16, 9, 16, 9 + bottom),
      decoration: BoxDecoration(
        color: const Color(AppColors.bg).withValues(alpha: 0.92),
        border: const Border(top: BorderSide(color: Color(AppColors.hairline))),
      ),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _openBoardSheet,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Text(
                        '发布到',
                        style: AppType.micro.copyWith(
                          fontSize: 9,
                          color: const Color(AppColors.textTertiary),
                        ),
                      ),
                      const SizedBox(width: 5),
                      Flexible(
                        child: Text(
                          board,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppType.micro.copyWith(
                            fontSize: 11,
                            color: _boardId.isEmpty
                                ? const Color(AppColors.accent)
                                      .withValues(alpha: 0.78)
                                : const Color(AppColors.textPrimary),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (_boardId.isEmpty) ...[
                        const SizedBox(width: 2),
                        Icon(
                          Icons.chevron_right_rounded,
                          size: 13,
                          color: const Color(AppColors.accent)
                              .withValues(alpha: 0.72),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    hint,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.micro.copyWith(
                      fontSize: 9,
                      color: _canPublish
                          ? const Color(AppColors.textTertiary)
                          : const Color(AppColors.accent)
                                .withValues(alpha: 0.68),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: width < 360 ? 124 : 138,
            child: PillButton(
              label: isVideo ? '发布视频' : '发布',
              variant: _canPublish ? PillVariant.primary : PillVariant.tonal,
              size: PillSize.lg,
              expand: true,
              glow: _canPublish,
              enabled: _canPublish,
              onTap: _publish,
            ),
          ),
        ],
      ),
    );
  }

  Widget _stagePill(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.40),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      child: Text(
        label,
        style: AppType.micro.copyWith(
          fontSize: 9,
          color: Colors.white.withValues(alpha: 0.82),
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
        ),
      ),
    );
  }

  String _videoSizeLabel(File f) {
    try {
      final mb = f.lengthSync() / 1024 / 1024;
      return '${mb.toStringAsFixed(mb >= 10 ? 0 : 1)}MB';
    } catch (_) {
      return '视频';
    }
  }

  String get _coverLabel {
    if (_coverFile != null) return '自定义封面';
    if (_coverTime != null) return '帧 ${_fmtTime(_coverTime!)}';
    return '自动首帧';
  }

  String _fmtTime(double seconds) {
    final m = seconds ~/ 60;
    final s = (seconds % 60).floor().toString().padLeft(2, '0');
    return '$m:$s';
  }

  // ---------------- 版块选择 / 显示名 ----------------

  String _boardName(String id) {
    for (final b in _boards) {
      if (b['id'] == id) return '${b['icon'] ?? '📌'} ${b['name']}';
    }
    return '选择版块';
  }

  Future<void> _openBoardSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      sheetAnimationStyle: const AnimationStyle(
        duration: AppMotion.page,
        curve: AppMotion.standard,
        reverseCurve: AppMotion.exit,
      ),
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
                            const Icon(
                              Icons.check_rounded,
                              size: 18,
                              color: Color(AppColors.accent),
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }
}

class _DockItem {
  const _DockItem({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;
}

class _SettingHairline extends StatelessWidget {
  const _SettingHairline();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 1,
      margin: const EdgeInsets.only(left: 49),
      color: const Color(AppColors.hairline),
    );
  }
}

class _DashedBorderPainter extends CustomPainter {
  const _DashedBorderPainter({required this.color, required this.radius});

  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = color;
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius)),
      );
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      const dash = 5.0;
      const gap = 4.0;
      while (distance < metric.length) {
        final end = (distance + dash).clamp(0.0, metric.length);
        canvas.drawPath(metric.extractPath(distance, end), paint);
        distance = end + gap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorderPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.radius != radius;
}
