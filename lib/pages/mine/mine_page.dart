/// 我的页：登录互通 + 等级/装扮展示（占位入口）
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../api/client.dart';
import '../../config.dart';
import 'login_page.dart';

class MinePage extends StatefulWidget {
  const MinePage({super.key});

  @override
  State<MinePage> createState() => _MinePageState();
}

class _MinePageState extends State<MinePage> {
  Map<String, dynamic>? _me;
  String? _name;
  String? _avatar;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final sp = await SharedPreferences.getInstance();
    final tok = sp.getString('community_token') ?? '';
    if (tok.isNotEmpty) {
      ApiClient.token = tok;
      try {
        final j = await ApiClient.myProfile();
        if (!mounted) return;
        setState(() {
          _me = j;
          _name = (j['name'] ?? '') as String;
          _avatar = (j['avatar'] ?? '') as String;
          _loading = false;
        });
        return;
      } catch (_) {
        ApiClient.token = null;
        await sp.remove('community_token');
      }
    }
    if (!mounted) return;
    setState(() => _loading = false);
  }

  Future<void> _goLogin() async {
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const LoginPage()),
    );
    if (ok == true) {
      await _init();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(AppTheme.bg),
      body: SafeArea(
        child: _loading
            ? const Center(
                child: CircularProgressIndicator(color: Color(AppTheme.accent)))
            : ApiClient.token == null
                ? _buildLoggedOut()
                : _buildLoggedIn(),
      ),
    );
  }

  Widget _buildLoggedOut() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.person_outline, size: 64, color: Color(0xFF3A3A46)),
          const SizedBox(height: 12),
          const Text('登录后同步流萤音乐账号',
              style: TextStyle(
                  color: Color(AppTheme.textSecondary), fontSize: 14)),
          const SizedBox(height: 24),
          GestureDetector(
            onTap: _goLogin,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 44, vertical: 12),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(AppTheme.gradStart), Color(AppTheme.gradEnd)],
                ),
                borderRadius: BorderRadius.circular(24),
              ),
              child: const Text('登录 / 注册',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w600)),
            ),
          ),
          const SizedBox(height: 12),
          Text('未注册账号请先在流萤音乐 App 注册',
              style: TextStyle(
                  color: Colors.white.withOpacity(0.4), fontSize: 11)),
        ],
      ),
    );
  }

  Widget _buildLoggedIn() {
    final adminLevel = (_me?['adminLevel'] ?? 0) as int;
    final title = (_me?['title'] ?? '') as String;
    final verified = (_me?['verified'] ?? false) as bool;
    final verifiedLabel = (_me?['verifiedLabel'] ?? '') as String;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // 头部：头像 + 昵称 + 认证
        Row(
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                    color: const Color(AppTheme.accent), width: 2),
              ),
              child: ClipOval(
                child: (_avatar ?? '').isNotEmpty
                    ? CachedNetworkImage(
                        imageUrl: _avatar!,
                        fit: BoxFit.cover,
                        errorWidget: (_, __, ___) => const Icon(
                            Icons.person,
                            color: Color(AppTheme.textSecondary),
                            size: 32),
                      )
                    : const Icon(Icons.person,
                        color: Color(AppTheme.textSecondary), size: 32),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(_name ?? '用户',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 19,
                                fontWeight: FontWeight.bold)),
                      ),
                      if (verified || adminLevel > 0) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                                colors: [
                                  Color(AppTheme.gradStart),
                                  Color(AppTheme.gradEnd)
                                ]),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            verified
                                ? (verifiedLabel.isNotEmpty
                                    ? verifiedLabel
                                    : '认证')
                                : (adminLevel == 1
                                    ? '超级管理员'
                                    : '管理员'),
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (title.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(title,
                        style: const TextStyle(
                            color: Color(AppTheme.textSecondary),
                            fontSize: 12)),
                  ],
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        // 等级（占位：等级配置在后台）
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(AppTheme.card),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              const Icon(Icons.military_tech,
                  color: Color(AppTheme.accent), size: 22),
              const SizedBox(width: 10),
              Text('等级 Lv.${_me?['level'] ?? 0}',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w600)),
              const Spacer(),
              Text('经验 ${_me?['exp'] ?? 0}',
                  style: const TextStyle(
                      color: Color(AppTheme.textSecondary), fontSize: 13)),
            ],
          ),
        ),
        const SizedBox(height: 12),
        // 装扮：头像框占位
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(AppTheme.card),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              const Icon(Icons.auto_awesome,
                  color: Color(0xFFFFB84D), size: 22),
              const SizedBox(width: 10),
              const Text('个性装扮',
                  style: TextStyle(color: Colors.white, fontSize: 15)),
              const Spacer(),
              Text('头像框 · 动静态',
                  style: const TextStyle(
                      color: Color(AppTheme.textSecondary), fontSize: 12)),
              Icon(Icons.chevron_right,
                  color: Colors.white.withOpacity(0.35), size: 20),
            ],
          ),
        ),
        const SizedBox(height: 12),
        // 退出登录
        GestureDetector(
          onTap: () async {
            ApiClient.token = null;
            final sp = await SharedPreferences.getInstance();
            await sp.remove('community_token');
            if (!mounted) return;
            setState(() => _me = null);
          },
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(AppTheme.card),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Row(
              children: [
                Icon(Icons.logout, color: Color(0xFFFF4D6D), size: 22),
                SizedBox(width: 10),
                Text('退出登录',
                    style: TextStyle(color: Color(0xFFFF4D6D), fontSize: 15)),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
