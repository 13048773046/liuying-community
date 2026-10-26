/// 我的页（P0）：登录互通 + 等级进度 + 签到 + 个性装扮（头像框）+ 任务
library;

import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../api/client.dart';
import '../../config.dart';
import '../../models/feed_item.dart';
import '../../services/notify_bus.dart';
import '../../widgets/user_avatar.dart';
import '../../widgets/waterfall_card.dart';
import '../feedback/feedback_page.dart';
import '../post/post_detail.dart';
import '../post/post_editor.dart';
import '../settings/settings_page.dart';
import '../user/user_profile.dart';
import 'login_page.dart';
import 'task_center_page.dart';

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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 16:9 横幅（渐变 + 光晕，右上设置）
        SizedBox(
          height: 148,
          width: double.infinity,
          child: Stack(
            children: [
              Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFF1E3A31), Color(0xFF101318)],
                  ),
                ),
              ),
              // 光晕装饰圆
              Positioned(
                right: -30,
                top: -40,
                child: Container(
                  width: 130,
                  height: 130,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(AppTheme.accent)
                        .withValues(alpha: 0.08),
                  ),
                ),
              ),
              Positioned(
                left: 24,
                bottom: 18,
                child: Text('流萤社区',
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.85),
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 2)),
              ),
              // 设置入口（右上）
              Positioned(
                top: 8,
                right: 8,
                child: IconButton(
                  onPressed: () => Navigator.push(context,
                      MaterialPageRoute(
                          builder: (_) => const SettingsPage())),
                  icon: const Icon(Icons.settings_outlined,
                      color: Color(AppTheme.textSecondary), size: 20),
                ),
              ),
            ],
          ),
        ),
        // 头像叠层 + 资料区
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
          child: Transform.translate(
            offset: const Offset(0, -34),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    // 头像 76px（叠横幅） + 认证徽章
                    Stack(
                      children: [
                        Container(
                          width: 78,
                          height: 78,
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
                              size: 74),
                        ),
                        if (verified || adminLevel > 0)
                          Positioned(
                            right: 0,
                            bottom: 0,
                            child: Container(
                              width: 24,
                              height: 24,
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
                                verified
                                    ? 'V'
                                    : (adminLevel == 1 ? '管' : '管'),
                                style: const TextStyle(
                                    color: Colors.black,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w800,
                                    height: 1),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 8),
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
                                          fontSize: 20,
                                          fontWeight: FontWeight.bold)),
                                ),
                                if (verifiedLabel.isNotEmpty) ...[
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 5, vertical: 1.5),
                                    decoration: BoxDecoration(
                                      color: const Color(AppTheme.accentSoft),
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
                    ),
                  ],
                ),
                // 统计行：关注 / 粉丝 / 帖子
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Row(
                    children: [
                      _statItem('关注', _cnt(followings)),
                      const SizedBox(width: 36),
                      _statItem('粉丝', _cnt(followers)),
                      const SizedBox(width: 36),
                      _statItem('帖子', _cnt(_postCount)),
                    ],
                  ),
                ),
                // 等级进度条
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Row(
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
                ),
                // 编辑资料 pill
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: GestureDetector(
                    onTap: () {
                      final uid = ApiClient.userId;
                      if (uid == null) return;
                      Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) =>
                                  UserProfilePage(uid: uid)));
                    },
                    child: Container(
                      height: 34,
                      width: double.infinity,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        borderRadius:
                            BorderRadius.circular(AppTheme.radiusPill),
                        border: Border.all(
                            color: const Color(AppTheme.border)),
                      ),
                      child: const Text('编辑资料',
                          style: TextStyle(
                              color: Color(AppTheme.textPrimary),
                              fontSize: 13,
                              fontWeight: FontWeight.w500)),
                    ),
                  ),
                ),
                // 轻量入口行：任务 / 签到 / 装扮 / 反馈 / 关于
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Row(
                    children: [
                      _pillEntry(Icons.emoji_events_outlined, '任务', () {
                        Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => const TaskCenterPage()));
                      }),
                      const SizedBox(width: 8),
                      _pillEntry(
                          signedToday
                              ? Icons.check_circle
                              : Icons.calendar_today_outlined,
                          signedToday ? '已签到' : '每日签到',
                          signedToday ? null : _signin),
                      const SizedBox(width: 8),
                      _pillEntry(Icons.auto_awesome_outlined, '个性装扮',
                          _openFrames),
                      const SizedBox(width: 8),
                      _pillEntry(Icons.feedback_outlined, '意见反馈', () {
                        Navigator.push(context,
                            MaterialPageRoute(
                                builder: (_) => const FeedbackPage()));
                      }),
                      const SizedBox(width: 8),
                      _pillEntry(Icons.info_outline, '关于', _showAbout),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        // 文字 Tab：帖子 / 收藏 / 稍后看
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
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
        const SizedBox(height: 4),
        // 作品内容
        Expanded(child: _tabBody()),
      ],
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

  Widget _tabBody() {
    if (_tab == 0) return _mineGrid();
    return _favGrid(later: _tab == 2);
  }

  /// 我的帖子：双列瀑布流（任务已移至任务中心，不再内嵌）
  Widget _mineGrid() {
    return RefreshIndicator(
      onRefresh: () async {
        await _loadMine(refresh: true);
        await _loadExtras();
      },
      color: const Color(AppTheme.accent),
      backgroundColor: const Color(AppTheme.card),
      child: _mine.isEmpty && _mineLoading
          ? const Center(
              child: CircularProgressIndicator(
                  color: Color(AppTheme.accent)))
          : _mine.isEmpty && _mineLoaded
              ? ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: [
                    const SizedBox(height: 100),
                    Center(
                      child: Column(
                        children: [
                          const Icon(Icons.article_outlined,
                              size: 52,
                              color: Color(AppTheme.textTertiary)),
                          const SizedBox(height: 10),
                          const Text('还没有发布过帖子',
                              style: TextStyle(
                                  color: Color(AppTheme.textSecondary),
                                  fontSize: 13)),
                          const SizedBox(height: 12),
                          FilledButton(
                            style: FilledButton.styleFrom(
                              backgroundColor:
                                  const Color(AppTheme.accent),
                              foregroundColor: Colors.black,
                              shape: RoundedRectangleBorder(
                                  borderRadius:
                                      BorderRadius.circular(22)),
                            ),
                            onPressed: () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                    builder: (_) =>
                                        const PostEditorPage(mode: 'text'))),
                            child: const Text('去发布'),
                          ),
                        ],
                      ),
                    ),
                  ],
                )
              : NotificationListener<ScrollNotification>(
                  onNotification: (n) {
                    if (n.metrics.extentAfter < 300) {
                      _loadMine(refresh: false);
                    }
                    return false;
                  },
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding:
                        const EdgeInsets.fromLTRB(12, 4, 12, 20),
                    children: [
                      MasonryGridView.count(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        crossAxisCount: 2,
                        mainAxisSpacing: 12,
                        crossAxisSpacing: 12,
                        itemCount: _mine.length,
                        itemBuilder: (_, i) => WaterfallCard(
                          item: _mine[i],
                          onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => PostDetailPage(
                                      postId: _mine[i].id))),
                        ),
                      ),
                    ],
                  ),
                ),
    );
  }

  /// 收藏 / 稍后看：双列瀑布流
  Widget _favGrid({required bool later}) {
    final items = later ? _laters : _favs;
    final loading = later ? _laterLoading : _favLoading;
    final loaded = later ? _laterLoaded : _favLoaded;
    return RefreshIndicator(
      onRefresh: () async => _loadFav(later: later, refresh: true),
      color: const Color(AppTheme.accent),
      backgroundColor: const Color(AppTheme.card),
      child: items.isEmpty && loading
          ? const Center(
              child: CircularProgressIndicator(
                  color: Color(AppTheme.accent)))
          : items.isEmpty && loaded
              ? ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: [
                    const SizedBox(height: 100),
                    Center(
                      child: Column(
                        children: [
                          Icon(
                              later
                                  ? Icons.schedule_outlined
                                  : Icons.bookmark_border,
                              size: 52,
                              color: const Color(AppTheme.textTertiary)),
                          const SizedBox(height: 10),
                          Text(
                              later ? '暂无稍后看内容' : '暂无收藏内容',
                              style: const TextStyle(
                                  color: Color(AppTheme.textSecondary),
                                  fontSize: 13)),
                        ],
                      ),
                    ),
                  ],
                )
              : NotificationListener<ScrollNotification>(
                  onNotification: (n) {
                    if (n.metrics.extentAfter < 300) {
                      _loadFav(later: later, refresh: false);
                    }
                    return false;
                  },
                  child: MasonryGridView.count(
                    physics: const AlwaysScrollableScrollPhysics(),
                    crossAxisCount: 2,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 20),
                    itemCount: items.length,
                    itemBuilder: (_, i) => WaterfallCard(
                      item: items[i],
                      onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) =>
                                  PostDetailPage(postId: items[i].id))),
                    ),
                  ),
                ),
    );
  }

  void _showAbout() {
    showAboutDialog(
      context: context,
      applicationName: '流萤社区',
      applicationVersion: '1.0.0',
      applicationIcon: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
              colors: [Color(AppTheme.accent), Color(AppTheme.sky)]),
          borderRadius: BorderRadius.circular(12),
        ),
        alignment: Alignment.center,
        child: const Icon(Icons.public, color: Colors.black, size: 26),
      ),
      children: [
        const Text('流萤社区 · 与流萤音乐同一账号体系\n'
            '问题反馈请使用「意见反馈」入口',
            style: TextStyle(
                color: Color(AppTheme.textSecondary),
                fontSize: 12,
                height: 1.6)),
      ],
    );
  }
}

