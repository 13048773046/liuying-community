/// 收藏的应用列表。与“我的投稿”分离：收藏只展示已上架应用。
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../api/app_market_api.dart';
import '../../api/client.dart';
import '../../design/components.dart';
import '../../models/app_market.dart';
import '../mine/login_page.dart';
import 'app_detail_page.dart';
import 'app_widgets.dart';

enum AppListMode { favorites }

class AppListPage extends StatefulWidget {
  const AppListPage({super.key, required this.mode, required this.title});

  final AppListMode mode;
  final String title;

  @override
  State<AppListPage> createState() => _AppListPageState();
}

class _AppListPageState extends State<AppListPage> {
  List<MarketApp> _apps = const [];
  bool _loaded = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    if (ApiClient.token == null || ApiClient.token!.isEmpty) {
      if (!mounted) return;
      final ok = await Navigator.of(context)
          .push<bool>(MaterialPageRoute(builder: (_) => const LoginPage()));
      if (!mounted) return;
      if (ok != true) {
        Navigator.of(context).maybePop();
        return;
      }
    }
    setState(() {
      _error = null;
    });
    try {
      final list = widget.mode == AppListMode.favorites
          ? await AppMarketApi.favorites()
          : <MarketApp>[];
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

  @override
  Widget build(BuildContext context) {
    return ImmersivePage(
      child: Column(
        children: [
          GlassTopBar(title: widget.title, solid: true),
          Expanded(
            child: RefreshIndicator(
              color: const Color(AppColors.accent),
              backgroundColor: const Color(AppColors.card),
              onRefresh: _load,
              child: !_loaded
                  ? const ShimmerScope(child: _AppListSkeleton())
                  : _error != null
                  ? ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                        const SizedBox(height: 80),
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
                        const SizedBox(height: 68),
                        EmptyState(
                          icon: Icons.bookmark_border_rounded,
                          title: '还没有收藏应用',
                          message: '在应用详情点收藏，就会出现在这里',
                          actionLabel: '去应用市场逛逛',
                          onAction: () => Navigator.of(context).maybePop(),
                        ),
                      ],
                    )
                  : ListView.separated(
                      scrollCacheExtent: const ScrollCacheExtent.pixels(300),
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
                      separatorBuilder: (_, _) =>
                          const SizedBox(height: AppSpace.x2),
                      itemBuilder: (context, i) => StaggerReveal(
                        key: ValueKey('fav-app-${_apps[i].id}'),
                        index: i,
                        delay: const Duration(milliseconds: 50),
                        duration: const Duration(milliseconds: 450),
                        offsetY: 24,
                        child: AppListTile(
                          app: _apps[i],
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => AppDetailPage(appId: _apps[i].id),
                            ),
                          ),
                          trailing: const Icon(
                            Icons.chevron_right_rounded,
                            size: 20,
                            color: Color(AppColors.textTertiary),
                          ),
                        ),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 收藏应用列表的首屏骨架：与真实行同高，避免从加载态到列表时跳版。
class _AppListSkeleton extends StatelessWidget {
  const _AppListSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: EdgeInsets.fromLTRB(
        AppSpace.gutter,
        AppSpace.x3,
        AppSpace.gutter,
        MediaQuery.paddingOf(context).bottom + 30,
      ),
      physics: const NeverScrollableScrollPhysics(),
      children: List.generate(
        5,
        (_) => Padding(
          padding: const EdgeInsets.only(bottom: AppSpace.x2),
          child: Container(
            height: 108,
            padding: const EdgeInsets.all(AppSpace.x3),
            decoration: BoxDecoration(
              color: const Color(AppColors.card).withValues(alpha: 0.42),
              borderRadius: BorderRadius.circular(AppRadius.lg),
              border: Border.all(color: const Color(AppColors.hairline)),
            ),
            child: const Row(
              children: [
                SkeletonBox(width: 58, height: 58, radius: AppRadius.md),
                SizedBox(width: AppSpace.x3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SkeletonBox(width: 132, height: 13),
                      SizedBox(height: 9),
                      SkeletonBox(width: 210, height: 10),
                      SizedBox(height: 9),
                      SkeletonBox(width: 80, height: 9),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
