/// 独立于发布页 State 的发布任务。
///
/// 页面在点击发布后立即关闭，任务继续在后台执行；悬浮窗只观察这里的
/// progress / stage / error，不依赖任何 BuildContext 或已销毁的 State。
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../api/client.dart';
import '../utils/draft_store.dart';
import 'publish_bus.dart';

enum PublishKind { text, video }

class PublishPreview {
  const PublishPreview({
    required this.kind,
    required this.content,
    this.imagePath,
    this.imageBytes,
    this.hasAttachment = false,
  });

  final PublishKind kind;
  final String content;

  /// 图文首图，或视频的自定义封面路径。
  final String? imagePath;

  /// 视频帧封面（内存图）。
  final Uint8List? imageBytes;

  final bool hasAttachment;

  bool get hasMedia => imagePath != null || imageBytes != null;

  String get badge => switch (kind) {
    PublishKind.video => '视频',
    PublishKind.text => hasMedia ? '图文' : (hasAttachment ? '文件' : '文字'),
  };
}

class PublishPayload {
  PublishPayload({
    required this.kind,
    required this.content,
    required this.images,
    required this.video,
    required this.coverFile,
    required this.coverFromFrame,
    required this.coverTime,
    required this.boardId,
    required this.poll,
    required this.music,
    required this.topics,
    required this.audioVolume,
    required this.musicVolume,
    required this.preview,
    this.attachment,
    this.attachmentLabel = '',
  });

  final PublishKind kind;
  final String content;
  final List<File> images;
  final File? video;
  final File? coverFile;
  final bool coverFromFrame;
  final double? coverTime;
  final String boardId;
  final Map<String, dynamic>? poll;
  final Map<String, dynamic>? music;
  final List<String> topics;
  final int audioVolume;
  final int musicVolume;
  final PublishPreview preview;
  final File? attachment;
  final String attachmentLabel;

  bool get isVideo => kind == PublishKind.video;
}

class PublishJob {
  PublishJob._(PublishPayload payload)
    : payload = payload,
      preview = payload.preview;

  /// 视觉验收用：不会真正发起请求，done 永不完成。
  @visibleForTesting
  PublishJob.forTest({
    required this.preview,
    double progress = 0,
    String stage = '正在发布',
  }) : payload = null {
    this.progress.value = progress.clamp(0, 1);
    this.stage.value = stage;
  }

  final PublishPayload? payload;
  final PublishPreview preview;

  final ValueNotifier<double> progress = ValueNotifier<double>(0);
  final ValueNotifier<String> stage = ValueNotifier<String>('准备发布');
  final ValueNotifier<String?> error = ValueNotifier<String?>(null);

  final Completer<bool> _done = Completer<bool>();
  Timer? _creepTimer;
  double _target = 0;
  double _value = 0;
  bool _finished = false;
  bool _auditPending = false;

  bool get auditPending => _auditPending;

  Future<bool> get done => _done.future;

  static PublishJob start(PublishPayload payload) {
    final job = PublishJob._(payload);
    unawaited(job._run());
    return job;
  }

  void _setTarget(double target, String label) {
    _target = target.clamp(0.0, 1.0);
    stage.value = label;
    _creepTimer ??= Timer.periodic(const Duration(milliseconds: 90), (_) {
      final diff = _target - _value;
      if (diff <= 0) return;
      _value += math.max(0.0012, diff * 0.14);
      if (_value > _target) _value = _target;
      progress.value = _value.clamp(0.0, 1.0);
    });
    // 立即推进一小步，避免 0% 停留太久。
    _value = math.max(_value, math.min(_target, _value + 0.004));
    progress.value = _value;
  }

  Future<void> _run() async {
    final p = payload!;
    try {
      _setTarget(0.035, p.isVideo ? '读取视频…' : '准备发布…');

      if (!p.isVideo) {
        final names = <String>[];
        for (var i = 0; i < p.images.length; i++) {
          _setTarget(
            0.12 + (i / math.max(1, p.images.length)) * 0.60,
            '上传图片 ${i + 1}/${p.images.length}',
          );
          final j = await ApiClient.uploadImage(p.images[i].path);
          final name = (j['name'] ?? '').toString();
          if (name.isEmpty) throw Exception('图片上传返回为空');
          names.add(name);
        }
        _setTarget(0.84, '整理内容…');
        final attachmentMeta = <Map<String, dynamic>>[];
        if (p.attachment != null) {
          _setTarget(0.87, '上传附件…');
          final aj = await ApiClient.uploadAttachment(
            p.attachment!.path,
            filename: p.attachmentLabel,
          );
          final name = (aj['name'] ?? '').toString();
          if (name.isEmpty) throw Exception('附件上传返回为空');
          attachmentMeta.add({
            'name': name,
            'label': (aj['label'] ?? p.attachmentLabel).toString(),
            'size': (aj['size'] is num)
                ? (aj['size'] as num).toInt()
                : p.attachment!.lengthSync(),
            'ext': (aj['ext'] ?? '').toString(),
            'mime': (aj['mime'] ?? '').toString(),
          });
        }
        _setTarget(0.92, '正在发布…');
        final r = await ApiClient.post(
          '/post',
          body: {
            'content': p.content,
            'images': names,
            'boardId': p.boardId,
            'topic': p.topics,
            if (p.poll != null) 'poll': p.poll,
            if (p.music != null) 'music': p.music,
            if (attachmentMeta.isNotEmpty) 'attachments': attachmentMeta,
            'audioVolume': p.audioVolume,
            'musicVolume': p.musicVolume,
          },
        );
        _auditPending = _isAuditPending(r);
      } else {
        _setTarget(0.30, '上传视频…');
        final up = await ApiClient.uploadVideo(p.video!.path);
        final vid = up['videoId'] as String;
        _setTarget(0.36, '视频已上传…');

        var cover = 'auto';
        if (!p.coverFromFrame && p.coverFile != null) {
          _setTarget(0.43, '上传自定义封面…');
          final cj = await ApiClient.uploadImage(p.coverFile!.path);
          cover = cj['name'] as String;
        } else if (!p.coverFromFrame && p.coverTime != null) {
          _setTarget(0.44, '抽取封面帧…');
          try {
            final cj = await ApiClient.coverFrame(vid, p.coverTime!);
            final c = (cj['cover'] ?? '').toString();
            if (c.isNotEmpty) cover = c.split('/').last;
          } catch (_) {
            cover = 'auto';
          }
        } else {
          _setTarget(0.42, '使用自动首帧…');
        }

        _setTarget(0.48, '等待视频转码…');
        var ready = false;
        for (var i = 0; i < 24; i++) {
          try {
            final st = await ApiClient.videoStatus(vid);
            final s = (st['status'] ?? '') as String;
            if (s == 'done' || s == 'ready') {
              ready = true;
              break;
            }
            if (s == 'failed') {
              throw ApiException(500, '视频转码失败，请重新选择视频');
            }
          } catch (e) {
            if (e is ApiException && e.code == 500) rethrow;
          }
          _setTarget(0.48 + ((i + 1) / 24) * 0.40, '正在转码 ${i + 1}/24…');
          await Future.delayed(const Duration(seconds: 10));
        }
        if (!ready) {
          throw ApiException(408, '视频转码较慢，内容已保留为草稿');
        }

        _setTarget(0.92, '正在发布…');
        final attachmentMeta = <Map<String, dynamic>>[];
        if (p.attachment != null) {
          _setTarget(0.93, '上传附件…');
          final aj = await ApiClient.uploadAttachment(
            p.attachment!.path,
            filename: p.attachmentLabel,
          );
          final name = (aj['name'] ?? '').toString();
          if (name.isEmpty) throw Exception('附件上传返回为空');
          attachmentMeta.add({
            'name': name,
            'label': (aj['label'] ?? p.attachmentLabel).toString(),
            'size': (aj['size'] is num)
                ? (aj['size'] as num).toInt()
                : p.attachment!.lengthSync(),
            'ext': (aj['ext'] ?? '').toString(),
            'mime': (aj['mime'] ?? '').toString(),
          });
        }
        final r = await ApiClient.post(
          '/video/post',
          body: {
            'video': vid,
            'cover': cover,
            'duration': (up['duration'] ?? 0) is num
                ? (up['duration'] as num).toInt()
                : 0,
            'content': p.content,
            'boardId': p.boardId,
            'topic': p.topics,
            if (p.music != null) 'music': p.music,
            if (attachmentMeta.isNotEmpty) 'attachments': attachmentMeta,
            'audioVolume': p.audioVolume,
            'musicVolume': p.musicVolume,
          },
        );
        _auditPending = _isAuditPending(r);
      }

      await DraftStore.clear();
      _finish(true);
    } catch (e) {
      _finish(false, e is ApiException ? e.message : '发布失败，请稍后重试');
    }
  }

  void _finish(bool ok, [String? errorText]) {
    if (_finished) return;
    _finished = true;
    _creepTimer?.cancel();
    if (ok) {
      _value = 1;
      progress.value = 1;
      stage.value = _auditPending ? '审核中 · 仅自己可见' : '已发布';
      PublishBus.completed.value++;
    } else {
      error.value = errorText ?? '发布失败';
      stage.value = '发布未完成';
      if (_value <= 0.02) progress.value = 0.02;
    }
    if (!_done.isCompleted) _done.complete(ok);
  }

  static bool _isAuditPending(Map<String, dynamic> response) {
    final post = response['post'];
    if (post is! Map) return false;
    final status = post['auditStatus'];
    return status is num && status.toInt() == 0;
  }
}
