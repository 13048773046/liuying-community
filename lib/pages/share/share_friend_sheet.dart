/// 全站分享 · 互关好友选择器（应用 / 帖子 / 主页共用）
///
/// 只列双向关注好友；服务端会再次校验。送出的是私信 card 消息，
/// 接收方点卡片会直达应用详情、帖子详情或用户主页。
library;

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../config.dart';
import '../../design/components.dart';
import '../../models/feed_item.dart';
import '../../widgets/image_box.dart';

class ShareFriendTarget {
  const ShareFriendTarget({
    required this.type,
    required this.id,
    required this.title,
    this.subtitle = '',
    this.iconUrl = '',
    this.shareUrl = '',
  });

  /// app | post | user
  final String type;
  final String id;
  final String title;
  final String subtitle;
  final String iconUrl;
  final String shareUrl;

  String get typeLabel => switch (type) {
    'app' => '应用',
    'post' => '帖子',
    'user' => '主页',
    _ => '内容',
  };
}

Future<void> showShareFriendSheet(
  BuildContext context,
  ShareFriendTarget target,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    useSafeArea: true,
    builder: (_) => ShareFriendSheet(target: target),
  );
}

class ShareFriendSheet extends StatefulWidget {
  const ShareFriendSheet({super.key, required this.target});

  final ShareFriendTarget target;

  @override
  State<ShareFriendSheet> createState() => _ShareFriendSheetState();
}

class _ShareFriendSheetState extends State<ShareFriendSheet> {
  final _note = TextEditingController();
  final _selected = <String>{};
  Future<Map<String, dynamic>>? _future;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _future = ApiClient.dmFriends();
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  void _toggle(String id) {
    if (id.isEmpty) return;
    setState(() {
      if (_selected.contains(id)) {
        _selected.remove(id);
      } else {
        _selected.add(id);
      }
    });
  }

  Future<void> _send() async {
    if (_selected.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final j = await ApiClient.dmShareTarget(
        type: widget.target.type,
        id: widget.target.id,
        peers: _selected.toList(),
        note: _note.text,
      );
      if (!mounted) return;
      final sent = (j['sent'] as List?)?.length ?? 0;
      final failed = (j['failed'] as List?)?.length ?? 0;
      // 先弹 Toast 再关弹层：Toast 会落在下层 Scaffold 上，弹层收起后
      // 正好可见，同时避免用已被 pop 的弹层 context 再查找 Overlay。
      if (sent > 0) {
        showAppToast(
          context,
          failed > 0 ? '已分享给 $sent 位好友，$failed 位失败' : '已分享给 $sent 位好友',
        );
      } else {
        showAppToast(context, '发送失败，请确认对方已回关你');
      }
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      showAppToast(context, '分享失败：$e');
    }
  }

  Widget _thumb() {
    final url = widget.target.iconUrl.trim();
    final child = url.isEmpty
        ? const Icon(Icons.alternate_email_rounded, size: 24)
        : CachedNetworkImageCompat(
            url: url,
            fit: BoxFit.cover,
            width: 52,
            height: 52,
            memCacheWidth: 140,
            errorWidget: const Icon(
              Icons.alternate_email_rounded,
              size: 24,
            ),
          );
    return Container(
      width: 52,
      height: 52,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(13),
        color: const Color(AppColors.elevated),
        border: Border.all(color: const Color(AppColors.border)),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    final target = widget.target;
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.86,
        ),
        decoration: const BoxDecoration(
          color: Color(AppColors.canvas),
          borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 10, 18, 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    _thumb(),
                    const SizedBox(width: 11),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '分享给互关好友',
                            style: AppType.title.copyWith(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            '${target.typeLabel} · ${target.title}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppType.micro.copyWith(fontSize: 10.5),
                          ),
                        ],
                      ),
                    ),
                    IconCircleButton(
                      icon: Icons.close_rounded,
                      size: 34,
                      iconSize: 17,
                      background: Colors.transparent,
                      tooltip: '关闭',
                      onTap: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: FutureBuilder<Map<String, dynamic>>(
                    future: _future,
                    builder: (context, snap) {
                      if (snap.connectionState == ConnectionState.waiting) {
                        return const Center(
                          child: SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2.2),
                          ),
                        );
                      }
                      if (snap.hasError) {
                        return Center(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 18),
                            child: Text(
                              '好友列表加载失败：${snap.error}\n请先登录后再试。',
                              textAlign: TextAlign.center,
                              style: AppType.bodySm.copyWith(height: 1.7),
                            ),
                          ),
                        );
                      }
                      final list = ((snap.data?['list'] ?? []) as List)
                          .whereType<Map>()
                          .map((e) => Map<String, dynamic>.from(e))
                          .toList();
                      if (list.isEmpty) {
                        return Center(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 26),
                            child: Text(
                              '还没有互关好友。\n先去关注对方，等对方回关后就能分享。',
                              textAlign: TextAlign.center,
                              style: AppType.bodySm.copyWith(height: 1.8),
                            ),
                          ),
                        );
                      }
                      return ListView.separated(
                        itemCount: list.length,
                        separatorBuilder: (_, _) => const Divider(
                          height: 1,
                          color: Color(AppColors.hairline),
                        ),
                        itemBuilder: (_, i) {
                          final f = list[i];
                          final id = (f['id'] ?? '').toString();
                          final name = (f['name'] ?? '好友').toString();
                          final avatar = avatarUrl(
                            (f['avatar'] ?? '').toString(),
                          );
                          final title = (f['title'] ?? '').toString();
                          final checked = _selected.contains(id);
                          return InkWell(
                            onTap: () => _toggle(id),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 7),
                              child: Row(
                                children: [
                                  AppAvatar(
                                    url: avatar.isEmpty
                                        ? avatarUrlOf(
                                            (f['id'] ?? '').toString(),
                                          )
                                        : avatar,
                                    name: name,
                                    size: 38,
                                    verified:
                                        verifiedOf(f['verified']) ||
                                        (f['verifiedLabel'] ?? '')
                                            .toString()
                                            .trim()
                                            .isNotEmpty,
                                    isAi:
                                        boolOf(f['isAi']) ||
                                        (f['verifiedLabel'] ?? '')
                                                .toString()
                                                .trim()
                                                .toUpperCase() ==
                                            'AI',
                                    frameUrl: frameUrlOf(
                                      (f['frameId'] ?? '').toString(),
                                    ),
                                  ),
                                  const SizedBox(width: 9),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: AppType.body.copyWith(
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        if (title.isNotEmpty)
                                          Text(
                                            title,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: AppType.micro.copyWith(
                                              fontSize: 10,
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                  Checkbox(
                                    value: checked,
                                    activeColor: const Color(AppColors.accent),
                                    onChanged: (_) => _toggle(id),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _note,
                  maxLength: 120,
                  maxLines: 2,
                  minLines: 1,
                  style: AppType.bodySm,
                  decoration: InputDecoration(
                    hintText: '附一句推荐语（可选）',
                    counterText: '',
                    filled: true,
                    fillColor: const Color(AppColors.card),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadius.md),
                      borderSide: const BorderSide(
                        color: Color(AppColors.border),
                      ),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadius.md),
                      borderSide: const BorderSide(
                        color: Color(AppColors.border),
                      ),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadius.md),
                      borderSide: const BorderSide(
                        color: Color(AppColors.accent),
                      ),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                PillButton(
                  label: _selected.isEmpty
                      ? '选择好友后发送'
                      : '发送给 ${_selected.length} 位好友',
                  size: PillSize.lg,
                  icon: Icons.send_rounded,
                  expand: true,
                  glow: _selected.isNotEmpty,
                  enabled: _selected.isNotEmpty && !_sending,
                  loading: _sending,
                  onTap: _send,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
