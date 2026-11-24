/// 任务中心：真实签到、真实任务进度、真实活动，不再放静态占位卡。
///
/// 数据全部来自后端：
/// - `/signins`、`/signin`：签到记录与签到动作
/// - `/tasks`、`/tasks/{id}/claim`：任务进度与领取
/// - `/activities`：后台配置的进行中话题活动
library;

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../design/components.dart';
import '../../models/feed_item.dart';
import '../../services/user_data_bus.dart';
import '../discover/topic_detail_page.dart';
import '../mine/login_page.dart';
import '../post/post_editor.dart';

class TaskCenterPage extends StatefulWidget {
  const TaskCenterPage({super.key});

  @override
  State<TaskCenterPage> createState() => _TaskCenterPageState();
}

class _TaskCenterPageState extends State<TaskCenterPage> {
  List<Map<String, dynamic>> _tasks = [];
  List<String> _signins = [];
  List<Map<String, dynamic>> _activities = [];
  bool _loading = true;
  bool _signing = false;
  String _claiming = '';
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  static String _dayKey(DateTime d) {
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '$y-$m-$day';
  }

  Future<void> _load() async {
    if (ApiClient.token == null) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = null;
        });
      }
      return;
    }
    if (mounted) {
      setState(() {
        _loading = _tasks.isEmpty && _activities.isEmpty;
        _error = null;
      });
    }
    try {
      final results = await Future.wait<Map<String, dynamic>>([
        ApiClient.tasks(),
        ApiClient.signins(),
        ApiClient.activities(),
      ]);
      if (!mounted) return;
      final taskJson = results[0];
      final signinJson = results[1];
      final activityJson = results[2];
      setState(() {
        _tasks = ((taskJson['list'] ?? []) as List)
            .whereType<Map<String, dynamic>>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
        _signins = ((signinJson['list'] ?? []) as List)
            .map((e) => e.toString())
            .where((e) => e.isNotEmpty)
            .toList();
        _activities = ((activityJson['list'] ?? []) as List)
            .whereType<Map<String, dynamic>>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e is ApiException ? e.message : '$e';
      });
    }
  }

  bool get _signedToday => _signins.contains(_dayKey(DateTime.now()));

  int get _streakDays {
    final set = _signins.toSet();
    var day = DateTime.now();
    var streak = 0;
    while (set.contains(_dayKey(day))) {
      streak++;
      day = DateTime(day.year, day.month, day.day - 1);
    }
    return streak;
  }

  int get _doneTaskCount => _tasks.where((t) {
    final status = (t['status'] ?? '').toString();
    return boolOf(t['done']) ||
        boolOf(t['claimed']) ||
        status == 'done' ||
        status == 'claimed';
  }).length;

  Future<void> _signin() async {
    if (_signing) return;
    setState(() => _signing = true);
    try {
      final j = await ApiClient.signin();
      if (!mounted) return;
      final day = (j['day'] ?? _dayKey(DateTime.now())).toString();
      setState(() {
        if (!_signins.contains(day)) _signins.add(day);
        _signing = false;
      });
      final msg = (j['msg'] ?? '').toString().trim();
      showAppToast(context, msg.isEmpty ? '签到成功' : msg);
      UserDataBus.touch();
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _signing = false);
      showAppToast(context, e is ApiException ? e.message : '$e');
    }
  }

  Future<void> _claim(String id) async {
    if (_claiming.isNotEmpty || id.isEmpty) return;
    setState(() => _claiming = id);
    try {
      final j = await ApiClient.claimTask(id);
      if (!mounted) return;
      final msg = (j['msg'] ?? '').toString().trim();
      showAppToast(context, msg.isEmpty ? '已领取奖励' : msg);
      UserDataBus.touch();
      await _load();
    } catch (e) {
      if (!mounted) return;
      showAppToast(context, e is ApiException ? e.message : '$e');
    } finally {
      if (mounted) setState(() => _claiming = '');
    }
  }

  void _openLogin() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const LoginPage()),
    ).then((ok) {
      if (ok == true && mounted) _load();
    });
  }

  void _openActivity(Map<String, dynamic> a) {
    final topic = (a['topicId'] ?? '').toString().trim();
    if (topic.isEmpty) {
      showAppToast(context, '该活动还没有关联话题');
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => PostEditorPage(initialTopics: [topic])),
    );
  }

  void _openTopic(Map<String, dynamic> a) {
    final topic = (a['topicId'] ?? '').toString().trim();
    if (topic.isEmpty) return;
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => TopicDetailPage(topic: topic)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ImmersivePage(
      child: Column(
        children: [
          GlassTopBar(
            title: '任务中心',
            subtitle: ApiClient.token == null
                ? '登录后签到、做任务、领经验'
                : '签到、任务与活动都来自真实数据',
            solid: true,
          ),
          Expanded(
            child: _loading
                ? const Center(
                    child: CircularProgressIndicator(strokeWidth: 2.4),
                  )
                : ApiClient.token == null
                ? _notLogin()
                : _error != null
                ? Center(
                    child: ErrorState(message: _error!, onRetry: _load),
                  )
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
      children: [
        EmptyState(
          icon: Icons.lock_outline_rounded,
          title: '登录后可参与任务',
          message: '登录后即可签到、累计任务进度并领取经验',
          actionLabel: '去登录',
          onAction: _openLogin,
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
          if (_activities.isNotEmpty) ...[
            const SectionHeader(
              title: '进行中的活动',
              subtitle: '活动结束后，按话题参与记录统一发放经验',
              padding: EdgeInsets.fromLTRB(0, AppSpace.x3, 0, AppSpace.x3),
            ),
            for (final a in _activities) _activityCard(a),
            const SizedBox(height: AppSpace.x2),
          ],
          _signinCard(),
          const SizedBox(height: AppSpace.x4),
          SectionHeader(
            title: '成长任务',
            subtitle: _tasks.isEmpty
                ? '暂无任务'
                : '已完成 $_doneTaskCount / ${_tasks.length}',
            padding: const EdgeInsets.fromLTRB(0, 0, 0, AppSpace.x3),
          ),
          if (_tasks.isEmpty)
            const EmptyState(
              icon: Icons.task_alt_rounded,
              title: '暂无任务',
              message: '任务正在整理中，稍后再来看看',
              compact: true,
            )
          else
            for (final t in _tasks) _taskTile(t),
        ],
      ),
    );
  }

  Widget _activityCard(Map<String, dynamic> a) {
    final title = (a['title'] ?? '').toString();
    final desc = (a['desc'] ?? '').toString();
    final topic = (a['topicId'] ?? '').toString();
    final reward = intOf(a['rewardExp']);
    final endAt = intOf(a['endAt']);
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpace.x2),
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
            child: const Icon(
              Icons.emoji_events_outlined,
              color: Color(AppColors.accent),
              size: 24,
            ),
          ),
          const SizedBox(width: AppSpace.x3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title, style: AppType.title, maxLines: 1),
                const SizedBox(height: 3),
                Text(
                  desc.isEmpty
                      ? '#$topic · +$reward 经验'
                      : '$desc · +$reward 经验',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.caption,
                ),
                const SizedBox(height: 5),
                Text(
                  _activityTimeText(endAt),
                  style: AppType.micro.copyWith(
                    color: const Color(AppColors.textTertiary),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpace.x2),
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              PillButton(
                label: '去发帖',
                size: PillSize.sm,
                onTap: () => _openActivity(a),
              ),
              const SizedBox(height: 4),
              PressableScale(
                onTap: () => _openTopic(a),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Text(
                    '查看话题',
                    style: AppType.micro.copyWith(
                      color: const Color(AppColors.textTertiary),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _activityTimeText(int endAt) {
    if (endAt <= 0) return '长期活动 · 进行中';
    final left = endAt - (DateTime.now().millisecondsSinceEpoch ~/ 1000);
    if (left <= 0) return '活动已结束';
    final days = left ~/ 86400;
    if (days >= 1) return '剩余 $days 天';
    final hours = left ~/ 3600;
    if (hours >= 1) return '剩余 $hours 小时';
    return '即将结束';
  }

  Widget _signinCard() {
    final done = _signedToday;
    final streak = _streakDays;
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
              done ? Icons.check_circle_rounded : Icons.calendar_today_rounded,
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
                Text(
                  done ? '今日已签到' : '每日签到',
                  style: AppType.title.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  done ? '已连续签到 $streak 天，明天继续' : '签到得经验 +5，连续 7 天额外 +20',
                  style: AppType.caption,
                ),
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
    final name = (t['name'] ?? '').toString();
    final desc = (t['desc'] ?? '').toString();
    final reward = intOf(t['rewardExp']);
    final status = (t['status'] ?? '').toString();
    final claimed = boolOf(t['claimed']) || status == 'claimed';
    final done = boolOf(t['done']) || status == 'done';
    final target = intOf(t['target'], 1).clamp(1, 999999).toInt();
    final progress = intOf(t['progress']).clamp(0, target).toInt();
    final id = (t['id'] ?? '').toString();
    final ratio = target <= 0 ? 0.0 : (progress / target).clamp(0.0, 1.0);
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpace.x2),
      padding: const EdgeInsets.all(AppSpace.x3),
      decoration: BoxDecoration(
        color: const Color(AppColors.card),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: const Color(AppColors.border)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
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
              claimed
                  ? Icons.check_circle_rounded
                  : done
                  ? Icons.redeem_rounded
                  : Icons.bolt_rounded,
              color: claimed || done
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
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppType.body.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '+$reward 经验',
                      style: AppType.micro.copyWith(
                        color: const Color(AppColors.accent),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  desc.isEmpty ? '完成进度 $progress/$target' : desc,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.caption,
                ),
                const SizedBox(height: 7),
                Row(
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                          value: ratio,
                          minHeight: 3,
                          backgroundColor: const Color(AppColors.elevated),
                          valueColor: AlwaysStoppedAnimation(
                            claimed || done
                                ? const Color(AppColors.accent)
                                : const Color(AppColors.textTertiary),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '$progress/$target',
                      style: AppType.micro.copyWith(
                        color: const Color(AppColors.textTertiary),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpace.x2),
          if (claimed)
            Padding(
              padding: const EdgeInsets.only(top: 7),
              child: Text(
                '已领取',
                style: AppType.caption.copyWith(
                  color: const Color(AppColors.accent),
                ),
              ),
            )
          else if (done)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: PillButton(
                label: '领取',
                size: PillSize.sm,
                loading: _claiming == id,
                onTap: () => _claim(id),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.only(top: 7),
              child: Text('进行中', style: AppType.caption),
            ),
        ],
      ),
    );
  }
}
