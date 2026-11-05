/// 设置页：账号信息 + 通用设置 + 关于社区 + 退出登录
library;

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../config.dart';
import '../../design/components.dart';
import '../../services/auth_session.dart';
import '../favorites/favorites_page.dart';
import '../feedback/feedback_page.dart';
import '../mine/frames_page.dart';
import '../mine/login_page.dart';
import '../mine/task_center_page.dart';
import '../user/user_profile.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  Map<String, dynamic>? _me;
  bool _clearing = false;

  @override
  void initState() {
    super.initState();
    _loadMe();
  }

  Future<void> _loadMe() async {
    if (ApiClient.token == null) return;
    try {
      final j = await ApiClient.myProfile();
      if (!mounted) return;
      setState(() => _me = Map<String, dynamic>.from(j['user'] as Map));
    } catch (_) {}
  }

  Future<void> _logout() async {
    await AuthSession.logout();
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  /// 切换账号底部弹窗（与音乐端「切换账号」UI 一致）
  Future<void> _showSwitchDialog() async {
    final accounts = await AuthSession.loadAccounts();
    if (!mounted) return;
    var accs = accounts;
    final currentUid = ApiClient.userId ?? '';
    var switched = false;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => SheetShell(
        title: '切换账号',
        subtitle: '选择本地保存的账号快速登录',
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: AppSpace.x4),
          child: _card([
            for (var idx = 0; idx < accs.length; idx++) ...[
              _accountRow(
                ctx: ctx,
                account: accs[idx],
                currentUid: currentUid,
                onSwitched: () {
                  switched = true;
                  _me = null;
                },
              ),
              if (idx < accs.length - 1) const Hairline(indent: 72),
            ],
            if (accs.isNotEmpty) const Hairline(indent: 72),
            ListRow(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpace.x4,
                vertical: AppSpace.x3,
              ),
              showChevron: false,
              leading: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                      color: Colors.white.withValues(alpha: 0.18)),
                ),
                child: const Icon(Icons.add_rounded,
                    size: 20, color: Color(AppColors.textTertiary)),
              ),
              title: '添加账号',
              onTap: () async {
                Navigator.pop(ctx);
                final ok = await Navigator.of(context).push<bool>(
                  MaterialPageRoute(builder: (_) => const LoginPage()),
                );
                if (ok == true) {
                  if (!mounted) return;
                  setState(() => _me = null);
                  await _loadMe();
                }
              },
            ),
          ]),
        ),
      ),
    );
    if (switched && mounted) {
      Navigator.of(context).pop(true);
    }
  }

  /// 历史账号行（弹窗内）
  Widget _accountRow({
    required BuildContext ctx,
    required SavedAccount account,
    required String currentUid,
    required VoidCallback onSwitched,
  }) {
    final isCurrent = account.uid == currentUid;
    return ListRow(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.x4,
        vertical: AppSpace.x3,
      ),
      showChevron: false,
      leading: AppAvatar(
        url: account.avatarUrl,
        name: account.name,
        size: 44,
      ),
      title: account.name.isEmpty ? '用户' : account.name,
      subtitle: '账号 ${account.account}',
      trailing: Container(
        width: 20,
        height: 20,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: isCurrent
              ? const Color(AppColors.accent)
              : Colors.transparent,
          border: isCurrent
              ? null
              : Border.all(color: Colors.white.withValues(alpha: 0.25)),
        ),
        alignment: Alignment.center,
        child: isCurrent
            ? const Icon(Icons.check_rounded,
                size: 12, color: Color(AppColors.onAccent))
            : null,
      ),
      onTap: () async {
        if (isCurrent) {
          Navigator.pop(ctx);
          return;
        }
        // 切换：注入 token + 重连通知
        await AuthSession.switchTo(account);
        if (!ctx.mounted) return;
        Navigator.pop(ctx, true);
        if (!mounted) return;
        setState(onSwitched);
        await _loadMe();
      },
    );
  }

  Future<void> _clearCache() async {
    if (_clearing) return;
    setState(() => _clearing = true);
    try {
      // 真实清理：图片内存缓存（磁盘缓存位于 flutter_cache_manager，
      // 该包仅为 cached_network_image 的传递依赖、未在 pubspec 声明，故不直接引用）
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      if (!mounted) return;
      showAppToast(context, '图片缓存已清理');
    } catch (_) {
      if (!mounted) return;
      showAppToast(context, '清理失败');
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
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
            colors: [Color(AppColors.accent), Color(AppColors.accentPressed)],
          ),
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
        alignment: Alignment.center,
        child: const Icon(Icons.public_rounded,
            color: Color(AppColors.onAccent), size: 24),
      ),
      children: [
        Text(
          '流萤社区 · 与流萤音乐同一账号体系\n'
          '问题反馈请使用「意见反馈」入口，或发送邮件至 yosar027@163.com',
          style: AppType.bodySm.copyWith(height: 1.6),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = _me;
    final name = (user?['name'] ?? '') as String;
    final avRaw = (user?['avatar'] ?? '') as String;
    final avatar = avRaw.isEmpty
        ? ''
        : avatarUrlOf((user?['id'] ?? '') as String);
    final email = (user?['email'] ?? '') as String;
    return ImmersivePage(
      child: Column(
        children: [
          const GlassTopBar(title: '设置', solid: true),
          Expanded(
            child: ListView(
              physics: const BouncingScrollPhysics(),
              padding: EdgeInsets.fromLTRB(
                AppSpace.gutter,
                AppSpace.x2,
                AppSpace.gutter,
                AppSpace.x6 + MediaQuery.paddingOf(context).bottom,
              ),
              children: [
                if (ApiClient.token != null) ...[
                  _accountCard(name: name, avatar: avatar, email: email),
                  _section('功能'),
                  _card([
                    _row(Icons.emoji_events_outlined, '每日签到', () {
                      Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => const TaskCenterPage()));
                    }),
                    const Hairline(indent: 48),
                    _row(Icons.auto_awesome_outlined, '个性装扮', () {
                      Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => const FramesPage()));
                    }),
                    const Hairline(indent: 48),
                    _row(Icons.bookmark_border_rounded, '我的收藏', () {
                      Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => const FavoritesPage()));
                    }),
                    const Hairline(indent: 48),
                    _row(Icons.feedback_outlined, '意见反馈', () {
                      Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => const FeedbackPage()));
                    }),
                  ]),
                  _section('通用'),
                  _card([
                    _row(
                      Icons.cleaning_services_outlined,
                      _clearing ? '清理中…' : '清除缓存',
                      _clearing ? null : _clearCache,
                      trailing: _clearing
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                  strokeWidth: 1.8),
                            )
                          : null,
                    ),
                    const Hairline(indent: 48),
                    _row(Icons.info_outline_rounded, '关于社区', _showAbout),
                  ]),
                  _section('账号'),
                  _card([
                    _row(Icons.swap_horiz_rounded, '切换账号', _showSwitchDialog),
                  ]),
                  const SizedBox(height: AppSpace.x4),
                  PillButton(
                    label: '退出登录',
                    icon: Icons.logout_rounded,
                    variant: PillVariant.danger,
                    expand: true,
                    onTap: _logout,
                  ),
                ] else ...[
                  _guestCard(),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _accountCard({
    required String name,
    required String avatar,
    required String email,
  }) {
    return _card([
      ListRow(
        padding: const EdgeInsets.all(AppSpace.x4),
        leading: AppAvatar(url: avatar, name: name, size: 48),
        title: name.isEmpty ? '用户' : name,
        subtitle: email.isEmpty ? null : email,
        onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) =>
                    UserProfilePage(uid: ApiClient.userId ?? ''))),
      ),
    ]);
  }

  Widget _guestCard() {
    return _card([
      const EmptyState(
        icon: Icons.lock_outline_rounded,
        title: '登录后解锁全部功能',
        message: '收藏、意见反馈与更多设置需要登录',
        compact: true,
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpace.x4,
          0,
          AppSpace.x4,
          AppSpace.x4,
        ),
        child: PillButton(
          label: '登录 / 注册',
          size: PillSize.lg,
          expand: true,
          glow: true,
          onTap: () async {
            final ok = await Navigator.of(context).push<bool>(
              MaterialPageRoute(builder: (_) => const LoginPage()),
            );
            if (ok == true) _loadMe();
          },
        ),
      ),
    ]);
  }

  Widget _card(List<Widget> children) {
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: const Color(AppColors.card),
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: const Color(AppColors.border)),
      ),
      child: Column(children: children),
    );
  }

  Widget _section(String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.x1,
        AppSpace.x5,
        AppSpace.x1,
        AppSpace.x2,
      ),
      child: Text(
        label,
        style:
            AppType.caption.copyWith(color: const Color(AppColors.textTertiary)),
      ),
    );
  }

  Widget _row(
    IconData icon,
    String label,
    VoidCallback? onTap, {
    Widget? trailing,
  }) {
    return ListRow(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.x4,
        vertical: AppSpace.x4,
      ),
      leading: Icon(icon,
          size: 20, color: const Color(AppColors.textSecondary)),
      title: label,
      trailing: trailing,
      onTap: onTap,
    );
  }
}
