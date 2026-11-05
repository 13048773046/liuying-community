import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../config.dart';
import '../../design/components.dart';
import '../../models/feed_item.dart';

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
      showAppToast(context, '加载失败：$e');
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
      showAppToast(
        context,
        action == 'audit' && reason == null
            ? '已通过'
            : action == 'audit'
                ? '已拒绝'
                : '已下架',
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showAppToast(context, '操作失败：$e');
    }
  }

  Future<void> _reject(FeedItem it) async {
    final ctrl = TextEditingController();
    final reason = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => SheetShell(
        title: '拒绝理由',
        subtitle: '原因会展示给作者',
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: AppSpace.x2),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: ctrl,
                maxLength: 60,
                autofocus: true,
                style: AppType.body,
                cursorColor: const Color(AppColors.accent),
                decoration: InputDecoration(
                  hintText: '填写拒绝原因（作者可见）',
                  hintStyle: AppType.bodySm
                      .copyWith(color: const Color(AppColors.textTertiary)),
                  counterText: '',
                  filled: true,
                  fillColor: const Color(AppColors.elevated),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: AppSpace.x4,
                    vertical: AppSpace.x3,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: AppRadius.rSm,
                    borderSide: BorderSide.none,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: AppRadius.rSm,
                    borderSide: BorderSide.none,
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: AppRadius.rSm,
                    borderSide: const BorderSide(
                        color: Color(AppColors.accent), width: 1),
                  ),
                ),
              ),
              const SizedBox(height: AppSpace.x4),
              Row(
                children: [
                  Expanded(
                    child: PillButton(
                      label: '取消',
                      variant: PillVariant.ghost,
                      onTap: () => Navigator.pop(ctx),
                    ),
                  ),
                  const SizedBox(width: AppSpace.x3),
                  Expanded(
                    child: PillButton(
                      label: '确认拒绝',
                      variant: PillVariant.danger,
                      onTap: () => Navigator.pop(ctx, ctrl.text.trim()),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpace.x3),
            ],
          ),
        ),
      ),
    );
    if (reason != null && reason.isNotEmpty) {
      await _action(it, 'audit', reason: reason);
    }
  }

  void _switchTab(int i) {
    if (_tab == i) return;
    setState(() => _tab = i);
    _load(refresh: true);
  }

  @override
  Widget build(BuildContext context) {
    return ImmersivePage(
      child: Column(
        children: [
          const GlassTopBar(
            title: '内容审核',
            subtitle: '通过 / 拒绝待审内容',
            solid: true,
          ),
          TagRail(
            labels: const ['待审核', '已拒绝'],
            index: _tab,
            onChanged: _switchTab,
          ),
          const SizedBox(height: AppSpace.x1),
          Expanded(
            child: RefreshIndicator(
              color: const Color(AppColors.accent),
              backgroundColor: const Color(AppColors.elevated),
              onRefresh: () => _load(refresh: true),
              child: _body(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading && _items.isEmpty) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.4));
    }
    if (_loaded && _items.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(top: AppSpace.x8),
        children: [
          EmptyState(
            icon: _tab == 0
                ? Icons.fact_check_outlined
                : Icons.verified_outlined,
            title: _tab == 0 ? '暂无待审核内容' : '暂无已拒绝内容',
            message: _tab == 0 ? '新的投稿会出现在这里' : '被拒绝的内容会出现在这里',
          ),
        ],
      );
    }
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(
        parent: BouncingScrollPhysics(),
      ),
      padding: EdgeInsets.fromLTRB(
        AppSpace.gutter,
        AppSpace.x2,
        AppSpace.gutter,
        AppSpace.x6 + MediaQuery.paddingOf(context).bottom,
      ),
      itemCount: _items.length + 1,
      itemBuilder: (_, i) {
        if (i >= _items.length) {
          return LoadMoreFooter(
            hasMore: true,
            onTap: () => _load(refresh: false),
          );
        }
        return _auditCard(_items[i]);
      },
    );
  }

  Widget _auditCard(FeedItem it) {
    final thumb = (it.type == 'video' && it.cover.isNotEmpty)
        ? it.cover
        : (it.images.isNotEmpty ? it.images.first : '');
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpace.x3),
      padding: const EdgeInsets.all(AppSpace.x3),
      decoration: BoxDecoration(
        color: const Color(AppColors.card),
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: const Color(AppColors.border)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 76,
            height: 76,
            child: ClipRRect(
              borderRadius: AppRadius.rSm,
              child: thumb.isNotEmpty
                  ? Image.network(
                      thumb.startsWith('http') ? thumb : mediaUrl(thumb),
                      width: 76,
                      height: 76,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) =>
                          const ImagePlaceholder(radius: 0),
                    )
                  : const ImagePlaceholder(
                      icon: Icons.article_outlined, radius: 0),
            ),
          ),
          const SizedBox(width: AppSpace.x3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    AppAvatar(
                      url: avatarUrl(it.author.avatar),
                      name: it.author.name,
                      size: 22,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        it.author.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppType.label,
                      ),
                    ),
                    const SizedBox(width: AppSpace.x2),
                    _statusChip(it),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  it.content,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.bodySm.copyWith(height: 1.4),
                ),
                const SizedBox(height: AppSpace.x3),
                Row(
                  children: [
                    if (_tab == 0) ...[
                      PillButton(
                        label: '通过',
                        size: PillSize.sm,
                        enabled: !_busy,
                        onTap: () => _action(it, 'audit'),
                      ),
                      const SizedBox(width: AppSpace.x2),
                      PillButton(
                        label: '拒绝',
                        size: PillSize.sm,
                        variant: PillVariant.danger,
                        enabled: !_busy,
                        onTap: () => _reject(it),
                      ),
                    ] else ...[
                      PillButton(
                        label: '恢复通过',
                        size: PillSize.sm,
                        enabled: !_busy,
                        onTap: () => _action(it, 'audit'),
                      ),
                      const SizedBox(width: AppSpace.x2),
                      PillButton(
                        label: '下架',
                        size: PillSize.sm,
                        variant: PillVariant.danger,
                        enabled: !_busy,
                        onTap: () => _action(it, 'takedown'),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusChip(FeedItem it) {
    final pending = it.auditStatus == 0;
    final color =
        pending ? const Color(AppColors.warning) : const Color(AppColors.danger);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(AppRadius.xs),
      ),
      child: Text(
        pending ? '待审核' : '已拒绝',
        style: AppType.micro.copyWith(color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}
