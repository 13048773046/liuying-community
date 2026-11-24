/// 热门话题：话题标签流（[TagPill]），点击进入话题详情
library;

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../design/components.dart';
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

  void _open(Map<String, dynamic> t) {
    final name = (t['name'] ?? '') as String;
    final count = ((t['count'] ?? 0) as num).toInt();
    Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => TopicDetailPage(topic: name, count: count)),
    );
  }

  /// 话题标签：名称 + 帖子数（点击参数不变）。
  Widget _tagPill(int i) {
    final t = _topics[i];
    final name = (t['name'] ?? '') as String;
    final count = ((t['count'] ?? 0) as num).toInt();
    return TagPill(
      label: '#$name · $count',
      icon: i < 3 ? Icons.local_fire_department_rounded : null,
      onTap: () => _open(t),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ImmersivePage(
      child: Column(
        children: [
          const GlassTopBar(title: '热门话题', solid: true),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading) return const _TopicSkeleton();
    if (_topics.isEmpty) {
      return const Center(
        child: EmptyState(
          icon: Icons.tag_rounded,
          title: '暂无话题',
          message: '等大家聊起来，这里就会热闹',
        ),
      );
    }
    return ListView(
      padding: EdgeInsets.fromLTRB(
        AppSpace.gutter,
        AppSpace.x4,
        AppSpace.gutter,
        MediaQuery.paddingOf(context).bottom + 28,
      ),
      children: [
        Row(
          children: [
            const Icon(Icons.local_fire_department_rounded,
                size: 15, color: Color(AppColors.accent)),
            const SizedBox(width: AppSpace.x1),
            Text('${_topics.length} 个话题正在热议', style: AppType.caption),
          ],
        ),
        const SizedBox(height: AppSpace.x4),
        Wrap(
          spacing: AppSpace.x2,
          runSpacing: AppSpace.x2,
          children: [
            for (var i = 0; i < _topics.length; i++) _tagPill(i),
          ],
        ),
      ],
    );
  }
}

/// 首屏骨架：标签流占位。
class _TopicSkeleton extends StatelessWidget {
  const _TopicSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
          AppSpace.gutter, AppSpace.x5, AppSpace.gutter, 0),
      physics: const NeverScrollableScrollPhysics(),
      children: [
        const SkeletonBox(width: 160, height: 12),
        const SizedBox(height: AppSpace.x4),
        Wrap(
          spacing: AppSpace.x2,
          runSpacing: AppSpace.x2,
          children: [
            for (var i = 0; i < 12; i++)
              SkeletonBox(width: 60.0 + (i % 4) * 22, height: 32, radius: 16),
          ],
        ),
      ],
    );
  }
}
