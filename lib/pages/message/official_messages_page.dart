/// 官方通知聊天记录页（沉浸黑）：与流萤音乐官方通知界面一致
/// 聊天气泡样式，官方消息靠左，只读不可回复
library;

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../design/components.dart';

class OfficialMessagesPage extends StatefulWidget {
  const OfficialMessagesPage({super.key});

  @override
  State<OfficialMessagesPage> createState() => _OfficialMessagesPageState();
}

class _OfficialMessagesPageState extends State<OfficialMessagesPage> {
  List<Map<String, dynamic>> _messages = [];
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      var after = 0.0;
      final all = <Map<String, dynamic>>[];
      while (true) {
        final j = await ApiClient.officialMessages(after: after);
        final list = ((j['list'] ?? []) as List)
            .whereType<Map<String, dynamic>>()
            .toList();
        if (list.isEmpty) break;
        all.addAll(list);
        after = (list.last['created'] as num).toDouble();
        if (list.length < 100) break;
      }
      if (!mounted) return;
      setState(() {
        _messages = all; // 后端按 created ASC 返回
        _loading = false;
        _failed = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  void _retry() {
    setState(() {
      _loading = true;
      _failed = false;
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return ImmersivePage(
      child: Column(
        children: [
          const GlassTopBar(title: '官方通知', solid: true),
          // 常驻提示（对齐音乐项目官方通知界面）
          Padding(
            padding: const EdgeInsets.only(
                top: AppSpace.x1, bottom: AppSpace.x2),
            child: Center(
              child: Text('仅流萤社区官方可发送，无法回复', style: AppType.micro),
            ),
          ),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2.2),
        ),
      );
    }
    if (_failed) {
      return Center(
        child: ErrorState(message: '加载失败，下拉重试', onRetry: _retry),
      );
    }
    return RefreshIndicator(
      color: const Color(AppColors.accent),
      backgroundColor: const Color(AppColors.elevated),
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(
          AppSpace.gutter,
          AppSpace.x2,
          AppSpace.gutter,
          MediaQuery.paddingOf(context).bottom + AppSpace.x4,
        ),
        children: [
          if (_messages.isEmpty)
            const EmptyState(
              icon: Icons.campaign_outlined,
              title: '暂无官方通知',
              message: '官方公告与活动提醒会出现在这里',
            )
          else
            ..._bubbles(),
          if (_messages.isNotEmpty)
            const LoadMoreFooter(
              hasMore: false,
              endLabel: '— 已显示全部官方通知 —',
            ),
        ],
      ),
    );
  }

  /// 相邻同发送者消息只展示一次头像/名称（标准 IM 样式）
  List<Widget> _bubbles() {
    final out = <Widget>[];
    for (var i = 0; i < _messages.length; i++) {
      final m = _messages[i];
      final content = (m['content'] ?? '') as String;
      final sender = (m['senderName'] ?? '') as String;
      final showHeader = i == 0 ||
          (m['senderName'] ?? '') != (_messages[i - 1]['senderName'] ?? '');
      out.add(Padding(
        padding: EdgeInsets.only(
          top: showHeader && i > 0 ? AppSpace.x3 : 0,
          bottom: AppSpace.x1,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (showHeader) ...[
              Row(
                children: [
                  SizedBox(
                    width: 26,
                    height: 26,
                    child: ClipOval(
                      child: Image.asset(
                        'assets/logo.png',
                        width: 26,
                        height: 26,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => const DecoratedBox(
                          decoration: BoxDecoration(
                            color: Color(AppColors.accentSoft),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpace.x2),
                  Text(
                    sender.isEmpty ? '流萤社区官方' : sender,
                    style: AppType.caption,
                  ),
                ],
              ),
              const SizedBox(height: AppSpace.x1 + 2),
            ],
            // 消息气泡（无描边、左上小圆角，贴近原生 IM）
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpace.x4, vertical: AppSpace.x2 + 2),
              decoration: const BoxDecoration(
                color: Color(AppColors.card),
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(AppRadius.xs),
                  topRight: Radius.circular(AppRadius.md),
                  bottomLeft: Radius.circular(AppRadius.md),
                  bottomRight: Radius.circular(AppRadius.md),
                ),
              ),
              child: Text(content, style: AppType.body),
            ),
          ],
        ),
      ));
    }
    return out;
  }
}
