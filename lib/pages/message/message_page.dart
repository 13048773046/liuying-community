/// 消息页（沉浸黑）：通知入口 + 私信会话平铺
///
/// - 顶部两个入口项：互动通知 / 官方通知（未读数字角标）
///   - 互动通知 → 二级列表页（/notifications，已隔离 community_%）
///   - 官方通知 → 聊天框页（只读气泡，对齐音乐项目官方通知界面）
/// - 私信：不设入口页，最近会话直接平铺在消息页（微信式），点会话进聊天框
/// - 未读角标：NotificationsUnread + 会话项自身 unread，WS 实时驱动
library;

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../config.dart';
import '../../design/components.dart';
import '../../models/feed_item.dart';
import '../../services/notify_bus.dart';
import '../mine/login_page.dart';
import 'dm_chat_page.dart';
import 'dm_conversations_page.dart';
import 'notif_list_page.dart';
import 'official_messages_page.dart';

class MessagePage extends StatefulWidget {
  const MessagePage({super.key});

  @override
  State<MessagePage> createState() => _MessagePageState();
}

class _MessagePageState extends State<MessagePage> {
  bool _loading = true;
  bool _needLogin = false;
  String? _loadError;

  int _interactUnread = 0;
  int _officialUnread = 0;

  /// 分组：0 = 全部（通知入口 + 私信） / 1 = 只看私信
  int _seg = 0;

  /// 私信会话（直接平铺在一级列表）
  List<Map<String, dynamic>> _dmConvs = [];
  bool _dmLoading = false;
  bool _dmHasMore = false;
  int _dmPage = 0;
  String? _dmError;

  @override
  void initState() {
    super.initState();
    _load();
    // WS 实时驱动未读 / 会话
    NotifyBus.shared.unread.addListener(_onNotifyUnread);
    NotifyBus.shared.dmUnread.addListener(_onDmUnread);
    NotifyBus.shared.onDm.stream.listen((_) {
      if (mounted) _loadDm(refresh: true);
    });
  }

  @override
  void dispose() {
    NotifyBus.shared.unread.removeListener(_onNotifyUnread);
    NotifyBus.shared.dmUnread.removeListener(_onDmUnread);
    super.dispose();
  }

  void _onNotifyUnread() {
    if (!mounted) return;
    setState(() {});
  }

  void _onDmUnread() {
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    String? err;
    try {
      final j = await ApiClient.notificationsUnread();
      if (!mounted) return;
      setState(() {
        _interactUnread = (j['unread'] ?? 0) as int;
        _officialUnread = (j['officialUnread'] ?? 0) as int;
        _loading = false;
        _loadError = null;
        _needLogin = false;
      });
    } on ApiException catch (e) {
      if (e.code == 401) {
        setState(() {
          _needLogin = true;
          _loading = false;
        });
      } else {
        err = e.message;
      }
    } catch (_) {
      err = '网络异常，请检查网络后重试';
    }
    if (err != null && mounted) {
      setState(() {
        _loading = false;
        _loadError = err;
      });
    }
    await _loadDm(refresh: true);
  }

  Future<void> _loadDm({bool refresh = false}) async {
    if (_dmLoading || (!_dmHasMore && !refresh)) return;
    setState(() => _dmLoading = true);
    try {
      final j = await ApiClient.dmConversations(
          page: refresh ? 1 : _dmPage + 1, size: 20);
      final list = ((j['list'] ?? []) as List)
          .whereType<Map<String, dynamic>>()
          .toList();
      if (!mounted) return;
      setState(() {
        if (refresh) {
          _dmConvs = list;
          _dmPage = 1;
        } else {
          _dmConvs.addAll(list);
          _dmPage++;
        }
        _dmHasMore = boolOf(j['hasMore']);
        _dmLoading = false;
        _dmError = null;
      });
      // 同步全局私信未读
      final d = await ApiClient.dmUnread();
      if (mounted) {
        setState(() {});
        NotifyBus.shared.dmUnread.value = (d['unread'] ?? 0) as int;
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _dmLoading = false;
        _dmError = e is ApiException ? e.message : '网络异常，请检查网络后重试';
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
    if (mounted) _loadDm(refresh: true);
  }

  Future<void> _goLogin() async {
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const LoginPage()),
    );
    if (ok == true && mounted) {
      setState(() {
        _needLogin = false;
        _loadError = null;
      });
      _load();
    }
  }

  Future<void> _open(Widget Function() page) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => page()),
    );
    if (mounted) _load();
  }

  void _switchSeg(int i) {
    if (_seg == i) return;
    setState(() => _seg = i);
  }

  // ------------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    return ImmersivePage(
      child: SafeArea(
        // 底部导航栏避让由 RootPage 统一处理，这里只避让顶部状态栏
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(),
            FeedTabs(
              labels: const ['全部', '私信'],
              index: _seg,
              onChanged: _switchSeg,
            ),
            Expanded(child: _body()),
          ],
        ),
      ),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpace.gutter, AppSpace.x3, AppSpace.gutter, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          const Text('消息', style: AppType.h1),
          const SizedBox(width: AppSpace.x2),
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.x1),
            child: Text('互动 · 官方 · 私信', style: AppType.micro),
          ),
          const Spacer(),
          IconCircleButton(
            icon: Icons.sync_rounded,
            size: 34,
            iconSize: 17,
            background: const Color(AppColors.canvas),
            onTap: () {
              _load();
            },
          ),
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
        child: ErrorState(
          message: _loadError!,
          onRetry: () {
            _load();
          },
        ),
      );
    }
    return RefreshIndicator(
      color: const Color(AppColors.accent),
      backgroundColor: const Color(AppColors.elevated),
      onRefresh: _load,
      child: ListView(
        physics:
            const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
        padding: EdgeInsets.only(
            bottom: tabBarBottomInset(context) + AppSpace.x6),
        children: _rows(),
      ),
    );
  }

  List<Widget> _rows() {
    return [
      if (_seg == 0) ...[
        _entry(
          icon: Icons.favorite_rounded,
          color: const Color(AppColors.heart),
          title: '互动通知',
          subtitle: '点赞、评论、@提及、新增关注',
          unread: _interactUnread,
          onTap: () => _open(() => const NotifListPage()),
        ),
        const Hairline(indent: AppSpace.gutter + 44 + AppSpace.x3),
        _entry(
          icon: Icons.campaign_rounded,
          color: const Color(AppColors.info),
          title: '官方通知',
          subtitle: '官方公告与活动提醒',
          unread: _officialUnread,
          onTap: () => _open(() => const OfficialMessagesPage()),
        ),
        const Hairline(indent: AppSpace.gutter + 44 + AppSpace.x3),
      ],
      const SectionHeader(
        title: '私信',
        padding: EdgeInsets.fromLTRB(
            AppSpace.gutter, AppSpace.x5, AppSpace.gutter, AppSpace.x2),
      ),
      ..._dmRows(),
    ];
  }

  Widget _entry({
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    required int unread,
    required VoidCallback onTap,
  }) {
    return ListRow(
      leading: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: AppRadius.rMd,
        ),
        child: Icon(icon, color: color, size: 21),
      ),
      title: title,
      subtitle: subtitle,
      showChevron: false,
      onTap: onTap,
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpace.gutter, vertical: AppSpace.x3),
      trailing: unread > 0
          ? CountBadge(count: unread)
          : const Icon(Icons.chevron_right_rounded,
              size: 20, color: Color(AppColors.textTertiary)),
    );
  }

  List<Widget> _dmRows() {
    if (_dmError != null && _dmConvs.isEmpty) {
      return [
        ErrorState(
          message: _dmError!,
          onRetry: () {
            _loadDm(refresh: true);
          },
        ),
      ];
    }
    if (_dmLoading && _dmConvs.isEmpty) {
      return const [
        Padding(
          padding: EdgeInsets.symmetric(vertical: AppSpace.x7),
          child: Center(
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
      ];
    }
    if (_dmConvs.isEmpty) {
      return const [
        EmptyState(
          compact: true,
          icon: Icons.forum_outlined,
          title: '暂无私信',
          message: '与互相关注的好友开启私聊，在对方主页点击「私信」即可发起',
        ),
      ];
    }
    return [
      for (final it in _dmConvs) ...[
        RepaintBoundary(child: buildConvTile(it, onTap: () => _openChat(it))),
        const Hairline(indent: AppSpace.gutter + 48 + AppSpace.x3),
      ],
      if (_dmHasMore || _dmLoading)
        LoadMoreFooter(
          loading: _dmLoading,
          hasMore: _dmHasMore,
          onTap: () {
            _loadDm();
          },
        ),
    ];
  }

  Widget _loginEmpty() {
    return Center(
      child: EmptyState(
        icon: Icons.lock_outline_rounded,
        title: '登录后查看消息',
        message: '互动通知、官方通知、私信\n登录后才会出现',
        actionLabel: '去登录',
        onAction: _goLogin,
      ),
    );
  }
}
