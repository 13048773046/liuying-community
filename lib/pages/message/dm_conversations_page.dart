/// 私信会话列表页（沉浸黑）：头像 + 名字 + 最后消息 + 时间 + 未读数字角标
/// 点击进入聊天页；下拉刷新；WS 新消息实时更新列表
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../features/message/data/message_repository.dart';
import '../../config.dart';
import '../../design/components.dart';
import '../../features/emoji/text_emoji.dart';
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
  final Set<String> _seenDmIds = <String>{};
  bool _chatOpening = false;

  @override
  void initState() {
    super.initState();
    _load(refresh: true);
    // 新私信实时本地置顶/更新，不整表重载
    _dmSub = NotifyBus.shared.onDm.stream.listen(_onDmEvent);
  }

  @override
  void dispose() {
    _dmSub?.cancel();
    super.dispose();
  }

  void _onDmEvent(Map<String, dynamic> dm) {
    if (!mounted) return;
    final mid = (dm['id'] ?? '').toString();
    if (mid.isNotEmpty && !_seenDmIds.add(mid)) return;
    final convId = (dm['convId'] ?? '').toString();
    if (convId.isEmpty) return;
    final from = dm['from'] is Map
        ? Map<String, dynamic>.from(dm['from'] as Map)
        : <String, dynamic>{};
    final preview = (dm['preview'] ?? dm['content'] ?? '').toString();
    final mtype = (dm['msgType'] ?? 'text').toString();
    final created = (dm['created'] as num?)?.toDouble() ?? 0;
    final convUnread = intOf(dm['convUnread']);
    setState(() {
      final idx = _items.indexWhere((e) => (e['id'] ?? '') == convId);
      Map<String, dynamic> item;
      if (idx >= 0) {
        item = _items.removeAt(idx);
        item['lastMsg'] = preview;
        item['lastType'] = mtype;
        item['lastTime'] = created;
        item['unread'] = convUnread;
      } else {
        item = {
          'id': convId,
          'peer': {
            'id': (from['id'] ?? '').toString(),
            'name': (from['name'] ?? '').toString(),
            'avatar': (from['avatar'] ?? '').toString(),
            'title': '',
            'verified': '',
            'verifiedLabel': '',
            'isAi': false,
            'frameId': '',
          },
          'lastMsg': preview,
          'lastType': mtype,
          'lastTime': created,
          'unread': convUnread,
        };
      }
      _items = [item, ..._items];
      _loading = false;
      _loadError = null;
    });
    final total = _items.fold<int>(0, (sum, it) => sum + intOf(it['unread']));
    NotifyBus.shared.setDmUnread(total);
  }

  Future<void> _load({bool refresh = false}) async {
    if (!refresh && !_hasMore) return;
    setState(() => _loading = refresh);
    try {
      final j = await MessageRepository.instance.dmConversations(
        page: refresh ? 1 : _page + 1,
        size: 20,
      );
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
      final total = _items.fold<int>(0, (sum, it) => sum + intOf(it['unread']));
      NotifyBus.shared.setDmUnread(total);
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

  int get _unreadCount =>
      _items.fold<int>(0, (sum, it) => sum + intOf(it['unread']));

  Future<void> _markAllRead() async {
    if (_unreadCount <= 0) return;
    var allOk = false;
    try {
      await MessageRepository.instance.dmReadAll();
      allOk = true;
    } catch (_) {}
    if (!allOk) {
      for (final it in _items) {
        if (intOf(it['unread']) <= 0) continue;
        final peer = (it['peer'] ?? {}) as Map<String, dynamic>;
        final peerId = (peer['id'] ?? '') as String;
        if (peerId.isEmpty) continue;
        try {
          await MessageRepository.instance.dmRead(peerId);
        } catch (_) {}
      }
    }
    if (!mounted) return;
    setState(() {
      for (final it in _items) {
        it['unread'] = 0;
      }
    });
    NotifyBus.shared.clearDmUnread();
    showAppToast(context, '全部私信已标为已读');
  }

  Future<void> _openChat(Map<String, dynamic> it) async {
    if (_chatOpening) return;
    final peer = (it['peer'] ?? {}) as Map<String, dynamic>;
    _chatOpening = true;
    try {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => DmChatPage(
            peerId: (peer['id'] ?? '') as String,
            peerName: (peer['name'] ?? '') as String,
            peerAvatar: (peer['avatar'] ?? '') as String,
            peerFrameId: (peer['frameId'] ?? '') as String,
            peerVerified:
                verifiedOf(peer['verified']) ||
                (peer['verifiedLabel'] ?? '').toString().trim().isNotEmpty,
            peerVerifiedLabel: (peer['verifiedLabel'] ?? '').toString(),
            peerIsAi:
                boolOf(peer['isAi']) ||
                (peer['verifiedLabel'] ?? '').toString().trim().toUpperCase() ==
                    'AI',
          ),
        ),
      );
    } finally {
      _chatOpening = false;
    }
    if (mounted) _load(refresh: true);
  }

  Future<void> _goLogin() async {
    final ok = await Navigator.of(context)
        .push<bool>(MaterialPageRoute(builder: (_) => const LoginPage()));
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
          GlassTopBar(
            title: '私信',
            solid: true,
            actions: [
              if (_unreadCount > 0)
                TextButton(
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(AppColors.textSecondary),
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    minimumSize: const Size(0, 32),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: _markAllRead,
                  child: Text(
                    '全部已读',
                    style: AppType.caption.copyWith(
                      color: const Color(AppColors.textSecondary),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
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
                bottom: MediaQuery.paddingOf(context).bottom + AppSpace.x6,
              ),
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
                bottom: MediaQuery.paddingOf(context).bottom + AppSpace.x4,
              ),
              itemCount: _items.length + (showFooter ? 1 : 0),
              separatorBuilder: (_, _) =>
                  const Hairline(indent: AppSpace.gutter + 48 + AppSpace.x3),
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
                  child: KeyedSubtree(
                    key: ValueKey('dm-conv-${it['id']}'),
                    child: buildConvTile(it, onTap: () => _openChat(it)),
                  ),
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
  final hasUnread = unread > 0;

  return ListRow(
    onTap: onTap,
    showChevron: false,
    padding: const EdgeInsets.symmetric(
      horizontal: AppSpace.gutter,
      vertical: AppSpace.x3,
    ),
    leading: Stack(
      clipBehavior: Clip.none,
      children: [
        AppAvatar(
          url: avatar.isEmpty
              ? avatarUrlOf((peer['id'] ?? '') as String)
              : avatarUrl(avatar),
          name: name,
          size: 48,
          verified:
              verifiedOf(peer['verified']) ||
              (peer['verifiedLabel'] ?? '').toString().trim().isNotEmpty,
          isAi:
              boolOf(peer['isAi']) ||
              (peer['verifiedLabel'] ?? '').toString().trim().toUpperCase() ==
                  'AI',
          frameUrl: frameUrlOf((peer['frameId'] ?? '') as String),
        ),
        if (unread > 0)
          Positioned(
            right: -5,
            top: -5,
            child: CountBadge(count: unread, large: true),
          ),
      ],
    ),
    title: name.isEmpty ? '用户' : name,
    titleStyle: AppType.body.copyWith(
      fontWeight: hasUnread ? FontWeight.w600 : FontWeight.w400,
      color: const Color(AppColors.textPrimary),
    ),
    subtitle: lastMsg.isEmpty ? '还没有消息' : lastMsg,
    subtitleWidget: lastMsg.isEmpty
        ? null
        : TextEmojiText(
            lastMsg,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppType.caption.copyWith(
              color: hasUnread
                  ? const Color(AppColors.textSecondary)
                  : const Color(AppColors.textTertiary),
              fontWeight: hasUnread ? FontWeight.w500 : FontWeight.w400,
            ),
          ),
    subtitleStyle: AppType.caption.copyWith(
      color: hasUnread
          ? const Color(AppColors.textSecondary)
          : const Color(AppColors.textTertiary),
      fontWeight: hasUnread ? FontWeight.w500 : FontWeight.w400,
    ),
    trailing: Padding(
      padding: const EdgeInsets.only(left: AppSpace.x2),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            timeAgo(lastTime),
            style: AppType.micro.copyWith(
              color: hasUnread
                  ? const Color(AppColors.textSecondary)
                  : const Color(AppColors.textTertiary),
              fontWeight: hasUnread ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            hasUnread ? '未读' : (lastMsg.isEmpty ? '尚无消息' : '已读'),
            style: AppType.micro.copyWith(
              fontSize: 10,
              height: 1.1,
              color: hasUnread
                  ? const Color(AppColors.heart)
                  : const Color(AppColors.textTertiary),
              fontWeight: hasUnread ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
        ],
      ),
    ),
  );
}
