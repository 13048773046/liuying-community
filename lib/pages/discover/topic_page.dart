/// 热门话题列表页（首页运营栏入口）：话题榜 → 详情
library;

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../config.dart';
import 'topic_detail_page.dart';

class TopicPage extends StatefulWidget {
  const TopicPage({super.key});

  @override
  State<TopicPage> createState() => _TopicPageState();
}

class _TopicPageState extends State<TopicPage> {
  List<Map<String, dynamic>> _topics = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await ApiClient.topicsHot();
      if (!mounted) return;
      setState(() {
        _topics = list;
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
      appBar: AppBar(
        backgroundColor: const Color(AppTheme.bg),
        elevation: 0,
        centerTitle: true,
        title: const Text('热门话题',
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
          : _topics.isEmpty
              ? const Center(
                  child: Text('暂无话题',
                      style:
                          TextStyle(color: Color(AppTheme.textSecondary))))
              : ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: _topics.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (_, i) {
                    final t = _topics[i];
                    final name = (t['name'] ?? '') as String;
                    final count = ((t['count'] ?? 0) as num).toInt();
                    return GestureDetector(
                      onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => TopicDetailPage(
                                  topic: name, count: count))),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 12),
                        decoration: BoxDecoration(
                          color: const Color(AppTheme.card),
                          borderRadius:
                              BorderRadius.circular(AppTheme.radiusCard),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 38,
                              height: 38,
                              decoration: BoxDecoration(
                                color: const Color(AppTheme.accent)
                                    .withValues(alpha: 0.14),
                                borderRadius: BorderRadius.circular(11),
                              ),
                              alignment: Alignment.center,
                              child: const Text('#',
                                  style: TextStyle(
                                      color: Color(AppTheme.accent),
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold)),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 14.5,
                                          fontWeight: FontWeight.w600)),
                                  const SizedBox(height: 2),
                                  Text('$_fmt(count) 帖参与',
                                      style: const TextStyle(
                                          color:
                                              Color(AppTheme.textTertiary),
                                          fontSize: 11)),
                                ],
                              ),
                            ),
                            const Icon(Icons.chevron_right_rounded,
                                color: Color(AppTheme.textTertiary),
                                size: 20),
                          ],
                        ),
                      ),
                    );
                  },
                ),
    );
  }

  String _fmt(int n) {
    if (n >= 10000) {
      final w = n / 10000;
      return w >= 100
          ? '${w.toStringAsFixed(0)}万'
          : '${w.toStringAsFixed(1)}万';
    }
    return '$n';
  }
}
