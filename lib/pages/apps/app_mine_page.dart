/// 我的应用投稿：显示审核状态、驳回原因，并支持草稿/被拒投稿修改后重新提交。
library;

import 'package:flutter/material.dart';

import '../../api/app_market_api.dart';
import '../../api/client.dart';
import '../../design/components.dart';
import '../../models/app_market.dart';
import '../mine/login_page.dart';
import 'app_detail_page.dart';
import 'app_submit_page.dart';
import 'app_widgets.dart';

class AppMinePage extends StatefulWidget {
  const AppMinePage({super.key});

  @override
  State<AppMinePage> createState() => _AppMinePageState();
}

class _AppMinePageState extends State<AppMinePage> {
  List<MarketApp> _apps = const [];
  bool _loaded = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    if (!mounted) return;
    if (ApiClient.token == null || ApiClient.token!.isEmpty) {
      final ok = await Navigator.of(context)
          .push<bool>(MaterialPageRoute(builder: (_) => const LoginPage()));
      if (!mounted) return;
      if (ok != true) {
        Navigator.of(context).maybePop();
        return;
      }
    }
    if (mounted) {
      setState(() => _error = null);
    }
    try {
      final list = await AppMarketApi.mine();
      if (!mounted) return;
      setState(() {
        _apps = list;
        _loaded = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loaded = true;
        _error = e.toString();
      });
    }
  }

  Future<void> _openSubmit() async {
    final result = await Navigator.of(context)
        .push<bool>(MaterialPageRoute(builder: (_) => const AppSubmitPage()));
    if (result == true && mounted) _load();
  }

  Future<void> _openItem(MarketApp app) async {
    if (app.status == 2) {
      Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => AppDetailPage(appId: app.id)));
      return;
    }
    if (app.needsEdit) {
      final result = await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => AppSubmitPage(existing: app)),
      );
      if (result == true && mounted) _load();
      return;
    }
    if (app.status == 1) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(AppColors.card),
          title: const Text('审核中', style: AppType.title),
          content: Text(
            '《${app.name}》已提交人工审核，通常会尽快处理。审核通过后会显示在应用市场。',
            style: AppType.bodySm,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
      return;
    }
    showAppToast(context, app.statusText.isEmpty ? '当前状态不可操作' : app.statusText);
  }

  @override
  Widget build(BuildContext context) {
    return ImmersivePage(
      child: Column(
        children: [
          GlassTopBar(
            title: '我的投稿',
            subtitle: '新投稿默认人工审核',
            solid: true,
            actions: [
              IconCircleButton(
                icon: Icons.add_rounded,
                size: 36,
                iconSize: 18,
                color: const Color(AppColors.accent),
                background: const Color(AppColors.accent)
                    .withValues(alpha: 0.12),
                tooltip: '投稿应用',
                onTap: _openSubmit,
              ),
              const SizedBox(width: 4),
            ],
          ),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _body() {
    if (!_loaded) {
      return const Center(
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: Color(AppColors.accent),
        ),
      );
    }
    return RefreshIndicator(
      color: const Color(AppColors.accent),
      backgroundColor: const Color(AppColors.card),
      onRefresh: _load,
      child: _error != null
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                const SizedBox(height: 70),
                EmptyState(
                  icon: Icons.cloud_off_rounded,
                  title: '加载失败',
                  message: _error,
                  actionLabel: '重新加载',
                  onAction: _load,
                ),
              ],
            )
          : _apps.isEmpty
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                const SizedBox(height: 70),
                EmptyState(
                  icon: Icons.upload_file_rounded,
                  title: '还没有投稿',
                  message: '把你的好应用分享给社区，审核通过后会出现在应用市场',
                  actionLabel: '投稿第一个应用',
                  onAction: _openSubmit,
                ),
              ],
            )
          : ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(
                parent: BouncingScrollPhysics(),
              ),
              padding: EdgeInsets.fromLTRB(
                AppSpace.gutter,
                AppSpace.x3,
                AppSpace.gutter,
                MediaQuery.paddingOf(context).bottom + 30,
              ),
              itemCount: _apps.length,
              separatorBuilder: (_, _) => const SizedBox(height: AppSpace.x3),
              itemBuilder: (context, i) {
                final app = _apps[i];
                final label = switch (app.status) {
                  0 => '继续填写',
                  1 => '审核中',
                  2 => '查看详情',
                  3 => '修改重投',
                  4 => '已下架',
                  _ => '查看',
                };
                return AppListTile(
                  app: app,
                  showStatus: true,
                  onTap: () => _openItem(app),
                  trailing: PillButton(
                    label: label,
                    size: PillSize.sm,
                    variant: app.status == 3
                        ? PillVariant.danger
                        : app.status == 2
                        ? PillVariant.primary
                        : PillVariant.ghost,
                    onTap: () => _openItem(app),
                  ),
                );
              },
            ),
    );
  }
}
