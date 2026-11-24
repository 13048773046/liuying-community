/// 互动通知二级列表页（沉浸黑）：点赞/评论/@提及/新增关注/审核结果
/// 单列表 + 类型图标 + 未读红点 + 相对时间 + 空态/登录引导/失败重试
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../features/message/data/message_repository.dart';
import '../../config.dart';
import '../../design/components.dart';
import '../../design/shared_element.dart';
import '../../features/emoji/text_emoji.dart';
import '../../models/feed_item.dart';
import '../../services/notify_bus.dart';
import '../mine/login_page.dart';
import '../post/post_detail.dart';
import '../user/user_profile.dart';

class NotifListPage extends StatefulWidget {
  const NotifListPage({super.key, this.kind});

  /// 二级分类过滤：like / comment / follow；为空时显示全部互动
  final String? kind;

  @override
  State<NotifListPage> createState() => _NotifListPageState();
}

class _NotifListPageState extends State<NotifListPage> {
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;
  bool _hasMore = false;
  int _page = 0;
  bool _listLoading = false;
  bool _needLogin = false;
  String? _loadError;
  StreamSubscription? _notifSub;

  /// 按分类过滤后的可见条目（不改变原始列表，删除/恢复仍按 _items 处理）
  List<Map<String, dynamic>> get _visible {
    final k = widget.kind;
    if (k == null) return _items;
    return _items.where((n) {
      final t = _strOf(n['type']).toLowerCase();
      switch (k) {
        case 'like':
          return t.contains('like');
        case 'comment':
          return t.contains('comment') ||
              t.contains('reply') ||
              t.contains('mention');
        case 'follow':
          // 后端新增关注实际类型为 community_interact，不含 follow
          return t.contains('follow') || t.contains('interact');
        case 'audit':
          return t.contains('audit');
        default:
          return true;
      }
    }).toList();
  }

  @override
  void initState() {
    super.initState();
    _notifSub = NotifyBus.shared.onNotification.stream.listen(_onNotification);
    _load(refresh: true);
  }

  @override
  void dispose() {
    _notifSub?.cancel();
    super.dispose();
  }

  bool _eventMatches(Map<String, dynamic> n) {
    final k = widget.kind;
    if (k == null) return true;
    final t = _strOf(n['type']).toLowerCase();
    switch (k) {
      case 'like':
        return t.contains('like');
      case 'comment':
        return t.contains('comment') ||
            t.contains('reply') ||
            t.contains('mention');
      case 'follow':
        return t.contains('follow') || t.contains('interact');
      case 'audit':
        return t.contains('audit');
      default:
        return true;
    }
  }

  /// WS 新互动通知：页面打开时直接插到顶部，无需刷新/重进。
  void _onNotification(Map<String, dynamic> n) {
    if (!mounted || !_eventMatches(n)) return;
    final id = _strOf(n['id']);
    if (id.isNotEmpty && _items.any((e) => _strOf(e['id']) == id)) return;
    setState(() {
      _items = [n, ..._items];
      _loading = false;
      _loadError = null;
    });
  }

  Future<void> _load({bool refresh = false}) async {
    if (_listLoading || (!_hasMore && !refresh)) return;
    setState(() => _listLoading = true);
    try {
      final j = await MessageRepository.instance.notifications(
        group: widget.kind ?? '',
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
        _listLoading = false;
        _loadError = null;
      });
      // 进入列表不再自动全部已读：保留未读/已读差异，由用户点单条或「全部已读」。
    } catch (e) {
      if (!mounted) return;
      final is401 = e is ApiException && e.code == 401;
      setState(() {
        _loading = false;
        _listLoading = false;
        _needLogin = is401;
        _loadError = is401
            ? null
            : (e is ApiException ? e.message : '网络异常，请检查网络后重试');
      });
    }
  }

  Future<void> _goLogin() async {
    final ok = await Navigator.of(context)
        .push<bool>(MaterialPageRoute(builder: (_) => const LoginPage()));
    if (ok == true) {
      if (!mounted) return;
      setState(() {
        _needLogin = false;
        _loadError = null;
        _items = [];
        _hasMore = false;
        _loading = true;
        _page = 0;
      });
      _load(refresh: true);
    }
  }

  void _retry() {
    setState(() {
      _loadError = null;
      _loading = true;
      _items = [];
      _hasMore = false;
      _page = 0;
    });
    _load(refresh: true);
  }

  String? get _groupForKind {
    switch (widget.kind) {
      case 'like':
        return 'like';
      case 'comment':
        return 'comment';
      case 'follow':
        return 'follow';
      case 'audit':
        return 'audit';
      default:
        return null;
    }
  }

  int get _unreadCount => _visible.where((n) => !boolOf(n['isRead'])).length;

  /// 从服务端重新取互动总未读，精确同步底部导航与消息页入口。
  Future<void> _refreshGlobalUnread() async {
    try {
      final j = await MessageRepository.instance.notificationsUnread();
      NotifyBus.shared.setUnread(intOf(j['unread']));
    } catch (_) {}
  }

  Future<void> _markAllRead() async {
    if (_unreadCount <= 0) return;
    try {
      await MessageRepository.instance.markNotificationsRead(
        group: _groupForKind,
      );
    } catch (_) {
      if (!mounted) return;
      showAppToast(context, '操作失败，请重试');
      return;
    }
    if (!mounted) return;
    setState(() {
      for (final it in _visible) {
        it['isRead'] = 1;
      }
    });
    await _refreshGlobalUnread();
    if (mounted) showAppToast(context, '已全部标为已读');
  }

  /// 点击通知：先标已读，再按目标回流到帖子 / 评论 / 对方主页。
  /// 旧实现只标已读，已读通知点下去完全无反应。
  Future<void> _openNotification(Map<String, dynamic> item) async {
    await _readOne(item);
    if (!mounted) return;
    final postId = _strOf(item['postId']).trim();
    final fromUid = _strOf(item['fromUserId']).trim();
    if (postId.isNotEmpty) {
      await Navigator.of(context)
          .push(AppPageRoute(builder: (_) => PostDetailPage(postId: postId)));
      return;
    }
    if (fromUid.isNotEmpty) {
      await Navigator.of(context)
          .push(AppPageRoute(builder: (_) => UserProfilePage(uid: fromUid)));
    }
  }

  /// 点击单条未读通知即标已读（已读通知不重复请求）。
  Future<void> _readOne(Map<String, dynamic> item) async {
    if (boolOf(item['isRead'])) return;
    final id = _strOf(item['id']);
    if (id.isEmpty) return;
    try {
      await MessageRepository.instance.markNotificationsRead(id: id);
    } catch (_) {
      if (!mounted) return;
      showAppToast(context, '标记已读失败，请重试');
      return;
    }
    if (!mounted) return;
    setState(() => item['isRead'] = 1);
    await _refreshGlobalUnread();
  }

  /// 左滑删除单条通知：先本地移除（乐观更新），失败再插回原位并提示
  Future<void> _deleteNotif(String id) async {
    final idx = _items.indexWhere((e) => _strOf(e['id']) == id);
    if (idx < 0) return;
    final removed = _items[idx];
    setState(() {
      _items.removeAt(idx);
    });
    final wasUnread = !boolOf(removed['isRead']);
    try {
      await MessageRepository.instance.deleteNotification(id);
      if (wasUnread) await _refreshGlobalUnread();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        final at = idx > _items.length ? _items.length : idx;
        _items.insert(at, removed);
      });
      showAppToast(context, '删除失败，请重试');
    }
  }

  /// 左滑删除背景：红色圆角「删除」胶囊
  Widget _deleteBackground() {
    return Container(
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.only(right: AppSpace.gutter),
      child: Container(
        width: 60,
        height: 56,
        decoration: BoxDecoration(
          color: const Color(AppColors.danger),
          borderRadius: AppRadius.rMd,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.delete_outline_rounded,
              size: 18,
              color: Color(AppColors.onAccent),
            ),
            const SizedBox(height: 2),
            Text(
              '删除',
              style: AppType.micro.copyWith(
                color: const Color(AppColors.onAccent),
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ImmersivePage(
      child: Column(
        children: [
          GlassTopBar(
            title: switch (widget.kind) {
              'like' => '赞与收藏',
              'comment' => '评论',
              'follow' => '新增粉丝',
              'audit' => '审核通知',
              _ => '互动通知',
            },
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

    final showFooter = _hasMore || _listLoading;
    return RefreshIndicator(
      color: const Color(AppColors.accent),
      backgroundColor: const Color(AppColors.elevated),
      onRefresh: () => _load(refresh: true),
      child: _visible.isEmpty
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.only(
                bottom: MediaQuery.paddingOf(context).bottom + AppSpace.x6,
              ),
              children: const [
                EmptyState(
                  icon: Icons.notifications_none_rounded,
                  title: '暂无互动通知',
                  message: '点赞、评论、@提及、新增关注、审核结果\n都会出现在这里',
                ),
              ],
            )
          : ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.only(
                bottom: MediaQuery.paddingOf(context).bottom + AppSpace.x4,
              ),
              itemCount: _visible.length + (showFooter ? 1 : 0),
              separatorBuilder: (_, _) =>
                  const Hairline(indent: AppSpace.gutter + 40 + AppSpace.x3),
              itemBuilder: (_, i) {
                if (i == _visible.length) {
                  return LoadMoreFooter(
                    loading: _listLoading,
                    hasMore: _hasMore,
                    onTap: () {
                      _load();
                    },
                  );
                }
                final item = _visible[i];
                final id = _strOf(item['id']);
                return RepaintBoundary(
                  child: Dismissible(
                    key: ValueKey(id.isEmpty ? 'notif-$i' : 'notif-$id'),
                    direction: id.isEmpty
                        ? DismissDirection.none
                        : DismissDirection.endToStart,
                    background: _deleteBackground(),
                    onDismissed: (_) => _deleteNotif(id),
                    child: _buildNotifTile(
                      item,
                      onTap: () => _openNotification(item),
                    ),
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
        title: '登录后查看消息',
        message: '点赞、评论、@提及、审核结果\n登录后才会出现在这里',
        actionLabel: '去登录',
        onAction: _goLogin,
      ),
    );
  }
}

// ==================== 顶层 tile（与消息页共用，供渲染回归测试驱动） ====================

String _strOf(dynamic v) => v == null ? '' : v.toString();

int _numOf(dynamic v) {
  if (v is num) return v.toInt();
  if (v is String) {
    final s = v.trim();
    if (s.isEmpty) return 0;
    return int.tryParse(s) ?? double.tryParse(s)?.toInt() ?? 0;
  }
  return 0;
}

(IconData, Color) _notifStyle(String type) {
  final t = type.toLowerCase();
  if (t.contains('like')) {
    return (Icons.favorite_rounded, const Color(AppColors.heart));
  }
  if (t.contains('comment') || t.contains('reply')) {
    return (Icons.chat_bubble_rounded, const Color(AppColors.info));
  }
  if (t.contains('follow') || t.contains('interact')) {
    return (Icons.person_add_alt, const Color(AppColors.accent));
  }
  if (t.contains('mention')) {
    return (Icons.alternate_email, const Color(AppColors.lilac));
  }
  if (t.contains('audit')) {
    return (Icons.fact_check_outlined, const Color(AppColors.warning));
  }
  if (t.contains('app') || t.contains('member')) {
    return (Icons.verified_user_outlined, const Color(AppColors.info));
  }
  return (Icons.notifications_none, const Color(AppColors.textSecondary));
}

/// 单条互动通知（沉浸黑列表行：头像/类型图标 + 未读点 + 标题/摘要 + 相对时间）
Widget buildNotifTile(Map<String, dynamic> n) => _buildNotifTile(n);

Widget _buildNotifTile(Map<String, dynamic> n, {VoidCallback? onTap}) {
  final type = _strOf(n['type']);
  final title = _strOf(n['title']);
  final content = _strOf(n['content']);
  final fromName = _strOf(n['fromUserName']);
  final created = _numOf(n['created']);
  final isRead = boolOf(n['isRead']);
  final (icon, color) = _notifStyle(type);

  // 有发送者 → 头像（右下角带类型角标）；系统通知 → 类型图标
  final Widget leading = fromName.isEmpty
      ? Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.14),
            borderRadius: AppRadius.rSm,
          ),
          child: Icon(icon, color: color, size: 20),
        )
      : AppAvatar(
          url: _strOf(n['fromAvatar']).isEmpty
              ? avatarUrlOf(_strOf(n['fromUserId']))
              : avatarUrl(_strOf(n['fromAvatar'])),
          name: fromName,
          size: 40,
          verified:
              verifiedOf(n['fromVerified']) ||
              _strOf(n['fromVerifiedLabel']).trim().isNotEmpty,
          isAi:
              boolOf(n['fromIsAi']) ||
              _strOf(n['fromVerifiedLabel']).trim().toUpperCase() == 'AI',
          frameUrl: frameUrlOf(_strOf(n['fromFrameId'])),
          badge: Container(
            width: 18,
            height: 18,
            decoration: const BoxDecoration(
              color: Color(AppColors.bg),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: color, size: 11),
          ),
        );

  return ListRow(
    showChevron: false,
    onTap: onTap,
    padding: const EdgeInsets.symmetric(
      horizontal: AppSpace.gutter,
      vertical: AppSpace.x3,
    ),
    leading: Stack(
      clipBehavior: Clip.none,
      children: [
        leading,
        if (!isRead)
          Positioned(
            right: -3,
            top: -3,
            child: Container(
              width: 11,
              height: 11,
              decoration: BoxDecoration(
                color: const Color(AppColors.heart),
                shape: BoxShape.circle,
                border: Border.all(color: const Color(AppColors.bg), width: 2),
              ),
            ),
          ),
      ],
    ),
    title: title.isEmpty ? '通知' : title,
    titleStyle: AppType.body.copyWith(
      fontWeight: isRead ? FontWeight.w400 : FontWeight.w600,
      color: isRead
          ? const Color(AppColors.textSecondary)
          : const Color(AppColors.textPrimary),
    ),
    subtitle: fromName.isEmpty ? content : '$fromName：$content',
    subtitleWidget: TextEmojiText(
      fromName.isEmpty ? content : '$fromName：$content',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: AppType.caption.copyWith(
        color: isRead
            ? const Color(AppColors.textTertiary)
            : const Color(AppColors.textSecondary),
        fontWeight: isRead ? FontWeight.w400 : FontWeight.w500,
      ),
    ),
    trailing: Padding(
      padding: const EdgeInsets.only(left: AppSpace.x2),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(timeAgo(created), style: AppType.micro),
          const SizedBox(height: 2),
          Text(
            isRead ? '已读' : '未读',
            style: AppType.micro.copyWith(
              fontSize: 10,
              height: 1.1,
              color: isRead
                  ? const Color(AppColors.textTertiary)
                  : const Color(AppColors.heart),
              fontWeight: isRead ? FontWeight.w500 : FontWeight.w600,
            ),
          ),
        ],
      ),
    ),
  );
}
