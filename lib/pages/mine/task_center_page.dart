/// 任务中心（独立任务入口，替代原帖子区内嵌任务卡）
/// 聚合：发帖赢好礼活动 + 每日签到 + 后端 /tasks 任务列表
library;

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../config.dart';
import '../post/post_editor.dart';

class TaskCenterPage extends StatefulWidget {
  const TaskCenterPage({super.key});

  @override
  State<TaskCenterPage> createState() => _TaskCenterPageState();
}

class _TaskCenterPageState extends State<TaskCenterPage> {
  List<Map<String, dynamic>> _tasks = [];
  List<String> _signins = [];
  bool _loading = true;
  bool _signing = false;
  String _claiming = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (ApiClient.token == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      final tj = await ApiClient.tasks();
      final sj = await ApiClient.signins();
      if (!mounted) return;
      setState(() {
        _tasks = ((tj['list'] ?? []) as List)
            .whereType<Map<String, dynamic>>()
            .toList();
        _signins = ((sj['list'] ?? []) as List)
            .whereType<String>()
            .toList();
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  bool get _signedToday => _signins.contains(DateTime.now().toString().split(' ')[0]);

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
          content: Text('签到成功，经验 +10'),
          backgroundColor: Color(AppTheme.card),
          behavior: SnackBarBehavior.floating));
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _signing = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('$e'),
          backgroundColor: const Color(AppTheme.card),
          behavior: SnackBarBehavior.floating));
    }
  }

  Future<void> _claim(String id) async {
    if (_claiming.isNotEmpty) return;
    setState(() => _claiming = id);
    try {
      await ApiClient.claimTask(id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('已领取奖励'),
          backgroundColor: Color(AppTheme.card),
          behavior: SnackBarBehavior.floating));
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('$e'),
          backgroundColor: const Color(AppTheme.card),
          behavior: SnackBarBehavior.floating));
    } finally {
      if (mounted) setState(() => _claiming = '');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(AppTheme.bg),
      appBar: AppBar(
        backgroundColor: const Color(AppTheme.bg),
        foregroundColor: const Color(AppTheme.textPrimary),
        elevation: 0,
        title: const Text('任务中心',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(
                  color: Color(AppTheme.accent), strokeWidth: 2.5))
          : ApiClient.token == null
              ? _notLogin()
              : RefreshIndicator(
                  color: const Color(AppTheme.accent),
                  backgroundColor: const Color(AppTheme.card),
                  onRefresh: _load,
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                    children: [
                      _campaignCard(),
                      const SizedBox(height: 14),
                      _signinCard(),
                      if (_tasks.isNotEmpty) ...[
                        const SizedBox(height: 20),
                        const Text('更多任务',
                            style: TextStyle(
                                color: Color(AppTheme.textPrimary),
                                fontSize: 15,
                                fontWeight: FontWeight.w600)),
                        const SizedBox(height: 10),
                        for (final t in _tasks) _taskTile(t),
                      ],
                    ],
                  ),
                ),
    );
  }

  Widget _notLogin() {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        const SizedBox(height: 120),
        const Icon(Icons.lock_outline,
            size: 52, color: Color(AppTheme.textTertiary)),
        const SizedBox(height: 10),
        const Center(
          child: Text('登录后可参与任务、领取奖励',
              style: TextStyle(
                  color: Color(AppTheme.textSecondary), fontSize: 13.5)),
        ),
      ],
    );
  }

  /// 发帖赢好礼活动头卡
  Widget _campaignCard() {
    return GestureDetector(
      onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => const PostEditorPage(mode: 'text'))),
      child: Container(
        height: 96,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [Color(0xFF1E3A31), Color(0xFF14221E)],
          ),
          borderRadius: BorderRadius.circular(AppTheme.radiusCard),
          border: Border.all(
              color: const Color(AppTheme.accent).withValues(alpha: 0.25)),
        ),
        child: Row(
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: const Color(AppTheme.accent).withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(13),
              ),
              child: const Icon(Icons.emoji_events_outlined,
                  color: Color(AppTheme.accent), size: 26),
            ),
            const SizedBox(width: 13),
            const Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('发帖赢好礼',
                      style: TextStyle(
                          color: Color(AppTheme.textPrimary),
                          fontSize: 15,
                          fontWeight: FontWeight.w600)),
                  SizedBox(height: 4),
                  Text('发布 1 篇内容，赢取限定装扮',
                      style: TextStyle(
                          color: Color(AppTheme.textSecondary),
                          fontSize: 12)),
                ],
              ),
            ),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 15, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(AppTheme.accent),
                borderRadius: BorderRadius.circular(AppTheme.radiusPill),
              ),
              child: const Text('去参与',
                  style: TextStyle(
                      color: Colors.black,
                      fontSize: 13,
                      fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }

  /// 每日签到卡
  Widget _signinCard() {
    final done = _signedToday;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(AppTheme.card),
        borderRadius: BorderRadius.circular(AppTheme.radiusCard),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: done
                  ? const Color(AppTheme.accentSoft)
                  : const Color(AppTheme.bg),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(
              done ? Icons.check_circle : Icons.calendar_today_outlined,
              color: done
                  ? const Color(AppTheme.accent)
                  : const Color(0xFFFFB84D),
              size: 20,
            ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(done ? '今日已签到' : '每日签到',
                    style: const TextStyle(
                        color: Color(AppTheme.textPrimary), fontSize: 14.5)),
                const SizedBox(height: 2),
                const Text('签到得经验 +10',
                    style: TextStyle(
                        color: Color(AppTheme.textTertiary), fontSize: 11.5)),
              ],
            ),
          ),
          GestureDetector(
            onTap: done ? null : _signin,
            child: Container(
              width: 74,
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: done
                    ? const Color(AppTheme.elevated)
                    : const Color(AppTheme.accent),
                borderRadius: BorderRadius.circular(AppTheme.radiusPill),
              ),
              child: _signing
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Color(AppTheme.accent)))
                  : Text(done ? '已完成' : '签到',
                      style: TextStyle(
                          color: done
                              ? const Color(AppTheme.textSecondary)
                              : Colors.black,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _taskTile(Map<String, dynamic> t) {
    final name = (t['name'] ?? '') as String;
    final desc = (t['desc'] ?? '') as String;
    final reward = ((t['rewardExp'] ?? 0) as num).toInt();
    final status = (t['status'] ?? '') as String;
    final claimed = status == 'claimed';
    final done = status == 'done';
    final id = (t['id'] ?? '') as String;
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
              onTap: () => _claim(id),
              child: Container(
                width: 64,
                height: 28,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: const Color(AppTheme.accent),
                  borderRadius: BorderRadius.circular(AppTheme.radiusPill),
                ),
                child: _claiming == id
                    ? const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.black))
                    : const Text('领取',
                        style: TextStyle(
                            color: Colors.black,
                            fontSize: 12,
                            fontWeight: FontWeight.w600)),
              ),
            )
          else
            const Text('进行中',
                style: TextStyle(
                    color: Color(AppTheme.textTertiary), fontSize: 12)),
        ],
      ),
    );
  }
}
