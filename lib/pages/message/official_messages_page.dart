/// 官方通知聊天记录页：与流萤音乐官方通知界面一致
/// 聊天气泡样式，官方消息靠左，只读不可回复
library;

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../config.dart';

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(AppTheme.bg),
      appBar: AppBar(
        backgroundColor: const Color(AppTheme.bg),
        elevation: 0,
        centerTitle: true,
        title: const Text('官方通知',
            style: TextStyle(
                color: Color(AppTheme.textPrimary),
                fontSize: 16,
                fontWeight: FontWeight.w600)),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded,
              color: Colors.white, size: 18),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(
                  color: Color(AppTheme.accent), strokeWidth: 2.5))
          : _failed
              ? _retry()
              : RefreshIndicator(
                  color: const Color(AppTheme.accent),
                  backgroundColor: const Color(AppTheme.card),
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                    children: [
                      // 顶部提示（对齐音乐项目官方通知界面）
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: Center(
                          child: Text('仅流萤社区官方可发送，无法回复',
                              style: TextStyle(
                                  color: Color(AppTheme.textTertiary),
                                  fontSize: 11)),
                        ),
                      ),
                      if (_messages.isEmpty)
                        const Padding(
                          padding: EdgeInsets.only(top: 80),
                          child: Center(
                            child: Text('暂无官方通知',
                                style: TextStyle(
                                    color: Color(AppTheme.textTertiary),
                                    fontSize: 13)),
                          ),
                        )
                      else
                        ..._bubbles(),
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        child: Center(
                          child: Text('— 已显示全部官方通知 —',
                              style: TextStyle(
                                  color: Color(AppTheme.textTertiary)
                                      .withValues(alpha: 0.7),
                                  fontSize: 10)),
                        ),
                      ),
                    ],
                  ),
                ),
    );
  }

  Widget _retry() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('加载失败，下拉重试',
              style: TextStyle(
                  color: Color(AppTheme.textTertiary), fontSize: 13)),
          const SizedBox(height: 12),
          OutlinedButton(
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(AppTheme.accent),
              side: const BorderSide(color: Color(AppTheme.accent)),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20)),
            ),
            onPressed: () {
              setState(() {
                _loading = true;
                _failed = false;
              });
              _load();
            },
            child: const Text('重新加载'),
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
      final showHeader =
          i == 0 || (m['senderName'] ?? '') != (_messages[i - 1]['senderName'] ?? '');
      out.add(Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (showHeader) ...[
              Row(children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(AppTheme.accent)
                        .withValues(alpha: 0.15),
                  ),
                  child: ClipOval(
                    child: Image.asset(
                      'assets/logo.png',
                      width: 28,
                      height: 28,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const SizedBox(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(sender.isEmpty ? '流萤社区官方' : sender,
                    style: const TextStyle(
                        color: Color(AppTheme.textTertiary),
                        fontSize: 12,
                        fontWeight: FontWeight.w500)),
              ]),
              const SizedBox(height: 4),
            ],
            // 消息气泡（无描边、左小右大圆角，贴近原生 IM）
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: const BoxDecoration(
                color: Color(AppTheme.card),
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(4),
                  topRight: Radius.circular(16),
                  bottomLeft: Radius.circular(16),
                  bottomRight: Radius.circular(16),
                ),
              ),
              child: Text(content,
                  style: const TextStyle(
                      color: Color(AppTheme.textPrimary), fontSize: 14)),
            ),
          ],
        ),
      ));
    }
    return out;
  }
}
