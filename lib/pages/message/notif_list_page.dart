/// 互动通知二级列表页：点赞/评论/@提及/新增关注/审核结果（仅社区互动通知）
/// 单列表 + 类型图标 + 未读红点 + 相对时间 + 空态/登录引导/失败重试
library;

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../config.dart';
import '../../models/feed_item.dart';
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(AppTheme.bg),
      appBar: AppBar(
        backgroundColor: const Color(AppTheme.bg),
        elevation: 0,
        centerTitle: true,
        title: const Text('互动通知',
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
                              children: [
                                _empty(Icons.notifications_none, '暂无互动通知',
                                    '点赞、评论、@提及、新增关注、审核结果\n都会出现在这里'),
                              ],
                            )
                          : ListView.separated(
                              padding: EdgeInsets.only(
                                  bottom: 16 +
                                      MediaQuery.paddingOf(context).bottom),
                              itemCount: _items.length + (_hasMore ? 1 : 0),
                              separatorBuilder: (_, __) => const Divider(
                                  height: 1,
                                  indent: 68,
                                  endIndent: 16,
                                  color: Color(AppTheme.border)),
                              itemBuilder: (_, i) {
                                if (i == _items.length) {
                                  return GestureDetector(
                                    onTap: _load,
                                    behavior: HitTestBehavior.opaque,
                                    child: const Padding(
                                      padding: EdgeInsets.symmetric(vertical: 14),
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
                                return buildNotifTile(_items[i]);
                              },
                            ),
                    ),
    );
  }

  Widget _empty(IconData icon, String title, String subtitle,
      {Widget? action}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 60),
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
              child: Icon(icon,
                  size: 30, color: const Color(AppTheme.textTertiary)),
            ),
            const SizedBox(height: 14),
            Text(title,
                style: const TextStyle(
                    color: Color(AppTheme.textPrimary),
                    fontSize: 15,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(subtitle,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: Color(AppTheme.textTertiary),
                    fontSize: 12.5,
                    height: 1.6)),
            if (action != null) ...[const SizedBox(height: 18), action],
          ],
        ),
      ),
    );
  }

  Widget _loginEmpty() {
    return _empty(
      Icons.lock_outline,
      '登录后查看消息',
      '点赞、评论、@提及、审核结果\n登录后才会出现在这里',
      action: FilledButton(
        style: FilledButton.styleFrom(
          backgroundColor: const Color(AppTheme.accent),
          foregroundColor: Colors.black,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 10),
        ),
        onPressed: _goLogin,
        child: const Text('去登录',
            style: TextStyle(fontWeight: FontWeight.bold)),
      ),
    );
  }

  Widget _errorRetry() {
    return _empty(
      Icons.wifi_off_outlined,
      '加载失败',
      _loadError ?? '请检查网络后重试',
      action: OutlinedButton(
        style: OutlinedButton.styleFrom(
          foregroundColor: const Color(AppTheme.accent),
          side: const BorderSide(color: Color(AppTheme.accent)),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 10),
        ),
        onPressed: () {
          setState(() {
            _loadError = null;
            _loading = true;
            _items = [];
            _hasMore = false;
            _page = 0;
          });
          _load(refresh: true);
        },
        child: const Text('重新加载',
            style: TextStyle(fontWeight: FontWeight.bold)),
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
    return (Icons.favorite_rounded, const Color(AppTheme.heart));
  }
  if (t.contains('comment') || t.contains('reply')) {
    return (Icons.chat_bubble_rounded, const Color(AppTheme.sky));
  }
  if (t.contains('follow')) {
    return (Icons.person_add_alt, const Color(AppTheme.accent));
  }
  if (t.contains('mention')) {
    return (Icons.alternate_email, const Color(AppTheme.lilac));
  }
  if (t.contains('audit')) {
    return (Icons.fact_check_outlined, const Color(0xFFFFB84D));
  }
  if (t.contains('interact')) {
    return (Icons.favorite_outline, const Color(AppTheme.heart));
  }
  return (Icons.notifications_none, const Color(AppTheme.textSecondary));
}

/// 单条互动通知（小红书式：分隔线列表；未读红点 + 标题高亮）
Widget buildNotifTile(Map<String, dynamic> n) {
  final type = _strOf(n['type']);
  final title = _strOf(n['title']);
  final content = _strOf(n['content']);
  final fromName = _strOf(n['fromUserName']);
  final created = _numOf(n['created']);
  final isRead = boolOf(n['isRead']);
  final (icon, color) = _notifStyle(type);
  return Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Stack(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.13),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: color, size: 20),
            ),
            if (!isRead)
              Positioned(
                right: -1,
                top: -1,
                child: Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(
                    color: const Color(0xFFFF4D4F),
                    shape: BoxShape.circle,
                    border: Border.all(color: const Color(AppTheme.bg)),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(width: 12),
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
                          fontSize: 14.5,
                          fontWeight:
                              isRead ? FontWeight.normal : FontWeight.w600,
                        )),
                  ),
                  Text(timeAgo(created),
                      style: const TextStyle(
                          color: Color(AppTheme.textTertiary), fontSize: 11)),
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
}
