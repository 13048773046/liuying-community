/// 我的页（P0）：登录互通 + 等级进度 + 签到 + 个性装扮（头像框）+ 任务
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../api/client.dart';
import '../../config.dart';
import '../../services/notify_bus.dart';
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
  Map<String, dynamic> _level = {};
  List<String> _signins = [];
  bool _signing = false;
  List<Map<String, dynamic>> _frames = [];
  String _myFrame = '';
  List<Map<String, dynamic>> _tasks = [];

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
        final user = Map<String, dynamic>.from(j['user'] as Map);
        if (!mounted) return;
        setState(() {
          _me = user;
          _name = (user['name'] ?? '') as String;
          _avatar = (user['avatar'] ?? '') as String;
          _loading = false;
        });
        await _loadExtras();
        NotifyBus.shared.connect(tok);
        return;
      } catch (_) {
        ApiClient.token = null;
        await sp.remove('community_token');
      }
    }
    if (!mounted) return;
    setState(() => _loading = false);
  }

  /// 等级 / 签到 / 装扮 / 任务并行拉取
  Future<void> _loadExtras() async {
    try {
      final lv = await ApiClient.levelMe();
      final sg = await ApiClient.signins();
      final fr = await ApiClient.frames();
      final mf = await ApiClient.myFrame();
      List<Map<String, dynamic>> tasks = [];
      try {
        final tj = await ApiClient.tasks();
        tasks = ((tj['list'] ?? []) as List)
            .whereType<Map<String, dynamic>>()
            .toList();
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _level = Map<String, dynamic>.from(lv);
        _signins = ((sg['list'] ?? []) as List).map((e) => e.toString()).toList();
        _frames = ((fr['list'] ?? []) as List)
            .whereType<Map<String, dynamic>>()
            .toList();
        _myFrame = (mf['frameId'] ?? '') as String;
        _tasks = tasks;
      });
    } catch (_) {}
  }

  Future<void> _goLogin() async {
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const LoginPage()),
    );
    if (ok == true) {
      await _init();
    }
  }

  Future<void> _signin() async {
    if (_signing) return;
    setState(() => _signing = true);
    try {
      await ApiClient.signin();
      if (!mounted) return;
      setState(() {
        _signins.add(DateTime.now().toString().split(' ')[0]);
        _signing = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('签到成功，经验+10'),
          backgroundColor: Color(AppTheme.card)));
      await _loadExtras();
    } catch (e) {
      if (!mounted) return;
      setState(() => _signing = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('$e'), backgroundColor: const Color(AppTheme.card)));
    }
  }

  Future<void> _openFrames() async {
    await showModalBottomSheet(
      context: context,
      backgroundColor: const Color(AppTheme.card),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 10),
              child: Text('个性装扮 · 头像框',
                  style: TextStyle(
                      color: Color(AppTheme.textPrimary),
                      fontSize: 16,
                      fontWeight: FontWeight.bold)),
            ),
            Flexible(
              child: GridView.builder(
                shrinkWrap: true,
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3, mainAxisSpacing: 10, crossAxisSpacing: 10),
                itemCount: _frames.length + 1,
                padding: const EdgeInsets.all(16),
                itemBuilder: (_, i) {
                  if (i == 0) {
                    return _frameCell(
                        id: '', name: '无头像框', isDefault: true);
                  }
                  final f = _frames[i - 1];
                  return _frameCell(
                      id: (f['id'] ?? '') as String,
                      name: (f['name'] ?? '') as String,
                      isDefault: false);
                },
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _frameCell({required String id, required String name, required bool isDefault}) {
    final sel = _myFrame == id;
    return GestureDetector(
      onTap: () async {
        try {
          await ApiClient.equipFrame(id);
          if (!mounted) return;
          setState(() => _myFrame = id);
          Navigator.pop(context);
        } catch (e) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text('$e'), backgroundColor: const Color(AppTheme.card)));
        }
      },
      child: Container(
        decoration: BoxDecoration(
          color: const Color(AppTheme.bg),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: sel ? const Color(AppTheme.accent) : const Color(AppTheme.border),
            width: sel ? 2 : 1,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: sel
                    ? Border.all(color: const Color(AppTheme.accent), width: 2)
                    : null,
              ),
              child: CircleAvatar(
                radius: 22,
                backgroundColor: const Color(AppTheme.card),
                child: const Icon(Icons.person, color: Color(AppTheme.textSecondary)),
              ),
            ),
            const SizedBox(height: 6),
            Text(name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: Color(AppTheme.textSecondary), fontSize: 11)),
          ],
        ),
      ),
    );
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
                : RefreshIndicator(
                    color: const Color(AppTheme.accent),
                    backgroundColor: const Color(AppTheme.card),
                    onRefresh: _loadExtras,
                    child: _buildLoggedIn(),
                  ),
      ),
    );
  }

  Widget _buildLoggedOut() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.person_outline,
              size: 64, color: Color(AppTheme.textTertiary)),
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
                color: const Color(AppTheme.accent),
                borderRadius: BorderRadius.circular(24),
              ),
              child: const Text('登录 / 注册',
                  style: TextStyle(
                      color: Colors.black,
                      fontSize: 15,
                      fontWeight: FontWeight.w600)),
            ),
          ),
          const SizedBox(height: 12),
          const Text('未注册账号请先在流萤音乐 App 注册',
              style: TextStyle(
                  color: Color(AppTheme.textTertiary), fontSize: 11)),
        ],
      ),
    );
  }

  Widget _buildLoggedIn() {
    final user = _me!;
    final title = (user['title'] ?? '') as String;
    final verified = (user['verified'] ?? false) as bool;
    final verifiedLabel = (user['verifiedLabel'] ?? '') as String;
    final adminLevel = (user['adminLevel'] ?? 0) as int;
    final level = (_level['level'] ?? user['level'] ?? 0) as int;
    final exp = (_level['exp'] ?? 0) as int;
    final progress = (_level['progress'] ?? 0.0) as num;
    final next = _level['nextThreshold'];
    final today = DateTime.now().toString().split(' ')[0];
    final signedToday = _signins.contains(today);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // 头部
        Row(
          children: [
            Container(
              width: 64,
              height: 64,
              padding: const EdgeInsets.all(1.5),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: _myFrame.isNotEmpty
                    ? Border.all(color: const Color(AppTheme.accent), width: 2)
                    : null,
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
                                color: Color(AppTheme.textPrimary),
                                fontSize: 19,
                                fontWeight: FontWeight.bold)),
                      ),
                      if (verified || adminLevel > 0) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: const Color(AppTheme.accentSoft),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                                color: const Color(AppTheme.accent), width: 0.6),
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
                                color: Color(AppTheme.accent),
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
                            color: Color(AppTheme.textSecondary), fontSize: 12)),
                  ],
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        // 等级进度
        _card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.military_tech,
                      color: Color(AppTheme.accent), size: 22),
                  const SizedBox(width: 10),
                  Text('Lv.$level',
                      style: const TextStyle(
                          color: Color(AppTheme.textPrimary),
                          fontSize: 15,
                          fontWeight: FontWeight.w600)),
                  const Spacer(),
                  Text('经验 $exp',
                      style: const TextStyle(
                          color: Color(AppTheme.textSecondary), fontSize: 13)),
                ],
              ),
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: progress.toDouble().clamp(0.0, 1.0),
                  minHeight: 6,
                  backgroundColor: const Color(AppTheme.bg),
                  color: const Color(AppTheme.accent),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                next == null
                    ? '已达最高等级'
                    : '距 Lv.${level + 1} 还需 $next 经验（发帖/评论/视频/点赞/分享可获得）',
                style: const TextStyle(
                    color: Color(AppTheme.textTertiary), fontSize: 11),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        // 签到 + 任务
        Row(
          children: [
            Expanded(
              child: _card(
                child: GestureDetector(
                  onTap: signedToday ? null : _signin,
                  child: Row(
                    children: [
                      Icon(signedToday ? Icons.check_circle : Icons.calendar_today,
                          color: signedToday
                              ? const Color(AppTheme.accent)
                              : const Color(0xFFFFB84D),
                          size: 22),
                      const SizedBox(width: 10),
                      Text(signedToday ? '今日已签到' : '每日签到',
                          style: const TextStyle(
                              color: Color(AppTheme.textPrimary), fontSize: 15)),
                      if (_signing)
                        const Padding(
                          padding: EdgeInsets.only(left: 8),
                          child: SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Color(AppTheme.accent)),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _card(
                child: GestureDetector(
                  onTap: _openFrames,
                  child: Row(
                    children: [
                      const Icon(Icons.auto_awesome,
                          color: Color(0xFFFFB84D), size: 22),
                      const SizedBox(width: 10),
                      const Text('个性装扮',
                          style: TextStyle(
                              color: Color(AppTheme.textPrimary), fontSize: 15)),
                      const Spacer(),
                      const Icon(Icons.chevron_right,
                          color: Color(AppTheme.textTertiary), size: 20),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        // 任务
        if (_tasks.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text('新手任务',
                style: TextStyle(
                    color: Color(AppTheme.textSecondary), fontSize: 13)),
          ),
          ..._tasks.map(_taskTile),
          const SizedBox(height: 12),
        ],
        // 退出登录
        GestureDetector(
          onTap: () async {
            ApiClient.token = null;
            NotifyBus.shared.disconnect();
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

  Widget _card({required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(AppTheme.card),
        borderRadius: BorderRadius.circular(14),
      ),
      child: child,
    );
  }

  Widget _taskTile(Map<String, dynamic> t) {
    final name = (t['name'] ?? '') as String;
    final desc = (t['desc'] ?? '') as String;
    final reward = (t['rewardExp'] ?? 0) as int;
    final status = (t['status'] ?? '') as String; // pending | done | claimed
    final claimed = status == 'claimed';
    final done = status == 'done';
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(AppTheme.card),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: claimed
                  ? const Color(AppTheme.accentSoft)
                  : const Color(AppTheme.bg),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              claimed ? Icons.check_circle : Icons.bolt,
              color: claimed
                  ? const Color(AppTheme.accent)
                  : const Color(0xFFFFB84D),
              size: 18,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    style: const TextStyle(
                        color: Color(AppTheme.textPrimary), fontSize: 14)),
                const SizedBox(height: 2),
                Text(desc.isEmpty ? '奖励经验 +$reward' : '$desc · +$reward 经验',
                    style: const TextStyle(
                        color: Color(AppTheme.textTertiary), fontSize: 11)),
              ],
            ),
          ),
          if (claimed)
            const Text('已领取',
                style: TextStyle(
                    color: Color(AppTheme.accent), fontSize: 12))
          else if (done)
            GestureDetector(
              onTap: () async {
                try {
                  await ApiClient.claimTask(t['id'] as String);
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text('已领取奖励'),
                      backgroundColor: Color(AppTheme.card)));
                  await _loadExtras();
                } catch (e) {
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text('$e'),
                      backgroundColor: const Color(AppTheme.card)));
                }
              },
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(AppTheme.accent),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Text('领取',
                    style: TextStyle(
                        color: Colors.black,
                        fontSize: 12,
                        fontWeight: FontWeight.bold)),
              ),
            )
          else
            const Text('未完成',
                style:
                    TextStyle(color: Color(AppTheme.textTertiary), fontSize: 12)),
        ],
      ),
    );
  }
}
