/// 我的页（P0）：登录互通 + 等级进度 + 签到 + 个性装扮（头像框）+ 任务
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../api/client.dart';
import '../../config.dart';
import '../../models/feed_item.dart';
import '../../services/notify_bus.dart';
import '../../widgets/user_avatar.dart';
import '../post/post_detail.dart';
import '../post/post_editor.dart';
import '../settings/settings_page.dart';
import 'login_page.dart';
import 'task_center_page.dart';
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
  List<Map<String, dynamic>> _frames = [];
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
    setState(() => _mineLoading = true);
    try {
      final j = await ApiClient.get('/user/$uid/posts', query: {
        'type': 'all',
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
        _postCount = list.length;
        _mineLoading = false;
        _mineLoaded = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _mineLoading = false;
        _mineLoaded = true;
      });
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
      final fr = await ApiClient.frames();
      final mf = await ApiClient.myFrame();
      if (!mounted) return;
      setState(() {
        _level = Map<String, dynamic>.from(lv);
        _signins = ((sg['list'] ?? []) as List).map((e) => e.toString()).toList();
        _frames = ((fr['list'] ?? []) as List)
            .whereType<Map<String, dynamic>>()
            .toList();
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
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('签到成功，经验+10'),
          backgroundColor: Color(AppTheme.card)));
      await _loadExtras();
    } catch (e) {
      if (!mounted) return;
      setState(() => _signing = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('$e'), backgroundColor: const Color(AppTheme.card)));
    }
  }

  Future<void> _openFrames() async {
    await showModalBottomSheet(
      context: context,
      backgroundColor: const Color(AppTheme.card),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 10),
              child: Text('个性装扮 · 头像框',
                  style: TextStyle(
                      color: Color(AppTheme.textPrimary),
                      fontSize: 16,
                      fontWeight: FontWeight.bold)),
            ),
            Flexible(
              child: GridView.builder(
                shrinkWrap: true,
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3, mainAxisSpacing: 10, crossAxisSpacing: 10),
                itemCount: _frames.length + 1,
                padding: const EdgeInsets.all(16),
                itemBuilder: (_, i) {
                  if (i == 0) {
                    return _frameCell(
                        id: '', name: '无头像框', isDefault: true);
                  }
                  final f = _frames[i - 1];
                  return _frameCell(
                      id: (f['id'] ?? '') as String,
                      name: (f['name'] ?? '') as String,
                      isDefault: false);
                },
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _frameCell({required String id, required String name, required bool isDefault}) {
    final sel = _myFrame == id;
    return GestureDetector(
      onTap: () async {
        try {
          await ApiClient.equipFrame(id);
          if (!mounted) return;
          setState(() => _myFrame = id);
          Navigator.pop(context);
        } catch (e) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text('$e'), backgroundColor: const Color(AppTheme.card)));
        }
      },
      child: Container(
        decoration: BoxDecoration(
          color: const Color(AppTheme.bg),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: sel ? const Color(AppTheme.accent) : const Color(AppTheme.border),
            width: sel ? 2 : 1,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: sel
                    ? Border.all(color: const Color(AppTheme.accent), width: 2)
                    : null,
              ),
              child: CircleAvatar(
                radius: 22,
                backgroundColor: const Color(AppTheme.card),
                child: const Icon(Icons.person, color: Color(AppTheme.textSecondary)),
              ),
            ),
            const SizedBox(height: 6),
            Text(name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: Color(AppTheme.textSecondary), fontSize: 11)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(AppTheme.bg),
      body: SafeArea(
        child: _loading
            ? const Center(
                child: CircularProgressIndicator(color: Color(AppTheme.accent)))
            : ApiClient.token == null
                ? _buildLoggedOut()
                : RefreshIndicator(
                    color: const Color(AppTheme.accent),
                    backgroundColor: const Color(AppTheme.card),
                    onRefresh: _loadExtras,
                    child: _buildLoggedIn(),
                  ),
      ),
    );
  }

  Widget _buildLoggedOut() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.person_outline,
              size: 64, color: Color(AppTheme.textTertiary)),
          const SizedBox(height: 12),
          const Text('邮箱验证码登录，账号与流萤音乐互通',
              style: TextStyle(
                  color: Color(AppTheme.textSecondary), fontSize: 14)),
          const SizedBox(height: 24),
          GestureDetector(
            onTap: _goLogin,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 44, vertical: 12),
              decoration: BoxDecoration(
                color: const Color(AppTheme.accent),
                borderRadius: BorderRadius.circular(24),
              ),
              child: const Text('登录 / 注册',
                  style: TextStyle(
                      color: Colors.black,
                      fontSize: 15,
                      fontWeight: FontWeight.w600)),
            ),
          ),
          const SizedBox(height: 12),
          const Text('新邮箱将自动注册，与流萤音乐同一账号体系',
              style: TextStyle(
                  color: Color(AppTheme.textTertiary), fontSize: 11)),
        ],
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
    final today = DateTime.now().toString().split(' ')[0];
    final signedToday = _signins.contains(today);
    // 整页滚动（对齐音乐版我的页）：背景头+资料+Tab+内容全部在同一 CustomScrollView
    return RefreshIndicator(
      color: const Color(AppTheme.accent),
      backgroundColor: const Color(AppTheme.card),
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
            if (n.metrics.extentAfter < 300) _loadFav(later: _tab == 2, refresh: false);
          }
          return false;
        },
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(child: _profileHeader(
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
            )),
            // 文字 Tab：帖子 / 收藏 / 稍后看
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                child: Row(
                  children: [
                    _mineSeg(0, '帖子'),
                    const SizedBox(width: 28),
                    _mineSeg(1, '收藏'),
                    const SizedBox(width: 28),
                    _mineSeg(2, '稍后看'),
                  ],
                ),
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 8)),
            if (_tab == 0) _mineSliver() else _favSliver(later: _tab == 2),
          ],
        ),
      ),
    );
  }

  /// 背景头 + 资料区 + 功能钮（对齐概念稿/音乐版：渐变背景 + 遮罩融合 + 左上签到 + 右上编辑资料/分享/设置）
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
  }) {
    return Stack(
      children: [
        // 背景：深绿渐变（概念稿深色 + 薄荷绿氛围）
        Container(
          height: 330,
          width: double.infinity,
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF1E3A31), Color(0xFF101318)],
            ),
          ),
          child: Stack(
            children: [
              // 光晕装饰圆
              Positioned(
                right: -40,
                top: -60,
                child: Container(
                  width: 170,
                  height: 170,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(AppTheme.accent)
                        .withValues(alpha: 0.09),
                  ),
                ),
              ),
              Positioned(
                left: -50,
                bottom: 40,
                child: Container(
                  width: 150,
                  height: 150,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(AppTheme.sky).withValues(alpha: 0.05),
                  ),
                ),
              ),
            ],
          ),
        ),
        // 底部渐变遮罩：背景与内容自然融合（音乐版衔接方式）
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: 110,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    const Color(AppTheme.bg).withValues(alpha: 0.92),
                  ],
                ),
              ),
            ),
          ),
        ),
        // 内容
        Positioned.fill(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 顶部行：左上签到胶囊 + 右上 编辑资料/分享/设置
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 左上角签到（概念稿/用户要求）
                    GestureDetector(
                      onTap: signedToday ? null : _signin,
                      child: Container(
                        height: 32,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(AppTheme.radiusPill),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              signedToday
                                  ? Icons.check_circle
                                  : Icons.calendar_today_outlined,
                              color: signedToday
                                  ? const Color(AppTheme.accent)
                                  : Colors.white,
                              size: 14,
                            ),
                            const SizedBox(width: 5),
                            Text(
                              signedToday ? '已签到' : '每日签到',
                              style: TextStyle(
                                color: signedToday
                                    ? const Color(AppTheme.accent)
                                    : Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const Spacer(),
                    _roundIcon(Icons.edit_outlined, '编辑资料', _editProfile),
                    const SizedBox(width: 8),
                    _roundIcon(Icons.share_outlined, '分享', _shareProfile),
                    const SizedBox(width: 8),
                    _roundIcon(Icons.settings_outlined, '设置', () {
                      Navigator.push(context,
                          MaterialPageRoute(builder: (_) => const SettingsPage()));
                    }),
                  ],
                ),
                const SizedBox(height: 26),
                // slogan（概念稿：萤火相聚·点亮彼此）
                const Text('萤火相聚·点亮彼此',
                    style: TextStyle(
                        color: Color(AppTheme.accent),
                        fontSize: 13,
                        letterSpacing: 1.2,
                        fontWeight: FontWeight.w500)),
                const SizedBox(height: 10),
                // 头像 + 昵称/简介
                Row(
                  children: [
                    Stack(
                      children: [
                        Container(
                          width: 66,
                          height: 66,
                          padding: const EdgeInsets.all(2),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: const Color(AppTheme.card),
                            border: _myFrame.isNotEmpty
                                ? Border.all(
                                    color: const Color(AppTheme.accent),
                                    width: 2.5)
                                : null,
                          ),
                          child: UserAvatar(
                              url: _avatar ?? '',
                              name: _name ?? '',
                              size: 62),
                        ),
                        if (verified || adminLevel > 0)
                          Positioned(
                            right: 0,
                            bottom: 0,
                            child: Container(
                              width: 22,
                              height: 22,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: const LinearGradient(
                                    colors: [
                                      Color(AppTheme.accent),
                                      Color(AppTheme.sky)
                                    ]),
                                border: Border.all(
                                    color: const Color(AppTheme.bg),
                                    width: 2),
                              ),
                              alignment: Alignment.center,
                              child: Text(
                                verified ? 'V' : '管',
                                style: const TextStyle(
                                    color: Colors.black,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w800,
                                    height: 1),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(_name ?? '用户',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        color: Color(AppTheme.textPrimary),
                                        fontSize: 19,
                                        fontWeight: FontWeight.bold)),
                              ),
                              if (verifiedLabel.isNotEmpty) ...[
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 5, vertical: 1.5),
                                  decoration: BoxDecoration(
                                    color:
                                        const Color(AppTheme.accentSoft),
                                    borderRadius: BorderRadius.circular(5),
                                  ),
                                  child: Text(
                                    verifiedLabel,
                                    style: const TextStyle(
                                        color: Color(AppTheme.accent),
                                        fontSize: 9.5,
                                        fontWeight: FontWeight.w600),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          if (signature.isNotEmpty) ...[
                            const SizedBox(height: 3),
                            Text(signature,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    color: Color(AppTheme.textSecondary),
                                    fontSize: 12.5,
                                    height: 1.4)),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                // 统计行：关注 / 粉丝 / 帖子（点击进入列表/切 Tab）
                Row(
                  children: [
                    _statTap(followings, '关注', () {
                      if (ApiClient.userId == null) return;
                      Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => UserListPage(
                                  uid: ApiClient.userId!,
                                  kind: 'followings',
                                  title: '关注')));
                    }),
                    const SizedBox(width: 36),
                    _statTap(followers, '粉丝', () {
                      if (ApiClient.userId == null) return;
                      Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => UserListPage(
                                  uid: ApiClient.userId!,
                                  kind: 'followers',
                                  title: '粉丝')));
                    }),
                    const SizedBox(width: 36),
                    GestureDetector(
                      onTap: () => setState(() => _tab = 0),
                      behavior: HitTestBehavior.opaque,
                      child: _statItem('帖子', _cnt(_postCount)),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // 等级进度条
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: const Color(AppTheme.accent)
                            .withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text('Lv.$level',
                          style: const TextStyle(
                              color: Color(AppTheme.accent),
                              fontSize: 12,
                              fontWeight: FontWeight.bold)),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: LinearProgressIndicator(
                          value: progress.toDouble().clamp(0.0, 1.0),
                          minHeight: 5,
                          backgroundColor: const Color(AppTheme.card),
                          color: const Color(AppTheme.accent),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      next == null ? '已满级' : '经验 $exp',
                      style: const TextStyle(
                          color: Color(AppTheme.textTertiary),
                          fontSize: 11),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                // 轻量入口行：任务 / 个性装扮（签到已移左上角，反馈/关于移入设置页）
                Row(
                  children: [
                    _pillEntry(Icons.emoji_events_outlined, '任务', () {
                      Navigator.push(context,
                          MaterialPageRoute(builder: (_) => const TaskCenterPage()));
                    }),
                    const SizedBox(width: 8),
                    _pillEntry(Icons.auto_awesome_outlined, '个性装扮',
                        _openFrames),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 右上角圆形图标（半透明白底）
  Widget _roundIcon(IconData icon, String tooltip, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.12),
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: Icon(icon, color: Colors.white, size: 17),
      ),
    );
  }

  /// 可点击统计项
  Widget _statTap(int value, String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: _statItem(label, _cnt(value)),
    );
  }

  /// 编辑资料（昵称/简介）→ POST /user/me
  Future<void> _editProfile() async {
    final nameCtrl = TextEditingController(text: _name ?? '');
    final sigCtrl = TextEditingController(text: (ApiClient.meSignature ?? ''));
    var saving = false;
    await showModalBottomSheet(
      context: context,
      backgroundColor: const Color(AppTheme.card),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => Padding(
          padding: EdgeInsets.only(
              left: 16, right: 16, top: 16, bottom: MediaQuery.of(ctx).viewInsets.bottom + 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('编辑资料',
                  style: TextStyle(
                      color: Color(AppTheme.textPrimary),
                      fontSize: 16,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 14),
              TextField(
                controller: nameCtrl,
                maxLength: 20,
                style: const TextStyle(color: Color(AppTheme.textPrimary)),
                cursorColor: const Color(AppTheme.accent),
                decoration: InputDecoration(
                  labelText: '昵称',
                  labelStyle: const TextStyle(
                      color: Color(AppTheme.textSecondary)),
                  filled: true,
                  fillColor: const Color(AppTheme.bg),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: sigCtrl,
                maxLength: 80,
                maxLines: 2,
                style: const TextStyle(color: Color(AppTheme.textPrimary)),
                cursorColor: const Color(AppTheme.accent),
                decoration: InputDecoration(
                  labelText: '简介',
                  labelStyle: const TextStyle(
                      color: Color(AppTheme.textSecondary)),
                  filled: true,
                  fillColor: const Color(AppTheme.bg),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none),
                ),
              ),
              const SizedBox(height: 14),
              GestureDetector(
                onTap: saving
                    ? null
                    : () async {
                        setSt(() => saving = true);
                        try {
                          await ApiClient.updateProfile(
                              name: nameCtrl.text.trim(),
                              signature: sigCtrl.text.trim());
                          if (!ctx.mounted) return;
                          Navigator.pop(ctx);
                          await _init();
                        } catch (e) {
                          if (!ctx.mounted) return;
                          setSt(() => saving = false);
                          ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                              content: Text('$e'),
                              backgroundColor: const Color(AppTheme.card)));
                        }
                      },
                child: Container(
                  width: double.infinity,
                  height: 44,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: const Color(AppTheme.accent),
                    borderRadius: BorderRadius.circular(AppTheme.radiusPill),
                  ),
                  child: saving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.black))
                      : const Text('保存',
                          style: TextStyle(
                              color: Colors.black,
                              fontSize: 15,
                              fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 分享我的主页（复制链接）
  void _shareProfile() {
    final uid = ApiClient.userId ?? '';
    final url = 'https://www.dbmt999.asia/community/share.html?uid=$uid';
    Clipboard.setData(ClipboardData(text: url));
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('主页链接已复制，去分享给好友吧'),
        backgroundColor: Color(AppTheme.card),
        behavior: SnackBarBehavior.floating));
  }

  /// 帖子 sliver：双列图片网格（对齐概念稿图片网格）
  Widget _mineSliver() {
    if (_mineLoading && _mine.isEmpty) {
      return const SliverFillRemaining(
        hasScrollBody: false,
        child: Center(
            child: CircularProgressIndicator(
                color: Color(AppTheme.accent))),
      );
    }
    if (_mineLoaded && _mine.isEmpty) {
      return SliverFillRemaining(
        hasScrollBody: false,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.article_outlined,
                size: 52, color: Color(AppTheme.textTertiary)),
            const SizedBox(height: 10),
            const Text('还没有发布过帖子',
                style: TextStyle(
                    color: Color(AppTheme.textSecondary), fontSize: 13)),
            const SizedBox(height: 12),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(AppTheme.accent),
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(22)),
              ),
              onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const PostEditorPage(mode: 'text'))),
              child: const Text('去发布'),
            ),
          ],
        ),
      );
    }
    return _imgSliver(_mine);
  }

  /// 收藏/稍后看 sliver
  Widget _favSliver({required bool later}) {
    final items = later ? _laters : _favs;
    final loading = later ? _laterLoading : _favLoading;
    final loaded = later ? _laterLoaded : _favLoaded;
    if (loading && items.isEmpty) {
      return const SliverFillRemaining(
        hasScrollBody: false,
        child: Center(
            child: CircularProgressIndicator(
                color: Color(AppTheme.accent))),
      );
    }
    if (loaded && items.isEmpty) {
      return SliverFillRemaining(
        hasScrollBody: false,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(later ? Icons.schedule_outlined : Icons.bookmark_border,
                size: 52, color: const Color(AppTheme.textTertiary)),
            const SizedBox(height: 10),
            Text(later ? '暂无稍后看内容' : '暂无收藏内容',
                style: const TextStyle(
                    color: Color(AppTheme.textSecondary), fontSize: 13)),
          ],
        ),
      );
    }
    return _imgSliver(items);
  }

  /// 双列图片网格
  Widget _imgSliver(List<FeedItem> items) {
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 0.95,
        ),
        delegate: SliverChildBuilderDelegate((_, i) {
          final it = items[i];
          final thumb = (it.type == 'video' && it.cover.isNotEmpty)
              ? it.cover
              : (it.images.isNotEmpty ? it.images.first : '');
          return GestureDetector(
            onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => PostDetailPage(postId: it.id))),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (thumb.isNotEmpty)
                    Image.network(
                      thumb.startsWith('http') ? thumb : mediaUrl(thumb),
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => Container(
                          color: const Color(AppTheme.elevated)),
                    )
                  else
                    Container(
                      color: const Color(AppTheme.card),
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.all(10),
                          child: Text(it.content,
                              maxLines: 4,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: Color(AppTheme.textSecondary),
                                  fontSize: 12.5)),
                        ),
                      ),
                    ),
                  if (it.type == 'video')
                    const Center(
                      child: Icon(Icons.play_circle_fill,
                          color: Colors.white, size: 30),
                    ),
                  // 底部渐变 + 数据
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Container(
                      padding:
                          const EdgeInsets.fromLTRB(8, 12, 8, 6),
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Colors.transparent, Colors.black54],
                        ),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.favorite,
                              size: 11, color: Colors.white),
                          const SizedBox(width: 3),
                          Text(_cnt(it.likeCount),
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 10.5)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        }, childCount: items.length),
      ),
    );
  }

  String _cnt(int n) {
    if (n >= 10000) {
      final w = n / 10000;
      return w >= 100 ? '${(w).toStringAsFixed(0)}万' : '${w.toStringAsFixed(1)}万';
    }
    return '$n';
  }

  Widget _statItem(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(value,
            style: const TextStyle(
                color: Color(AppTheme.textPrimary),
                fontSize: 17,
                fontWeight: FontWeight.w700)),
        const SizedBox(height: 2),
        Text(label,
            style: const TextStyle(
                color: Color(AppTheme.textTertiary), fontSize: 11.5)),
      ],
    );
  }

  Widget _pillEntry(IconData icon, String label, VoidCallback? onTap) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          height: 34,
          decoration: BoxDecoration(
            color: const Color(AppTheme.card),
            borderRadius: BorderRadius.circular(AppTheme.radiusPill),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon,
                  size: 15,
                  color: onTap == null
                      ? const Color(AppTheme.accent)
                      : const Color(AppTheme.textSecondary)),
              const SizedBox(width: 5),
              Text(label,
                  style: const TextStyle(
                      color: Color(AppTheme.textPrimary),
                      fontSize: 12,
                      fontWeight: FontWeight.w500)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _mineSeg(int i, String label) {
    final sel = _tab == i;
    return GestureDetector(
      onTap: () => setState(() => _tab = i),
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label,
                style: TextStyle(
                    color: sel
                        ? const Color(AppTheme.textPrimary)
                        : const Color(AppTheme.textSecondary),
                    fontSize: 14.5,
                    fontWeight: sel ? FontWeight.w600 : FontWeight.w400)),
            const SizedBox(height: 4),
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              width: 18,
              height: 2,
              decoration: BoxDecoration(
                color: sel
                    ? const Color(AppTheme.accent)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          ],
        ),
      ),
    );
  }



}
