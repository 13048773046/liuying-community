/// 投票卡组件（瀑布卡 / 详情页复用）：问题 + 选项 + 进度/投票
/// - 未投：显示选项按钮，点击调 /poll/vote
/// - 已投/截止：显示各选项票数与百分比进度条
/// - 投票后本地乐观更新并回调 onChanged
library;

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../config.dart';

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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(msg),
        backgroundColor: const Color(AppTheme.card),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final opts = (widget.poll['options'] ?? []) as List;
    final showResult = _voted || _closed || _total > 0;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(AppTheme.elevated),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.how_to_vote_rounded,
                  size: 15, color: Color(AppTheme.lilac)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  (widget.poll['question'] ?? '投票') as String,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600),
                ),
              ),
              if (_closed)
                const Text('已截止',
                    style: TextStyle(
                        color: Color(AppTheme.textTertiary), fontSize: 10))
              else if (showResult)
                Text('$_total 票',
                    style: const TextStyle(
                        color: Color(AppTheme.textTertiary), fontSize: 10)),
            ],
          ),
          const SizedBox(height: 10),
          for (var i = 0; i < opts.length; i++) ...[
            _optionRow(i, (opts[i] ?? '').toString(), showResult),
            if (i < opts.length - 1) const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }

  Widget _optionRow(int idx, String label, bool showResult) {
    final voted = _voted && _myOption == idx;
    if (!showResult) {
      return GestureDetector(
        onTap: () => _vote(idx),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: const Color(AppTheme.card),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
                color: voted
                    ? const Color(AppTheme.accent)
                    : const Color(AppTheme.border)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(label,
                    style: const TextStyle(
                        color: Color(AppTheme.textPrimary), fontSize: 13)),
              ),
              const Icon(Icons.radio_button_unchecked_rounded,
                  size: 16, color: Color(AppTheme.textTertiary)),
            ],
          ),
        ),
      );
    }
    final pct = _total == 0
        ? 0.0
        : (idx < _votes.length ? _votes[idx] : 0) / _total;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(AppTheme.card),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
            color: voted
                ? const Color(AppTheme.accent)
                : Colors.transparent),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(label,
                          style: TextStyle(
                              color: voted
                                  ? const Color(AppTheme.accent)
                                  : const Color(AppTheme.textPrimary),
                              fontSize: 13)),
                    ),
                    Text('${(pct * 100).round()}%',
                        style: const TextStyle(
                            color: Color(AppTheme.textTertiary),
                            fontSize: 11)),
                  ],
                ),
                const SizedBox(height: 5),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: pct,
                    minHeight: 4,
                    backgroundColor: const Color(AppTheme.border),
                    valueColor: const AlwaysStoppedAnimation(
                        Color(AppTheme.accent)),
                  ),
                ),
              ],
            ),
          ),
          if (voted) ...[
            const SizedBox(width: 8),
            const Icon(Icons.check_circle_rounded,
                size: 16, color: Color(AppTheme.accent)),
          ],
        ],
      ),
    );
  }
}
