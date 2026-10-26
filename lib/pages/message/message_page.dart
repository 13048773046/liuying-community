/// 消息页：互动通知 + 社区官方通知 合并成单一消息流（小红书/抖音式）
///
/// - 所有通知按时间倒序混排，左侧类型图标（点赞/评论/关注/@提及/审核/官方）
/// - 未读项标题高亮 + 图标右上角红点；已读项整体淡化
/// - 空态 / 未登录引导 / 失败重试 三态完整
library;

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../config.dart';
import '../../models/feed_item.dart';
import '../mine/login_page.dart';

class MessagePage extends StatefulWidget {
  const MessagePage({super.key});

  @override
  State<MessagePage> createState() => _MessagePageState();
}

class _MessagePageState extends State<MessagePage> {
  /// 合并后的消息流（每项带 '_src': 'notif' | 'official'）
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;
  bool _hasMore = false;
  int _page = 0;
  bool _listLoading = false;
  bool _needLogin = false; // 401 时引导登录
  String? _loadError; // 网络/服务异常时的可读错误（显示重试按钮）

  @override
  void initState() {
    super.initState();
    _load(refresh: true);
  }

  Future<void> _load({bool refresh = false}) async {
    if (_listLoading || (!_hasMore && !refresh)) return;
    setState(() => _listLoading = true);
    List<Map<String, dynamic>> notif = [];
    List<Map<String, dynamic>> official = [];
    String? err;
    var authFail = false;
    // 互动通知：支持分页
    try {
      final j = await ApiClient.notifications(
          page: refresh ? 1 : _page + 1, size: 20);
      notif = ((j['list'] ?? []) as List)
          .whereType<Map<String, dynamic>>()
          .toList();
      _hasMore = boolOf(j['hasMore']);
    } on ApiException catch (e) {
      if (e.code == 401) {
        authFail = true;
      } else {
        err = e.message;
      }
    } catch (_) {
      err = '网络异常，请检查网络后重试';
    }
    // 社区官方：一次全量
    try {
      final j = await ApiClient.officialMessages();
      official = ((j['list'] ?? []) as List)
          .whereType<Map<String, dynamic>>()
          .toList();
    } on ApiException catch (e) {
      if (e.code == 401) authFail = true;
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _listLoading = false;
      if (authFail) {
        _needLogin = true;
        _loadError = null;
        _items = [];
        _loading = false;
        return;
      }
      final merged = <Map<String, dynamic>>[
        ...notif.map((n) => {...n, '_src': 'notif'}),
        ...official.map((m) => {...m, '_src': 'official'}),
      ];
      merged.sort(
          (a, b) => _numOf(b['created']).compareTo(_numOf(a['created'])));
      if (refresh) {
        _items = merged;
        _page = 1;
      } else {
        _items.addAll(merged);
        _page++;
      }
      _loading = false;
      // 任一源失败且本次没有任何数据 → 显示错误态；否则静默（另一源仍展示）
      _loadError = (err != null && merged.isEmpty) ? err : null;
    });
    if (refresh) {
      // 拉到即标记已读（失败静默，不影响页面展示）
      try {
        await ApiClient.markNotificationsRead();
      } catch (_) {}
      try {
        await ApiClient.markOfficialRead();
      } catch (_) {}
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
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Row(
                children: [
                  const Text('消息',
                      style: TextStyle(
                          color: Color(AppTheme.textPrimary),
                          fontSize: 22,
                          fontWeight: FontWeight.bold)),
                  const Spacer(),
                  const Text('音乐官方通知请在音乐 App 内查看',
                      style: TextStyle(
                          color: Color(AppTheme.textTertiary),
                          fontSize: 11)),
                ],
              ),
            ),
            Expanded(
              child: _loading
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
                                        _empty(
                                            Icons.notifications_none,
                                            '暂无消息',
                                            '点赞、评论、@提及、新增关注、官方公告\n都会出现在这里'),
                                      ],
                                    )
                                  : ListView.separated(
                                      padding:
                                          const EdgeInsets.only(bottom: 16),
                                      itemCount:
                                          _items.length + (_hasMore ? 1 : 0),
                                      separatorBuilder: (_, __) => const Divider(
                                          height: 1,
                                          indent: 68,
                                          endIndent: 16,
                                          color: Color(AppTheme.border)),
                                      itemBuilder: (_, i) {
                                        if (i == _items.length) {
                                          return GestureDetector(
                                            onTap: _load,
                                            behavior:
                                                HitTestBehavior.opaque,
                                            child: const Padding(
                                              padding: EdgeInsets.symmetric(
                                                  vertical: 14),
                                              child: Center(
                                                child: Text('加载更多',
                                                    style: TextStyle(
                                                        color: Color(
                                                            AppTheme
                                                                .textSecondary),
                                                        fontSize: 13)),
                                              ),
                                            ),
                                          );
                                        }
                                        final it = _items[i];
                                        return it['_src'] == 'official'
                                            ? buildOfficialTile(it)
                                            : buildNotifTile(it);
                                      },
                                    ),
                            ),
            ),
          ],
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
            if (action != null) ...[
              const SizedBox(height: 18),
              action,
            ],
          ],
        ),
      ),
    );
  }

  /// 未登录引导空态
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

  /// 加载失败空态：可读错误 + 重试
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

// ==================== 顶层 tile 构建（公开，供渲染回归测试直接驱动） ====================

/// 容错字符串化：null/数字/布尔/嵌套结构一律安全转字符串，杜绝类型强转崩溃
String _strOf(dynamic v) => v == null ? '' : v.toString();

/// 容错时间戳：支持 int/double/数字字符串，解析失败归 0
int _numOf(dynamic v) {
  if (v is num) return v.toInt();
  if (v is String) {
    final s = v.trim();
    if (s.isEmpty) return 0;
    return int.tryParse(s) ?? double.tryParse(s)?.toInt() ?? 0;
  }
  return 0;
}

/// 通知类型 → 图标 + 主题色（小红书式彩色图标底）
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

/// 单条互动通知（小红书式：无卡片容器，分隔线列表；未读红点 + 标题高亮）
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
        // 左侧类型图标（右上角未读红点）
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
}

/// 单条社区官方通知（同风格：蓝色官方图标 + 时间）
Widget buildOfficialTile(Map<String, dynamic> m) {
  final content = _strOf(m['content']);
  final sender = _strOf(m['senderName']);
  final created = _numOf(m['created']);
  final isRead = boolOf(m['isRead'] ?? true);
  const color = Color(AppTheme.sky);
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
              child: const Icon(Icons.campaign_outlined,
                  color: color, size: 20),
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
                    child: Text(sender.isEmpty ? '流萤社区官方' : sender,
                        style: const TextStyle(
                            color: Color(AppTheme.textPrimary),
                            fontSize: 14.5,
                            fontWeight: FontWeight.w600)),
                  ),
                  Text(timeAgo(created),
                      style: const TextStyle(
                          color: Color(AppTheme.textTertiary),
                          fontSize: 11)),
                ],
              ),
              const SizedBox(height: 4),
              Text(content,
                  style: const TextStyle(
                      color: Color(AppTheme.textSecondary),
                      fontSize: 13,
                      height: 1.4)),
            ],
          ),
        ),
      ],
    ),
  );
}
