/// 消息页（P0）：互动通知 + 社区官方通知（与音乐官方通知完全分离）
///
/// - 互动通知：@提及、审核结果、新关注、点赞评论等（写共享 notifications 表，两边可见）
/// - 官方通知：读 community_official_messages（独立于音乐 official_messages）
library;

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../config.dart';
import '../../models/feed_item.dart';
import '../../widgets/image_box.dart';

class MessagePage extends StatefulWidget {
  const MessagePage({super.key});

  @override
  State<MessagePage> createState() => _MessagePageState();
}

class _MessagePageState extends State<MessagePage> {
  int _tab = 0; // 0=互动通知 1=社区官方
  List<Map<String, dynamic>> _notifs = [];
  List<Map<String, dynamic>> _official = [];
  bool _loading = true;
  bool _hasMore = false;
  int _page = 0;
  bool _listLoading = false;

  @override
  void initState() {
    super.initState();
    _load(refresh: true);
  }

  Future<void> _load({bool refresh = false}) async {
    if (_listLoading || (!_hasMore && !refresh)) return;
    setState(() => _listLoading = true);
    try {
      if (_tab == 0) {
        final j = await ApiClient.notifications(
            page: refresh ? 1 : _page + 1, size: 20);
        final list = ((j['list'] ?? []) as List)
            .whereType<Map<String, dynamic>>()
            .toList();
        if (!mounted) return;
        setState(() {
          if (refresh) {
            _notifs = list;
            _page = 1;
          } else {
            _notifs.addAll(list);
            _page++;
          }
          _hasMore = (j['hasMore'] ?? false) as bool;
          _loading = false;
          _listLoading = false;
        });
        // 全部标记已读
        if (refresh && list.isNotEmpty) {
          await ApiClient.markNotificationsRead();
        }
      } else {
        final j = await ApiClient.officialMessages();
        if (!mounted) return;
        setState(() {
          _official = ((j['list'] ?? []) as List)
              .whereType<Map<String, dynamic>>()
              .toList();
          _hasMore = false;
          _loading = false;
          _listLoading = false;
        });
        await ApiClient.markOfficialRead();
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _listLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(AppTheme.bg),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 10),
              child: Text('消息',
                  style: TextStyle(
                      color: Color(AppTheme.textPrimary),
                      fontSize: 20,
                      fontWeight: FontWeight.bold)),
            ),
            _tabBar(),
            const Divider(color: Color(AppTheme.border), height: 1),
            Expanded(
              child: _loading
                  ? const Center(
                      child: CircularProgressIndicator(
                          color: Color(AppTheme.accent), strokeWidth: 2.5))
                  : RefreshIndicator(
                      color: const Color(AppTheme.accent),
                      backgroundColor: const Color(AppTheme.card),
                      onRefresh: () => _load(refresh: true),
                      child: ListView(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        children:
                            _tab == 0 ? _notifTiles() : _officialTiles(),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tabBar() {
    return Row(
      children: [
        _tabItem(0, '互动通知'),
        _tabItem(1, '社区官方'),
        const Expanded(
          child: Text('音乐官方通知请在音乐 App 内查看',
              textAlign: TextAlign.right,
              style: TextStyle(color: Color(AppTheme.textTertiary), fontSize: 11)),
        ),
      ],
    );
  }

  Widget _tabItem(int i, String label) {
    final sel = _tab == i;
    return GestureDetector(
      onTap: () {
        if (sel) return;
        setState(() {
          _tab = i;
          _notifs = [];
          _official = [];
          _hasMore = false;
          _loading = true;
          _page = 0;
        });
        _load(refresh: true);
      },
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 4, 0, 0),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: sel ? const Color(AppTheme.accent) : Colors.transparent,
              width: 2.5,
            ),
          ),
        ),
        child: Text(label,
            style: TextStyle(
              color: sel
                  ? const Color(AppTheme.accent)
                  : const Color(AppTheme.textSecondary),
              fontSize: 14,
              fontWeight: sel ? FontWeight.bold : FontWeight.normal,
            )),
      ),
    );
  }

  List<Widget> _notifTiles() {
    if (_notifs.isEmpty) {
      return [
        _empty('暂无互动通知\n点赞、评论、@提及、审核结果都会出现在这里')
      ];
    }
    final List<Widget> tiles = _notifs.map((n) {
      final type = (n['type'] ?? '') as String;
      final title = (n['title'] ?? '') as String;
      final content = (n['content'] ?? '') as String;
      final fromName = (n['fromUserName'] ?? '') as String;
      final created = (n['created'] ?? 0) as int;
      final isRead = (n['isRead'] ?? false) as bool;
      final icon = _notifIcon(type);
      return Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: const BoxDecoration(
          border: Border(
              bottom:
                  BorderSide(color: Color(AppTheme.border), width: 0.5)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: const Color(AppTheme.accentSoft),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: const Color(AppTheme.accent), size: 18),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(title,
                            style: TextStyle(
                              color: isRead
                                  ? const Color(AppTheme.textSecondary)
                                  : const Color(AppTheme.textPrimary),
                              fontSize: 14,
                              fontWeight:
                                  isRead ? FontWeight.normal : FontWeight.w600,
                            )),
                      ),
                      Text(timeAgo(created),
                          style: const TextStyle(
                              color: Color(AppTheme.textTertiary),
                              fontSize: 11)),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    fromName.isEmpty ? content : '$fromName：$content',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Color(AppTheme.textSecondary),
                        fontSize: 13,
                        height: 1.4),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }).toList();
    if (_hasMore) {
      tiles.add(GestureDetector(
        onTap: () => _load(),
        child: const Padding(
          padding: EdgeInsets.symmetric(vertical: 14),
          child: Center(
            child: Text('加载更多',
                style: TextStyle(
                    color: Color(AppTheme.textSecondary), fontSize: 13)),
          ),
        ),
      ));
    }
    return tiles;
  }

  List<Widget> _officialTiles() {
    if (_official.isEmpty) {
      return [_empty('暂无社区官方通知')];
    }
    return _official.map((m) {
      final content = (m['content'] ?? '') as String;
      final sender = (m['senderName'] ?? '') as String;
      final created = (m['created'] ?? 0) as int;
      return Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: const BoxDecoration(
          border: Border(
              bottom:
                  BorderSide(color: Color(AppTheme.border), width: 0.5)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: const Color(AppTheme.sky).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.campaign_outlined,
                  color: Color(AppTheme.sky), size: 18),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(sender.isEmpty ? '流萤社区官方' : sender,
                      style: const TextStyle(
                          color: Color(AppTheme.textPrimary),
                          fontSize: 14,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text(content,
                      style: const TextStyle(
                          color: Color(AppTheme.textSecondary),
                          fontSize: 13,
                          height: 1.4)),
                  const SizedBox(height: 4),
                  Text(timeAgo(created),
                      style: const TextStyle(
                          color: Color(AppTheme.textTertiary), fontSize: 11)),
                ],
              ),
            ),
          ],
        ),
      );
    }).toList();
  }

  IconData _notifIcon(String type) {
    switch (type) {
      case 'community_mention':
        return Icons.alternate_email;
      case 'community_audit':
        return Icons.fact_check_outlined;
      case 'community_interact':
        return Icons.favorite_outline;
      case 'community_follow':
        return Icons.person_add_alt;
      default:
        return Icons.notifications_none;
    }
  }

  Widget _empty(String s) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 80),
      child: Center(
        child: Text(s,
            textAlign: TextAlign.center,
            style: const TextStyle(
                color: Color(AppTheme.textTertiary),
                fontSize: 13,
                height: 1.6)),
      ),
    );
  }
}
