/// 我的页（P0）：登录互通 + 等级进度 + 签到 + 个性装扮（头像框）+ 任务
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../api/client.dart';
import '../../config.dart';
import '../../design/components.dart';
import '../../models/feed_item.dart';
import '../../services/notify_bus.dart';
import '../../widgets/post_card.dart';
import '../post/post_detail.dart';
import '../post/post_editor.dart';
import '../settings/settings_page.dart';
import '../game/petalwake_page.dart';
import '../feedback/feedback_page.dart';
import 'audit_page.dart';
import 'edit_profile_page.dart';
import 'login_page.dart';
import 'user_list_page.dart';

class MinePage extends StatefulWidget {
  const MinePage({super.key});

  @override
  State<MinePage> createState() => _MinePageState();
}

class _MinePageState extends State<MinePage> {
  Map<String, dynamic>? _me;
  String? _name;
  String? _avatar;
  bool _loading = true;
  Map<String, dynamic> _level = {};
  List<String> _signins = [];
  bool _signing = false;
  String _myFrame = '';
  // A2 作品 Tab：帖子 / 收藏 / 稍后看
  int _tab = 0;
  final List<FeedItem> _mine = [];
  final List<FeedItem> _favs = [];
  final List<FeedItem> _laters = [];
  bool _mineLoading = false;
  bool _mineHasMore = true;
  bool _favLoading = false;
  bool _laterLoading = false;
  bool _favLoaded = false;
  bool _laterLoaded = false;
  int _minePage = 0;
  int _postCount = 0;
  bool _mineLoaded = false;

  /// 我的帖子（帖子 Tab 数据 + 帖子统计数）
  Future<void> _loadMine({bool refresh = false}) async {
    if (_mineLoading || (!_mineHasMore && !refresh)) return;
    final uid = ApiClient.userId;
    if (uid == null) return;
    final countNeeded = !_mineLoaded;
    setState(() => _mineLoading = true);
    try {
      // 注意：后端 type 是字面过滤（text/video/poll），传 'all' 会查不到任何数据，
      // 因此这里不传 type —— 表示「全部作品」。
      final j = await ApiClient.get('/user/$uid/posts', query: {
        'page': '${refresh ? 1 : _minePage + 1}',
        'size': '10',
      });
      if (!mounted) return;
      final list = ((j['list'] ?? []) as List)
          .whereType<Map<String, dynamic>>()
          .map(FeedItem.fromJson)
          .toList();
      setState(() {
        if (refresh) {
          _mine.clear();
          _minePage = 0;
        }
        _minePage++;
        _mineHasMore = boolOf(j['hasMore']);
        _mine.addAll(list);
        _mineLoading = false;
        _mineLoaded = true;
      });
      // 首次加载时统计真实作品总数（接口只返回分页 list / hasMore，无 total）
      if (refresh && countNeeded) await _syncPostCount(uid);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _mineLoading = false;
        _mineLoaded = true;
      });
    }
  }

  /// 作品总数：`/user/{uid}/posts` 只有分页 list + hasMore（无 total 字段），
  /// 首次加载时按 hasMore 逐页累加（每页 50、最多 20 页），避免「作品」只显示单页条数。
  /// 注：不传 type，按全部类型（图文/短视频）统计总数。
  Future<void> _syncPostCount(String uid) async {
    var total = 0;
    try {
      for (var page = 1; page <= 20; page++) {
        final j = await ApiClient.get('/user/$uid/posts', query: {
          'page': '$page',
          'size': '50',
        });
        final rows = (j['list'] ?? []) as List;
        total += rows.length;
        if (!boolOf(j['hasMore']) || rows.isEmpty) break;
      }
      if (!mounted) return;
      setState(() => _postCount = total);
    } catch (_) {
      // 统计失败时退回已加载条数，不影响作品列表展示
      if (!mounted) return;
      setState(() => _postCount = _mine.length);
    }
  }

  /// 收藏 / 稍后看（Tab 数据）
  Future<void> _loadFav({required bool later, bool refresh = false}) async {
    if (refresh || (!(later ? _laterLoading : _favLoading) &&
        (later ? _laters : _favs).isEmpty)) {
      // 首载或刷新
    }
    if (refresh == false && (later ? _laterLoading : _favLoading)) return;
    setState(() {
      if (later) {
        _laterLoading = true;
      } else {
        _favLoading = true;
      }
    });
    try {
      final j = await ApiClient.favorites(
          kind: later ? 'later' : 'fav', page: 1, size: 20);
      if (!mounted) return;
      final list = FeedPage.fromJson(j).list;
      setState(() {
        if (later) {
          _laters
            ..clear()
            ..addAll(list);
          _laterLoading = false;
          _laterLoaded = true;
        } else {
          _favs
            ..clear()
            ..addAll(list);
          _favLoading = false;
          _favLoaded = true;
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        if (later) {
          _laterLoading = false;
          _laterLoaded = true;
        } else {
          _favLoading = false;
          _favLoaded = true;
        }
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final sp = await SharedPreferences.getInstance();
    final tok = sp.getString('community_token') ?? '';
    if (tok.isNotEmpty) {
      ApiClient.token = tok;
      try {
        final j = await ApiClient.myProfile();
        final user = Map<String, dynamic>.from(j['user'] as Map);
        if (!mounted) return;
        setState(() {
          _me = user;
          _name = (user['name'] ?? '') as String;
          // 头像：字段为空（未设置）→ 显示默认头像；否则按 uid 走音乐端头像接口
          final avRaw = (user['avatar'] ?? '') as String;
          _avatar =
              avRaw.isEmpty ? '' : avatarUrlOf((user['id'] ?? '') as String);
          _loading = false;
        });
        await _loadExtras();
        _loadMine(refresh: true);
        _loadFav(later: false, refresh: true);
        _loadFav(later: true, refresh: true);
        NotifyBus.shared.connect(tok);
        return;
      } catch (_) {
        ApiClient.token = null;
        await sp.remove('community_token');
      }
    }
    if (!mounted) return;
    setState(() => _loading = false);
  }

  /// 等级 / 签到 / 装扮 / 任务并行拉取
  Future<void> _loadExtras() async {
    try {
      final lv = await ApiClient.levelMe();
      final sg = await ApiClient.signins();
      final mf = await ApiClient.myFrame();
      if (!mounted) return;
      setState(() {
        _level = Map<String, dynamic>.from(lv);
        _signins = ((sg['list'] ?? []) as List).map((e) => e.toString()).toList();
        _myFrame = (mf['frameId'] ?? '') as String;
      });
    } catch (_) {}
  }

  Future<void> _goLogin() async {
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const LoginPage()),
    );
    if (ok == true) {
      await _init();
    }
  }

  Future<void> _signin() async {
    if (_signing) return;
    setState(() => _signing = true);
    try {
      await ApiClient.signin();
      if (!mounted) return;
      setState(() {
        _signins.add(DateTime.now().toString().split(' ')[0]);
        _signing = false;
      });
      showAppToast(context, '签到成功，经验+10');
      await _loadExtras();
    } catch (e) {
      if (!mounted) return;
      setState(() => _signing = false);
      showAppToast(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return ImmersivePage(
      child: _loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2.4))
          : ApiClient.token == null
              ? _buildLoggedOut()
              : _buildLoggedIn(),
    );
  }

  Widget _buildLoggedOut() {
    return SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpace.gutter,
            vertical: AppSpace.x6,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const EmptyState(
                icon: Icons.person_outline_rounded,
                title: '登录后开启完整社区',
                message: '邮箱验证码登录，账号与流萤音乐互通',
                compact: true,
              ),
              PillButton(
                label: '登录 / 注册',
                size: PillSize.lg,
                expand: true,
                glow: true,
                onTap: _goLogin,
              ),
              const SizedBox(height: AppSpace.x3),
              Text(
                '新邮箱将自动注册，与流萤音乐同一账号体系',
                textAlign: TextAlign.center,
                style: AppType.micro,
              ),
              const SizedBox(height: AppSpace.x7),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLoggedIn() {
    final user = _me!;
    final verified = boolOf(user['verified']);
    final verifiedLabel = (user['verifiedLabel'] ?? '') as String;
    final adminLevel = ((user['adminLevel'] ?? 0) as num).toInt();
    final followers = ((user['followers'] ?? 0) as num).toInt();
    final followings = ((user['followings'] ?? 0) as num).toInt();
    final signature = (user['signature'] ?? '') as String;
    final level = ((_level['level'] ?? user['level'] ?? 0) as num).toInt();
    final exp = ((_level['exp'] ?? 0) as num).toInt();
    final progress = (_level['progress'] ?? 0.0) as num;
    final next = _level['nextThreshold'];
    final likes = ((user['likes'] ?? user['likeCount'] ?? 0) as num).toInt();
    final favCount =
        ((user['favCount'] ?? user['favorites'] ?? _favs.length) as num).toInt();
    final today = DateTime.now().toString().split(' ')[0];
    final signedToday = _signins.contains(today);
    return Stack(
      children: [
        Positioned(top: 0, left: 0, right: 0, child: _bgLayer()),
        SafeArea(
          bottom: false,
          child: RefreshIndicator(
            color: const Color(AppColors.accent),
            backgroundColor: const Color(AppColors.elevated),
            edgeOffset: 8,
            onRefresh: () async {
              await _loadMine(refresh: true);
              await _loadFav(later: false, refresh: true);
              await _loadFav(later: true, refresh: true);
              await _loadExtras();
            },
            child: NotificationListener<ScrollNotification>(
              onNotification: (n) {
                if (_tab == 0) {
                  if (n.metrics.extentAfter < 300) _loadMine(refresh: false);
                } else {
                  if (n.metrics.extentAfter < 300) {
                    _loadFav(later: _tab == 2, refresh: false);
                  }
                }
                return false;
              },
              child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(
                  parent: BouncingScrollPhysics(),
                ),
                slivers: [
                  SliverToBoxAdapter(
                    child: _profileHeader(
                      user: user,
                      verified: verified,
                      verifiedLabel: verifiedLabel,
                      adminLevel: adminLevel,
                      followers: followers,
                      followings: followings,
                      signature: signature,
                      level: level,
                      exp: exp,
                      progress: progress,
                      next: next,
                      signedToday: signedToday,
                      likes: likes,
                      favCount: favCount,
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(
                        AppSpace.gutter,
                        AppSpace.x5,
                        AppSpace.gutter,
                        AppSpace.x3,
                      ),
                      child: Row(
                        children: [
                          Text(
                            _tab == 0
                                ? '我的作品'
                                : (_tab == 1 ? '我的收藏' : '稍后看'),
                            style: AppType.title.copyWith(
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.02,
                            ),
                          ),
                          const Spacer(),
                          Text(
                            _tab == 0
                                ? '全部 ${formatCount(_postCount)} 篇'
                                : (_tab == 1
                                    ? '${formatCount(_favs.length)} 篇'
                                    : '${formatCount(_laters.length)} 篇'),
                            style: AppType.micro.copyWith(
                              color: const Color(AppColors.textTertiary),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: FeedTabs(
                      labels: const ['作品', '收藏', '稍后看'],
                      index: _tab,
                      onChanged: (i) => setState(() => _tab = i),
                    ),
                  ),
                  const SliverToBoxAdapter(
                    child: SizedBox(height: AppSpace.x1),
                  ),
                  if (_tab == 0) _mineSliver() else _favSliver(later: _tab == 2),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(
                          AppSpace.gutter, AppSpace.x6, AppSpace.gutter, 0),
                      child: Column(
                        children: [
                          _settingRow(
                            icon: Icons.sports_esports_outlined,
                            label: '小游戏',
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => const PetalwakePage()),
                            ),
                          ),
                          _settingRow(
                            icon: Icons.chat_bubble_outline_rounded,
                            label: '意见反馈',
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => const FeedbackPage()),
                            ),
                          ),
                          _settingRow(
                            icon: Icons.info_outline_rounded,
                            label: '关于流萤',
                            tail: '0.5.4',
                            onTap: _showAbout,
                          ),
                        ],
                      ),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: SizedBox(height: tabBarBottomInset(context)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 背景层：音乐设置的用户背景图（无图回退纯黑 + 薄荷光晕），
  /// 从屏幕顶部延伸到头部，底部渐隐到纯黑与内容融合。
  Widget _bgLayer() {
    final topInset = MediaQuery.paddingOf(context).top;
    final uid = ApiClient.userId ?? '';
    final bg = ((_me ?? const {})['background'] ?? '') as String;
    final hasBg = uid.isNotEmpty && bg.isNotEmpty;
    return Container(
      height: 300 + topInset,
      width: double.infinity,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(AppColors.canvas), Color(AppColors.bg)],
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (hasBg) ...[
            CachedNetworkImage(
              imageUrl: '$kMusicBase/api/background/$uid',
              fit: BoxFit.cover,
              placeholder: (_, _) => const _BgGradient(),
              errorWidget: (_, _, _) => const _BgGradient(),
            ),
            // 深色蒙层：保证白色文字在背景图上可读
            Container(color: Colors.black.withValues(alpha: 0.52)),
          ] else ...[
            Positioned(
              right: -60,
              top: -80,
              child: _glowCircle(size: 200, alpha: 0.10),
            ),
            Positioned(
              left: -50,
              bottom: 10,
              child: _glowCircle(size: 150, alpha: 0.06),
            ),
          ],
          // 底部渐变遮罩：背景与内容自然融合
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 120,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, const Color(AppColors.bg)],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _glowCircle({required double size, required double alpha}) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(AppColors.accent).withValues(alpha: alpha),
      ),
    );
  }

  /// 资料区：大标题 + 头像/昵称/签名 + 统计行 + 等级进度 + 快捷操作。
  Widget _profileHeader({
    required Map<String, dynamic> user,
    required bool verified,
    required String verifiedLabel,
    required int adminLevel,
    required int followers,
    required int followings,
    required String signature,
    required int level,
    required int exp,
    required num progress,
    required Object? next,
    required bool signedToday,
    required int likes,
    required int favCount,
  }) {
    final parts = <String>[];
    final g = (user['gender'] ?? '') as String;
    final a = (user['age'] ?? 0) as num;
    final c = (user['city'] ?? '') as String;
    if (g.isNotEmpty) parts.add(g);
    if (a > 0) parts.add('$a岁');
    if (c.isNotEmpty) parts.add(c);
    final metaLine = parts.join(' · ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.gutter,
        AppSpace.x3,
        AppSpace.gutter,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 大标题 + 右上操作
          Row(
            children: [
              const Text('我的', style: AppType.display),
              const Spacer(),
              if (adminLevel > 0) ...[
                IconCircleButton(
                  icon: Icons.fact_check_outlined,
                  size: 36,
                  iconSize: 18,
                  onTap: _openAudit,
                ),
                const SizedBox(width: AppSpace.x2),
              ],
              IconCircleButton(
                icon: Icons.ios_share_rounded,
                size: 36,
                iconSize: 18,
                onTap: _shareProfile,
              ),
              const SizedBox(width: AppSpace.x2),
              IconCircleButton(
                icon: Icons.settings_outlined,
                size: 36,
                iconSize: 18,
                onTap: _openSettings,
              ),
            ],
          ),
          const SizedBox(height: AppSpace.x1),
          Text(
            '萤火相聚 · 点亮彼此',
            style: AppType.micro.copyWith(
              color: const Color(AppColors.accent),
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: AppSpace.x5),
          // 头像 + 昵称 / 签名
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppAvatar(
                url: _avatar ?? '',
                name: _name ?? '',
                size: 68,
                ring: _myFrame.isNotEmpty,
                badge: (verified || adminLevel > 0)
                    ? _verifiedBadge(verified)
                    : null,
              ),
              const SizedBox(width: AppSpace.x4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            _name ?? '用户',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppType.h2,
                          ),
                        ),
                        if (verifiedLabel.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: const Color(AppColors.accent)
                                  .withValues(alpha: 0.14),
                              borderRadius:
                                  BorderRadius.circular(AppRadius.xs),
                            ),
                            child: Text(
                              verifiedLabel,
                              style: AppType.micro.copyWith(
                                color: const Color(AppColors.accent),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (signature.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        signature,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppType.bodySm,
                      ),
                    ],
                    if (metaLine.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(metaLine, style: AppType.micro),
                    ],
                    if ((user['id'] ?? '').toString().isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        'ID ${_publicId((user['id'] ?? '').toString())}',
                        style: AppType.micro.copyWith(
                          color: const Color(AppColors.textTertiary),
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.x5),
          // 数据四项：不套卡片，直接落在画布上
          Row(
            children: [
              Expanded(
                child: _statCell(
                  value: formatCount(followings),
                  label: '关注',
                  onTap: () {
                    if (ApiClient.userId == null) return;
                    Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => UserListPage(
                                uid: ApiClient.userId!,
                                kind: 'followings',
                                title: '关注')));
                  },
                ),
              ),
              Expanded(
                child: _statCell(
                  value: formatCount(followers),
                  label: '粉丝',
                  onTap: () {
                    if (ApiClient.userId == null) return;
                    Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => UserListPage(
                                uid: ApiClient.userId!,
                                kind: 'followers',
                                title: '粉丝')));
                  },
                ),
              ),
              Expanded(
                child: _statCell(
                  value: formatCount(likes),
                  label: '获赞',
                ),
              ),
              Expanded(
                child: _statCell(
                  value: formatCount(favCount),
                  label: '收藏',
                  onTap: () => setState(() => _tab = 1),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.x6),
          // 等级进度：徽章在左，经验在右，条压在文字下
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(AppColors.accent).withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(AppRadius.xs),
                ),
                child: Text(
                  'Lv.$level',
                  style: AppType.caption.copyWith(
                    color: const Color(AppColors.accent),
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const Spacer(),
              RollingText(
                text: next == null ? '已满级' : '$exp / $next XP',
                style: AppType.micro.copyWith(
                  color: const Color(AppColors.textTertiary),
                  fontVariations: const [FontVariation('wght', 500)],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.x2),
          GrowBar(
            value: progress.toDouble().clamp(0.0, 1.0),
            height: 3,
          ),
          const SizedBox(height: AppSpace.x2),
          Row(
            children: [
              Expanded(
                child: Text(
                  next == null
                      ? '已达当前最高等级'
                      : '再获得 ${((next as num) - exp).clamp(0, 1 << 31)} 经验升到 Lv.${level + 1}',
                  style: AppType.micro.copyWith(
                    color: const Color(AppColors.textTertiary),
                  ),
                ),
              ),
              if (next != null) ...[
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(AppColors.accent).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Text(
                    '升级加速中',
                    style: AppType.micro.copyWith(
                      fontSize: 10,
                      color: const Color(AppColors.accent),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: AppSpace.x4),
          // 操作：编辑资料（通栏）+ 签到（右侧方块）
          Row(
            children: [
              Expanded(
                child: PressableScale(
                  onTap: _editProfile,
                  scale: 0.98,
                  child: Container(
                    height: 44,
                    decoration: BoxDecoration(
                      color: const Color(AppColors.card),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(AppColors.border)),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.edit_outlined,
                            size: 16, color: Color(AppColors.textSecondary)),
                        const SizedBox(width: 6),
                        Text(
                          '编辑资料',
                          style: AppType.caption.copyWith(
                            color: const Color(AppColors.textPrimary),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: AppSpace.x2),
              PressableScale(
                onTap: signedToday || _signing ? null : _signin,
                scale: 0.96,
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: const Color(AppColors.card),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(AppColors.border)),
                  ),
                  child: Icon(
                    signedToday
                        ? Icons.check_circle_rounded
                        : Icons.calendar_today_rounded,
                    size: 18,
                    color: signedToday
                        ? const Color(AppColors.accent)
                        : const Color(AppColors.textSecondary),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.x5),
          Container(height: 1, color: const Color(AppColors.hairline)),
        ],
      ),
    );
  }

  /// 数据格：数字在上、标签在下，左对齐，不套容器
  Widget _statCell({
    required String value,
    required String label,
    VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            RollingText(
              text: value,
              style: AppType.h2.copyWith(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.02,
                fontVariations: const [FontVariation('wght', 800)],
              ),
            ),
            const SizedBox(height: 3),
            Text(
              label,
              style: AppType.micro.copyWith(
                color: const Color(AppColors.textTertiary),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _verifiedBadge(bool verified) {
    return Container(
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(AppColors.accent),
        border: Border.all(color: const Color(AppColors.bg), width: 2),
      ),
      alignment: Alignment.center,
      child: Text(
        verified ? 'V' : '管',
        style: AppType.micro.copyWith(
          color: const Color(AppColors.onAccent),
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }

  /// 对外展示的 ID：纯数字 uid 原样使用；其它内部标识做稳定不可逆散列成 10 位数字，
  /// 避免把账号内部 uid / token 形态的字符串暴露在界面上。
  String _publicId(String raw) {
    if (raw.isEmpty) return '';
    if (RegExp(r'^[0-9]{5,12}$').hasMatch(raw)) return raw;
    var h = 0x811c9dc5;
    for (final c in raw.codeUnits) {
      h ^= c;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return (1000000000 + (h % 8000000000)).toString();
  }

  Widget _settingRow({
    required IconData icon,
    required String label,
    String? tail,
    VoidCallback? onTap,
  }) {
    return PressableScale(
      onTap: onTap,
      child: Container(
        height: 52,
        decoration: const BoxDecoration(
          border: Border(
            bottom: BorderSide(color: Color(AppColors.hairline)),
          ),
        ),
        child: Row(
          children: [
            Icon(icon, size: 18, color: const Color(AppColors.textSecondary)),
            const SizedBox(width: 12),
            Text(
              label,
              style: const TextStyle(
                fontSize: 14,
                color: Color(AppColors.textPrimary),
              ),
            ),
            const Spacer(),
            if (tail != null)
              Text(tail, style: AppType.micro.copyWith(fontSize: 11.5)),
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right_rounded,
                size: 18, color: Color(AppColors.textTertiary)),
          ],
        ),
      ),
    );
  }

  void _showAbout() {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(AppColors.card),
        title: const Text('关于流萤'),
        content: const Text('流萤社区 0.5.4\n一个安静的写作与分享社区。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  /// 编辑资料 → 独立编辑页（头像/昵称/签名/性别/年龄/地址/邮箱）
  Future<void> _editProfile() async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => EditProfilePage(user: _me ?? const {})),
    );
    if (changed == true && mounted) {
      await _init();
    }
  }

  /// 内容审核入口（仅管理员）：App 内审核列表
  void _openAudit() {
    Navigator.push(context,
        MaterialPageRoute(builder: (_) => const AuditPage()));
  }

  /// 设置页：返回 true 时刷新资料与收藏
  Future<void> _openSettings() async {
    final changed = await Navigator.push<bool>(
        context, MaterialPageRoute(builder: (_) => const SettingsPage()));
    if (changed == true && mounted) {
      await _init();
      await _loadFav(later: false, refresh: true);
      await _loadFav(later: true, refresh: true);
    }
  }

  /// 分享我的主页（复制链接）
  void _shareProfile() {
    final uid = ApiClient.userId ?? '';
    final url = 'https://www.dbmt999.asia/community/share.html?uid=$uid';
    Clipboard.setData(ClipboardData(text: url));
    showAppToast(context, '主页链接已复制，去分享给好友吧');
  }

  /// 作品 sliver：三列网格
  Widget _mineSliver() {
    if (_mineLoading && _mine.isEmpty) {
      return const SliverToBoxAdapter(child: FeedSkeleton(count: 2));
    }
    if (_mineLoaded && _mine.isEmpty) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.only(top: AppSpace.x6),
          child: EmptyState(
            icon: Icons.video_library_outlined,
            title: '还没有发布过作品',
            message: '记录此刻，发布你的第一条内容',
            actionLabel: '去发布',
            onAction: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const PostEditorPage())),
          ),
        ),
      );
    }
    return _gridSliver(_mine);
  }

  /// 收藏/稍后看 sliver
  Widget _favSliver({required bool later}) {
    final items = later ? _laters : _favs;
    final loading = later ? _laterLoading : _favLoading;
    final loaded = later ? _laterLoaded : _favLoaded;
    if (loading && items.isEmpty) {
      return const SliverToBoxAdapter(child: FeedSkeleton(count: 2));
    }
    if (loaded && items.isEmpty) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.only(top: AppSpace.x6),
          child: EmptyState(
            icon: later
                ? Icons.schedule_outlined
                : Icons.bookmark_border_rounded,
            title: later ? '暂无稍后看内容' : '暂无收藏内容',
            message: later ? '看到想留到以后的内容，就加入稍后看' : '喜欢的内容，收藏起来慢慢看',
          ),
        ),
      );
    }
    return _gridSliver(items);
  }

  /// 三列作品网格
  Widget _gridSliver(List<FeedItem> items) {
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.gutter,
        AppSpace.x2,
        AppSpace.gutter,
        AppSpace.x6,
      ),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          mainAxisSpacing: AppSpace.x1,
          crossAxisSpacing: AppSpace.x1,
          childAspectRatio: 0.75,
        ),
        delegate: SliverChildBuilderDelegate(
          (_, i) {
            final it = items[i];
            return RepaintBoundary(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  PostGridTile(
                    item: it,
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => PostDetailPage(postId: it.id)),
                    ),
                  ),
                  if (it.auditStatus == 0 || it.auditStatus == 2)
                    Positioned(
                      top: 4,
                      left: 4,
                      child: IgnorePointer(child: _auditBadge(it)),
                    ),
                ],
              ),
            );
          },
          childCount: items.length,
        ),
      ),
    );
  }

  /// 待审 / 已拒绝角标（保留原审核状态提示信息）
  Widget _auditBadge(FeedItem it) {
    final pending = it.auditStatus == 0;
    final color =
        pending ? const Color(AppColors.warning) : const Color(AppColors.danger);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(AppRadius.xs),
        border: Border.all(color: color.withValues(alpha: 0.55)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            pending ? Icons.hourglass_top_rounded : Icons.block_rounded,
            size: 10,
            color: color,
          ),
          const SizedBox(width: 3),
          Text(
            pending ? '审核中' : '已拒绝',
            style: AppType.micro.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// 默认背景渐变（无背景图 / 加载中 / 加载失败时使用）
class _BgGradient extends StatelessWidget {
  const _BgGradient();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(AppColors.canvas), Color(AppColors.bg)],
        ),
      ),
    );
  }
}
