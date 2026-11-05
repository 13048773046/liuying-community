/// 任务中心（独立任务入口，替代原帖子区内嵌任务卡）
/// 聚合：发帖赢好礼活动 + 每日签到 + 后端 /tasks 任务列表
library;

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../design/components.dart';
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

  bool get _signedToday =>
      _signins.contains(DateTime.now().toString().split(' ')[0]);

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
      showAppToast(context, '签到成功，经验 +10');
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _signing = false);
      showAppToast(context, '$e');
    }
  }

  Future<void> _claim(String id) async {
    if (_claiming.isNotEmpty) return;
    setState(() => _claiming = id);
    try {
      await ApiClient.claimTask(id);
      if (!mounted) return;
      showAppToast(context, '已领取奖励');
      await _load();
    } catch (e) {
      if (!mounted) return;
      showAppToast(context, '$e');
    } finally {
      if (mounted) setState(() => _claiming = '');
    }
  }

  @override
  Widget build(BuildContext context) {
    return ImmersivePage(
      child: Column(
        children: [
          const GlassTopBar(
            title: '任务中心',
            subtitle: '每日签到 · 完成任务领经验',
            solid: true,
          ),
          Expanded(
            child: _loading
                ? const Center(
                    child: CircularProgressIndicator(strokeWidth: 2.4))
                : ApiClient.token == null
                    ? _notLogin()
                    : _body(),
          ),
        ],
      ),
    );
  }

  Widget _notLogin() {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.fromLTRB(
        AppSpace.gutter,
        AppSpace.x8,
        AppSpace.gutter,
        AppSpace.x6 + MediaQuery.paddingOf(context).bottom,
      ),
      children: const [
        EmptyState(
          icon: Icons.lock_outline_rounded,
          title: '登录后可参与任务',
          message: '登录后即可签到、领取任务奖励',
        ),
      ],
    );
  }

  Widget _body() {
    return RefreshIndicator(
      color: const Color(AppColors.accent),
      backgroundColor: const Color(AppColors.elevated),
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        padding: EdgeInsets.fromLTRB(
          AppSpace.gutter,
          AppSpace.x2,
          AppSpace.gutter,
          AppSpace.x6 + MediaQuery.paddingOf(context).bottom,
        ),
        children: [
          _campaignCard(),
          const SizedBox(height: AppSpace.x3),
          _signinCard(),
          if (_tasks.isNotEmpty) ...[
            const SizedBox(height: AppSpace.x2),
            const SectionHeader(
              title: '更多任务',
              padding: EdgeInsets.fromLTRB(0, AppSpace.x5, 0, AppSpace.x3),
            ),
            for (final t in _tasks) _taskTile(t),
          ],
        ],
      ),
    );
  }

  /// 发帖赢好礼活动头卡
  Widget _campaignCard() {
    return PressableScale(
      onTap: () => Navigator.push(context,
          MaterialPageRoute(builder: (_) => const PostEditorPage())),
      child: Container(
        padding: const EdgeInsets.all(AppSpace.x4),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [
              const Color(AppColors.accent).withValues(alpha: 0.16),
              const Color(AppColors.card),
            ],
          ),
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(
            color: const Color(AppColors.accent).withValues(alpha: 0.28),
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: const Color(AppColors.accent).withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              child: const Icon(Icons.emoji_events_outlined,
                  color: Color(AppColors.accent), size: 24),
            ),
            const SizedBox(width: AppSpace.x3),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('发帖赢好礼', style: AppType.title),
                  SizedBox(height: 3),
                  Text('发布 1 篇内容，赢取限定装扮', style: AppType.caption),
                ],
              ),
            ),
            const SizedBox(width: AppSpace.x2),
            PillButton(
              label: '去参与',
              size: PillSize.sm,
              onTap: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const PostEditorPage())),
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
      padding: const EdgeInsets.all(AppSpace.x4),
      decoration: BoxDecoration(
        color: const Color(AppColors.card),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: const Color(AppColors.border)),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: done
                  ? const Color(AppColors.accentSoft)
                  : const Color(AppColors.elevated),
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: Icon(
              done
                  ? Icons.check_circle_rounded
                  : Icons.calendar_today_rounded,
              color: done
                  ? const Color(AppColors.accent)
                  : const Color(AppColors.warning),
              size: 20,
            ),
          ),
          const SizedBox(width: AppSpace.x3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(done ? '今日已签到' : '每日签到',
                    style: AppType.title.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                const Text('签到得经验 +10', style: AppType.caption),
              ],
            ),
          ),
          PillButton(
            label: done ? '已完成' : '签到',
            size: PillSize.sm,
            variant: done ? PillVariant.ghost : PillVariant.primary,
            loading: _signing,
            onTap: done ? null : _signin,
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
      margin: const EdgeInsets.only(bottom: AppSpace.x2),
      padding: const EdgeInsets.all(AppSpace.x3),
      decoration: BoxDecoration(
        color: const Color(AppColors.card),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: const Color(AppColors.border)),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: claimed
                  ? const Color(AppColors.accentSoft)
                  : const Color(AppColors.elevated),
              borderRadius: BorderRadius.circular(AppRadius.xs),
            ),
            child: Icon(
              claimed ? Icons.check_circle_rounded : Icons.bolt_rounded,
              color: claimed
                  ? const Color(AppColors.accent)
                  : const Color(AppColors.warning),
              size: 18,
            ),
          ),
          const SizedBox(width: AppSpace.x3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(name,
                    style:
                        AppType.body.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(
                  desc.isEmpty ? '奖励经验 +$reward' : '$desc · +$reward 经验',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.caption,
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpace.x2),
          if (claimed)
            Text('已领取',
                style: AppType.caption
                    .copyWith(color: const Color(AppColors.accent)))
          else if (done)
            PillButton(
              label: '领取',
              size: PillSize.sm,
              loading: _claiming == id,
              onTap: () => _claim(id),
            )
          else
            Text('进行中', style: AppType.caption),
        ],
      ),
    );
  }
}
