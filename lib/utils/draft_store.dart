/// 发布页本地草稿：编辑中的正文/版块/模式自动暂存，下次进入可恢复。
///
/// 只存文本类字段（正文、版块 id/名称、模式、配乐名）——图片/视频是本地临时文件，
/// 重启后大概率失效，存了反而误导。
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class DraftStore {
  DraftStore._();

  static const String _key = 'post_editor_draft_v1';

  /// 保存草稿（内容为空视为清空）
  static Future<void> save({
    required String content,
    required String boardId,
    required String boardName,
    required String mode,
    String musicName = '',
  }) async {
    try {
      final sp = await SharedPreferences.getInstance();
      if (content.trim().isEmpty && boardId.isEmpty) {
        await sp.remove(_key);
        return;
      }
      await sp.setString(
        _key,
        jsonEncode({
          'content': content,
          'boardId': boardId,
          'boardName': boardName,
          'mode': mode,
          'musicName': musicName,
          'savedAt': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        }),
      );
    } catch (_) {}
  }

  /// 读取草稿（没有则 null）
  static Future<Map<String, dynamic>?> load() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(_key);
      if (raw == null || raw.isEmpty) return null;
      final j = jsonDecode(raw);
      if (j is! Map) return null;
      final m = Map<String, dynamic>.from(j);
      if ((m['content'] ?? '').toString().trim().isEmpty) return null;
      return m;
    } catch (_) {
      return null;
    }
  }

  /// 清空草稿（发布成功 / 用户丢弃）
  static Future<void> clear() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.remove(_key);
    } catch (_) {}
  }
}
