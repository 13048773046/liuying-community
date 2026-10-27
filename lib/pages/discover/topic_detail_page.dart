/// 话题详情页：话题头 + 该话题帖子流（feed?topic=）
library;

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../config.dart';
import '../../models/feed_item.dart';
import '../../widgets/waterfall_card.dart';
import '../post/post_detail.dart';

class TopicDetailPage extends StatefulWidget {
  final String topic;
  final int count;
  const TopicDetailPage({super.key, required this.topic, this.count = 0});

  @override
  State<TopicDetailPage> createState() => _TopicDetailPageState();
}

class _TopicDetailPageState extends State<TopicDetailPage> {
  List<FeedItem> _items = [];
  bool _loading = true;
  int _page = 0;
  bool _hasMore = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final fp = await ApiClient.feed(topic: widget.topic, page: _page + 1);
      if (!mounted) return;
      setState(() {
        _items.addAll(fp.list);
        _page++;
        _hasMore = fp.hasMore;
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
        title: Text('#${widget.topic}',
            style: const TextStyle(
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
          : _items.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('暂无内容',
                          style: TextStyle(
                              color: Color(AppTheme.textSecondary))),
                      const SizedBox(height: 8),
                      if (widget.count > 0)
                        Text('${widget.count} 篇参与',
                            style: const TextStyle(
                                color: Color(AppTheme.textTertiary),
                                fontSize: 12)),
                    ],
                  ),
                )
              : GridView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 20),
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: 0.74,
                  ),
                  itemCount: _items.length + (_hasMore ? 1 : 0),
                  itemBuilder: (_, i) {
                    if (i == _items.length) {
                      return GestureDetector(
                        onTap: _hasMore ? _load : null,
                        child: const Center(
                          child: Text('加载更多',
                              style: TextStyle(
                                  color: Color(AppTheme.textTertiary),
                                  fontSize: 12)),
                        ),
                      );
                    }
                    final it = _items[i];
                    return GestureDetector(
                      onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) =>
                                  PostDetailPage(postId: it.id))),
                      child: WaterfallCard(
                        item: it,
                        onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) =>
                                    PostDetailPage(postId: it.id))),
                      ),
                    );
                  },
                ),
    );
  }
}
