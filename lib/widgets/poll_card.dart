/// 投票卡组件（瀑布卡 / 详情页复用）：问题 + 选项 + 进度/投票
/// - 未投：显示选项按钮，点击调 /poll/vote
/// - 已投/截止：显示各选项票数与百分比进度条（薄荷绿按比例填充）
/// - 投票后本地乐观更新并回调 onChanged
library;

import 'package:flutter/material.dart';

import '../api/client.dart';
import '../design/components.dart';

class PollCard extends StatefulWidget {
  final String postId;
  final Map<String, dynamic> poll;
  final VoidCallback? onChanged; // 投票成功后的刷新回调
  const PollCard({
    super.key,
    required this.postId,
    required this.poll,
    this.onChanged,
  });

  @override
  State<PollCard> createState() => _PollCardState();
}

class _PollCardState extends State<PollCard> {
  bool _voting = false;
  bool _voted = false;
  int _myOption = -1;
  List<int> _votes = [];
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    _sync(widget.poll);
  }

  void _sync(Map<String, dynamic> p) {
    _voted = (p['voted'] ?? false) == true;
    _closed = (p['closed'] ?? false) == true;
    _myOption = ((p['myOption'] ?? (p['votedOption'] ?? -1)) as num).toInt();
    final opts = (p['options'] ?? []) as List;
    final vs = (p['votes'] ?? []) as List;
    _votes = [
      for (var i = 0; i < opts.length; i++)
        (i < vs.length ? ((vs[i] ?? 0) as num).toInt() : 0)
    ];
  }

  int get _total =>
      _votes.isEmpty ? 0 : _votes.fold(0, (a, b) => a + b);

  Future<void> _vote(int option) async {
    if (_voting || _voted || _closed) return;
    setState(() {
      _voting = true;
      _myOption = option;
      _voted = true;
      // 乐观更新
      final vs = List<int>.from(_votes);
      while (vs.length <= option) {
        vs.add(0);
      }
      vs[option] += 1;
      _votes = vs;
    });
    try {
      final j = await ApiClient.pollVote(widget.postId, option);
      if (!mounted) return;
      final np = j['poll'];
      if (np is Map<String, dynamic>) {
        setState(() => _sync(np));
      }
      widget.onChanged?.call();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _voting = false;
        _voted = false;
        _myOption = -1;
        // 回滚
        final vs = List<int>.from(_votes);
        if (option < vs.length) vs[option] = vs[option] > 0 ? vs[option] - 1 : 0;
        _votes = vs;
      });
      final msg = e is ApiException ? e.message : '投票失败';
      showAppToast(context, msg);
    }
  }

  @override
  Widget build(BuildContext context) {
    final opts = (widget.poll['options'] ?? []) as List;
    final showResult = _voted || _closed || _total > 0;
    return Container(
      padding: const EdgeInsets.all(AppSpace.x4),
      decoration: BoxDecoration(
        color: const Color(AppColors.card),
        borderRadius: AppRadius.rLg,
        border: Border.all(color: const Color(AppColors.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.how_to_vote_rounded,
                  size: 16, color: Color(AppColors.accent)),
              const SizedBox(width: AppSpace.x2),
              Expanded(
                child: Text(
                  (widget.poll['question'] ?? '投票') as String,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.body.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(width: AppSpace.x2),
              if (_closed)
                Text('已截止', style: AppType.micro)
              else if (showResult)
                Text('$_total 票',
                    style: AppType.numeric
                        .copyWith(color: const Color(AppColors.textTertiary))),
            ],
          ),
          const SizedBox(height: AppSpace.x3),
          for (var i = 0; i < opts.length; i++) ...[
            _optionRow(i, (opts[i] ?? '').toString(), showResult),
            if (i < opts.length - 1) const SizedBox(height: AppSpace.x2),
          ],
        ],
      ),
    );
  }

  Widget _optionRow(int idx, String label, bool showResult) {
    final voted = _voted && _myOption == idx;
    if (!showResult) {
      return PressableScale(
        onTap: () => _vote(idx),
        child: AnimatedContainer(
          duration: AppMotion.base,
          curve: AppMotion.standard,
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpace.x3, vertical: AppSpace.x3),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.04),
            borderRadius: AppRadius.rSm,
            border: Border.all(
                color: voted
                    ? const Color(AppColors.accent)
                    : const Color(AppColors.border)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: AppType.bodySm
                      .copyWith(color: const Color(AppColors.textPrimary)),
                ),
              ),
              const SizedBox(width: AppSpace.x2),
              const Icon(Icons.radio_button_unchecked_rounded,
                  size: 16, color: Color(AppColors.textTertiary)),
            ],
          ),
        ),
      );
    }
    final pct = _total == 0
        ? 0.0
        : (idx < _votes.length ? _votes[idx] : 0) / _total;
    return AnimatedContainer(
      duration: AppMotion.base,
      curve: AppMotion.standard,
      padding: const EdgeInsets.all(AppSpace.x3),
      decoration: BoxDecoration(
        color: voted
            ? const Color(AppColors.accent).withValues(alpha: 0.08)
            : Colors.white.withValues(alpha: 0.04),
        borderRadius: AppRadius.rSm,
        border: Border.all(
            color: voted
                ? const Color(AppColors.accent)
                : const Color(AppColors.hairline)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: AppType.bodySm.copyWith(
                    color: voted
                        ? const Color(AppColors.accent)
                        : const Color(AppColors.textPrimary),
                    fontWeight: voted ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
              if (voted) ...[
                const Icon(Icons.check_circle_rounded,
                    size: 14, color: Color(AppColors.accent)),
                const SizedBox(width: AppSpace.x1),
              ],
              Text('${(pct * 100).round()}%',
                  style: AppType.numeric
                      .copyWith(color: const Color(AppColors.textTertiary))),
            ],
          ),
          const SizedBox(height: AppSpace.x2),
          // 进度条：薄荷绿按票数比例填充
          SizedBox(
            height: 5,
            child: ClipRRect(
              borderRadius: AppRadius.rPill,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  const ColoredBox(color: Color(AppColors.hairline)),
                  TweenAnimationBuilder<double>(
                    tween: Tween<double>(
                        begin: 0, end: pct.clamp(0.0, 1.0).toDouble()),
                    duration: AppMotion.slow,
                    curve: AppMotion.standard,
                    builder: (_, v, _) => Align(
                      alignment: Alignment.centerLeft,
                      child: FractionallySizedBox(
                        widthFactor: v,
                        heightFactor: 1,
                        child: const ColoredBox(color: Color(AppColors.accent)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
