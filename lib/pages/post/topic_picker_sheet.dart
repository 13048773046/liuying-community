/// 多话题选择 / 用户级创建（发布页复用，图文与视频同款）
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../design/components.dart';

Future<List<String>?> showTopicPicker(
  BuildContext context, {
  required List<String> selected,
  int maxCount = 10,
}) {
  return showModalBottomSheet<List<String>>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    useSafeArea: true,
    builder: (_) =>
        TopicPickerSheet(initialSelected: selected, maxCount: maxCount),
  );
}

class TopicPickerSheet extends StatefulWidget {
  const TopicPickerSheet({
    super.key,
    required this.initialSelected,
    this.maxCount = 10,
  });

  final List<String> initialSelected;
  final int maxCount;

  @override
  State<TopicPickerSheet> createState() => _TopicPickerSheetState();
}

class _TopicPickerSheetState extends State<TopicPickerSheet> {
  final _search = TextEditingController();
  final _selected = <String>[];
  Timer? _debounce;
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;
  bool _creating = false;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _selected.addAll(widget.initialSelected);
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load([String q = '']) async {
    if (mounted) setState(() => _loading = true);
    try {
      final list = q.trim().isEmpty
          ? await ApiClient.topicsHot()
          : await ApiClient.topicsSearch(q.trim());
      if (!mounted) return;
      setState(() => _items = list);
    } catch (_) {
      if (mounted) setState(() => _items = []);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _onSearch(String v) {
    _query = v.trim();
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () => _load(v));
    setState(() {});
  }

  bool _hasExact() {
    final q = _query.trim();
    if (q.isEmpty) return false;
    return _items.any((e) => (e['name'] ?? '').toString() == q) ||
        _selected.contains(q);
  }

  Future<void> _create() async {
    final name = _query.trim().replaceAll('#', '').trim();
    if (name.isEmpty || _creating) return;
    if (name.length > 30) {
      showAppToast(context, '话题名最多 30 个字');
      return;
    }
    setState(() => _creating = true);
    try {
      final j = await ApiClient.createTopic(name);
      final created = (j['name'] ?? name).toString();
      if (!mounted) return;
      if (_selected.length >= widget.maxCount) {
        showAppToast(context, '最多添加 ${widget.maxCount} 个话题');
        return;
      }
      setState(() {
        if (!_selected.contains(created)) _selected.add(created);
        _search.clear();
        _query = '';
      });
      showAppToast(context, '已创建话题 #$created');
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, '创建失败：$e');
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  void _toggle(String name) {
    if (name.isEmpty) return;
    if (_selected.contains(name)) {
      setState(() => _selected.remove(name));
      return;
    }
    if (_selected.length >= widget.maxCount) {
      showAppToast(context, '最多添加 ${widget.maxCount} 个话题');
      return;
    }
    setState(() => _selected.add(name));
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: Container(
        height: MediaQuery.sizeOf(context).height * 0.78,
        decoration: const BoxDecoration(
          color: Color(AppColors.canvas),
          borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              const SizedBox(height: 10),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpace.gutter,
                  14,
                  AppSpace.gutter,
                  0,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '添加话题',
                            style: AppType.title.copyWith(
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            '最多 ${widget.maxCount} 个 · 可创建新话题',
                            style: AppType.micro.copyWith(fontSize: 10),
                          ),
                        ],
                      ),
                    ),
                    PillButton(
                      label: '完成',
                      size: PillSize.sm,
                      onTap: () =>
                          Navigator.pop(context, List<String>.of(_selected)),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpace.gutter,
                  12,
                  AppSpace.gutter,
                  8,
                ),
                child: TextField(
                  controller: _search,
                  onChanged: _onSearch,
                  textInputAction: TextInputAction.search,
                  style: AppType.bodySm,
                  decoration: InputDecoration(
                    hintText: '搜索话题，或直接输入新话题名',
                    prefixIcon: const Icon(Icons.search_rounded, size: 18),
                    suffixIcon: _query.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close_rounded, size: 17),
                            onPressed: () {
                              _search.clear();
                              _onSearch('');
                            },
                          ),
                    filled: true,
                    fillColor: const Color(AppColors.card),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                      borderSide: const BorderSide(
                        color: Color(AppColors.border),
                      ),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                      borderSide: const BorderSide(
                        color: Color(AppColors.border),
                      ),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                      borderSide: const BorderSide(
                        color: Color(AppColors.accent),
                      ),
                    ),
                  ),
                ),
              ),
              if (_selected.isNotEmpty)
                SizedBox(
                  height: 40,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpace.gutter,
                    ),
                    itemCount: _selected.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 6),
                    itemBuilder: (_, i) {
                      final name = _selected[i];
                      return InputChip(
                        label: Text('#$name'),
                        labelStyle: AppType.micro.copyWith(
                          color: const Color(AppColors.accent),
                          fontWeight: FontWeight.w600,
                        ),
                        backgroundColor: const Color(AppColors.accent)
                            .withValues(alpha: .09),
                        side: BorderSide(
                          color: const Color(AppColors.accent)
                              .withValues(alpha: .28),
                        ),
                        deleteIconColor: const Color(AppColors.accent),
                        onDeleted: () => _toggle(name),
                        visualDensity: VisualDensity.compact,
                      );
                    },
                  ),
                ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpace.gutter,
                    4,
                    AppSpace.gutter,
                    12,
                  ),
                  children: [
                    if (_query.isNotEmpty && !_hasExact())
                      ListRow(
                        leading: Container(
                          width: 30,
                          height: 30,
                          decoration: BoxDecoration(
                            color: const Color(AppColors.accent)
                                .withValues(alpha: .12),
                            shape: BoxShape.circle,
                          ),
                          child: _creating
                              ? const Padding(
                                  padding: EdgeInsets.all(9),
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(
                                  Icons.add_rounded,
                                  size: 18,
                                  color: Color(AppColors.accent),
                                ),
                        ),
                        title: '创建 #${_query.trim()}',
                        subtitle: '用户级话题，创建后所有帖子可用',
                        showChevron: false,
                        onTap: _create,
                      ),
                    if (_loading)
                      const Padding(
                        padding: EdgeInsets.all(30),
                        child: Center(
                          child: SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2.2),
                          ),
                        ),
                      )
                    else if (_items.isEmpty)
                      const EmptyState(
                        compact: true,
                        icon: Icons.tag_rounded,
                        title: '没有匹配的话题',
                        message: '直接输入名称，创建第一个',
                      )
                    else
                      for (final t in _items)
                        ListRow(
                          leading: const Icon(
                            Icons.tag_rounded,
                            size: 18,
                            color: Color(AppColors.accent),
                          ),
                          title: '#${(t['name'] ?? '').toString()}',
                          subtitle:
                              '${(t['count'] ?? 0)} 帖参与${(t['mine'] == true) ? ' · 我创建的' : ''}',
                          trailing: Checkbox(
                            value: _selected.contains(
                              (t['name'] ?? '').toString(),
                            ),
                            activeColor: const Color(AppColors.accent),
                            onChanged: (_) =>
                                _toggle((t['name'] ?? '').toString()),
                          ),
                          showChevron: false,
                          onTap: () => _toggle((t['name'] ?? '').toString()),
                        ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
