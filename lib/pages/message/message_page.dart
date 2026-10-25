/// 消息页（P0）：互动通知 + 社区官方通知（与音乐官方通知完全分离）
///
/// - 互动通知：@提及、审核结果、新关注、点赞评论等（写共享 notifications 表，两边可见）
/// - 官方通知：读 community_official_messages（独立于音乐 official_messages）
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
  int _tab = 0; // 0=互动通知 1=社区官方
  List<Map<String, dynamic>> _notifs = [];
  List<Map<String, dynamic>> _official = [];
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
          _hasMore = boolOf(j['hasMore']);
          _loading = false;
          _listLoading = false;
          _loadError = null;
        });
        // 全部标记已读（fire-and-forget，失败不影响页面）
        if (refresh && list.isNotEmpty) {
          // ignore: unawaited_futures
          ApiClient.markNotificationsRead();
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
          _loadError = null;
        });
        // ignore: unawaited_futures
        ApiClient.markOfficialRead();
      }
    } catch (e) {
      if (!mounted) return;
      final is401 = e is ApiException && e.code == 401;
      setState(() {
        _loading = false;
        _listLoading = false;
        // 未登录 401：登录引导空态；其他失败：可读错误 + 重试（不误显示"暂无通知"）
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
        _notifs = [];
        _official = [];
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
                  : _needLogin
                      ? _loginEmpty()
                      : _loadError != null
                          ? _errorRetry()
                          : RefreshIndicator(
                              color: const Color(AppTheme.accent),
                              backgroundColor: const Color(AppTheme.card),
                              onRefresh: () => _load(refresh: true),
                              child: ListView(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 8),
                                children: _tab == 0
                                    ? _notifTiles()
                                    : _officialTiles(),
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
        _empty(Icons.notifications_none,
            '暂无互动通知',
            '点赞、评论、@提及、审核结果都会出现在这里'),
      ];
    }
    final List<Widget> tiles = _notifs.map(buildNotifTile).toList();
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
      return [_empty(Icons.campaign_outlined, '暂无社区官方通知',
          '官方公告、活动提醒会在这里通知你')];
    }
    return _official.map(buildOfficialTile).toList();
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

  /// 加载失败空态：可读错误 + 重试（网络/服务异常时不误显示"暂无通知"）
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
            _notifs = [];
            _official = [];
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

/// 通知类型 → 图标
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

/// 单条互动通知卡片（对任何脏数据都安全渲染）
Widget buildNotifTile(Map<String, dynamic> n) {
  final type = _strOf(n['type']);
  final title = _strOf(n['title']);
  final content = _strOf(n['content']);
  final fromName = _strOf(n['fromUserName']);
  final created = _numOf(n['created']);
  final isRead = boolOf(n['isRead']);
  final icon = _notifIcon(type);
  return Container(
    margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: const Color(AppTheme.card),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: const Color(AppTheme.accentSoft),
            borderRadius: BorderRadius.circular(11),
          ),
          child: Icon(icon, color: const Color(AppTheme.accent), size: 19),
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
}

/// 单条社区官方通知卡片（对任何脏数据都安全渲染）
Widget buildOfficialTile(Map<String, dynamic> m) {
  final content = _strOf(m['content']);
  final sender = _strOf(m['senderName']);
  final created = _numOf(m['created']);
  return Container(
    margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: const Color(AppTheme.card),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: const Color(AppTheme.sky).withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(11),
          ),
          child: const Icon(Icons.campaign_outlined,
              color: Color(AppTheme.sky), size: 19),
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
}
