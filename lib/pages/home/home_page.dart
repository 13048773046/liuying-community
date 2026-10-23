/// 社区首页：图文信息流（feed?tab=all&type=post）
/// 帖子卡片：作者行（头像+认证LOGO+昵称+等级）+ 内容 + 图片(≤3) + 互动行
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../config.dart';
import '../../models/feed_item.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final List<FeedItem> _items = [];
  bool _loading = false;
  bool _loaded = false;
  int _page = 0;
  bool _hasMore = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool refresh = false}) async {
    if (_loading || (!_hasMore && !refresh)) return;
    setState(() => _loading = true);
    try {
      final p = await ApiClient.feed(
          type: 'post', page: refresh ? 1 : _page + 1, size: 10);
      if (!mounted) return;
      setState(() {
        if (refresh) {
          _items.clear();
          _page = 0;
        }
        _page = p.page;
        _hasMore = p.hasMore;
        _items.addAll(p.list);
        _loaded = true;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loaded = true;
        _loading = false;
      });
      if (_items.isEmpty) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('加载失败：$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(AppTheme.bg),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () => _load(refresh: true),
          color: const Color(AppTheme.accent),
          child: _items.isEmpty
              ? ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: [
                    const SizedBox(height: 200),
                    Center(
                      child: Text(
                        _loading ? '加载中…' : '还没有内容，去发第一帖吧',
                        style: const TextStyle(
                            color: Color(AppTheme.textSecondary), fontSize: 14),
                      ),
                    ),
                  ],
                )
              : ListView.builder(
                  physics: const AlwaysScrollableScrollPhysics(),
                  itemCount: _items.length + 1,
                  itemBuilder: (_, i) {
                    if (i == _items.length) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 18),
                        child: Center(
                          child: _hasMore
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Color(AppTheme.accent)),
                                )
                              : const Text('— 到底啦 —',
                                  style: TextStyle(
                                      color: Color(AppTheme.textSecondary),
                                      fontSize: 12)),
                        ),
                      );
                    }
                    if (i >= _items.length - 3) _load();
                    return _PostCard(item: _items[i]);
                  },
                ),
        ),
      ),
    );
  }
}

class _PostCard extends StatelessWidget {
  final FeedItem item;
  const _PostCard({required this.item});

  @override
  Widget build(BuildContext context) {
    final a = item.author;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(AppTheme.card),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 作者行
          Row(
            children: [
              _avatar(a.avatar),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            a.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (a.isAdmin) ...[
                          const SizedBox(width: 4),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 4, vertical: 1),
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(
                                  colors: [Color(0xFF7C4DFF), Color(0xFF4A90E2)]),
                              borderRadius: BorderRadius.circular(5),
                            ),
                            child: const Text(
                              '管理员',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 8.5,
                                  height: 1.3),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${a.name} · ${timeAgo(item.created)}',
                      style: const TextStyle(
                          color: Color(AppTheme.textSecondary), fontSize: 11),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // 内容（富文本简化：纯文本 + 话题高亮）
          if (item.content.isNotEmpty)
            _content(item.content, item.topic),
          const SizedBox(height: 10),
          // 图片 ≤3
          if (item.images.isNotEmpty) _images(item.images),
          const SizedBox(height: 10),
          // 互动行
          Row(
            children: [
              _miniAction(Icons.favorite_border, item.likeCount),
              const SizedBox(width: 20),
              _miniAction(Icons.chat_bubble_outline, item.commentCount),
              const SizedBox(width: 20),
              _miniAction(Icons.arrow_upward_outlined, item.shareCount),
              const Spacer(),
              if (item.featured)
                const Text('★ 精华',
                    style: TextStyle(
                        color: Color(0xFFFFB84D), fontSize: 11)),
              if (item.sticky) ...[
                const SizedBox(width: 8),
                const Text('📌 置顶',
                    style: TextStyle(
                        color: Color(0xFF7CC7FF), fontSize: 11)),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _avatar(String url) {
    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white.withOpacity(0.25)),
      ),
      child: ClipOval(
        child: url.isNotEmpty
            ? CachedNetworkImage(
                imageUrl: url,
                fit: BoxFit.cover,
                errorWidget: (_, __, ___) => const Icon(Icons.person,
                    color: Color(AppTheme.textSecondary)),
              )
            : const Icon(Icons.person, color: Color(AppTheme.textSecondary)),
      ),
    );
  }

  Widget _content(String text, List<String> topics) {
    final spans = <TextSpan>[];
    if (topics.isEmpty) {
      spans.add(TextSpan(text: text));
    } else {
      final kw = RegExp('(#[^\\s#]+)');
      var last = 0;
      for (final m in kw.allMatches(text)) {
        if (m.start > last) spans.add(TextSpan(text: text.substring(last, m.start)));
        spans.add(TextSpan(
          text: m.group(0),
          style: const TextStyle(
              color: Color(0xFF9AA8FF), fontWeight: FontWeight.w600),
        ));
        last = m.end;
      }
      if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
    }
    return Text.rich(
      TextSpan(
        style: const TextStyle(
            color: Colors.white, fontSize: 14, height: 1.5),
        children: spans,
      ),
    );
  }

  Widget _images(List<String> images) {
    final n = images.length;
    if (n == 1) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: CachedNetworkImage(
          imageUrl: mediaUrl(images[0]),
          width: double.infinity,
          height: 200,
          fit: BoxFit.cover,
          placeholder: (_, __) => Container(
            height: 200,
            color: const Color(0xFF22222B),
          ),
          errorWidget: (_, __, ___) => Container(
            height: 200,
            color: const Color(0xFF22222B),
            child: const Icon(Icons.broken_image,
                color: Color(AppTheme.textSecondary)),
          ),
        ),
      );
    }
    // 2~3 张：等宽网格
    return Row(
      children: [
        for (var i = 0; i < n; i++)
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(right: i < n - 1 ? 6 : 0),
              child: AspectRatio(
                aspectRatio: 1,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: CachedNetworkImage(
                    imageUrl: mediaUrl(images[i]),
                    fit: BoxFit.cover,
                    placeholder: (_, __) =>
                        Container(color: const Color(0xFF22222B)),
                    errorWidget: (_, __, ___) => Container(
                      color: const Color(0xFF22222B),
                      child: const Icon(Icons.broken_image,
                          color: Color(AppTheme.textSecondary)),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _miniAction(IconData icon, int count) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: const Color(AppTheme.textSecondary)),
        const SizedBox(width: 3),
        Text(
          countText(count),
          style: const TextStyle(
              color: Color(AppTheme.textSecondary), fontSize: 12),
        ),
      ],
    );
  }
}
