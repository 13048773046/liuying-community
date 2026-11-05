/// 私信会话列表页（沉浸黑）：头像 + 名字 + 最后消息 + 时间 + 未读数字角标
/// 点击进入聊天页；下拉刷新；WS 新消息实时更新列表
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../config.dart';
import '../../design/components.dart';
import '../../models/feed_item.dart';
import '../../services/notify_bus.dart';
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

  Future<void> _goLogin() async {
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
  }

  void _retry() {
    setState(() {
      _loadError = null;
      _loading = true;
    });
    _load(refresh: true);
  }

  @override
  Widget build(BuildContext context) {
    return ImmersivePage(
      child: Column(
        children: [
          const GlassTopBar(title: '私信', solid: true),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2.2),
        ),
      );
    }
    if (_needLogin) return _loginEmpty();
    if (_loadError != null) {
      return Center(
        child: ErrorState(message: _loadError!, onRetry: _retry),
      );
    }

    final showFooter = _hasMore;
    return RefreshIndicator(
      color: const Color(AppColors.accent),
      backgroundColor: const Color(AppColors.elevated),
      onRefresh: () => _load(refresh: true),
      child: _items.isEmpty
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.only(
                  bottom: MediaQuery.paddingOf(context).bottom + AppSpace.x6),
              children: const [
                EmptyState(
                  icon: Icons.forum_outlined,
                  title: '暂无私信',
                  message: '与互相关注的好友开启私聊\n在对方主页点击「私信」即可发起',
                ),
              ],
            )
          : ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.only(
                  bottom: MediaQuery.paddingOf(context).bottom + AppSpace.x4),
              itemCount: _items.length + (showFooter ? 1 : 0),
              separatorBuilder: (_, _) => const Hairline(
                indent: AppSpace.gutter + 48 + AppSpace.x3,
              ),
              itemBuilder: (_, i) {
                if (i == _items.length) {
                  return LoadMoreFooter(
                    loading: false,
                    hasMore: true,
                    onTap: () {
                      _load();
                    },
                  );
                }
                final it = _items[i];
                return RepaintBoundary(
                  child: buildConvTile(it, onTap: () => _openChat(it)),
                );
              },
            ),
    );
  }

  Widget _loginEmpty() {
    return Center(
      child: EmptyState(
        icon: Icons.lock_outline_rounded,
        title: '登录后查看私信',
        message: '与互相关注的好友的会话会出现在这里',
        actionLabel: '去登录',
        onAction: _goLogin,
      ),
    );
  }
}

// ==================== 公共会话项（消息页一级列表复用） ====================

/// 会话列表项：头像（未读角标）+ 名字/最后消息 + 时间 + 未读点
Widget buildConvTile(Map<String, dynamic> it, {required VoidCallback onTap}) {
  final peer = (it['peer'] ?? {}) as Map<String, dynamic>;
  final name = (peer['name'] ?? '') as String;
  final avatar = (peer['avatar'] ?? '') as String;
  final lastMsg = (it['lastMsg'] ?? '') as String;
  final lastTime = ((it['lastTime'] ?? 0) as num).toInt();
  final unread = ((it['unread'] ?? 0) as num).toInt();

  return ListRow(
    onTap: onTap,
    showChevron: false,
    padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.gutter, vertical: AppSpace.x3),
    leading: Stack(
      clipBehavior: Clip.none,
      children: [
        AppAvatar(url: avatarUrl(avatar), name: name, size: 48),
        if (unread > 0)
          Positioned(
            right: -4,
            top: -4,
            child: CountBadge(count: unread),
          ),
      ],
    ),
    title: name.isEmpty ? '用户' : name,
    subtitle: lastMsg.isEmpty ? '还没有消息' : lastMsg,
    trailing: Padding(
      padding: const EdgeInsets.only(left: AppSpace.x2),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(timeAgo(lastTime), style: AppType.micro),
          if (unread > 0) ...[
            const SizedBox(height: AppSpace.x1),
            Container(
              width: 6,
              height: 6,
              decoration: const BoxDecoration(
                color: Color(AppColors.heart),
                shape: BoxShape.circle,
              ),
            ),
          ],
        ],
      ),
    ),
  );
}
