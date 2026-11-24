/// 消息页（沉浸黑）：通知入口 + 私信会话平铺
///
/// - 顶部两个入口项：互动通知 / 官方通知（未读数字角标）
///   - 互动通知 → 二级列表页（/notifications，已隔离 community_%）
///   - 官方通知 → 聊天框页（只读气泡，对齐音乐项目官方通知界面）
/// - 私信：不设入口页，最近会话直接平铺在消息页（微信式），点会话进聊天框
/// - 未读角标：NotificationsUnread + 会话项自身 unread，WS 实时驱动
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../features/message/data/message_repository.dart';
import '../../config.dart';
import '../../design/components.dart';
import '../../models/feed_item.dart';
import '../../services/notify_bus.dart';
import '../mine/login_page.dart';
import 'dm_chat_page.dart';
import 'dm_conversations_page.dart';
import 'notif_list_page.dart';
import '../search/search_page.dart';
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
  int _dmUnread = 0;

  /// 互动通知按类型拆分（like/comment/follow/audit），用于二级入口角标。
  Map<String, int> _byType = const {};

  /// 分组：0 = 全部（通知入口 + 私信） / 1 = 只看私信
  int _seg = 0;

  /// 私信会话（直接平铺在一级列表）
  List<Map<String, dynamic>> _dmConvs = [];
  bool _dmLoading = false;
  bool _dmHasMore = false;
  int _dmPage = 0;
  String? _dmError;
  StreamSubscription? _dmSub;
  StreamSubscription? _notifSub;
  final Set<String> _seenDmIds = <String>{};
  bool _chatOpening = false;

  @override
  void initState() {
    super.initState();
    _dmUnread = NotifyBus.shared.currentDmUnread;
    _load();
    // WS 实时驱动未读 / 会话
    NotifyBus.shared.unread.addListener(_onNotifyUnread);
    NotifyBus.shared.officialUnread.addListener(_onNotifyUnread);
    NotifyBus.shared.dmUnread.addListener(_onDmUnread);
    _dmSub = NotifyBus.shared.onDm.stream.listen(_onDmEvent);
    _notifSub = NotifyBus.shared.onNotification.stream.listen(_onNotification);
  }

  @override
  void dispose() {
    NotifyBus.shared.unread.removeListener(_onNotifyUnread);
    NotifyBus.shared.officialUnread.removeListener(_onNotifyUnread);
    NotifyBus.shared.dmUnread.removeListener(_onDmUnread);
    _dmSub?.cancel();
    _notifSub?.cancel();
    super.dispose();
  }

  void _onNotifyUnread() {
    if (!mounted) return;
    setState(() {
      _interactUnread = NotifyBus.shared.currentUnread;
      _officialUnread = NotifyBus.shared.currentOfficialUnread;
    });
  }

  /// WS 新通知：除总线上的总未读外，还要同步二级分类角标。
  /// 不重新拉整页，避免消息页在实时事件里闪骨架。
  void _onNotification(Map<String, dynamic> n) {
    if (!mounted) return;
    final type = (n['type'] ?? '').toString().toLowerCase();
    String? group;
    if (type.contains('like')) {
      group = 'like';
    } else if (type.contains('comment') ||
        type.contains('reply') ||
        type.contains('mention')) {
      group = 'comment';
    } else if (type.contains('follow') || type.contains('interact')) {
      group = 'follow';
    } else if (type.contains('audit')) {
      group = 'audit';
    }
    setState(() {
      _interactUnread = NotifyBus.shared.currentUnread;
      if (group != null) {
        _byType = Map<String, int>.from(_byType);
        _byType[group] = (_byType[group] ?? 0) + 1;
      }
    });
  }

  void _onDmUnread() {
    if (!mounted) return;
    setState(() => _dmUnread = NotifyBus.shared.currentDmUnread);
  }

  /// WS 新私信：直接本地置顶/更新会话，不重拉整表、不闪加载态。
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
      final idx = _dmConvs.indexWhere((e) => (e['id'] ?? '') == convId);
      Map<String, dynamic> item;
      if (idx >= 0) {
        item = _dmConvs.removeAt(idx);
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
      _dmConvs = [item, ..._dmConvs];
      _dmLoading = false;
      _dmError = null;
    });
  }

  int _typeUnread(String type) => _byType[type] ?? 0;

  int get _totalUnread => _interactUnread + _officialUnread + _dmUnread;

  Future<void> _load() async {
    setState(() => _loading = true);
    String? err;
    try {
      final j = await MessageRepository.instance.notificationsUnread();
      if (!mounted) return;
      final raw = (j['byType'] as Map?) ?? const {};
      final by = <String, int>{
        'like': intOf(raw['like']),
        'comment': intOf(raw['comment']),
        'follow': intOf(raw['follow']),
        'audit': intOf(raw['audit']),
        'other': intOf(raw['other']),
      };
      final interact = intOf(j['unread']);
      final official = intOf(j['officialUnread']);
      NotifyBus.shared.setUnread(interact);
      NotifyBus.shared.setOfficialUnread(official);
      setState(() {
        _interactUnread = interact;
        _officialUnread = official;
        _byType = by;
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
      final j = await MessageRepository.instance.dmConversations(
        page: refresh ? 1 : _dmPage + 1,
        size: 20,
      );
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
      // 同步全局私信未读（也用于底部导航合计角标）
      final d = await MessageRepository.instance.dmUnread();
      if (mounted) {
        final n = intOf(d['unread'] ?? d['count']);
        setState(() => _dmUnread = n);
        NotifyBus.shared.setDmUnread(n);
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
    if (mounted) {
      await _loadDm(refresh: true);
      if (mounted) await _load();
    }
  }

  Future<void> _goLogin() async {
    final ok = await Navigator.of(context)
        .push<bool>(MaterialPageRoute(builder: (_) => const LoginPage()));
    if (ok == true && mounted) {
      setState(() {
        _needLogin = false;
        _loadError = null;
      });
      _load();
    }
  }

  Future<void> _open(Widget Function() page) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => page()));
    if (mounted) _load();
  }

  /// 一键已读：互动通知 + 官方通知 + 所有私信会话（服务端逐会话清零）。
  Future<void> _markAllRead() async {
    if (_totalUnread <= 0) {
      showAppToast(context, '暂无未读消息');
      return;
    }
    try {
      await MessageRepository.instance.markNotificationsRead();
    } catch (_) {}
    try {
      await MessageRepository.instance.markOfficialRead();
    } catch (_) {}
    var dmAllOk = false;
    try {
      await MessageRepository.instance.dmReadAll();
      dmAllOk = true;
    } catch (_) {}
    if (!dmAllOk) {
      // 兼容旧服务端：至少把当前已加载的会话逐个清零
      for (final it in _dmConvs) {
        final unread = intOf(it['unread']);
        if (unread <= 0) continue;
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
      _interactUnread = 0;
      _officialUnread = 0;
      _dmUnread = 0;
      _byType = const {};
      for (final it in _dmConvs) {
        it['unread'] = 0;
      }
    });
    NotifyBus.shared.clearUnread();
    NotifyBus.shared.clearDmUnread();
    NotifyBus.shared.clearOfficialUnread();
    showAppToast(context, '全部消息已标为已读');
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
              labels: const ['私信', '互动'],
              index: _seg,
              onChanged: _switchSeg,
              badges: [_dmUnread, _interactUnread],
              onTrailing: _totalUnread > 0
                  ? Padding(
                      padding: const EdgeInsets.only(right: 6, bottom: 2),
                      child: Text(
                        '$_totalUnread 条未读',
                        style: AppType.micro.copyWith(fontSize: 11.5),
                      ),
                    )
                  : null,
            ),
            Expanded(child: _body()),
          ],
        ),
      ),
    );
  }

  Widget _header() {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 320 窄屏：隐藏副标题，保证「全部已读 + 搜索 + 同步」仍可点。
        final compact = constraints.maxWidth < 360;
        return Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpace.gutter,
            AppSpace.x3,
            AppSpace.gutter,
            0,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              const Text('消息', style: AppType.h1),
              if (!compact) ...[
                const SizedBox(width: AppSpace.x2),
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpace.x1),
                  child: Text('私信 · 互动 · 官方', style: AppType.micro),
                ),
              ],
              const Spacer(),
              if (_totalUnread > 0)
                PressableScale(
                  onTap: _markAllRead,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 10, bottom: 4),
                    child: Text(
                      '全部已读',
                      style: AppType.caption.copyWith(
                        color: const Color(AppColors.textSecondary),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              IconCircleButton(
                icon: Icons.search_rounded,
                size: 34,
                iconSize: 17,
                background: Colors.white.withValues(alpha: 0.06),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const SearchPage()),
                ),
              ),
              const SizedBox(width: AppSpace.x2),
              IconCircleButton(
                icon: Icons.sync_rounded,
                size: 34,
                iconSize: 17,
                background: Colors.white.withValues(alpha: 0.06),
                onTap: () {
                  _load();
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _skeleton() => const MessageListSkeleton();

  Widget _body() {
    if (_loading) return _skeleton();
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
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        padding: EdgeInsets.only(
          bottom: tabBarBottomInset(context) + AppSpace.x6,
        ),
        children: _rows(),
      ),
    );
  }

  List<Widget> _rows() {
    // 一级：私信 —— 会话直接平铺
    if (_seg == 0) return _dmRows();
    // 一级：互动 —— 四个二级分类，点进去看对应流水
    return [
      SectionHeader(
        title: _interactUnread > 0 ? '$_interactUnread 条未读互动' : '最近互动',
        padding: const EdgeInsets.fromLTRB(
          AppSpace.gutter,
          AppSpace.x4,
          AppSpace.gutter,
          AppSpace.x2,
        ),
      ),
      _entry(
        icon: Icons.favorite_rounded,
        color: const Color(AppColors.heart),
        title: '赞与收藏',
        subtitle: '赞过、收藏过你的内容',
        unread: _typeUnread('like'),
        onTap: () => _open(() => const NotifListPage(kind: 'like')),
      ),
      const Hairline(indent: AppSpace.gutter + 44 + AppSpace.x3),
      _entry(
        icon: Icons.chat_bubble_rounded,
        color: const Color(AppColors.info),
        title: '评论',
        subtitle: '评论、回复与 @ 提及',
        unread: _typeUnread('comment'),
        onTap: () => _open(() => const NotifListPage(kind: 'comment')),
      ),
      const Hairline(indent: AppSpace.gutter + 44 + AppSpace.x3),
      _entry(
        icon: Icons.person_add_alt_1_rounded,
        color: const Color(AppColors.accent),
        title: '新增粉丝',
        subtitle: '最近关注你的人',
        unread: _typeUnread('follow'),
        onTap: () => _open(() => const NotifListPage(kind: 'follow')),
      ),
      const Hairline(indent: AppSpace.gutter + 44 + AppSpace.x3),
      _entry(
        icon: Icons.fact_check_outlined,
        color: const Color(AppColors.warning),
        title: '审核通知',
        subtitle: '内容审核与处理结果',
        unread: _typeUnread('audit'),
        onTap: () => _open(() => const NotifListPage(kind: 'audit')),
      ),
      const Hairline(indent: AppSpace.gutter + 44 + AppSpace.x3),
      _entry(
        icon: Icons.campaign_rounded,
        color: const Color(AppColors.lilac),
        title: '系统通知',
        subtitle: '官方公告与活动提醒',
        unread: _officialUnread,
        onTap: () => _open(() => const OfficialMessagesPage()),
      ),
      const Hairline(indent: AppSpace.gutter + 44 + AppSpace.x3),
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
        horizontal: AppSpace.gutter,
        vertical: AppSpace.x3,
      ),
      trailing: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeIn,
        child: unread > 0
            ? CountBadge(
                key: ValueKey('message-entry-badge-$title'),
                count: unread,
                large: true,
              )
            : const Icon(
                Icons.chevron_right_rounded,
                key: ValueKey('chevron'),
                size: 20,
                color: Color(AppColors.textTertiary),
              ),
      ),
    );
  }

  List<Widget> _dmRows() {
    final header = SectionHeader(
      title: _dmUnread > 0 ? '$_dmUnread 条未读私信' : '最近私信',
      padding: const EdgeInsets.fromLTRB(
        AppSpace.gutter,
        AppSpace.x4,
        AppSpace.gutter,
        AppSpace.x2,
      ),
    );
    if (_dmError != null && _dmConvs.isEmpty) {
      return [
        header,
        ErrorState(
          message: _dmError!,
          onRetry: () {
            _loadDm(refresh: true);
          },
        ),
      ];
    }
    if (_dmLoading && _dmConvs.isEmpty) {
      return [header, const MessageListSkeleton()];
    }
    if (_dmConvs.isEmpty) {
      return [
        header,
        const EmptyState(
          compact: true,
          icon: Icons.forum_outlined,
          title: '暂无私信',
          message: '与互相关注的好友开启私聊，在对方主页点击「私信」即可发起',
        ),
      ];
    }
    return [
      header,
      for (final it in _dmConvs) ...[
        RepaintBoundary(
          key: ValueKey('dm-conv-${it['id']}'),
          child: buildConvTile(it, onTap: () => _openChat(it)),
        ),
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
