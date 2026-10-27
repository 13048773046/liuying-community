import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../config.dart';
import '../../models/feed_item.dart';
import '../../widgets/user_avatar.dart';

/// 内容审核页（App 内入口，仅管理员可见）
/// 待审 / 已拒绝 列表，支持 通过 / 拒绝(填原因) / 下架
class AuditPage extends StatefulWidget {
  const AuditPage({super.key});

  @override
  State<AuditPage> createState() => _AuditPageState();
}

class _AuditPageState extends State<AuditPage> {
  final List<FeedItem> _items = [];
  bool _loading = true;
  bool _loaded = false;
  int _tab = 0; // 0 待审 1 已拒绝
  int _page = 1;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load(refresh: true);
  }

  Future<void> _load({bool refresh = false}) async {
    if (refresh) {
      _page = 1;
      _items.clear();
      setState(() {
        _loading = true;
        _loaded = false;
      });
    } else {
      _page++;
    }
    try {
      final j = await ApiClient.adminPosts(
          audit: _tab == 0 ? 0 : 2, page: _page);
      final list = (j['list'] ?? []) as List;
      if (refresh) {
        _items.addAll(list.map((e) => FeedItem.fromJson(e)).toList());
        setState(() {
          _loading = false;
          _loaded = true;
        });
      } else {
        setState(() => _items.addAll(
            list.map((e) => FeedItem.fromJson(e)).toList()));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('加载失败：$e'),
          backgroundColor: const Color(AppTheme.card)));
    }
  }

  Future<void> _action(FeedItem it, String action, {String? reason}) async {
    setState(() => _busy = true);
    try {
      await ApiClient.adminAction(it.id, action, reason: reason);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _items.removeWhere((x) => x.id == it.id);
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(action == 'audit' && reason == null
              ? '已通过'
              : action == 'audit'
                  ? '已拒绝'
                  : '已下架'),
          backgroundColor: const Color(AppTheme.card)));
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('操作失败：$e'),
          backgroundColor: const Color(AppTheme.card)));
    }
  }

  Future<void> _reject(FeedItem it) async {
    final ctrl = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(AppTheme.card),
        title: const Text('拒绝理由',
            style: TextStyle(
                color: Color(AppTheme.textPrimary), fontSize: 15)),
        content: TextField(
          controller: ctrl,
          maxLength: 60,
          style: const TextStyle(color: Color(AppTheme.textPrimary)),
          cursorColor: const Color(AppTheme.accent),
          decoration: InputDecoration(
            hintText: '填写拒绝原因（作者可见）',
            hintStyle:
                const TextStyle(color: Color(AppTheme.textTertiary)),
            filled: true,
            fillColor: const Color(AppTheme.elevated),
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide.none),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消',
                style: TextStyle(color: Color(AppTheme.textSecondary))),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('确认拒绝',
                style: TextStyle(
                    color: Color(AppTheme.accent),
                    fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
    if (reason != null && reason.isNotEmpty) {
      await _action(it, 'audit', reason: reason);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(AppTheme.bg),
      appBar: AppBar(
        backgroundColor: const Color(AppTheme.bg),
        foregroundColor: const Color(AppTheme.textPrimary),
        elevation: 0,
        centerTitle: true,
        title: const Text('内容审核',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
      ),
      body: Column(
        children: [
          // 顶部 Tab：待审 / 已拒绝
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Row(
              children: [
                _seg(0, '待审核'),
                const SizedBox(width: 20),
                _seg(1, '已拒绝'),
              ],
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              color: const Color(AppTheme.accent),
              onRefresh: () => _load(refresh: true),
              child: _body(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _seg(int i, String label) {
    final sel = _tab == i;
    return GestureDetector(
      onTap: () {
        if (_tab == i) return;
        setState(() => _tab = i);
        _load(refresh: true);
      },
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
        decoration: BoxDecoration(
          color: sel ? const Color(AppTheme.accent) : const Color(AppTheme.elevated),
          borderRadius: BorderRadius.circular(AppTheme.radiusPill),
        ),
        child: Text(label,
            style: TextStyle(
                color: sel ? Colors.black : const Color(AppTheme.textSecondary),
                fontSize: 13,
                fontWeight: sel ? FontWeight.w600 : FontWeight.w400)),
      ),
    );
  }

  Widget _body() {
    if (_loading && _items.isEmpty) {
      return const Center(
          child: CircularProgressIndicator(color: Color(AppTheme.accent)));
    }
    if (_loaded && _items.isEmpty) {
      return ListView(
        children: [
          const SizedBox(height: 160),
          const Center(
              child: Icon(Icons.inbox_outlined,
                  size: 56, color: Color(AppTheme.textTertiary))),
          const SizedBox(height: 12),
          const Center(
              child: Text('暂无内容',
                  style: TextStyle(
                      color: Color(AppTheme.textTertiary),
                      fontSize: 14))),
        ],
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
      itemCount: _items.length + 1,
      itemBuilder: (_, i) {
        if (i >= _items.length) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Center(
              child: GestureDetector(
                onTap: () => _load(refresh: false),
                child: const Text('加载更多',
                    style: TextStyle(
                        color: Color(AppTheme.textTertiary),
                        fontSize: 13)),
              ),
            ),
          );
        }
        final it = _items[i];
        final thumb = (it.type == 'video' && it.cover.isNotEmpty)
            ? it.cover
            : (it.images.isNotEmpty ? it.images.first : '');
        return Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(AppTheme.card),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: thumb.isNotEmpty
                    ? Image.network(
                        thumb.startsWith('http') ? thumb : mediaUrl(thumb),
                        width: 72,
                        height: 72,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => Container(
                            width: 72,
                            height: 72,
                            color: const Color(AppTheme.elevated)))
                    : Container(
                        width: 72,
                        height: 72,
                        color: const Color(AppTheme.elevated),
                        alignment: Alignment.center,
                        child: const Icon(Icons.article_outlined,
                            color: Color(AppTheme.textTertiary), size: 26),
                      ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        UserAvatar(
                            url: it.author?.avatar ?? '',
                            name: it.author?.name ?? '?',
                            size: 20),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(it.author?.name ?? '',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: Color(AppTheme.textPrimary),
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600)),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: it.auditStatus == 0
                                ? const Color(0xFFFFB84D)
                                    .withValues(alpha: 0.18)
                                : const Color(0xFFE4574F)
                                    .withValues(alpha: 0.18),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            it.auditStatus == 0 ? '待审核' : '已拒绝',
                            style: TextStyle(
                                color: it.auditStatus == 0
                                    ? const Color(0xFFB97A16)
                                    : const Color(0xFFC43D35),
                                fontSize: 10,
                                fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(it.content,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Color(AppTheme.textSecondary),
                            fontSize: 12.5,
                            height: 1.4)),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        if (_tab == 0) ...[
                          _btn('通过', const Color(AppTheme.accent), () {
                            _action(it, 'audit');
                          }),
                          const SizedBox(width: 8),
                          _btn('拒绝', const Color(0xFFE4574F), () {
                            _reject(it);
                          }),
                        ] else ...[
                          _btn('恢复通过', const Color(AppTheme.accent), () {
                            _action(it, 'audit');
                          }),
                          const SizedBox(width: 8),
                          _btn('下架', const Color(0xFFE4574F), () {
                            _action(it, 'takedown');
                          }),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _btn(String label, Color bg, VoidCallback onTap) {
    return GestureDetector(
      onTap: _busy ? null : onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: bg.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(AppTheme.radiusPill),
        ),
        child: Text(label,
            style: TextStyle(
                color: bg, fontSize: 12, fontWeight: FontWeight.w600)),
      ),
    );
  }
}
