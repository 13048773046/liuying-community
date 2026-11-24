/// 消息域数据仓库（前端工业化试点）
///
/// 页面只依赖本仓库，不直接拼 `ApiClient` 的通知/私信方法：
/// - 统一错误与重试入口；
/// - 后续可在这里加本地缓存、已读乐观更新、请求去重；
/// - 迁移期仍复用 `ApiClient`，不改变现有 HTTP/WS 行为。
library;

import '../../../api/client.dart';

class MessageRepository {
  MessageRepository._();

  static final MessageRepository instance = MessageRepository._();

  // ---------- 互动通知 ----------
  Future<Map<String, dynamic>> notifications({
    String group = '',
    int page = 1,
    int size = 20,
  }) => ApiClient.notifications(group: group, page: page, size: size);

  Future<Map<String, dynamic>> notificationsUnread() =>
      ApiClient.notificationsUnread();

  Future<void> markNotificationsRead({String? id, String? group}) =>
      ApiClient.markNotificationsRead(id: id, group: group);

  Future<void> deleteNotification(String id) =>
      ApiClient.deleteNotification(id);

  // ---------- 官方通知 ----------
  Future<Map<String, dynamic>> officialMessages({double after = 0}) =>
      ApiClient.officialMessages(after: after);

  Future<void> markOfficialRead() => ApiClient.markOfficialRead();

  // ---------- 私信 ----------
  Future<Map<String, dynamic>> dmConversations({int page = 1, int size = 20}) =>
      ApiClient.dmConversations(page: page, size: size);

  Future<Map<String, dynamic>> dmMessages({
    required String peer,
    double before = 0,
    int limit = 30,
  }) => ApiClient.dmMessages(peer: peer, before: before, limit: limit);

  Future<Map<String, dynamic>> dmSend(
    String peer,
    String content, {
    String type = 'text',
  }) => ApiClient.dmSend(peer, content, type: type);

  Future<void> dmRead(String peer) => ApiClient.dmRead(peer);

  Future<void> dmReadAll() => ApiClient.dmReadAll();

  Future<Map<String, dynamic>> dmUnread() => ApiClient.dmUnread();
}
