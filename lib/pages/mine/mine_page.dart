/// 我的页（P0）：登录互通 + 等级进度 + 签到 + 个性装扮（头像框）+ 任务
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../api/app_market_api.dart';
import '../../api/client.dart';
import '../../config.dart';
import '../../design/components.dart';
import '../../models/app_market.dart';
import '../../models/feed_item.dart';
import '../../services/auth_session.dart';
import '../../services/notify_bus.dart';
import '../../services/publish_bus.dart';
import '../../services/secure_store.dart';
import '../../services/user_data_bus.dart';
import '../../widgets/post_card.dart';
import '../apps/app_detail_page.dart';
import '../apps/app_mine_page.dart';
import '../apps/app_submit_page.dart';
import '../post/post_detail.dart';
import '../post/post_editor.dart';
import '../share/share_target_sheet.dart';
import '../settings/settings_page.dart';
import '../apps/app_downloads_page.dart';
import '../feedback/feedback_page.dart';
import 'audit_page.dart';
import 'edit_profile_page.dart';
import 'login_page.dart';
import 'member_page.dart';
import 'mine_apps_section.dart';
import 'mine_entry_section.dart';
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
  String _myFrameImage = '';
  Map<String, dynamic> _member = {};
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
  final GlobalKey _worksKey = GlobalKey();

  /// 并发请求序号：账号切换/重复刷新时，旧请求不得覆盖新状态。
  int _profileRequest = 0;

  // 我的应用投稿：待审核 / 未通过需要直接出现在个人主页
  List<MarketApp> _myApps = const [];
  bool _myAppsLoading = false;
  bool _myAppsLoaded = false;
  String? _myAppsError;
  int _myAppsRequest = 0;

  /// 我的帖子（帖子 Tab 数据 + 帖子统计数）
  Future<void> _loadMine({bool refresh = false}) async {
    if (_mineLoading || (!_mineHasMore && !refresh)) return;
    final uid = ApiClient.userId;
    if (uid == null) return;
    final token = ApiClient.token;
    final countNeeded = !_mineLoaded;
    setState(() => _mineLoading = true);
    try {
      // 注意：后端 type 是字面过滤（text/video/poll），传 'all' 会查不到任何数据，
      // 因此这里不传 type —— 表示「全部作品」。
      final j = await ApiClient.get(
        '/user/$uid/posts',
        query: {'page': '${refresh ? 1 : _minePage + 1}', 'size': '10'},
      );
      if (!mounted || token != ApiClient.token || uid != ApiClient.userId) {
        return;
      }
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
      if (!mounted || token != ApiClient.token || uid != ApiClient.userId) {
        return;
      }
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
        final j = await ApiClient.get(
          '/user/$uid/posts',
          query: {'page': '$page', 'size': '50'},
        );
        final rows = (j['list'] ?? []) as List;
        total += rows.length;
        if (!boolOf(j['hasMore']) || rows.isEmpty) break;
      }
      if (!mounted || uid != ApiClient.userId) return;
      setState(() => _postCount = total);
    } catch (_) {
      // 统计失败时退回已加载条数，不影响作品列表展示
      if (!mounted) return;
      setState(() => _postCount = _mine.length);
    }
  }

  /// 收藏 / 稍后看（Tab 数据）
  Future<void> _loadFav({required bool later, bool refresh = false}) async {
    if (refresh ||
        (!(later ? _laterLoading : _favLoading) &&
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
    final token = ApiClient.token;
    try {
      final j = await ApiClient.favorites(
        kind: later ? 'later' : 'fav',
        page: 1,
        size: 20,
      );
      if (!mounted || token != ApiClient.token) return;
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
      if (!mounted || token != ApiClient.token) return;
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
    AuthSession.revision.addListener(_onSessionChanged);
    UserDataBus.revision.addListener(_onUserDataChanged);
    PublishBus.completed.addListener(_onPublishCompleted);
    _init();
  }

  @override
  void dispose() {
    AuthSession.revision.removeListener(_onSessionChanged);
    UserDataBus.revision.removeListener(_onUserDataChanged);
    PublishBus.completed.removeListener(_onPublishCompleted);
    super.dispose();
  }

  void _resetProfileState() {
    _me = null;
    _name = null;
    _avatar = '';
    _level = {};
    _signins = [];
    _myFrame = '';
    _myFrameImage = '';
    _member = {};
    _mine.clear();
    _favs.clear();
    _laters.clear();
    _postCount = 0;
    _minePage = 0;
    _mineHasMore = true;
    _mineLoaded = false;
    _favLoaded = false;
    _laterLoaded = false;
    _favLoading = false;
    _laterLoading = false;
    _mineLoading = false;
    _myApps = const [];
    _myAppsLoading = false;
    _myAppsLoaded = false;
    _myAppsError = null;
    _myAppsRequest++;
  }

  void _onSessionChanged() {
    if (!mounted) return;
    _profileRequest++;
    setState(() {
      _resetProfileState();
      _loading = true;
    });
    _init();
  }

  void _onUserDataChanged() {
    if (!mounted || ApiClient.token == null) return;
    _refreshProfile();
    _loadExtras();
    _loadMyApps();
  }

  void _onPublishCompleted() {
    if (!mounted || ApiClient.token == null) return;
    _loadMine(refresh: true);
  }

  /// 只更新资料头部，保留已加载的作品/收藏列表（编辑资料、头像上传后使用）。
  Future<void> _refreshProfile({bool showLoading = false}) async {
    final token = ApiClient.token;
    if (token == null || token.isEmpty) return;
    final req = ++_profileRequest;
    if (showLoading) setState(() => _loading = true);
    try {
      final j = await ApiClient.myProfile();
      if (!mounted || req != _profileRequest) return;
      final user = Map<String, dynamic>.from(j['user'] as Map);
      _applyUser(user);
    } catch (_) {
      if (!mounted || req != _profileRequest) return;
      if (showLoading) setState(() => _loading = false);
    }
  }

  void _applyUser(Map<String, dynamic> user) {
    if (!mounted) return;
    setState(() {
      _me = user;
      _name = (user['name'] ?? '').toString();
      final uid = (user['id'] ?? '').toString();
      final avRaw = (user['avatar'] ?? '').toString();
      // 头像 URL 固定按 uid 拼接；带版本参数，换头像后不会命中旧图缓存。
      _avatar = (avRaw.isEmpty || uid.isEmpty)
          ? ''
          : '${avatarUrlOf(uid)}?v=${DateTime.now().microsecondsSinceEpoch}';
      _loading = false;
    });
    AuthSession.updateSavedProfile(user);
  }

  Future<void> _init({bool showLoading = false}) async {
    final req = ++_profileRequest;
    final revision = AuthSession.revision.value;
    if (showLoading) setState(() => _loading = true);
    final tok = await SecureStore.read(SecureStore.tokenKey) ?? '';
    // 读取偏好期间可能已经切号/退出：先确认会话版本没变，再把磁盘 token
    // 注入内存（兼容冷启动/测试直接挂载 MinePage 的场景）。
    if (!mounted ||
        req != _profileRequest ||
        revision != AuthSession.revision.value) {
      return;
    }
    if (tok.isNotEmpty) {
      if (ApiClient.token == null) {
        ApiClient.token = tok;
      } else if (ApiClient.token != tok) {
        return;
      }
    }
    if (tok.isNotEmpty) {
      try {
        final j = await ApiClient.myProfile();
        if (!mounted || req != _profileRequest) return;
        final rawUser = j['user'];
        if (rawUser is! Map) return;
        final user = Map<String, dynamic>.from(rawUser);
        _applyUser(user);
        _loadMyApps();
        await _loadExtras();
        _loadMine(refresh: true);
        _loadFav(later: false, refresh: true);
        _loadFav(later: true, refresh: true);
        if (!mounted || req != _profileRequest) return;
        NotifyBus.shared.connect(tok);
        return;
      } catch (e) {
        if (!mounted || req != _profileRequest) return;
        // 只有 401 才是登录态失效；网络/服务端临时异常不能把用户静默退出。
        final unauthorized = e is ApiException && e.code == 401;
        if (unauthorized) {
          ApiClient.token = null;
          ApiClient.userId = null;
          ApiClient.meProfile = null;
          NotifyBus.shared.disconnect();
          await SecureStore.delete(SecureStore.tokenKey);
          setState(() {
            _resetProfileState();
            _loading = false;
          });
        } else {
          setState(() => _loading = false);
          showAppToast(context, '资料加载失败，请稍后重试');
        }
        return;
      }
    }
    if (!mounted || req != _profileRequest) return;
    setState(() {
      _resetProfileState();
      _loading = false;
    });
  }

  /// 等级 / 签到 / 装扮 / 任务并行拉取
  Future<void> _loadExtras() async {
    final token = ApiClient.token;
    try {
      final lv = await ApiClient.levelMe();
      final sg = await ApiClient.signins();
      final mf = await ApiClient.myFrame();
      Map<String, dynamic> mb = const {};
      if (ApiClient.token != null && ApiClient.token!.isNotEmpty) {
        try {
          mb = await ApiClient.memberStatus();
        } catch (_) {}
      }
      if (!mounted || token != ApiClient.token) return;
      setState(() {
        _level = Map<String, dynamic>.from(lv);
        _signins = ((sg['list'] ?? []) as List)
            .map((e) => e.toString())
            .toList();
        _myFrame = (mf['frameId'] ?? '').toString();
        // 直接按 frameId 拼图：不受上架列表影响，已佩戴的框一定能显示
        _myFrameImage = _myFrame.isEmpty ? '' : frameUrlOf(_myFrame);
        _member = Map<String, dynamic>.from(mb);
      });
    } catch (_) {}
  }

  /// 我的应用投稿：与资料并行加载，失败不阻塞个人主页。
  Future<void> _loadMyApps() async {
    final token = ApiClient.token;
    if (token == null || token.isEmpty) return;
    final id = ++_myAppsRequest;
    if (!mounted) return;
    setState(() {
      _myAppsLoading = true;
      _myAppsError = null;
    });
    try {
      final list = await AppMarketApi.mine();
      if (!mounted || id != _myAppsRequest || token != ApiClient.token) return;
      setState(() {
        _myApps = list;
        _myAppsLoading = false;
        _myAppsLoaded = true;
      });
    } catch (e) {
      if (!mounted || id != _myAppsRequest || token != ApiClient.token) return;
      setState(() {
        _myAppsLoading = false;
        _myAppsLoaded = true;
        _myAppsError = e.toString();
      });
    }
  }

  Future<void> _goLogin() async {
    final ok = await Navigator.of(context)
        .push<bool>(MaterialPageRoute(builder: (_) => const LoginPage()));
    if (ok == true) {
      await _init();
    }
  }

  Future<void> _signin() async {
    if (_signing) return;
    setState(() => _signing = true);
    try {
      final j = await ApiClient.signin();
      if (!mounted) return;
      setState(() {
        _signins.add(
          (j['day'] ?? DateTime.now().toString().split(' ')[0]).toString(),
        );
        _signing = false;
      });
      final msg = (j['msg'] ?? '').toString().trim();
      showAppToast(context, msg.isEmpty ? '签到成功' : msg);
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
      child: SkeletonSwap(
        loading: _loading,
        skeleton: const _MineSkeleton(),
        child: ApiClient.token == null
            ? _buildLoggedOut()
            : _me == null
            ? (_loading ? const _MineSkeleton() : _buildProfileError())
            : _buildLoggedIn(),
      ),
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

  /// token 还在、资料暂时没拉到：给重试入口，不把用户误判成未登录。
  Widget _buildProfileError() {
    return SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.gutter),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.cloud_off_outlined,
                size: 40,
                color: Color(AppColors.textTertiary),
              ),
              const SizedBox(height: AppSpace.x3),
              Text('资料暂时加载失败', style: AppType.title.copyWith(fontSize: 17)),
              const SizedBox(height: 6),
              Text(
                '网络恢复后重试一次即可，登录状态不会丢失',
                textAlign: TextAlign.center,
                style: AppType.caption.copyWith(
                  color: const Color(AppColors.textTertiary),
                ),
              ),
              const SizedBox(height: AppSpace.x4),
              PillButton(
                label: '重新加载',
                size: PillSize.md,
                onTap: () => _init(showLoading: true),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLoggedIn() {
    final user = _me!;
    final verifiedLabel = (user['verifiedLabel'] ?? '').toString().trim();
    final verified = verifiedOf(user['verified']) || verifiedLabel.isNotEmpty;
    final isAi = boolOf(user['isAi']) || verifiedLabel.toUpperCase() == 'AI';
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
        ((user['favCount'] ?? user['favorites'] ?? _favs.length) as num)
            .toInt();
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
              await _loadMyApps();
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
                      isAi: isAi,
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
                        0,
                        AppSpace.gutter,
                        0,
                      ),
                      child: MineEntrySection(
                        member: _member,
                        onMember: _openMember,
                        onDownloads: _openDownloads,
                        onWorks: () => _goWorks(),
                        onFeedback: _openFeedback,
                        onAbout: _showAbout,
                      ),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: MineAppsSection(
                      apps: _myApps,
                      loading: _myAppsLoading,
                      error: _myAppsLoaded ? _myAppsError : null,
                      onManage: _openMyApps,
                      onSubmit: _openSubmitApp,
                      onRetry: _loadMyApps,
                      onOpen: _openMyApp,
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: Padding(
                      key: _worksKey,
                      padding: const EdgeInsets.fromLTRB(
                        AppSpace.gutter,
                        AppSpace.x5,
                        AppSpace.gutter,
                        AppSpace.x3,
                      ),
                      child: Row(
                        children: [
                          Text(
                            _tab == 0 ? '我的作品' : (_tab == 1 ? '我的收藏' : '稍后看'),
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
                  if (_tab == 0)
                    _mineSliver()
                  else
                    _favSliver(later: _tab == 2),
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
    final decodeWidth =
        (MediaQuery.sizeOf(context).width *
                MediaQuery.devicePixelRatioOf(context))
            .ceil();
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
              imageUrl: backgroundUrlOf(uid),
              fit: BoxFit.cover,
              memCacheWidth: decodeWidth,
              fadeInDuration: const Duration(milliseconds: 220),
              fadeOutDuration: const Duration(milliseconds: 80),
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
    required bool isAi,
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
          const SizedBox(height: AppSpace.x4),
          // 头像 + 昵称 / 签名
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppAvatar(
                url: _avatar ?? '',
                name: _name ?? '',
                size: 68,
                ring: _myFrame.isEmpty,
                // _myFrameImage 已是完整 URL，不能再过一次 mediaUrl
                frameUrl: _myFrameImage.isEmpty ? null : _myFrameImage,
                verified: verified,
                isAi: isAi,
                badge: (!verified && adminLevel > 0) ? _adminBadge() : null,
              ),
              const SizedBox(width: AppSpace.x4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _name ?? '用户',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.h2,
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
                        'ID ${_displayId(user)}',
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
          const SizedBox(height: AppSpace.x4),
          // 数据四项：直接落在画布上，不再用卡片包裹
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
            child: Row(
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
                            title: '关注',
                          ),
                        ),
                      );
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
                            title: '粉丝',
                          ),
                        ),
                      );
                    },
                  ),
                ),
                Expanded(
                  child: _statCell(value: formatCount(likes), label: '获赞'),
                ),
                Expanded(
                  child: _statCell(
                    value: formatCount(favCount),
                    label: '收藏',
                    onTap: () => _goWorks(tab: 1),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpace.x4),
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
          GrowBar(value: progress.toDouble().clamp(0.0, 1.0), height: 3),
          const SizedBox(height: AppSpace.x2),
          Row(
            children: [
              Expanded(
                child: Text(
                  next == null
                      ? '已达当前最高等级'
                      : '再获得 ${((next as num) - exp).clamp(0, 1 << 31)} 经验升到 Lv.${level + 1}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.micro.copyWith(
                    color: const Color(AppColors.textTertiary),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _editPill(),
              const SizedBox(width: 6),
              PressableScale(
                onTap: signedToday || _signing ? null : _signin,
                scale: 0.96,
                child: Container(
                  height: 24,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  decoration: BoxDecoration(
                    color: signedToday
                        ? const Color(AppColors.accent).withValues(alpha: 0.10)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(7),
                    border: Border.all(
                      color: signedToday
                          ? const Color(AppColors.accent)
                                .withValues(alpha: 0.18)
                          : const Color(AppColors.border),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        signedToday
                            ? Icons.check_circle_rounded
                            : Icons.calendar_today_rounded,
                        size: 12,
                        color: signedToday
                            ? const Color(AppColors.accent)
                            : const Color(AppColors.textTertiary),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        signedToday ? '已签到' : '签到',
                        style: AppType.micro.copyWith(
                          fontSize: 10.5,
                          color: signedToday
                              ? const Color(AppColors.accent)
                              : const Color(AppColors.textTertiary),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.x4),
        ],
      ),
    );
  }

  /// 编辑资料：紧跟签到左侧，保持同一条等级操作带
  Widget _editPill() {
    return PressableScale(
      onTap: _editProfile,
      scale: 0.96,
      child: Container(
        height: 24,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: const Color(AppColors.card),
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: const Color(AppColors.border)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.edit_outlined,
              size: 12,
              color: Color(AppColors.textSecondary),
            ),
            const SizedBox(width: 4),
            Text(
              '编辑',
              style: AppType.micro.copyWith(
                fontSize: 10.5,
                color: const Color(AppColors.textSecondary),
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 数据格：数字在上、标签在下，居中落在画布上
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
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            RollingText(
              text: value,
              textAlign: TextAlign.center,
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
              textAlign: TextAlign.center,
              style: AppType.micro.copyWith(
                color: const Color(AppColors.textTertiary),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 管理员角标与“认证”是两件事：认证统一用 [VerifiedBadge] 的蓝 V；
  /// 这里仅在未认证的管理员头像右下角保留“管”标记，避免两个角标叠在一起。
  Widget _adminBadge() {
    return Container(
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(AppColors.warning),
        border: Border.all(color: const Color(AppColors.bg), width: 2),
      ),
      alignment: Alignment.center,
      child: Text(
        '管',
        style: AppType.micro.copyWith(
          color: Colors.white,
          fontSize: 9,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }

  /// 对外展示的 ID：优先用账号（与音乐端同一套账号体系），无账号时回落内部 uid。
  String _displayId(Map<String, dynamic> user) {
    final acc = (user['account'] ?? '').toString();
    if (acc.isNotEmpty) return acc;
    return _publicId((user['id'] ?? '').toString());
  }

  /// 内部标识兜底：纯数字 uid 原样使用，其余做稳定不可逆散列成 10 位数字。
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

  /// 切到作品区并滚动到位：快捷入口和统计里的「收藏」都走这里，
  /// 避免只改了 Tab 但用户还停在资料区、看不到变化。
  void _goWorks({int tab = 0}) {
    if (_tab != tab) setState(() => _tab = tab);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctx = _worksKey.currentContext;
      if (ctx == null) return;
      Scrollable.ensureVisible(
        ctx,
        duration: AppMotion.page,
        curve: AppMotion.standard,
        alignment: 0.04,
      );
    });
  }

  Future<void> _openMember() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const MemberPage()),
    );
    if (!mounted) return;
    // 会员页可能完成开通/续费/兑换；返回后资料与会员状态都重新拉一次。
    await _refreshProfile();
    await _loadExtras();
  }

  Future<void> _openMyApps() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const AppMinePage()),
    );
    if (!mounted) return;
    await _loadMyApps();
  }

  Future<void> _openSubmitApp() async {
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const AppSubmitPage()),
    );
    if (result == true && mounted) await _loadMyApps();
  }

  Future<void> _openMyApp(MarketApp app) async {
    if (app.status == 2) {
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => AppDetailPage(appId: app.id)),
      );
      return;
    }
    if (app.needsEdit) {
      final result = await Navigator.push<bool>(
        context,
        MaterialPageRoute(builder: (_) => AppSubmitPage(existing: app)),
      );
      if (result == true && mounted) await _loadMyApps();
      return;
    }
    await _openMyApps();
  }

  void _openDownloads() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const AppDownloadsPage()),
    );
  }

  void _openFeedback() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const FeedbackPage()),
    );
  }

  void _showAbout() {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(AppColors.card),
        title: const Text('关于社区'),
        content: const Text('流萤社区 $kAppVersion\n一个安静的写作与分享社区。'),
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
    await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => EditProfilePage(user: _me ?? const {})),
    );
    if (!mounted) return;
    // 保存或只换了头像都会返回；无论返回值如何都重拉资料，头像不会留旧缓存。
    await _refreshProfile();
  }

  /// 内容审核入口（仅管理员）：App 内审核列表
  void _openAudit() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const AuditPage()),
    );
  }

  /// 设置页：返回 true 时刷新资料与收藏
  Future<void> _openSettings() async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const SettingsPage()),
    );
    if (changed == true && mounted) {
      // 账号切换/退出由 AuthSession.revision 监听统一处理；
      // 这里再拉一次兜底，避免设置页返回时页面仍显示旧账号。
      await _init();
    }
  }

  /// 分享我的主页：短链 + 系统分享 + 互关好友私信
  void _shareProfile() {
    final uid = ApiClient.userId ?? '';
    if (uid.isEmpty) return;
    showProfileShareSheet(
      context,
      uid: uid,
      name: _name ?? '我',
      avatar: _avatar ?? '',
    );
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
              MaterialPageRoute(builder: (_) => const PostEditorPage()),
            ),
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
        delegate: SliverChildBuilderDelegate((_, i) {
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
                      builder: (_) => PostDetailPage(postId: it.id),
                    ),
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
        }, childCount: items.length),
      ),
    );
  }

  /// 待审 / 已拒绝角标（保留原审核状态提示信息）
  Widget _auditBadge(FeedItem it) {
    final pending = it.auditStatus == 0;
    final color = pending
        ? const Color(AppColors.warning)
        : const Color(AppColors.danger);
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

/// 我的页首屏骨架：和真实头部/统计/歌单卡同尺寸，避免首帧跳动。
class _MineSkeleton extends StatelessWidget {
  const _MineSkeleton();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          AppSpace.gutter,
          AppSpace.x4,
          AppSpace.gutter,
          AppSpace.x8,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const SkeletonBox(width: 64, height: 64, radius: 32),
                const SizedBox(width: AppSpace.x3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: const [
                      SkeletonBox(width: 120, height: 18),
                      SizedBox(height: 10),
                      SkeletonBox(width: 180, height: 11),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpace.x4),
            const SkeletonBox(height: 74, radius: AppRadius.md),
            const SizedBox(height: AppSpace.x3),
            Row(
              children: const [
                Expanded(child: SkeletonBox(height: 58)),
                SizedBox(width: AppSpace.x2),
                Expanded(child: SkeletonBox(height: 58)),
                SizedBox(width: AppSpace.x2),
                Expanded(child: SkeletonBox(height: 58)),
              ],
            ),
            const SizedBox(height: AppSpace.x5),
            const SkeletonBox(width: 96, height: 16),
            const SizedBox(height: AppSpace.x3),
            const SkeletonBox(height: 120, radius: AppRadius.md),
            const SizedBox(height: AppSpace.x3),
            const SkeletonBox(height: 120, radius: AppRadius.md),
          ],
        ),
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
