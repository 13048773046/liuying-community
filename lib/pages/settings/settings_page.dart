/// 设置页：账号信息 + 通用设置 + 关于社区 + 退出登录
library;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../api/client.dart';
import '../../config.dart';
import '../../widgets/user_avatar.dart';
import '../../services/notify_bus.dart';
import '../favorites/favorites_page.dart';
import '../feedback/feedback_page.dart';
import '../user/user_profile.dart';
import '../mine/login_page.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  Map<String, dynamic>? _me;
  bool _clearing = false;

  @override
  void initState() {
    super.initState();
    _loadMe();
  }

  Future<void> _loadMe() async {
    if (ApiClient.token == null) return;
    try {
      final j = await ApiClient.myProfile();
      if (!mounted) return;
      setState(() => _me = Map<String, dynamic>.from(j['user'] as Map));
    } catch (_) {}
  }

  Future<void> _logout() async {
    ApiClient.token = null;
    NotifyBus.shared.disconnect();
    final sp = await SharedPreferences.getInstance();
    await sp.remove('community_token');
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  Future<void> _clearCache() async {
    setState(() => _clearing = true);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (!mounted) return;
    setState(() => _clearing = false);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('缓存已清理'),
        backgroundColor: Color(AppTheme.card),
        behavior: SnackBarBehavior.floating));
  }

  void _showAbout() {
    showAboutDialog(
      context: context,
      applicationName: '流萤社区',
      applicationVersion: '1.0.0',
      applicationIcon: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
              colors: [Color(AppTheme.accent), Color(AppTheme.sky)]),
          borderRadius: BorderRadius.circular(12),
        ),
        alignment: Alignment.center,
        child: const Icon(Icons.public, color: Colors.black, size: 26),
      ),
      children: [
        const Text('流萤社区 · 与流萤音乐同一账号体系\n'
            '问题反馈请使用「意见反馈」入口，或发送邮件至 yosar027@163.com',
            style: TextStyle(
                color: Color(AppTheme.textSecondary),
                fontSize: 12,
                height: 1.6)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = _me;
    final name = (user?['name'] ?? '') as String;
    final avRaw = (user?['avatar'] ?? '') as String;
    final avatar = avRaw.isEmpty
        ? ''
        : avatarUrlOf((user?['id'] ?? '') as String);
    final email = (user?['email'] ?? '') as String;
    return Scaffold(
      backgroundColor: const Color(AppTheme.bg),
      appBar: AppBar(
        backgroundColor: const Color(AppTheme.bg),
        foregroundColor: const Color(AppTheme.textPrimary),
        elevation: 0,
        title: const Text('设置'),
        centerTitle: true,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (ApiClient.token != null) ...[
            // 账号卡
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(AppTheme.card),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  UserAvatar(url: avatar, name: name, size: 46),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(name.isEmpty ? '用户' : name,
                            style: const TextStyle(
                                color: Color(AppTheme.textPrimary),
                                fontSize: 16,
                                fontWeight: FontWeight.bold)),
                        if (email.isNotEmpty)
                          Text(email,
                              style: const TextStyle(
                                  color: Color(AppTheme.textSecondary),
                                  fontSize: 12)),
                      ],
                    ),
                  ),
                  GestureDetector(
                    onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => UserProfilePage(
                                uid: ApiClient.userId ?? ''))),
                    child: const Icon(Icons.chevron_right,
                        color: Color(AppTheme.textTertiary)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            _group('功能'),
            _tile(Icons.bookmark_border, '我的收藏', () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const FavoritesPage()))),
            _tile(Icons.feedback_outlined, '意见反馈', () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const FeedbackPage()))),
            const SizedBox(height: 12),
            _group('通用'),
            _tile(
                Icons.cleaning_services_outlined,
                _clearing ? '清理中…' : '清除缓存',
                _clearing ? null : _clearCache),
            _tile(Icons.info_outline, '关于社区', _showAbout),
            const SizedBox(height: 12),
            _group('账号'),
            _tile(Icons.logout, '退出登录', _logout, danger: true),
          ] else ...[
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: const Color(AppTheme.card),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                children: [
                  const Text('登录后查看收藏、反馈与更多功能',
                      style: TextStyle(
                          color: Color(AppTheme.textSecondary), fontSize: 13)),
                  const SizedBox(height: 14),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(AppTheme.accent),
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(22)),
                    ),
                    onPressed: () async {
                      final ok = await Navigator.of(context).push<bool>(
                        MaterialPageRoute(
                            builder: (_) => const LoginPage()),
                      );
                      if (ok == true) _loadMe();
                    },
                    child: const Text('登录 / 注册',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _group(String s) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(s,
          style: const TextStyle(
              color: Color(AppTheme.textSecondary), fontSize: 12)),
    );
  }

  Widget _tile(IconData icon, String label, VoidCallback? onTap,
      {bool danger = false}) {
    final c = danger ? const Color(0xFFFF4D6D) : const Color(AppTheme.textPrimary);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          decoration: BoxDecoration(
            color: const Color(AppTheme.card),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(icon,
                  size: 21,
                  color: danger
                      ? const Color(0xFFFF4D6D)
                      : const Color(AppTheme.accent)),
              const SizedBox(width: 12),
              Expanded(
                child: Text(label,
                    style: TextStyle(color: c, fontSize: 14.5)),
              ),
              const Icon(Icons.chevron_right,
                  color: Color(AppTheme.textTertiary), size: 18),
            ],
          ),
        ),
      ),
    );
  }
}
