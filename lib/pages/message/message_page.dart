/// 消息页：官方通知（与音乐分离）+ 互动通知入口
library;

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../config.dart';
import '../../models/feed_item.dart';

class MessagePage extends StatefulWidget {
  const MessagePage({super.key});

  @override
  State<MessagePage> createState() => _MessagePageState();
}

class _MessagePageState extends State<MessagePage> {
  List<Map<String, dynamic>> _official = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final j = await ApiClient.get('/official-messages', query: {'page': '1'});
      if (!mounted) return;
      setState(() {
        _official = ((j['list'] ?? []) as List)
            .whereType<Map<String, dynamic>>()
            .toList();
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(AppTheme.bg),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Text('消息',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold)),
            ),
            // 官方通知（社区独立）
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(AppTheme.card),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.campaign_outlined,
                          size: 16, color: Color(AppTheme.accent)),
                      SizedBox(width: 6),
                      Text('官方通知',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w600)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (_loading)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Center(
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Color(AppTheme.accent)),
                        ),
                      ),
                    )
                  else if (_official.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Center(
                        child: Text('暂无官方通知',
                            style: TextStyle(
                                color: Color(AppTheme.textSecondary),
                                fontSize: 12)),
                      ),
                    )
                  else
                    for (final m in _official.take(3))
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              (m['title'] ?? '') as String,
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 13),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              (m['content'] ?? '') as String,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: Color(AppTheme.textSecondary),
                                  fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                ],
              ),
            ),
            // 互动通知入口（占位，二期接入 /notifications 分页）
            Container(
              margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(AppTheme.card),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  const Icon(Icons.notifications_none,
                      size: 16, color: Color(AppTheme.accent)),
                  const SizedBox(width: 8),
                  const Text('互动通知（点赞/评论/@提及/审核结果）',
                      style: TextStyle(
                          color: Colors.white, fontSize: 13)),
                  const Spacer(),
                  Icon(Icons.chevron_right,
                      color: Colors.white.withOpacity(0.4)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
