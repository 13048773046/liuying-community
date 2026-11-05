/// 话题详情页：话题头 + 该话题帖子流（feed?topic=）
///
/// 沉浸黑：话题大标题 + 参与数，正文用全幅 [PostCard] 单列信息流。
library;

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../design/components.dart';
import '../../models/feed_item.dart';
import '../../widgets/post_card.dart';
import '../post/post_detail.dart';

class TopicDetailPage extends StatefulWidget {
  final String topic;
  final int count;
  const TopicDetailPage({super.key, required this.topic, this.count = 0});

  @override
  State<TopicDetailPage> createState() => _TopicDetailPageState();
}

class _TopicDetailPageState extends State<TopicDetailPage> {
  final List<FeedItem> _items = [];
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
    return ImmersivePage(
      child: Column(
        children: [
          GlassTopBar(title: '#${widget.topic}', solid: true),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading) return const _TopicDetailSkeleton();

    return ListView(
      padding: EdgeInsets.fromLTRB(
        AppSpace.gutter,
        AppSpace.x4,
        AppSpace.gutter,
        MediaQuery.paddingOf(context).bottom + 28,
      ),
      children: [
        _topicHeader(),
        const SizedBox(height: AppSpace.x4),
        if (_items.isEmpty)
          EmptyState(
            icon: Icons.tag_rounded,
            title: '暂无内容',
            message: widget.count > 0
                ? '${widget.count} 篇参与，来发第一帖吧'
                : '来发第一帖吧',
            compact: true,
          )
        else ...[
          for (final it in _items)
            PostCard(
              item: it,
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => PostDetailPage(postId: it.id)),
              ),
            ),
          LoadMoreFooter(
            hasMore: _hasMore,
            onTap: _load,
            endLabel: '— 已经到底啦 —',
          ),
        ],
      ],
    );
  }

  Widget _topicHeader() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('#${widget.topic}', style: AppType.h1),
        const SizedBox(height: AppSpace.x2),
        Wrap(
          spacing: AppSpace.x2,
          runSpacing: AppSpace.x2,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const Icon(Icons.local_fire_department_rounded,
                size: 14, color: Color(AppColors.accent)),
            TagPill(
              label: widget.count > 0
                  ? '${formatCount(widget.count)} 篇参与'
                  : '等你来发第一帖',
              compact: true,
            ),
          ],
        ),
      ],
    );
  }
}

/// 首屏骨架：话题头 + 两条内容卡占位。
class _TopicDetailSkeleton extends StatelessWidget {
  const _TopicDetailSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
          AppSpace.gutter, AppSpace.x4, AppSpace.gutter, 0),
      physics: const NeverScrollableScrollPhysics(),
      children: [
        const SkeletonBox(width: 180, height: 24, radius: AppRadius.xs),
        const SizedBox(height: AppSpace.x2),
        const SkeletonBox(width: 90, height: 11),
        const SizedBox(height: AppSpace.x5),
        for (var i = 0; i < 2; i++) ...[
          const SkeletonBox(height: 220, radius: AppRadius.lg),
          const SizedBox(height: AppSpace.x4),
        ],
      ],
    );
  }
}
