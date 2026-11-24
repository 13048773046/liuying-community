/// 帖子 / 用户主页分享面板：复制短链、系统分享、分享给互关好友。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../api/client.dart';
import '../../config.dart';
import '../../design/components.dart';
import '../../design/system.dart';
import '../../utils/share_util.dart';
import '../../widgets/image_box.dart';
import 'share_friend_sheet.dart';

Future<void> showPostShareSheet(
  BuildContext context, {
  required String postId,
  required String title,
  String cover = '',
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    useSafeArea: true,
    builder: (_) => ShareTargetSheet(
      type: 'post',
      id: postId,
      title: title.trim().isEmpty ? '这条帖子' : title.trim(),
      subtitle: '帖子分享',
      imageUrl: cover.isEmpty ? '' : mediaUrl(cover),
      shareText: '《${title.trim().isEmpty ? '流萤社区' : title.trim()}》\n来自流萤社区',
    ),
  );
}

Future<void> showProfileShareSheet(
  BuildContext context, {
  required String uid,
  required String name,
  String avatar = '',
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    useSafeArea: true,
    builder: (_) => ShareTargetSheet(
      type: 'user',
      id: uid,
      title: name.trim().isEmpty ? 'TA 的主页' : name.trim(),
      subtitle: '主页分享',
      imageUrl: avatar.trim().isEmpty ? '' : avatarUrl(avatar),
      shareText: '来看看 ${name.trim().isEmpty ? 'TA' : name.trim()} 的流萤主页',
    ),
  );
}

class ShareTargetSheet extends StatefulWidget {
  const ShareTargetSheet({
    super.key,
    required this.type,
    required this.id,
    required this.title,
    required this.subtitle,
    required this.shareText,
    this.imageUrl = '',
  });

  final String type; // post | user
  final String id;
  final String title;
  final String subtitle;
  final String shareText;
  final String imageUrl;

  @override
  State<ShareTargetSheet> createState() => _ShareTargetSheetState();
}

class _ShareTargetSheetState extends State<ShareTargetSheet> {
  String _url = '';
  bool _copied = false;
  late final Future<void> _load;
  Timer? _copyTimer;
  bool _sharing = false;

  String get _fallback =>
      widget.type == 'user' ? userShareUrl(widget.id) : postShareUrl(widget.id);

  @override
  void initState() {
    super.initState();
    _url = _fallback;
    _load = _resolve();
  }

  @override
  void dispose() {
    _copyTimer?.cancel();
    super.dispose();
  }

  Future<void> _resolve() async {
    final url = await ApiClient.shareShortLink(
      widget.type,
      widget.id,
      fallback: _fallback,
    );
    if (mounted) setState(() => _url = url);
  }

  Future<void> _copy() async {
    try {
      await _load;
      await AppClipboard.copy(_url);
      if (!mounted) return;
      setState(() => _copied = true);
      HapticFeedback.lightImpact();
      _copyTimer?.cancel();
      _copyTimer = Timer(const Duration(seconds: 2), () {
        if (mounted) setState(() => _copied = false);
      });
    } catch (_) {
      if (mounted) showAppToast(context, '复制失败，请稍后重试');
    }
  }

  Future<void> _systemShare() async {
    if (_sharing) return;
    _sharing = true;
    try {
      // 系统分享必须和「复制短链」用同一个最终地址。之前这里用了
      // _fallback，短链接口成功时用户复制到的是短链、分享出去的却是长链。
      await _load;
      if (!mounted) return;
      final box = context.findRenderObject() as RenderBox?;
      final origin = box != null && box.hasSize
          ? box.localToGlobal(Offset.zero) & box.size
          : null;
      final text = '${widget.shareText}\n$_url';
      await shareToSystem(text, subject: '流萤社区', origin: origin);
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) showAppToast(context, '系统分享失败，请复制链接后手动发送');
    } finally {
      _sharing = false;
    }
  }

  Future<void> _friendShare() async {
    if (_sharing) return;
    _sharing = true;
    try {
      await _load;
      if (!mounted) return;
      final target = ShareFriendTarget(
        type: widget.type,
        id: widget.id,
        title: widget.title,
        subtitle: widget.subtitle,
        iconUrl: widget.imageUrl,
        shareUrl: _url,
      );
      // 先抓住根 Navigator 的 context，再关闭分享面板。直接用已被 pop
      // 的弹层 context 打开下一个弹层，会在动画期间出现已卸载祖先错误。
      final host = Navigator.of(context, rootNavigator: true);
      host.pop();
      await showShareFriendSheet(host.context, target);
    } catch (_) {
      if (mounted) showAppToast(context, '打开好友列表失败，请稍后重试');
    } finally {
      _sharing = false;
    }
  }

  Widget _thumb() {
    final url = widget.imageUrl.trim();
    final child = url.isEmpty
        ? Icon(
            widget.type == 'user'
                ? Icons.person_rounded
                : Icons.article_rounded,
            size: 25,
          )
        : CachedNetworkImageCompat(
            url: url,
            fit: BoxFit.cover,
            width: 52,
            height: 52,
            memCacheWidth: 140,
            errorWidget: Icon(
              widget.type == 'user'
                  ? Icons.person_rounded
                  : Icons.article_rounded,
              size: 25,
            ),
          );
    return Container(
      width: 52,
      height: 52,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(widget.type == 'user' ? 26 : 13),
        color: const Color(AppColors.elevated),
        border: Border.all(color: const Color(AppColors.border)),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(AppColors.canvas),
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 16),
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
              const SizedBox(height: 18),
              Row(
                children: [
                  _thumb(),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppType.title.copyWith(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          widget.subtitle,
                          style: AppType.micro.copyWith(
                            fontSize: 10.5,
                            color: const Color(AppColors.textTertiary),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(AppColors.accent)
                          .withValues(alpha: .08),
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                    ),
                    child: Text(
                      widget.type == 'user' ? '主页分享' : '帖子分享',
                      style: AppType.micro.copyWith(
                        fontSize: 9.5,
                        color: const Color(AppColors.accent),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: _ActionTile(
                      icon: _copied ? Icons.check_rounded : Icons.link_rounded,
                      label: _copied ? '已复制' : '复制短链',
                      accent: _copied,
                      onTap: _copy,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _ActionTile(
                      icon: Icons.ios_share_rounded,
                      label: '系统分享',
                      onTap: _systemShare,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _ActionTile(
                      icon: Icons.forum_outlined,
                      label: '互关好友',
                      onTap: _friendShare,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
                decoration: BoxDecoration(
                  color: const Color(AppColors.card).withValues(alpha: .55),
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  border: Border.all(color: const Color(AppColors.border)),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.public_rounded,
                      size: 15,
                      color: Color(AppColors.textTertiary),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _url,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppType.micro.copyWith(
                          fontSize: 10.5,
                          color: const Color(AppColors.textSecondary),
                        ),
                      ),
                    ),
                    IconCircleButton(
                      icon: _copied
                          ? Icons.check_rounded
                          : Icons.content_copy_rounded,
                      size: 30,
                      iconSize: 14,
                      tooltip: '复制链接',
                      background: Colors.transparent,
                      color: _copied
                          ? const Color(AppColors.accent)
                          : const Color(AppColors.textTertiary),
                      onTap: _copy,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Text(
                '私信卡片会直接打开对应详情页，站外打开走同一个短链。',
                style: AppType.micro.copyWith(
                  fontSize: 9.5,
                  height: 1.55,
                  color: const Color(AppColors.textTertiary),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.accent = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final color = accent
        ? const Color(AppColors.accent)
        : const Color(AppColors.textPrimary);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 4),
        decoration: BoxDecoration(
          color: const Color(AppColors.card).withValues(alpha: .6),
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(
            color: accent
                ? const Color(AppColors.accent).withValues(alpha: .5)
                : const Color(AppColors.border),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(height: 5),
            Text(
              label,
              style: AppType.micro.copyWith(
                fontSize: 10.5,
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
