/// 抖音式评论弹窗（P0）：评论列表 + 底部输入栏
///
/// 交互参考抖音评论：
///  - 点击表情/图片图标 → 收起输入法，面板占住输入法原位置（互斥切换）
///  - 表情包（图片/GIF）与图片评论二选一（后端强制 images/sticker 互斥）
///  - 表情选择后进入待发预览区，可删除；图片同理
///  - @ 好友：弹层选择关注列表，插入「@昵称 」文本
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../api/client.dart';
import '../config.dart';
import '../design/components.dart';
import '../models/feed_item.dart' show timeAgo;
import '../pages/mine/login_page.dart';
import 'emoji_panel.dart';
import 'image_box.dart';
import 'input_panel_host.dart';

enum _PanelMode { none, emoji, image, at }

/// 跨评论弹窗事件：任一弹窗新增评论后广播，打开中的列表弹窗自动刷新
final ValueNotifier<int> commentAddedBus = ValueNotifier<int>(0);

/// 打开评论弹窗；[onChanged] 评论数变化回调
/// [pureInput]=true：纯输入弹窗（仅输入栏+表情/图片/@面板，不含评论列表），
/// 供帖子/视频详情页底部「说点什么…」使用：弹出即唤起输入法
/// [autoInputWhenEmpty]=true：列表加载完成后为空（0 条评论）时，
/// 自动在弹窗之上再叠一个纯输入弹窗并唤起输入法（短视频评论用）
Future<void> showCommentSheet(
  BuildContext context, {
  required String postId,
  ValueChanged<int>? onChanged,
  bool light = false,
  bool pureInput = false,
  bool autoInputWhenEmpty = false,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    useSafeArea: true,
    // 弹窗出入动画：柔和缓动（可见但不拖沓）
    sheetAnimationStyle: const AnimationStyle(
      duration: AppMotion.page,
      curve: AppMotion.standard,
      reverseCurve: AppMotion.exit,
    ),
    builder: (_) => CommentSheet(
        postId: postId,
        onChanged: onChanged,
        light: light,
        pureInput: pureInput,
        autoInputWhenEmpty: autoInputWhenEmpty),
  );
}

class CommentSheet extends StatefulWidget {
  const CommentSheet(
      {super.key,
      required this.postId,
      this.onChanged,
      this.light = false,
      this.pureInput = false,
      this.autoInputWhenEmpty = false});

  final String postId;
  final ValueChanged<int>? onChanged;

  /// light=true：仅评论列表弹窗（短视频详情用），
  /// 底部「说点什么…」点击后关闭本弹窗并打开完整抖音式评论弹窗
  final bool light;

  /// pureInput=true：纯输入弹窗（无评论列表），详情页底部「说点什么…」使用
  final bool pureInput;

  /// autoInputWhenEmpty=true：列表加载完为空时自动叠纯输入弹窗（短视频）
  final bool autoInputWhenEmpty;

  @override
  State<CommentSheet> createState() => _CommentSheetState();
}

class _CommentSheetState extends State<CommentSheet> {
  final _ctrl = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  late final bool _lightMode = widget.light;

  List<Map<String, dynamic>> _comments = [];
  int _page = 1;
  bool _hasMore = false;
  bool _loading = false;
  bool _sending = false;

  _PanelMode _panel = _PanelMode.none;
  File? _img;
  String? _sticker; // 表情文件名（媒体 URL）

  List<Map<String, dynamic>> _atList = [];
  bool _atLoading = false;

  @override
  void initState() {
    super.initState();
    if (!widget.pureInput) {
      _load(refresh: true);
      commentAddedBus.addListener(_onBusAdded);
    } else {
      // 纯输入弹窗：打开即唤起输入法
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusNode.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    commentAddedBus.removeListener(_onBusAdded);
    _ctrl.dispose();
    super.dispose();
  }

  /// 其他弹窗新增评论后：刷新本列表并回传最新评论数
  void _onBusAdded() {
    if (!mounted) return;
    _load(refresh: true);
    widget.onChanged?.call(_total);
  }

  int _total = 0;
  bool _autoInputShown = false; // 空列表自动叠输入弹窗，只叠一次

  Future<void> _load({bool refresh = false}) async {
    if (_loading) return;
    setState(() {
      if (refresh) {
        _page = 1;
      }
      _loading = true;
    });
    try {
      final j = await ApiClient.comments(widget.postId, page: _page, size: 20);
      final list = ((j['list'] ?? []) as List)
          .whereType<Map<String, dynamic>>()
          .toList();
      final hasMore = (j['hasMore'] ?? false) == true;
      final total = j['total'];
      if (!mounted) return;
      setState(() {
        _comments = refresh ? list : [..._comments, ...list];
        _hasMore = hasMore;
        _total = total is int ? total : _comments.length;
        _loading = false;
      });
      _maybeAutoInput();
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  /// 列表加载完且为空（0 条评论）→ 自动叠纯输入弹窗并唤起输入法（只叠一次）
  void _maybeAutoInput() {
    if (!widget.autoInputWhenEmpty || widget.pureInput || widget.light) return;
    if (_comments.isNotEmpty || _autoInputShown) return;
    _autoInputShown = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showCommentSheet(context,
          postId: widget.postId, pureInput: true);
    });
  }

  void _showPanel(_PanelMode m) {
    // 键盘/面板切换由 InputPanelHost 统一管理（隐藏键盘保留焦点，锁定键盘高度）
    setState(() => _panel = _panel == m ? _PanelMode.none : m);
  }

  Future<void> _pickImage() async {
    final p = await ImagePicker()
        .pickImage(source: ImageSource.gallery, maxWidth: 1600);
    if (p == null || !mounted) return;
    setState(() {
      _img = File(p.path);
      _sticker = null; // 互斥：选图片时清掉表情
      // 面板保持打开（图片位置不变），重新选图即替换
    });
  }

  void _pickSticker(Map<String, dynamic> e) {
    setState(() {
      _sticker = (e['image'] ?? '') as String;
      _img = null; // 互斥：选表情时清掉图片
      // 面板保持打开（表情位置不变），重新点选表情即替换
    });
  }

  void _atFriend() {
    if (ApiClient.token == null || ApiClient.token!.isEmpty) {
      _needLogin();
      return;
    }
    setState(() {
      _panel = _panel == _PanelMode.at ? _PanelMode.none : _PanelMode.at;
      if (_panel == _PanelMode.at && _atList.isEmpty) {
        _atLoading = true;
      }
    });
    if (_panel == _PanelMode.at && _atList.isEmpty) {
      _loadAtList();
    }
  }

  Future<void> _loadAtList() async {
    try {
      final j = await ApiClient.userList(ApiClient.userId ?? '',
          kind: 'followings', page: 1, size: 50);
      final list = ((j['list'] ?? []) as List)
          .whereType<Map<String, dynamic>>()
          .toList();
      if (!mounted) return;
      setState(() {
        _atList = list;
        _atLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _atLoading = false);
    }
  }

  void _pickAt(Map<String, dynamic> u) {
    final name = (u['name'] ?? '用户') as String;
    final at = _ctrl.text;
    _ctrl.text = at.isEmpty ? '@$name ' : '$at @$name ';
    _ctrl.selection = TextSelection.collapsed(offset: _ctrl.text.length);
    setState(() {
      _panel = _PanelMode.none; // 插入后回到键盘态继续输入
    });
  }

  void _needLogin() {
    showAppToast(context, '请先登录后评论（账号与流萤音乐互通）');
    Navigator.of(context).pop();
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const LoginPage()),
    );
  }

  Future<void> _send() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty && _img == null && _sticker == null) {
      showAppToast(context, '评论内容不能为空');
      return;
    }
    if (ApiClient.token == null || ApiClient.token!.isEmpty) {
      _needLogin();
      return;
    }
    if (_sending) return;
    setState(() => _sending = true);
    try {
      List<String> imgs = [];
      if (_img != null) {
        final j = await ApiClient.uploadImage(_img!.path);
        imgs = [j['name'] as String];
      }
      await ApiClient.addComment(widget.postId, text,
          images: imgs, sticker: _sticker);
      if (!mounted) return;
      setState(() {
        _ctrl.clear();
        _img = null;
        _sticker = null;
        _sending = false;
      });
      if (widget.pureInput) {
        // 纯输入弹窗：发送成功即关闭，广播让打开的列表弹窗刷新
        commentAddedBus.value += 1;
        Navigator.of(context).pop();
        return;
      }
      await _load(refresh: true);
      widget.onChanged?.call(_total > 0 ? _total : _comments.length);
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      showAppToast(context, '评论失败：$e');
    }
  }

  /// 举报（真实流程）：理由弹层 → 调后端 → 成功关闭弹层并轻提示
  Future<void> _report(String type, String id) async {
    if (ApiClient.token == null || ApiClient.token!.isEmpty) {
      showAppToast(context, '请先登录后举报');
      return;
    }
    const reasons = ['垃圾广告', '色情低俗', '人身攻击', '违法违规', '其他'];
    var submitting = false; // 提交中：锁定理由列表，防重复上报
    Object? failure; // 上报失败原因（弹层关闭后再提示，避免被弹层遮挡）
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      useSafeArea: true,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setSheetState) => SheetShell(
          title: '举报评论',
          subtitle: '请选择举报理由',
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < reasons.length; i++) ...[
                if (i > 0) const Hairline(),
                PressableScale(
                  onTap: submitting
                      ? null
                      : () async {
                          final reason = reasons[i];
                          setSheetState(() => submitting = true);
                          try {
                            await ApiClient.report(type, id, reason);
                            if (!ctx.mounted) return;
                            Navigator.of(ctx).pop(reason); // 成功后关闭弹层
                          } catch (e) {
                            failure = e;
                            if (!ctx.mounted) return;
                            Navigator.of(ctx).pop(); // 失败也关闭，提示才看得见
                          }
                        },
                  scale: 0.98,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: AppSpace.x4, vertical: AppSpace.x4),
                    child: Row(
                      children: [
                        Text(reasons[i], style: AppType.body),
                        const Spacer(),
                        const Icon(Icons.chevron_right_rounded,
                            size: 18, color: Color(AppColors.textTertiary)),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(height: AppSpace.x4),
            ],
          ),
        ),
      ),
    );
    if (!mounted) return;
    if (failure != null) {
      showAppToast(context, '举报失败：$failure');
      return;
    }
    if (picked == null) return;
    showAppToast(context, '举报已提交，我们会尽快处理');
  }

  /// 评论点赞（本地乐观切换，失败回滚；接口沿用 ApiClient.commentLike）
  Future<void> _toggleCommentLike(Map<String, dynamic> c) async {
    final cid = (c['id'] ?? '') as String;
    if (cid.isEmpty) return;
    final wasLiked = (c['liked'] ?? false) == true;
    setState(() {
      c['liked'] = !wasLiked;
      c['likeCount'] =
          ((c['likeCount'] ?? 0) as num).toInt() + (wasLiked ? -1 : 1);
    });
    try {
      await ApiClient.setCommentLike(cid, liked: !wasLiked);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        c['liked'] = wasLiked;
        c['likeCount'] =
            ((c['likeCount'] ?? 0) as num).toInt() + (wasLiked ? 1 : -1);
      });
    }
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    if (widget.pureInput) {
      // 纯输入弹窗：只有输入栏 + 表情/图片/@ 面板，无评论列表
      return SheetShell(
        showGrabber: false,
        padding: EdgeInsets.zero,
        child: InputPanelHost(
          absorbInsets: false,
          surfaceColor: const Color(AppColors.canvas),
          panel: _buildPanel(),
          inputBar: _inputBar(),
        ),
      );
    }
    final shown = _total > 0 ? _total : _comments.length;
    return SheetShell(
      title: '评论 $shown',
      subtitle: shown == 0 ? '还没有评论，来抢沙发' : '有爱评论，说点儿好听的',
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          Expanded(
            child: _loading && _comments.isEmpty
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                : _list(),
          ),
          const Hairline(),
          // 输入栏 + 面板（InputPanelHost 管理键盘/面板丝滑切换）
          _lightMode ? _lightInputBar() : _inputBar(),
        ],
      ),
    );
  }

  Widget _list() {
    if (_comments.isEmpty) {
      return const SingleChildScrollView(
        child: EmptyState(
          icon: Icons.mode_comment_outlined,
          title: '还没有评论',
          message: '说点儿好听的，来抢沙发',
          compact: true,
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(
          AppSpace.x4, AppSpace.x1, AppSpace.x4, AppSpace.x4),
      itemCount: _comments.length + 1,
      itemBuilder: (_, i) {
        if (i == _comments.length) {
          return LoadMoreFooter(
            loading: _loading,
            hasMore: _hasMore,
            endLabel: '— 没有更多评论了 —',
            onTap: () => _load(),
          );
        }
        return RepaintBoundary(child: _commentTile(_comments[i]));
      },
    );
  }

  /// 底部输入栏（预览条 + TextField + @ + 表情 + 图片 + 发送）
  Widget _inputBar() {
    return Container(
      color: const Color(AppColors.canvas),
      padding: const EdgeInsets.fromLTRB(
          AppSpace.x3, AppSpace.x2, AppSpace.x2, AppSpace.x2),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 待发预览：固定显示在输入框上方，键盘/面板切换时位置不动
          if (_sticker != null || _img != null) ...[
            _previewStrip(),
            const SizedBox(height: AppSpace.x2),
          ],
          Row(
            children: [
              Expanded(
                child: Container(
                  constraints: const BoxConstraints(minHeight: 38),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.07),
                    borderRadius: AppRadius.rPill,
                    border: Border.all(color: const Color(AppColors.border)),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: AppSpace.x3),
                  child: TextField(
                    controller: _ctrl,
                    focusNode: _focusNode,
                    onTap: () {
                      // 键盘占位：收起面板
                      if (_panel != _PanelMode.none) {
                        setState(() => _panel = _PanelMode.none);
                      }
                    },
                    style: AppType.bodySm
                        .copyWith(color: const Color(AppColors.textPrimary)),
                    cursorColor: const Color(AppColors.accent),
                    decoration: const InputDecoration(
                      hintText: '说点什么...',
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      filled: false,
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(vertical: 10),
                    ),
                  ),
                ),
              ),
              _toolIcon(Icons.alternate_email_rounded, _atFriend),
              _toolIcon(Icons.emoji_emotions_outlined,
                  () => _showPanel(_PanelMode.emoji),
                  active: _panel == _PanelMode.emoji),
              _toolIcon(Icons.image_outlined, () => _showPanel(_PanelMode.image),
                  active: _panel == _PanelMode.image),
              if (_sending)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: AppSpace.x3),
                  child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                )
              else
                PressableScale(
                  onTap: _send,
                  scale: 0.9,
                  child: Container(
                    height: 32,
                    padding:
                        const EdgeInsets.symmetric(horizontal: AppSpace.x3),
                    margin: const EdgeInsets.only(left: AppSpace.x1),
                    decoration: BoxDecoration(
                      color: const Color(AppColors.accent),
                      borderRadius: AppRadius.rPill,
                    ),
                    child: const Icon(Icons.send_rounded,
                        size: 16, color: Color(AppColors.onAccent)),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// 底部小工具图标（表情/图片/@）
  Widget _toolIcon(IconData icon, VoidCallback onTap, {bool active = false}) {
    return PressableScale(
      onTap: onTap,
      scale: 0.86,
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpace.x1, vertical: AppSpace.x1),
        child: Icon(
          icon,
          size: 21,
          color: active
              ? const Color(AppColors.accent)
              : const Color(AppColors.textSecondary),
        ),
      ),
    );
  }

  /// light 模式：列表内的「说点什么…」占位条，点击叠完整评论弹窗
  Widget _lightInputBar() {
    return PressableScale(
      onTap: () {
        // 列表弹窗保留，在其之上叠加完整抖音式评论弹窗
        showCommentSheet(context,
            postId: widget.postId, onChanged: widget.onChanged);
      },
      child: Container(
        color: const Color(AppColors.canvas),
        padding: const EdgeInsets.fromLTRB(
            AppSpace.x4, AppSpace.x3, AppSpace.x4, AppSpace.x3),
        child: Row(
          children: [
            AppAvatar(
              url: ApiClient.userId == null
                  ? null
                  : avatarUrlOf(ApiClient.userId!),
              size: 28,
              name: '我',
            ),
            const SizedBox(width: AppSpace.x2),
            Expanded(
              child: Container(
                height: 34,
                padding: const EdgeInsets.symmetric(horizontal: AppSpace.x3),
                alignment: Alignment.centerLeft,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.07),
                  borderRadius: AppRadius.rPill,
                  border: Border.all(color: const Color(AppColors.border)),
                ),
                child: Text('说点什么...', style: AppType.bodySm),
              ),
            ),
            const SizedBox(width: AppSpace.x2),
            const Icon(Icons.emoji_emotions_outlined,
                color: Color(AppColors.textTertiary), size: 20),
            const SizedBox(width: AppSpace.x3),
            const Icon(Icons.image_outlined,
                color: Color(AppColors.textTertiary), size: 20),
          ],
        ),
      ),
    );
  }

  /// 待发预览条：表情包或图片（二选一）+ 删除按钮 + 标签
  Widget _previewStrip() {
    return Row(
      children: [
        Stack(
          children: [
            ClipRRect(
              borderRadius: AppRadius.rSm,
              child: SizedBox(
                width: 60,
                height: 60,
                child: _img != null
                    ? Image.file(_img!, fit: BoxFit.cover)
                    : CachedNetworkImageCompat(
                        url: mediaUrl(_sticker ?? ''),
                        fit: BoxFit.cover,
                      ),
              ),
            ),
            Positioned(
              right: -4,
              top: -4,
              child: PressableScale(
                onTap: () => setState(() {
                  _img = null;
                  _sticker = null;
                }),
                scale: 0.9,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.6),
                    shape: BoxShape.circle,
                  ),
                  padding: const EdgeInsets.all(AppSpace.x1),
                  child: const Icon(Icons.close_rounded,
                      size: 14, color: Colors.white),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(width: AppSpace.x3),
        Text(
          _img != null ? '图片' : '表情包',
          style: AppType.caption,
        ),
      ],
    );
  }

  /// 当前面板内容（表情/图片/@好友）；none 返回 null（键盘态）
  Widget? _buildPanel() {
    switch (_panel) {
      case _PanelMode.emoji:
        return Container(
          color: const Color(AppColors.canvas),
          child: EmojiPanel(initialFav: true, onPick: _pickSticker),
        );
      case _PanelMode.image:
        return _imagePanel();
      case _PanelMode.at:
        return _atPanel();
      case _PanelMode.none:
        return null;
    }
  }

  /// @ 好友面板：收起键盘后占输入法位置，点击好友插入 @ 并回到键盘态
  Widget _atPanel() {
    return Container(
      color: const Color(AppColors.canvas),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(
                AppSpace.x4, AppSpace.x3, AppSpace.x4, AppSpace.x2),
            child: Text('@好友', style: AppType.label),
          ),
          Expanded(
            child: _atLoading
                ? const Center(
                    child: CircularProgressIndicator(strokeWidth: 2))
                : _atList.isEmpty
                    ? const Center(
                        child: Text('还没有关注的好友', style: AppType.caption),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.only(bottom: AppSpace.x2),
                        itemCount: _atList.length,
                        itemBuilder: (_, i) {
                          final u = _atList[i];
                          final name = (u['name'] ?? '用户') as String;
                          final av = (u['avatar'] ?? '') as String;
                          return PressableScale(
                            onTap: () => _pickAt(u),
                            scale: 0.98,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: AppSpace.x4,
                                  vertical: AppSpace.x2),
                              child: Row(
                                children: [
                                  AppAvatar(
                                    url: av.isEmpty ? null : avatarUrl(av),
                                    size: 34,
                                    name: name,
                                  ),
                                  const SizedBox(width: AppSpace.x3),
                                  Expanded(
                                    child: Text(name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: AppType.body),
                                  ),
                                  const Icon(Icons.north_west_rounded,
                                      size: 14,
                                      color: Color(AppColors.textTertiary)),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }

  Widget _imagePanel() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        PressableScale(
          onTap: _pickImage,
          child: Container(
            width: 84,
            height: 84,
            decoration: BoxDecoration(
              color: const Color(AppColors.elevated),
              borderRadius: AppRadius.rMd,
              border: Border.all(color: const Color(AppColors.border)),
            ),
            child: const Icon(Icons.add_photo_alternate_outlined,
                color: Color(AppColors.textSecondary), size: 30),
          ),
        ),
        const SizedBox(height: AppSpace.x3),
        const Text('选择图片（评论支持 1 张图片，与表情包二选一）',
            style: AppType.caption),
      ],
    );
  }

  Widget _commentTile(Map<String, dynamic> c) {
    final author = (c['author'] ?? const {}) as Map;
    final name = (author['name'] ?? '用户') as String;
    final avatar = (author['avatar'] ?? '') as String;
    final adminLevel = ((author['adminLevel'] ?? 0) as num).toInt();
    final adminName = (author['adminName'] ?? '') as String;
    final cid = (c['id'] ?? '') as String;
    final content = (c['content'] ?? '') as String;
    final images = (c['images'] ?? const []) as List;
    final sticker = (c['sticker'] ?? '') as String;
    final created = ((c['created'] ?? 0) as num).toInt();
    final liked = (c['liked'] ?? false) == true;
    final likeCount = ((c['likeCount'] ?? 0) as num).toInt();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpace.x3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppAvatar(
            url: avatar.isEmpty ? null : avatarUrl(avatar),
            size: 32,
            name: name,
            ring: adminLevel > 0,
          ),
          const SizedBox(width: AppSpace.x3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppType.caption.copyWith(
                            color: const Color(AppColors.textSecondary),
                            fontWeight: FontWeight.w600),
                      ),
                    ),
                    if (adminLevel > 0) ...[
                      const SizedBox(width: AppSpace.x1),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 1),
                        decoration: BoxDecoration(
                          color: const Color(AppColors.accentSoft),
                          borderRadius: AppRadius.rXs,
                        ),
                        child: Text(adminName.isEmpty ? '认证' : adminName,
                            style: AppType.micro.copyWith(
                                color: const Color(AppColors.accent),
                                height: 1.2)),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: AppSpace.x1),
                if (sticker.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: AppSpace.x1),
                    child: CachedNetworkImageCompat(
                      url: mediaUrl(sticker),
                      width: 64,
                      height: 64,
                      fit: BoxFit.contain,
                    ),
                  )
                else if (content.isNotEmpty)
                  Text(content, style: AppType.body.copyWith(height: 1.45)),
                if (images.isNotEmpty) ...[
                  const SizedBox(height: AppSpace.x2),
                  CachedNetworkImageCompat(
                    url: mediaUrl(images.first.toString()),
                    width: 140,
                    height: 140,
                    fit: BoxFit.cover,
                    borderRadius: AppRadius.sm,
                  ),
                ],
                const SizedBox(height: AppSpace.x2),
                Row(
                  children: [
                    Text(timeAgo(created), style: AppType.micro),
                    const SizedBox(width: AppSpace.x4),
                    PressableScale(
                      onTap: () => _report('comment', cid),
                      child: Text('举报', style: AppType.micro),
                    ),
                    const Spacer(),
                    // 点赞（乐观切换，失败回滚）
                    PressableScale(
                      onTap: () => _toggleCommentLike(c),
                      scale: 0.9,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            liked
                                ? Icons.favorite_rounded
                                : Icons.favorite_border_rounded,
                            size: 15,
                            color: liked
                                ? const Color(AppColors.heart)
                                : const Color(AppColors.textTertiary),
                          ),
                          if (likeCount > 0) ...[
                            const SizedBox(width: AppSpace.x1),
                            Text(
                              '$likeCount',
                              style: AppType.micro.copyWith(
                                color: liked
                                    ? const Color(AppColors.heart)
                                    : const Color(AppColors.textTertiary),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
