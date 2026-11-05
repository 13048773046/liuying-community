/// 互动通知二级列表页（沉浸黑）：点赞/评论/@提及/新增关注/审核结果
/// 单列表 + 类型图标 + 未读红点 + 相对时间 + 空态/登录引导/失败重试
library;

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../design/components.dart';
import '../../models/feed_item.dart';
import '../../services/notify_bus.dart';
import '../mine/login_page.dart';

class NotifListPage extends StatefulWidget {
  const NotifListPage({super.key});

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

  @override
  void initState() {
    super.initState();
    _load(refresh: true);
  }

  Future<void> _load({bool refresh = false}) async {
    if (_listLoading || (!_hasMore && !refresh)) return;
    setState(() => _listLoading = true);
    try {
      final j = await ApiClient.notifications(
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
        _listLoading = false;
        _loadError = null;
      });
      if (refresh) {
        try {
          await ApiClient.markNotificationsRead();
          if (!mounted) return;
          setState(() {
            for (final it in _items) {
              it['isRead'] = 1;
            }
          });
          // 本地清零未读，立刻消掉导航栏红点（不必等下一帧 WS 推送）
          NotifyBus.shared.clearUnread();
        } catch (_) {}
      }
    } catch (e) {
      if (!mounted) return;
      final is401 = e is ApiException && e.code == 401;
      setState(() {
        _loading = false;
        _listLoading = false;
        _needLogin = is401;
        _loadError =
            is401 ? null : (e is ApiException ? e.message : '网络异常，请检查网络后重试');
      });
    }
  }

  Future<void> _goLogin() async {
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const LoginPage()),
    );
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

  /// 左滑删除单条通知：先本地移除（乐观更新），失败再插回原位并提示
  Future<void> _deleteNotif(String id) async {
    final idx = _items.indexWhere((e) => _strOf(e['id']) == id);
    if (idx < 0) return;
    final removed = _items[idx];
    setState(() {
      _items.removeAt(idx);
    });
    try {
      await ApiClient.deleteNotification(id);
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
            const Icon(Icons.delete_outline_rounded,
                size: 18, color: Color(AppColors.onAccent)),
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
          const GlassTopBar(title: '互动通知', solid: true),
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
      child: _items.isEmpty
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.only(
                  bottom: MediaQuery.paddingOf(context).bottom + AppSpace.x6),
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
                  bottom: MediaQuery.paddingOf(context).bottom + AppSpace.x4),
              itemCount: _items.length + (showFooter ? 1 : 0),
              separatorBuilder: (_, _) => const Hairline(
                indent: AppSpace.gutter + 40 + AppSpace.x3,
              ),
              itemBuilder: (_, i) {
                if (i == _items.length) {
                  return LoadMoreFooter(
                    loading: _listLoading,
                    hasMore: _hasMore,
                    onTap: () {
                      _load();
                    },
                  );
                }
                final item = _items[i];
                final id = _strOf(item['id']);
                return RepaintBoundary(
                  child: Dismissible(
                    key: ValueKey(id.isEmpty ? 'notif-$i' : 'notif-$id'),
                    direction: id.isEmpty
                        ? DismissDirection.none
                        : DismissDirection.endToStart,
                    background: _deleteBackground(),
                    onDismissed: (_) => _deleteNotif(id),
                    child: buildNotifTile(item),
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
  if (t.contains('follow')) {
    return (Icons.person_add_alt, const Color(AppColors.accent));
  }
  if (t.contains('mention')) {
    return (Icons.alternate_email, const Color(AppColors.lilac));
  }
  if (t.contains('audit')) {
    return (Icons.fact_check_outlined, const Color(AppColors.warning));
  }
  if (t.contains('interact')) {
    return (Icons.favorite_outline, const Color(AppColors.heart));
  }
  return (Icons.notifications_none, const Color(AppColors.textSecondary));
}

/// 单条互动通知（沉浸黑列表行：头像/类型图标 + 未读点 + 标题/摘要 + 相对时间）
Widget buildNotifTile(Map<String, dynamic> n) {
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
          name: fromName,
          size: 40,
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
    padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.gutter, vertical: AppSpace.x3),
    leading: Stack(
      clipBehavior: Clip.none,
      children: [
        leading,
        if (!isRead)
          Positioned(
            right: -2,
            top: -2,
            child: Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(
                color: const Color(AppColors.heart),
                shape: BoxShape.circle,
                border: Border.all(color: const Color(AppColors.bg), width: 1.5),
              ),
            ),
          ),
      ],
    ),
    title: title.isEmpty ? '通知' : title,
    subtitle: fromName.isEmpty ? content : '$fromName：$content',
    trailing: Padding(
      padding: const EdgeInsets.only(left: AppSpace.x2),
      child: Text(timeAgo(created), style: AppType.micro),
    ),
  );
}
