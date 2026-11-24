/// 应用详情：下载面板、截图画廊、评分、收藏、评论、举报与分享。
library;

import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/secure_links.dart';

import '../../api/app_market_api.dart';
import '../../api/client.dart';
import '../../design/components.dart';
import '../../design/shared_element.dart';
import '../../features/emoji/text_emoji.dart';
import '../../widgets/emoji_panel.dart';
import '../../models/app_market.dart';
import '../../services/app_download_manager.dart';
import '../../services/app_install_service.dart';
import '../../services/hot_update.dart';
import '../../utils/cover_palette.dart';
import '../../utils/share_util.dart';
import '../../widgets/image_box.dart';
import '../../widgets/user_avatar.dart';
import '../mine/login_page.dart';
import '../user/user_profile.dart';
import 'app_gallery_page.dart';
import 'app_ios_install_sheet.dart';
import 'app_share_friend_sheet.dart';
import 'app_share_sheet.dart';
import 'app_widgets.dart';

class AppDetailPage extends StatefulWidget {
  const AppDetailPage({super.key, required this.appId});

  final String appId;

  @override
  State<AppDetailPage> createState() => _AppDetailPageState();
}

class _AppDetailPageState extends State<AppDetailPage> {
  final _comment = TextEmojiEditingController();
  final _commentFocus = FocusNode();
  final _scroll = ScrollController();
  final ValueNotifier<bool> _navTitle = ValueNotifier<bool>(false);
  final ValueNotifier<double> _heroCollapse = ValueNotifier<double>(0);
  final ValueNotifier<double> _heroPull = ValueNotifier<double>(0);

  /// 应用评论后端目前只支持文字；文字混排开关关闭时不再展示表情入口，
  /// 避免用户点开面板却无法选中任何表情。
  bool get _inlineEmojiEnabled =>
      HotUpdateService.instance.config.value.inlineTextEmojiEnabled;

  MarketApp? _app;
  ValueNotifier<AppDownloadTask>? _download;

  Color? _iconColor;
  int _paletteRequest = 0;

  bool _loading = true;
  String? _error;

  double _ratingAvg = 0;
  int _ratingCount = 0;
  int _myRating = 0;
  bool _ratingBusy = false;

  bool _favorited = false;
  int _favoriteCount = 0;
  bool _favoriteBusy = false;

  int _commentCount = 0;
  List<AppComment> _comments = const [];
  bool _commentsLoading = true;
  bool _commentsLoaded = false;
  int _commentsPage = 0;
  bool _commentsHasMore = false;
  int _commentRequest = 0;

  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (!_scroll.hasClients) return;
      final offset = _scroll.offset;
      final collapse = (offset / 260).clamp(0.0, 1.0);
      final pull = (offset < 0 ? -offset / 150 : 0.0).clamp(0.0, 1.0);
      if ((collapse - _heroCollapse.value).abs() > 0.001) {
        _heroCollapse.value = collapse;
      }
      if ((pull - _heroPull.value).abs() > 0.001) _heroPull.value = pull;
      final show = offset > 232;
      if (show != _navTitle.value) _navTitle.value = show;
    });
    HotUpdateService.instance.config.addListener(_onHotConfig);
    _load();
  }

  void _onHotConfig() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    HotUpdateService.instance.config.removeListener(_onHotConfig);
    _comment.dispose();
    _commentFocus.dispose();
    _scroll.dispose();
    _navTitle.dispose();
    _heroCollapse.dispose();
    _heroPull.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _iconColor = null;
      _paletteRequest++;
    });
    try {
      final app = await AppMarketApi.detail(widget.appId);
      if (!mounted) return;
      final iconUrl = iconUrlOf(app);
      final cachedColor = CoverPalette.cached(app.id, iconUrl);
      final notifier = AppDownloadManager.I.notifierFor(app);
      setState(() {
        _app = app;
        _download = notifier;
        _iconColor = cachedColor;
        _ratingAvg = app.rating;
        _ratingCount = app.ratingCount;
        _myRating = app.myRating;
        _favorited = app.favorited;
        _favoriteCount = app.favoriteCount;
        _commentCount = app.commentCount;
        _loading = false;
      });
      if (cachedColor == null && iconUrl.isNotEmpty) {
        _loadCoverColor(app, iconUrl);
      }
      try {
        await AppDownloadManager.I.restore(app);
      } catch (_) {
        // 文件系统不可用（例如测试/受限设备）不应阻断详情展示。
      }
      _loadComments(reset: true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  void _loadCoverColor(MarketApp app, String iconUrl) {
    final request = ++_paletteRequest;
    CoverPalette.colorFor(app.id, iconUrl).then((color) {
      if (!mounted || request != _paletteRequest || _app?.id != app.id) return;
      if (color == null) return;
      setState(() => _iconColor = color);
    });
  }

  Future<void> _loadComments({bool reset = false}) async {
    final app = _app;
    if (app == null) return;
    if (!reset && (_commentsLoading || !_commentsHasMore)) return;
    final id = ++_commentRequest;
    setState(() => _commentsLoading = true);
    try {
      final data = await AppMarketApi.comments(
        app.id,
        page: reset ? 1 : _commentsPage + 1,
        pageSize: 20,
      );
      if (!mounted || id != _commentRequest) return;
      setState(() {
        if (reset) {
          _comments = const [];
          _commentsPage = 0;
        }
        _comments = [..._comments, ...data.list];
        _commentsPage = data.page;
        _commentsHasMore = data.hasMore;
        _commentCount = data.total > 0 ? data.total : _commentCount;
        _commentsLoading = false;
        _commentsLoaded = true;
      });
    } catch (_) {
      if (!mounted || id != _commentRequest) return;
      setState(() {
        _commentsLoading = false;
        _commentsLoaded = true;
        _commentsHasMore = false;
      });
    }
  }

  Future<bool> _ensureLogin() async {
    if (ApiClient.token != null && ApiClient.token!.isNotEmpty) return true;
    final ok = await Navigator.of(context)
        .push<bool>(MaterialPageRoute(builder: (_) => const LoginPage()));
    return ok == true && ApiClient.token != null;
  }

  Future<void> _toggleFavorite() async {
    if (_favoriteBusy) return;
    if (!await _ensureLogin() || !mounted) return;
    final next = !_favorited;
    setState(() {
      _favoriteBusy = true;
      _favorited = next;
      _favoriteCount = (_favoriteCount + (next ? 1 : -1)).clamp(0, 1 << 30);
    });
    try {
      final j = next
          ? await AppMarketApi.favorite(widget.appId, add: true)
          : await AppMarketApi.favorite(widget.appId, add: false);
      if (!mounted) return;
      setState(() {
        _favorited = j['favorited'] == true;
        _favoriteCount =
            (j['favoriteCount'] as num?)?.toInt() ?? _favoriteCount;
        _favoriteBusy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _favorited = !next;
        _favoriteCount = (_favoriteCount + (next ? -1 : 1)).clamp(0, 1 << 30);
        _favoriteBusy = false;
      });
      showAppToast(context, '收藏失败：$e');
    }
  }

  Future<void> _rate(int score) async {
    if (_ratingBusy) return;
    if (!await _ensureLogin() || !mounted) return;
    setState(() => _ratingBusy = true);
    try {
      final j = await AppMarketApi.rating(widget.appId, score);
      if (!mounted) return;
      setState(() {
        final wasRated = _myRating > 0;
        _myRating = score;
        _ratingAvg = (j['rating'] as num?)?.toDouble() ?? _ratingAvg;
        _ratingCount = wasRated ? _ratingCount : _ratingCount + 1;
        _ratingBusy = false;
      });
      showAppToast(context, score >= 4 ? '谢谢你的推荐' : '已记录你的评分');
    } catch (e) {
      if (!mounted) return;
      setState(() => _ratingBusy = false);
      showAppToast(context, '评分失败：$e');
    }
  }

  Future<void> _sendComment() async {
    if (_sending) return;
    final text = _comment.text.trim();
    if (text.isEmpty) return;
    if (text.length > 600) {
      showAppToast(context, '评论最多 600 个字');
      return;
    }
    if (!await _ensureLogin() || !mounted) return;
    setState(() => _sending = true);
    try {
      await AppMarketApi.addComment(widget.appId, text);
      if (!mounted) return;
      _comment.clear();
      setState(() {
        _sending = false;
        _commentCount = _commentCount + 1;
      });
      await _loadComments(reset: true);
      if (mounted) FocusScope.of(context).unfocus();
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      showAppToast(context, '评论失败：$e');
    }
  }

  Future<void> _deleteComment(AppComment c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(AppColors.card),
        title: const Text('删除这条评论？', style: AppType.title),
        content: Text('删除后无法恢复。', style: AppType.bodySm),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text(
              '删除',
              style: TextStyle(color: Color(AppColors.danger)),
            ),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await AppMarketApi.deleteComment(widget.appId, c.id);
      if (!mounted) return;
      setState(() {
        _comments = _comments.where((e) => e.id != c.id).toList();
        _commentCount = (_commentCount - 1).clamp(0, 1 << 30);
      });
    } catch (e) {
      if (!mounted) return;
      showAppToast(context, '删除失败：$e');
    }
  }

  Future<void> _report() async {
    if (!await _ensureLogin() || !mounted) return;
    final reason = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      useSafeArea: true,
      builder: (ctx) => Container(
        decoration: const BoxDecoration(
          color: Color(AppColors.canvas),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 10),
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFF313136),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
              child: Text(
                '举报这款应用',
                style: AppType.title.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text('请选择举报原因，管理员会人工核实。', style: AppType.caption),
            ),
            for (final r in const [
              '安装包无法下载或已失效',
              '涉嫌盗版、破解或侵权',
              '含有恶意代码或不安全内容',
              '介绍与实际应用不符',
              '其他问题',
            ])
              ListTile(
                title: Text(r, style: AppType.body),
                onTap: () => Navigator.of(ctx).pop(r),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
              ),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );
    if (reason == null || !mounted) return;
    try {
      await AppMarketApi.report(widget.appId, reason);
      if (mounted) showAppToast(context, '举报已提交，管理员会尽快处理');
    } catch (e) {
      if (mounted) showAppToast(context, '举报失败：$e');
    }
  }

  Future<void> _share() async {
    final app = _app;
    if (app == null) return;
    final box = context.findRenderObject() as RenderBox?;
    final origin = box != null && box.hasSize
        ? box.localToGlobal(Offset.zero) & box.size
        : null;
    final url = await resolveAppShareUrl(app.id);
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      useSafeArea: true,
      builder: (ctx) => AppShareSheet(
        app: app,
        shareUrl: url,
        task: _download?.value,
        onSystemShare: () {
          Navigator.of(ctx).pop();
          shareToSystem(
            appShareText(
              name: app.name,
              version: app.version,
              appId: app.id,
              url: url,
            ),
            subject: '流萤社区 · 应用市场',
            origin: origin,
          );
        },
        onShareFriend: () {
          Navigator.of(ctx).pop();
          _shareToFriend(app);
        },
        onShareFile: () {
          Navigator.of(ctx).pop();
          final task = _download?.value;
          if (task != null) AppDownloadManager.I.shareFile(task);
        },
      ),
    );
  }

  Future<void> _shareToFriend(MarketApp app) async {
    await showAppShareFriendSheet(context, app);
  }

  void _openGallery(int index) {
    final app = _app;
    if (app == null || app.screenshots.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AppGalleryPage(
          images: app.screenshots,
          title: app.name,
          initialIndex: index,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = _app;
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    return ImmersivePage(
      topScrim: false,
      resizeToAvoidBottomInset: true,
      child: Stack(
        children: [
          Column(
            children: [
              Expanded(child: _body()),
              if (app != null && _download != null && keyboard == 0) _dock(app),
            ],
          ),
          Positioned(top: 0, left: 0, right: 0, child: _nav(app)),
        ],
      ),
    );
  }

  Widget _nav(MarketApp? app) {
    final top = MediaQuery.paddingOf(context).top;
    return ValueListenableBuilder<bool>(
      valueListenable: _navTitle,
      builder: (_, showTitle, _) {
        return AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          padding: EdgeInsets.fromLTRB(12, top + 7, 12, 10),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withValues(alpha: showTitle ? 0.72 : 0.20),
                Colors.transparent,
              ],
            ),
          ),
          child: Row(
            children: [
              IconCircleButton(
                icon: Icons.arrow_back_ios_new_rounded,
                size: 38,
                iconSize: 17,
                background: Colors.black.withValues(alpha: 0.22),
                tooltip: '返回',
                onTap: () => Navigator.of(context).maybePop(),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: IgnorePointer(
                  child: AnimatedOpacity(
                    opacity: showTitle ? 1 : 0,
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOut,
                    child: Center(
                      child: AnimatedScale(
                        scale: showTitle ? 1 : 0.94,
                        duration: const Duration(milliseconds: 180),
                        curve: Curves.easeOut,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(AppRadius.pill),
                          child: BackdropFilter(
                            filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 11,
                                vertical: 5,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.30),
                                borderRadius: BorderRadius.circular(
                                  AppRadius.pill,
                                ),
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.10),
                                ),
                              ),
                              child: Text(
                                app?.name ?? '',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                                style: AppType.title.copyWith(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w700,
                                  color: const Color(AppColors.textPrimary),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              _navActions(app),
            ],
          ),
        );
      },
    );
  }

  Widget _navActions(MarketApp? app) {
    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconCircleButton(
            icon: _favorited
                ? Icons.bookmark_rounded
                : Icons.bookmark_border_rounded,
            size: 32,
            iconSize: 16.5,
            background: Colors.transparent,
            color: _favorited
                ? const Color(AppColors.accent)
                : const Color(AppColors.textPrimary),
            tooltip: _favorited ? '取消收藏' : '收藏',
            onTap: app == null ? null : _toggleFavorite,
          ),
          IconCircleButton(
            icon: Icons.ios_share_rounded,
            size: 32,
            iconSize: 16.5,
            background: Colors.transparent,
            tooltip: '分享',
            onTap: app == null ? null : _share,
          ),
          IconCircleButton(
            icon: Icons.more_horiz_rounded,
            size: 32,
            iconSize: 16.5,
            background: Colors.transparent,
            tooltip: '更多',
            onTap: app == null ? null : _showMore,
          ),
        ],
      ),
    );
  }

  Widget _body() {
    final app = _app;
    if (_loading) {
      return const SingleChildScrollView(
        physics: AlwaysScrollableScrollPhysics(),
        child: Padding(
          padding: EdgeInsets.only(top: 100),
          child: _DetailSkeleton(),
        ),
      );
    }
    if (app == null || _error != null) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(top: 96),
        children: [
          const SizedBox(height: 24),
          EmptyState(
            icon: Icons.cloud_off_rounded,
            title: '应用详情加载失败',
            message: _error ?? '应用可能已下架',
            actionLabel: '重新加载',
            onAction: _load,
          ),
        ],
      );
    }
    return RefreshIndicator(
      color: const Color(AppColors.accent),
      backgroundColor: const Color(AppColors.card),
      onRefresh: _load,
      child: NotificationListener<ScrollEndNotification>(
        onNotification: (n) {
          // 停在封面展开/收起的半路时，按最近端吸附，避免标题卡在半空。
          if (_scroll.hasClients) {
            final o = _scroll.offset;
            if (o > 40 && o < 240) {
              final target = o < 140 ? 0.0 : 260.0;
              _scroll
                  .animateTo(
                    target,
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeOutCubic,
                  )
                  .whenComplete(() {});
            }
          }
          return false;
        },
        child: CustomScrollView(
          controller: _scroll,
          physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics(),
          ),
          slivers: [
            SliverToBoxAdapter(
              child: AnimatedBuilder(
                animation: Listenable.merge([_heroCollapse, _heroPull]),
                builder: (_, _) {
                  final c = _heroCollapse.value;
                  final pull = _heroPull.value;
                  return Transform.translate(
                    offset: Offset(0, -6 * c),
                    child: Transform.scale(
                      scale: 1 + pull * 0.06 - c * 0.035,
                      alignment: Alignment.topCenter,
                      child: Stack(
                        children: [
                          _cover(app),
                          // 收起时压暗，让顶部导航标题浮出来；下拉时恢复透亮。
                          Positioned.fill(
                            child: IgnorePointer(
                              child: ColoredBox(
                                color: Colors.black.withValues(
                                  alpha: 0.20 * c * (1 - pull),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            SliverToBoxAdapter(
              child: _sectionHead(
                '01',
                '预览',
                trailing: app.screenshots.isEmpty
                    ? '暂无'
                    : '${app.screenshots.length} 张 · 左右滑动',
              ),
            ),
            SliverToBoxAdapter(child: _previews(app)),
            SliverToBoxAdapter(
              child: _sectionHead('02', '关于这款应用', trailing: 'ABOUT'),
            ),
            SliverToBoxAdapter(child: _about(app)),
            if (app.shareReason.trim().isNotEmpty) ...[
              SliverToBoxAdapter(
                child: _sectionHead('03', '为什么推荐它', trailing: 'NOTE'),
              ),
              SliverToBoxAdapter(child: _quote(app.shareReason, app)),
            ],
            SliverToBoxAdapter(
              child: _sectionHead('04', '应用信息', trailing: 'SPECS'),
            ),
            SliverToBoxAdapter(child: _info(app)),
            SliverToBoxAdapter(
              child: _sectionHead('05', '评分', trailing: 'RATING'),
            ),
            SliverToBoxAdapter(child: _ratingSection()),
            SliverToBoxAdapter(
              child: _sectionHead('06', '评论', trailing: '$_commentCount 条讨论'),
            ),
            SliverToBoxAdapter(child: _commentSection()),
            SliverToBoxAdapter(
              child: SizedBox(
                height: 24 + MediaQuery.paddingOf(context).bottom,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _cover(MarketApp app) {
    final platform = platformColor(app.platform);
    final iconUrl = iconUrlOf(app);
    final extracted = _iconColor;
    // 有图标但还没取完色时先用中性深色，避免先闪一版平台绿。
    final color =
        extracted ?? (iconUrl.isEmpty ? platform : const Color(0xFF45494A));
    final shades = CoverPalette.gradientShades(color);
    final pageBg = const Color(AppColors.bg);
    final hasExtracted = extracted != null;
    final initial = app.name.trim().isEmpty ? 'A' : app.name.trim()[0];
    return AnimatedContainer(
      duration: const Duration(milliseconds: 420),
      curve: Curves.easeOutCubic,
      height: 356,
      clipBehavior: Clip.hardEdge,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            shades.top.withValues(alpha: hasExtracted ? 0.62 : 0.42),
            shades.mid.withValues(alpha: hasExtracted ? 0.46 : 0.30),
            Color.lerp(shades.bottom, pageBg, hasExtracted ? 0.66 : 0.68)!,
            pageBg,
          ],
          stops: const [0, 0.30, 0.68, 1],
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            right: -16,
            top: 62,
            child: IgnorePointer(
              child: Text(
                initial,
                style: TextStyle(
                  fontSize: 156,
                  height: 0.9,
                  fontWeight: FontWeight.w900,
                  color: Colors.white.withValues(alpha: 0.045),
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(-0.55, -0.8),
                    radius: 1.1,
                    colors: [color.withValues(alpha: 0.12), Colors.transparent],
                  ),
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.62),
                      const Color(AppColors.bg),
                    ],
                    stops: const [0, 0.50, 0.82, 1],
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              AppSpace.gutter,
              MediaQuery.paddingOf(context).top + 72,
              AppSpace.gutter,
              0,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      'APP DOSSIER',
                      style: AppType.micro.copyWith(
                        fontSize: 9,
                        letterSpacing: 2.2,
                        fontWeight: FontWeight.w700,
                        color: Color.lerp(color, Colors.white, 0.18)!,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      width: 18,
                      height: 1,
                      color: Colors.white.withValues(alpha: 0.16),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '应用档案',
                      style: AppType.micro.copyWith(
                        fontSize: 9,
                        letterSpacing: 1.4,
                        color: const Color(AppColors.textTertiary),
                      ),
                    ),
                    const Spacer(),
                    if (app.featured)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(AppRadius.pill),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.12),
                          ),
                        ),
                        child: Text(
                          '编辑精选',
                          style: AppType.micro.copyWith(
                            fontSize: 9,
                            color: const Color(AppColors.textPrimary),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 17),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _appIcon(app, color),
                    const SizedBox(width: 15),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            app.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: AppType.h1.copyWith(
                              fontSize: 25,
                              height: 1.12,
                              letterSpacing: -0.7,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              PlatformBadge(app: app, compact: true),
                              if (app.category.isNotEmpty) ...[
                                const SizedBox(width: 6),
                                Flexible(
                                  child: Text(
                                    app.subCategory.isEmpty
                                        ? app.category
                                        : '${app.category} / ${app.subCategory}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: AppType.micro.copyWith(
                                      fontSize: 10,
                                      color: const Color(
                                        AppColors.textSecondary,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 9),
                          PressableScale(
                            onTap: app.author.id.isEmpty
                                ? null
                                : () => Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (_) =>
                                          UserProfilePage(uid: app.author.id),
                                    ),
                                  ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                UserAvatar(
                                  url: app.author.avatar,
                                  uid: app.author.id,
                                  name: app.author.name,
                                  size: 19,
                                  verified: app.author.verified,
                                  verifiedLabel: app.author.verifiedLabel,
                                  isAi: app.author.isAi,
                                  borderColor: Colors.white.withValues(
                                    alpha: 0.18,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Flexible(
                                  child: Text(
                                    '由 ${app.author.name} 投稿',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: AppType.micro.copyWith(
                                      fontSize: 10.5,
                                      color: const Color(
                                        AppColors.textSecondary,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const Spacer(),
                _coverStats(app),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _appIcon(MarketApp app, Color color) {
    return Container(
      padding: const EdgeInsets.all(9),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [color.withValues(alpha: 0.26), color.withValues(alpha: 0)],
        ),
      ),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: 0.26),
              blurRadius: 30,
              offset: const Offset(0, 10),
            ),
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.24),
              blurRadius: 16,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: AppIconTile(
          app: app,
          size: 88,
          radius: 22,
          heroTag: SharedElementTags.appIcon(app.id),
        ),
      ),
    );
  }

  Widget _coverStats(MarketApp app) {
    final rating = _ratingCount > 0 ? _ratingAvg.toStringAsFixed(1) : '—';
    final stats = [
      ('社区评分', rating),
      ('下载', formatCount(app.downloadCount)),
      ('收藏', formatCount(_favoriteCount)),
      ('评论', formatCount(_commentCount)),
    ];
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 15),
      child: Row(
        children: [
          for (var i = 0; i < stats.length; i++) ...[
            if (i > 0)
              Container(
                width: 1,
                height: 24,
                color: Colors.white.withValues(alpha: 0.08),
              ),
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(left: i == 0 ? 0 : 13),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      stats[i].$2,
                      style: const TextStyle(
                        fontSize: 18,
                        height: 1.1,
                        fontWeight: FontWeight.w700,
                        color: Color(AppColors.textPrimary),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      stats[i].$1,
                      style: AppType.micro.copyWith(
                        fontSize: 9,
                        letterSpacing: 1.2,
                        color: const Color(AppColors.textTertiary),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _sectionHead(String index, String title, {String? trailing}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.gutter,
        AppSpace.x7,
        AppSpace.gutter,
        AppSpace.x3,
      ),
      child: Row(
        children: [
          Text(
            index,
            style: AppType.micro.copyWith(
              fontSize: 9.5,
              letterSpacing: 1.4,
              fontWeight: FontWeight.w700,
              color: const Color(AppColors.accent),
            ),
          ),
          const SizedBox(width: 9),
          Text(
            title,
            style: AppType.micro.copyWith(
              fontSize: 10.5,
              letterSpacing: 1.6,
              fontWeight: FontWeight.w700,
              color: const Color(AppColors.textSecondary),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Divider(
              height: 1,
              thickness: 1,
              color: Colors.white.withValues(alpha: 0.07),
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 9),
            Text(
              trailing,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppType.micro.copyWith(
                fontSize: 9,
                color: const Color(AppColors.textTertiary),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _previews(MarketApp app) {
    if (app.screenshots.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.gutter),
        child: Container(
          height: 96,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          child: Text(
            '投稿者没有上传截图',
            style: AppType.caption.copyWith(fontSize: 11.5),
          ),
        ),
      );
    }
    return SizedBox(
      height: 286,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.gutter),
        itemCount: app.screenshots.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, i) {
          return PressableScale(
            onTap: () => _openGallery(i),
            child: Container(
              width: 162,
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: const Color(AppColors.card),
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _shotImage(app.screenshots[i]),
                    Positioned(
                      left: 8,
                      bottom: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.52),
                          borderRadius: BorderRadius.circular(AppRadius.pill),
                        ),
                        child: Text(
                          '${(i + 1).toString().padLeft(2, '0')}'
                          ' / ${app.screenshots.length.toString().padLeft(2, '0')}',
                          style: AppType.micro.copyWith(
                            fontSize: 8,
                            letterSpacing: 0.6,
                            color: Colors.white.withValues(alpha: 0.8),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _about(MarketApp app) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.gutter),
      child: Text(
        app.description.isEmpty ? '投稿者没有填写应用介绍。' : app.description,
        style: AppType.body.copyWith(
          fontSize: 15,
          height: 1.82,
          color: const Color(AppColors.textSecondary),
        ),
      ),
    );
  }

  Widget _dock(MarketApp app) {
    if (app.isStore) return _storeDock(app);
    if (app.platform.toLowerCase() == 'harmony' &&
        app.packageType.toLowerCase() == 'app') {
      return _harmonyDock(app);
    }
    final notifier = _download;
    if (notifier == null) return const SizedBox.shrink();
    if (AppInstallService.canOtaInstall(app)) {
      return _iosDock(app, notifier);
    }
    return ValueListenableBuilder<AppDownloadTask>(
      valueListenable: notifier,
      builder: (context, task, _) {
        final active =
            task.status == AppDownloadStatus.downloading ||
            task.status == AppDownloadStatus.resolving;
        final showBar =
            active ||
            task.status == AppDownloadStatus.paused ||
            task.status == AppDownloadStatus.completed;
        final percent = task.totalBytes > 0
            ? '${(task.progress * 100).round()}%'
            : humanBytes(task.receivedBytes);
        final caption = switch (task.status) {
          AppDownloadStatus.idle =>
            '${app.platformLabel} · ${app.packageLabel}',
          AppDownloadStatus.resolving => '正在解析下载地址…',
          AppDownloadStatus.downloading => '下载中 $percent',
          AppDownloadStatus.paused => '已暂停 $percent',
          AppDownloadStatus.completed =>
            '已下载 ${humanBytes(task.receivedBytes)}',
          AppDownloadStatus.failed => '下载未完成，可重试',
          AppDownloadStatus.installing => '已交给 iOS 系统安装',
        };
        final title = switch (task.status) {
          AppDownloadStatus.idle => '准备安装',
          AppDownloadStatus.resolving => '获取安装包',
          AppDownloadStatus.downloading => '正在下载',
          AppDownloadStatus.paused => '已暂停',
          AppDownloadStatus.completed => '安装包已就绪',
          AppDownloadStatus.failed => '下载未完成',
          AppDownloadStatus.installing => '等待系统安装',
        };
        final label = switch (task.status) {
          AppDownloadStatus.idle => '下载安装包',
          AppDownloadStatus.resolving => '解析中…',
          AppDownloadStatus.downloading => '暂停下载',
          AppDownloadStatus.paused => '继续下载',
          AppDownloadStatus.completed =>
            app.packageType.toLowerCase() == 'apk' ? '安装应用' : '打开文件',
          AppDownloadStatus.failed => '重试下载',
          AppDownloadStatus.installing => '重新安装',
        };
        final icon = switch (task.status) {
          AppDownloadStatus.idle => Icons.download_rounded,
          AppDownloadStatus.resolving => Icons.hourglass_top_rounded,
          AppDownloadStatus.downloading => Icons.pause_rounded,
          AppDownloadStatus.paused => Icons.play_arrow_rounded,
          AppDownloadStatus.completed => Icons.open_in_new_rounded,
          AppDownloadStatus.failed => Icons.refresh_rounded,
          AppDownloadStatus.installing => Icons.system_update_alt_rounded,
        };
        return Container(
          decoration: BoxDecoration(
            color: const Color(AppColors.bg).withValues(alpha: 0.98),
            border: Border(
              top: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
            ),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (showBar) ...[
                    Row(
                      children: [
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(2),
                            child: LinearProgressIndicator(
                              minHeight: 3,
                              value: task.status == AppDownloadStatus.completed
                                  ? 1
                                  : task.totalBytes > 0
                                  ? task.progress
                                  : null,
                              backgroundColor: Colors.white.withValues(
                                alpha: 0.07,
                              ),
                              valueColor: const AlwaysStoppedAnimation(
                                Color(AppColors.accent),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          task.status == AppDownloadStatus.completed
                              ? '100%'
                              : percent,
                          style: AppType.micro.copyWith(
                            fontSize: 9.5,
                            color: const Color(AppColors.textTertiary),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 9),
                  ],
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppType.title.copyWith(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              caption,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppType.micro.copyWith(
                                fontSize: 9.5,
                                color: task.status == AppDownloadStatus.failed
                                    ? const Color(AppColors.danger)
                                    : const Color(AppColors.textTertiary),
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (task.status == AppDownloadStatus.downloading ||
                          task.status == AppDownloadStatus.paused ||
                          task.status == AppDownloadStatus.failed) ...[
                        IconCircleButton(
                          icon: Icons.close_rounded,
                          size: 32,
                          iconSize: 15,
                          tooltip: '取消下载',
                          onTap: () => _confirmCancelDownload(app),
                        ),
                        const SizedBox(width: 8),
                      ],
                      if (task.status == AppDownloadStatus.completed) ...[
                        IconCircleButton(
                          icon: Icons.ios_share_rounded,
                          size: 32,
                          iconSize: 15,
                          tooltip: '分享安装包',
                          onTap: () => AppDownloadManager.I.shareFile(task),
                        ),
                        const SizedBox(width: 8),
                      ],
                      SizedBox(
                        width: 154,
                        child: PillButton(
                          label: label,
                          size: PillSize.md,
                          icon: icon,
                          expand: true,
                          glow: task.status == AppDownloadStatus.idle,
                          loading: task.status == AppDownloadStatus.resolving,
                          enabled: task.status != AppDownloadStatus.resolving,
                          onTap: switch (task.status) {
                            AppDownloadStatus.idle ||
                            AppDownloadStatus.paused ||
                            AppDownloadStatus.failed =>
                              () => AppDownloadManager.I.start(app),
                            AppDownloadStatus.downloading =>
                              () => AppDownloadManager.I.pause(app.id),
                            AppDownloadStatus.completed => () => _openDownload(
                              task,
                            ),
                            AppDownloadStatus.resolving => null,
                            AppDownloadStatus.installing =>
                              () => _showIosInstall(app),
                          },
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 商店型应用（iOS App Store / Windows 商店）：只给一个前往商店的入口。
  Widget _storeDock(MarketApp app) {
    final isIos = app.platform.toLowerCase() == 'ios';
    final label = app.storeLabel;
    return Container(
      decoration: BoxDecoration(
        color: const Color(AppColors.bg).withValues(alpha: 0.98),
        border: Border(
          top: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.storefront_rounded,
                    size: 18,
                    color: Color(AppColors.accent),
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      '$label 应用',
                      style: AppType.title.copyWith(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Text(
                    app.platformLabel,
                    style: AppType.micro.copyWith(fontSize: 10),
                  ),
                ],
              ),
              const SizedBox(height: 9),
              PillButton(
                label: '前往 $label',
                size: PillSize.lg,
                icon: Icons.open_in_new_rounded,
                expand: true,
                glow: true,
                onTap: () => unawaited(_openStore(app)),
              ),
              const SizedBox(height: 7),
              Text(
                isIos
                    ? '将在 App Store 打开 · 由 Apple 提供下载、更新与内购'
                    : '将在 $label 打开 · 由商店提供下载与更新',
                textAlign: TextAlign.center,
                style: AppType.micro.copyWith(fontSize: 9.5, height: 1.5),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openStore(MarketApp app) async {
    final uri = _storeUri(app);
    if (uri == null) {
      if (mounted) showAppToast(context, '这个应用还没有配置有效的商店链接');
      return;
    }
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok && mounted) {
        showAppToast(context, '无法打开 ${app.storeLabel}，请稍后重试');
      }
    } catch (_) {
      if (mounted) showAppToast(context, '无法打开 ${app.storeLabel}，请稍后重试');
    }
  }

  Uri? _storeUri(MarketApp app) {
    final raw = app.storeUrl.trim();
    final fallback = app.platform.toLowerCase() == 'ios'
        ? 'https://apps.apple.com/cn/search?term=${Uri.encodeComponent(app.name)}'
        : '';
    final candidate = raw.isEmpty ? fallback : raw;
    if (candidate.isEmpty) return null;
    // 商店地址只接受 HTTPS，阻断 http 明文、userinfo 与自定义 scheme。
    return SecureLinks.httpsUri(candidate);
  }

  /// iOS 专用底栏：主按钮永远是“安装”，下载 IPA 只是备选。
  Widget _harmonyDock(MarketApp app) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(AppColors.bg).withValues(alpha: 0.98),
        border: Border(
          top: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.apps_rounded,
                    size: 18,
                    color: Color(AppColors.accent),
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      '鸿蒙原生应用',
                      style: AppType.title.copyWith(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Text('APP', style: AppType.micro.copyWith(fontSize: 10)),
                ],
              ),
              const SizedBox(height: 9),
              PillButton(
                label: '打开华为应用市场',
                size: PillSize.lg,
                icon: Icons.open_in_new_rounded,
                expand: true,
                glow: true,
                onTap: () => unawaited(_openHarmony(app)),
              ),
              const SizedBox(height: 7),
              Text(
                '跳转华为应用市场获取官方安装包 · 需在鸿蒙设备上打开',
                textAlign: TextAlign.center,
                style: AppType.micro.copyWith(fontSize: 9.5, height: 1.5),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openHarmony(MarketApp app) async {
    final raw = app.downloadUrl.trim();
    final fallback =
        'https://appgallery.huawei.com/search/${Uri.encodeComponent(app.packageName)}';
    // 鸿蒙条目只允许华为应用市场域名，避免投稿者用自定义 scheme 拉起任意 App。
    final uri = SecureLinks.httpsUri(
      raw.isEmpty ? fallback : raw,
      allowedHosts: const {'appgallery.huawei.com'},
    );
    if (uri == null) {
      if (mounted) showAppToast(context, '这个应用的市场链接不在华为官方域名，已阻断');
      return;
    }
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok && mounted) {
        showAppToast(context, '无法打开应用市场，请手动搜索“${app.name}”');
      }
    } catch (_) {
      if (mounted) showAppToast(context, '无法打开应用市场，请手动搜索“${app.name}”');
    }
  }

  Widget _iosDock(MarketApp app, ValueNotifier<AppDownloadTask> notifier) {
    return ValueListenableBuilder<AppDownloadTask>(
      valueListenable: notifier,
      builder: (context, task, _) {
        final downloading = task.status == AppDownloadStatus.downloading;
        final paused = task.status == AppDownloadStatus.paused;
        final installing = task.status == AppDownloadStatus.installing;
        final completed = task.status == AppDownloadStatus.completed;
        final percent = task.totalBytes > 0
            ? '${(task.progress * 100).round()}%'
            : humanBytes(task.receivedBytes);
        final caption = switch (task.status) {
          AppDownloadStatus.installing => '已发送给系统 · 回桌面查看进度，无法安装=包未签名',
          AppDownloadStatus.downloading => '下载中 $percent · 也可直接系统安装',
          AppDownloadStatus.paused => '已暂停 $percent · 可继续或直接安装',
          AppDownloadStatus.resolving => '正在获取下载地址…',
          AppDownloadStatus.completed =>
            'IPA 已就绪 ${humanBytes(task.receivedBytes)} · 可分享',
          AppDownloadStatus.failed =>
            task.error.isEmpty ? '下载未完成，可重试' : task.error,
          AppDownloadStatus.idle => 'iOS · IPA · 由系统接管安装',
        };
        final title = switch (task.status) {
          AppDownloadStatus.installing => '已交给系统安装',
          AppDownloadStatus.downloading => '正在下载 IPA',
          AppDownloadStatus.paused => '下载已暂停',
          AppDownloadStatus.resolving => '获取安装包',
          AppDownloadStatus.completed => '安装包已就绪',
          AppDownloadStatus.failed => '下载未完成',
          AppDownloadStatus.idle => '安装到 iPhone',
        };
        final label = switch (task.status) {
          AppDownloadStatus.installing => '重新安装',
          AppDownloadStatus.downloading => '暂停下载',
          AppDownloadStatus.paused => '继续下载',
          AppDownloadStatus.resolving => '解析中…',
          AppDownloadStatus.completed => '再次安装',
          AppDownloadStatus.failed => '重试下载',
          AppDownloadStatus.idle => '安装应用',
        };
        final icon = switch (task.status) {
          AppDownloadStatus.installing => Icons.system_update_alt_rounded,
          AppDownloadStatus.downloading => Icons.pause_rounded,
          AppDownloadStatus.paused => Icons.play_arrow_rounded,
          AppDownloadStatus.resolving => Icons.hourglass_top_rounded,
          AppDownloadStatus.completed => Icons.system_update_alt_rounded,
          AppDownloadStatus.failed => Icons.refresh_rounded,
          AppDownloadStatus.idle => Icons.system_update_alt_rounded,
        };
        final VoidCallback? onTap = switch (task.status) {
          AppDownloadStatus.downloading => () => AppDownloadManager.I.pause(
            app.id,
          ),
          AppDownloadStatus.paused ||
          AppDownloadStatus.failed => () => AppDownloadManager.I.start(app),
          AppDownloadStatus.resolving => null,
          _ => () => _showIosInstall(app),
        };
        return Container(
          decoration: BoxDecoration(
            color: const Color(AppColors.bg).withValues(alpha: 0.98),
            border: Border(
              top: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
            ),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (downloading || paused || completed) ...[
                    Row(
                      children: [
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(2),
                            child: LinearProgressIndicator(
                              minHeight: 3,
                              value: completed
                                  ? 1
                                  : task.totalBytes > 0
                                  ? task.progress
                                  : null,
                              backgroundColor: Colors.white.withValues(
                                alpha: 0.07,
                              ),
                              valueColor: const AlwaysStoppedAnimation(
                                Color(AppColors.accent),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          completed ? '100%' : percent,
                          style: AppType.micro.copyWith(
                            fontSize: 9.5,
                            color: const Color(AppColors.textTertiary),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 9),
                  ],
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text(
                                  title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppType.title.copyWith(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                if (installing) ...[
                                  const SizedBox(width: 6),
                                  Container(
                                    width: 5,
                                    height: 5,
                                    decoration: const BoxDecoration(
                                      color: Color(AppColors.accent),
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            const SizedBox(height: 2),
                            Text(
                              caption,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppType.micro.copyWith(
                                fontSize: 9.5,
                                color: task.status == AppDownloadStatus.failed
                                    ? const Color(AppColors.danger)
                                    : const Color(AppColors.textTertiary),
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (completed) ...[
                        IconCircleButton(
                          icon: Icons.ios_share_rounded,
                          size: 32,
                          iconSize: 15,
                          tooltip: '分享安装包',
                          onTap: () => AppDownloadManager.I.shareFile(task),
                        ),
                        const SizedBox(width: 8),
                      ],
                      SizedBox(
                        width: 150,
                        child: PillButton(
                          label: label,
                          size: PillSize.md,
                          icon: icon,
                          expand: true,
                          glow: task.status == AppDownloadStatus.idle,
                          loading: task.status == AppDownloadStatus.resolving,
                          enabled: task.status != AppDownloadStatus.resolving,
                          onTap: onTap,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _showIosInstall(MarketApp app) async {
    final outcome = await showAppIosInstallSheet(context, app);
    if (!mounted || outcome == null) return;
    if (outcome == AppIosInstallOutcome.installed) {
      AppDownloadManager.I.markInstalling(app);
      showAppToast(context, '已向 iOS 发送安装请求，请回到桌面查看进度');
    } else {
      await AppDownloadManager.I.start(app);
    }
  }

  Future<void> _openDownload(AppDownloadTask task) async {
    final message = await AppDownloadManager.I.openFile(task);
    if (message != null && mounted) showAppToast(context, message);
  }

  Future<void> _confirmCancelDownload(MarketApp app) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(AppColors.card),
        title: const Text('删除下载缓存？', style: AppType.title),
        content: Text('已下载的临时文件会被删除，之后需要重新开始。', style: AppType.bodySm),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('保留'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text(
              '删除',
              style: TextStyle(color: Color(AppColors.danger)),
            ),
          ),
        ],
      ),
    );
    if (confirmed == true) await AppDownloadManager.I.cancel(app.id);
  }

  Widget _shotImage(String path) {
    final url = AppMarketApi.mediaPathToUrl(path);
    return Container(
      color: const Color(AppColors.card),
      child: CachedNetworkImageCompat(
        url: url,
        fit: BoxFit.cover,
        memCacheWidth: 1080,
        placeholder: const Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 1.8,
              color: Color(AppColors.textTertiary),
            ),
          ),
        ),
        errorWidget: const ImagePlaceholder(
          icon: Icons.broken_image_outlined,
          radius: 0,
        ),
      ),
    );
  }

  Widget _quote(String text, MarketApp app) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.gutter),
      child: Container(
        padding: const EdgeInsets.fromLTRB(15, 2, 0, 2),
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              color: const Color(AppColors.accent).withValues(alpha: 0.62),
              width: 2,
            ),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '“',
              style: TextStyle(
                fontSize: 26,
                height: 0.8,
                fontWeight: FontWeight.w700,
                color: const Color(AppColors.accent).withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              text,
              style: AppType.body.copyWith(
                fontSize: 16,
                height: 1.8,
                color: const Color(AppColors.textPrimary),
              ),
            ),
            const SizedBox(height: 13),
            Row(
              children: [
                UserAvatar(
                  url: app.author.avatar,
                  uid: app.author.id,
                  name: app.author.name,
                  size: 21,
                  verified: app.author.verified,
                  verifiedLabel: app.author.verifiedLabel,
                  isAi: app.author.isAi,
                  borderColor: Colors.white.withValues(alpha: 0.16),
                ),
                const SizedBox(width: 7),
                Text(
                  '投稿者 · ${app.author.name}',
                  style: AppType.micro.copyWith(
                    fontSize: 10,
                    color: const Color(AppColors.textTertiary),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _info(MarketApp app) {
    final rows = <(String, String)>[
      ('应用名称', app.name),
      ('版本号', app.version.isEmpty ? '未填写' : app.version),
      ('安装包', app.packageLabel),
      ('包名 / 标识', app.packageName.isEmpty ? '未填写' : app.packageName),
      ('兼容版本', app.osVersion.isEmpty ? '未填写' : app.osVersion),
      (
        '分类',
        app.category.isEmpty ? '未分类' : '${app.category} / ${app.subCategory}',
      ),
      ('投稿者', app.author.name),
      if (app.publishedAt > 0)
        (
          '上架时间',
          DateTime.fromMillisecondsSinceEpoch(app.publishedAt * 1000)
              .toString()
              .split(' ')
              .first,
        ),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.gutter),
      child: Column(
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 11),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 92,
                    child: Text(
                      rows[i].$1,
                      style: AppType.micro.copyWith(
                        fontSize: 10.5,
                        color: const Color(AppColors.textTertiary),
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      rows[i].$2,
                      textAlign: TextAlign.right,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.bodySm.copyWith(
                        fontSize: 12.5,
                        color: const Color(AppColors.textSecondary),
                        height: 1.45,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (i != rows.length - 1)
              Divider(
                height: 1,
                thickness: 1,
                color: Colors.white.withValues(alpha: 0.055),
              ),
          ],
        ],
      ),
    );
  }

  Widget _ratingSection() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.gutter),
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _ratingCount > 0 ? _ratingAvg.toStringAsFixed(1) : '—',
                    style: const TextStyle(
                      fontSize: 46,
                      height: 0.92,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -2,
                      color: Color(AppColors.textPrimary),
                    ),
                  ),
                  const SizedBox(height: 8),
                  RatingStars(value: _ratingAvg, size: 15),
                  const SizedBox(height: 5),
                  Text(
                    _ratingCount > 0 ? '$_ratingCount 人评分' : '还没有人评分',
                    style: AppType.micro.copyWith(
                      fontSize: 9.5,
                      color: const Color(AppColors.textTertiary),
                    ),
                  ),
                ],
              ),
              const Spacer(),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    _myRating > 0 ? '你已评分 $_myRating 星' : '点击星星为它评分',
                    style: AppType.micro.copyWith(
                      fontSize: 10.5,
                      color: const Color(AppColors.textSecondary),
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (_ratingBusy)
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.8,
                        color: Color(AppColors.accent),
                      ),
                    )
                  else
                    RatingStars(
                      value: _myRating.toDouble(),
                      size: 25,
                      onChanged: _rate,
                    ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          Divider(
            height: 1,
            thickness: 1,
            color: Colors.white.withValues(alpha: 0.07),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              const Icon(
                Icons.shield_outlined,
                size: 13,
                color: Color(AppColors.textTertiary),
              ),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  '评分来自社区真实使用者，安装前请核对包名与版本。',
                  style: AppType.micro.copyWith(
                    fontSize: 9.5,
                    height: 1.5,
                    color: const Color(AppColors.textTertiary),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _commentSection() {
    if (!_commentsLoaded) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: AppSpace.gutter),
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(20),
            child: CircularProgressIndicator(
              strokeWidth: 1.8,
              color: Color(AppColors.textTertiary),
            ),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.gutter),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _commentComposer(),
          if (_comments.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 30),
              child: Center(
                child: Text('还没有评论，来说点使用感受吧', style: AppType.caption),
              ),
            )
          else ...[
            const SizedBox(height: 8),
            for (var i = 0; i < _comments.length; i++) ...[
              _commentRow(_comments[i]),
              if (i != _comments.length - 1)
                Divider(
                  height: 1,
                  thickness: 1,
                  color: Colors.white.withValues(alpha: 0.055),
                ),
            ],
          ],
          if (_commentsHasMore)
            Padding(
              padding: const EdgeInsets.only(top: AppSpace.x3),
              child: Center(
                child: PillButton(
                  label: _commentsLoading ? '加载中…' : '加载更多评论',
                  size: PillSize.sm,
                  variant: PillVariant.ghost,
                  loading: _commentsLoading,
                  onTap: _commentsLoading ? null : () => _loadComments(),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _pickCommentEmoji() async {
    if (!_inlineEmojiEnabled) return;
    final e = await showEmojiPanel(context);
    final code = (e?['textCode'] ?? '').toString();
    if (code.isEmpty || !kTextEmojiByCode.containsKey(code)) return;
    _comment.insertEmojiCode(code);
    setState(() {});
  }

  Widget _commentComposer() {
    return Container(
      padding: const EdgeInsets.fromLTRB(0, 2, 0, 8),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: _comment,
              focusNode: _commentFocus,
              minLines: 1,
              maxLines: 4,
              maxLength: 600,
              cursorColor: const Color(AppColors.accent),
              style: AppType.bodySm.copyWith(fontSize: 12.5, height: 1.4),
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: '说说你的使用感受…',
                hintStyle: AppType.bodySm.copyWith(
                  color: const Color(AppColors.textTertiary),
                  fontSize: 12.5,
                ),
                border: InputBorder.none,
                isDense: true,
                counterText: '',
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 2,
                  vertical: 9,
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),
          if (_inlineEmojiEnabled) ...[
            IconButton(
              onPressed: _pickCommentEmoji,
              icon: const Icon(
                Icons.emoji_emotions_outlined,
                size: 20,
                color: Color(AppColors.textTertiary),
              ),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              tooltip: '插入流萤表情',
            ),
            const SizedBox(width: 4),
          ],
          PillButton(
            label: '发送',
            size: PillSize.sm,
            loading: _sending,
            enabled: !_sending && _comment.text.trim().isNotEmpty,
            onTap: _sendComment,
          ),
        ],
      ),
    );
  }

  Widget _commentRow(AppComment c) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 14, 4, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PressableScale(
            onTap: c.author.id.isEmpty
                ? null
                : () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => UserProfilePage(uid: c.author.id),
                    ),
                  ),
            child: UserAvatar(
              url: c.author.avatar,
              uid: c.author.id,
              name: c.author.name,
              size: 30,
              verified: c.author.verified,
              verifiedLabel: c.author.verifiedLabel,
              isAi: c.author.isAi,
              borderColor: const Color(AppColors.hairline),
            ),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        c.author.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppType.micro.copyWith(
                          fontSize: 11,
                          color: const Color(AppColors.textSecondary),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Text(
                      c.timeText,
                      style: AppType.micro.copyWith(fontSize: 9.5),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                TextEmojiText(
                  c.content,
                  style: AppType.bodySm.copyWith(
                    fontSize: 12.5,
                    height: 1.55,
                    color: const Color(AppColors.textPrimary),
                  ),
                ),
              ],
            ),
          ),
          if (ApiClient.userId != null && ApiClient.userId == c.author.id)
            GestureDetector(
              onTap: () => _deleteComment(c),
              child: const Padding(
                padding: EdgeInsets.only(left: 4, top: 2),
                child: Icon(
                  Icons.close_rounded,
                  size: 15,
                  color: Color(AppColors.textTertiary),
                ),
              ),
            )
          else
            const SizedBox(width: 4),
        ],
      ),
    );
  }

  void _showMore() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      useSafeArea: true,
      builder: (ctx) => Container(
        decoration: const BoxDecoration(
          color: Color(AppColors.canvas),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: const Color(0xFF313136),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.ios_share_rounded),
              title: Text('分享应用', style: AppType.body),
              onTap: () {
                Navigator.of(ctx).pop();
                _share();
              },
            ),
            ListTile(
              leading: const Icon(Icons.flag_outlined),
              title: Text('举报应用', style: AppType.body),
              onTap: () {
                Navigator.of(ctx).pop();
                _report();
              },
            ),
            ListTile(
              leading: const Icon(Icons.bookmark_border_rounded),
              title: Text('收藏应用', style: AppType.body),
              onTap: () {
                Navigator.of(ctx).pop();
                _toggleFavorite();
              },
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}

class _DetailSkeleton extends StatelessWidget {
  const _DetailSkeleton();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.gutter,
        AppSpace.x3,
        AppSpace.gutter,
        30,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 168,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(AppColors.card).withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(AppRadius.lg),
              border: Border.all(color: const Color(AppColors.hairline)),
            ),
            child: const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SkeletonBox(width: 88, height: 88, radius: AppRadius.lg),
                SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SkeletonBox(width: 170, height: 20),
                      SizedBox(height: 10),
                      SkeletonBox(width: 120, height: 11),
                      SizedBox(height: 12),
                      SkeletonBox(width: 90, height: 16),
                      Spacer(),
                      SkeletonBox(width: 210, height: 10),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Container(
            height: 96,
            decoration: BoxDecoration(
              color: const Color(AppColors.card).withValues(alpha: 0.42),
              borderRadius: BorderRadius.circular(AppRadius.lg),
              border: Border.all(color: const Color(AppColors.hairline)),
            ),
            child: const Padding(
              padding: EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SkeletonBox(width: 110, height: 13),
                  SizedBox(height: 14),
                  SkeletonBox(height: 3),
                  SizedBox(height: 10),
                  SkeletonBox(width: 180, height: 10),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          const Row(
            children: [
              SkeletonBox(width: 70, height: 15),
              Spacer(),
              SkeletonBox(width: 90, height: 11),
            ],
          ),
          const SizedBox(height: 12),
          const SizedBox(
            height: 190,
            child: Row(
              children: [
                Expanded(child: SkeletonBox(height: 190, radius: AppRadius.md)),
                SizedBox(width: 8),
                Expanded(child: SkeletonBox(height: 190, radius: AppRadius.md)),
                SizedBox(width: 8),
                Expanded(child: SkeletonBox(height: 190, radius: AppRadius.md)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
