/// 消息页（二级架构）：一级列表 = 互动通知 / 官方通知 / 私信 三个入口
///
/// - 一级列表项：类型图标 + 标题 + 副标题 + 右侧未读数字角标
/// - 互动通知 → 二级列表页（/notifications，已隔离 community_%）
/// - 官方通知 → 聊天框页（只读气泡，对齐音乐项目官方通知界面）
/// - 私信     → 会话列表页 → 聊天页（WS 实时收发，仅互关可发）
/// - 未读角标：NotificationsUnread + DM 未读，WS hello/notification/dm 实时驱动
library;

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../config.dart';
import '../../services/notify_bus.dart';
import '../mine/login_page.dart';
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
  int _dmUnread = 0;

  @override
  void initState() {
    super.initState();
    _load();
    // WS 实时驱动未读
    NotifyBus.shared.unread.addListener(_onNotifyUnread);
    NotifyBus.shared.dmUnread.addListener(_onDmUnread);
  }

  @override
  void dispose() {
    NotifyBus.shared.unread.removeListener(_onNotifyUnread);
    NotifyBus.shared.dmUnread.removeListener(_onDmUnread);
    super.dispose();
  }

  void _onNotifyUnread() {
    if (!mounted) return;
    // 通知未读含互动 + 官方，这里用接口分项数据（WS 只给总数时做兜底）
    setState(() {});
  }

  void _onDmUnread() {
    if (!mounted) return;
    setState(() => _dmUnread = NotifyBus.shared.currentDmUnread);
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
    try {
      final d = await ApiClient.dmUnread();
      if (mounted) {
        setState(() {
          _dmUnread = (d['unread'] ?? 0) as int;
        });
        NotifyBus.shared.dmUnread.value = _dmUnread;
      }
    } catch (_) {}
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(AppTheme.bg),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Text('消息',
                  style: TextStyle(
                      color: Color(AppTheme.textPrimary),
                      fontSize: 22,
                      fontWeight: FontWeight.bold)),
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
                              onRefresh: _load,
                              child: ListView(
                                padding: EdgeInsets.only(
                                    bottom:
                                        16 + MediaQuery.paddingOf(context).bottom),
                                children: [
                                  _entry(
                                    icon: Icons.favorite_outline_rounded,
                                    color: const Color(AppTheme.heart),
                                    title: '互动通知',
                                    subtitle: '点赞、评论、@提及、新增关注',
                                    unread: _interactUnread,
                                    onTap: () => _open(() => const NotifListPage()),
                                  ),
                                  _divider(),
                                  _entry(
                                    icon: Icons.campaign_outlined,
                                    color: const Color(AppTheme.sky),
                                    title: '官方通知',
                                    subtitle: '官方公告与活动提醒',
                                    unread: _officialUnread,
                                    onTap: () => _open(
                                        () => const OfficialMessagesPage()),
                                  ),
                                  _divider(),
                                  _entry(
                                    icon: Icons.forum_outlined,
                                    color: const Color(AppTheme.accent),
                                    title: '私信',
                                    subtitle: '互相关注的好友消息',
                                    unread: _dmUnread,
                                    onTap: () => _open(
                                        () => const DmConversationsPage()),
                                  ),
                                ],
                              ),
                            ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _open(Widget Function() page) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => page()),
    );
    if (mounted) _load();
  }

  Widget _divider() => const Divider(
      height: 1, indent: 68, endIndent: 16, color: Color(AppTheme.border));

  Widget _entry({
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    required int unread,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 13, 16, 13),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.13),
                borderRadius: BorderRadius.circular(13),
              ),
              child: Icon(icon, color: color, size: 21),
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          color: Color(AppTheme.textPrimary),
                          fontSize: 15,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 3),
                  Text(subtitle,
                      style: const TextStyle(
                          color: Color(AppTheme.textTertiary),
                          fontSize: 12)),
                ],
              ),
            ),
            if (unread > 0)
              Container(
                constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
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
              )
            else
              const Icon(Icons.chevron_right_rounded,
                  color: Color(AppTheme.textTertiary), size: 20),
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

  Widget _loginEmpty() {
    return _empty(
      Icons.lock_outline,
      '登录后查看消息',
      '互动通知、官方通知、私信\n登录后才会出现',
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
        onPressed: _load,
        child: const Text('重新加载',
            style: TextStyle(fontWeight: FontWeight.bold)),
      ),
    );
  }
}
