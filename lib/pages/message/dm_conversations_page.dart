/// 私信会话列表页：头像 + 名字 + 最后消息 + 时间 + 未读数字角标
/// 点击进入聊天页；下拉刷新；WS 新消息实时更新列表
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../config.dart';
import '../../models/feed_item.dart';
import '../../services/notify_bus.dart';
import '../../widgets/user_avatar.dart';
import '../mine/login_page.dart';
import 'dm_chat_page.dart';

class DmConversationsPage extends StatefulWidget {
  const DmConversationsPage({super.key});

  @override
  State<DmConversationsPage> createState() => _DmConversationsPageState();
}

class _DmConversationsPageState extends State<DmConversationsPage> {
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;
  bool _hasMore = false;
  int _page = 0;
  bool _needLogin = false;
  String? _loadError;
  StreamSubscription? _dmSub;

  @override
  void initState() {
    super.initState();
    _load(refresh: true);
    // 新私信实时刷新列表（未读 + 置顶）
    _dmSub = NotifyBus.shared.onDm.stream.listen((_) {
      if (mounted) _load(refresh: true);
    });
  }

  @override
  void dispose() {
    _dmSub?.cancel();
    super.dispose();
  }

  Future<void> _load({bool refresh = false}) async {
    if (!refresh && !_hasMore) return;
    setState(() => _loading = refresh);
    try {
      final j = await ApiClient.dmConversations(
          page: refresh ? 1 : _page + 1, size: 20);
      final list = ((j['list'] ?? []) as List)
          .whereType<Map<String, dynamic>>()
          .toList();
      if (!mounted) return;
      setState(() {
        if (refresh) {
          _items = list;
          _page = 1;
        } else {
          _items.addAll(list);
          _page++;
        }
        _hasMore = boolOf(j['hasMore']);
        _loading = false;
        _loadError = null;
      });
    } catch (e) {
      if (!mounted) return;
      final is401 = e is ApiException && e.code == 401;
      setState(() {
        _loading = false;
        _needLogin = is401;
        _loadError = is401
            ? null
            : (e is ApiException ? e.message : '网络异常，请检查网络后重试');
      });
    }
  }

  Future<void> _openChat(Map<String, dynamic> it) async {
    final peer = (it['peer'] ?? {}) as Map<String, dynamic>;
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => DmChatPage(
            peerId: (peer['id'] ?? '') as String,
            peerName: (peer['name'] ?? '') as String,
            peerAvatar: (peer['avatar'] ?? '') as String)));
    if (mounted) _load(refresh: true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(AppTheme.bg),
      appBar: AppBar(
        backgroundColor: const Color(AppTheme.bg),
        elevation: 0,
        centerTitle: true,
        title: const Text('私信',
            style: TextStyle(
                color: Color(AppTheme.textPrimary),
                fontSize: 16,
                fontWeight: FontWeight.w600)),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded,
              color: Colors.white, size: 18),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(
                  color: Color(AppTheme.accent), strokeWidth: 2.5))
          : _needLogin
              ? _loginEmpty()
              : _loadError != null
                  ? _errorRetry()
                  : RefreshIndicator(
                      color: const Color(AppTheme.accent),
                      backgroundColor: const Color(AppTheme.card),
                      onRefresh: () => _load(refresh: true),
                      child: _items.isEmpty
                          ? ListView(
                              physics:
                                  const AlwaysScrollableScrollPhysics(),
                              children: [
                                _empty(),
                              ],
                            )
                          : ListView.separated(
                              padding: EdgeInsets.only(
                                  bottom:
                                      16 + MediaQuery.paddingOf(context).bottom),
                              itemCount:
                                  _items.length + (_hasMore ? 1 : 0),
                              separatorBuilder: (_, __) => const Divider(
                                  height: 1,
                                  indent: 76,
                                  endIndent: 16,
                                  color: Color(AppTheme.border)),
                              itemBuilder: (_, i) {
                                if (i == _items.length) {
                                  return GestureDetector(
                                    onTap: () => _load(),
                                    behavior: HitTestBehavior.opaque,
                                    child: const Padding(
                                      padding:
                                          EdgeInsets.symmetric(vertical: 14),
                                      child: Center(
                                        child: Text('加载更多',
                                            style: TextStyle(
                                                color: Color(
                                                    AppTheme.textSecondary),
                                                fontSize: 13)),
                                      ),
                                    ),
                                  );
                                }
                                final it = _items[i];
                                return buildConvTile(it, onTap: () => _openChat(it));
                              },
                            ),
                    ),
    );
  }


  Widget _empty() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 80),
      child: Center(
        child: Column(
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: const Color(AppTheme.card),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Icon(Icons.forum_outlined,
                  size: 30, color: Color(AppTheme.textTertiary)),
            ),
            const SizedBox(height: 14),
            const Text('暂无私信',
                style: TextStyle(
                    color: Color(AppTheme.textPrimary),
                    fontSize: 15,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            const Text('与互相关注的好友开启私聊\n在对方主页点击「私信」即可发起',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: Color(AppTheme.textTertiary),
                    fontSize: 12.5,
                    height: 1.6)),
          ],
        ),
      ),
    );
  }

  Widget _loginEmpty() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.lock_outline,
              size: 48, color: Color(AppTheme.textTertiary)),
          const SizedBox(height: 12),
          const Text('登录后查看私信',
              style: TextStyle(
                  color: Color(AppTheme.textPrimary), fontSize: 15)),
          const SizedBox(height: 16),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(AppTheme.accent),
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(22)),
            ),
            onPressed: () async {
              final ok = await Navigator.of(context).push<bool>(
                  MaterialPageRoute(builder: (_) => const LoginPage()));
              if (ok == true) {
                setState(() {
                  _needLogin = false;
                  _loading = true;
                  _items = [];
                });
                _load(refresh: true);
              }
            },
            child: const Text('去登录',
                style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Widget _errorRetry() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.wifi_off_outlined,
              size: 48, color: Color(AppTheme.textTertiary)),
          const SizedBox(height: 12),
          Text(_loadError ?? '加载失败',
              style: const TextStyle(
                  color: Color(AppTheme.textSecondary), fontSize: 13)),
          const SizedBox(height: 16),
          OutlinedButton(
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(AppTheme.accent),
              side: const BorderSide(color: Color(AppTheme.accent)),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(22)),
            ),
            onPressed: () {
              setState(() {
                _loadError = null;
                _loading = true;
              });
              _load(refresh: true);
            },
            child: const Text('重新加载'),
          ),
        ],
      ),
    );
  }
}

// ==================== 公共会话项（消息页一级列表复用） ====================

/// 会话列表项：头像 + 名字 + 最后消息 + 时间 + 未读数字角标
Widget buildConvTile(Map<String, dynamic> it, {required VoidCallback onTap}) {
  final peer = (it['peer'] ?? {}) as Map<String, dynamic>;
  final name = (peer['name'] ?? '') as String;
  final avatar = (peer['avatar'] ?? '') as String;
  final lastMsg = (it['lastMsg'] ?? '') as String;
  final lastTime = ((it['lastTime'] ?? 0) as num).toInt();
  final unread = ((it['unread'] ?? 0) as num).toInt();
  return InkWell(
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 11, 16, 11),
      child: Row(
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              UserAvatar(url: avatar, name: name, size: 48),
              if (unread > 0)
                Positioned(
                  right: -4,
                  top: -4,
                  child: Container(
                    constraints:
                        const BoxConstraints(minWidth: 18, minHeight: 18),
                    padding: const EdgeInsets.symmetric(horizontal: 5),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: const Color(0xFFFF4D4F),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Text(
                      unread > 99 ? '99+' : '$unread',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Color(AppTheme.textPrimary),
                              fontSize: 15,
                              fontWeight: FontWeight.w600)),
                    ),
                    Text(timeAgo(lastTime),
                        style: const TextStyle(
                            color: Color(AppTheme.textTertiary),
                            fontSize: 11)),
                  ],
                ),
                const SizedBox(height: 5),
                Text(
                  lastMsg,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: unread > 0
                        ? const Color(AppTheme.textPrimary)
                        : const Color(AppTheme.textSecondary),
                    fontSize: 13,
                    fontWeight:
                        unread > 0 ? FontWeight.w500 : FontWeight.normal,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
