/// 应用详情 · iOS 安装确认
///
/// 关键事实要提前说清楚：iOS 的安装由系统接管，本 App 只能“发起”，
/// 不能替系统完成签名校验；未签名 / 证书过期的 IPA 会在系统弹窗后失败。
library;

import 'package:flutter/material.dart';

import '../../design/components.dart';
import '../../models/app_market.dart';
import '../../services/app_install_service.dart';
import 'app_widgets.dart';

enum AppIosInstallOutcome { installed, download }

Future<AppIosInstallOutcome?> showAppIosInstallSheet(
  BuildContext context,
  MarketApp app,
) {
  return showModalBottomSheet<AppIosInstallOutcome>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => AppIosInstallSheet(app: app),
  );
}

class AppIosInstallSheet extends StatefulWidget {
  const AppIosInstallSheet({super.key, required this.app});

  final MarketApp app;

  @override
  State<AppIosInstallSheet> createState() => _AppIosInstallSheetState();
}

class _AppIosInstallSheetState extends State<AppIosInstallSheet> {
  bool _busy = false;
  String _error = '';

  Future<void> _install() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = '';
    });
    final result = await AppInstallService.install(widget.app);
    if (!mounted) return;
    if (result.ok) {
      Navigator.of(context).pop(AppIosInstallOutcome.installed);
      return;
    }
    setState(() {
      _busy = false;
      _error = result.message;
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    return Container(
      decoration: const BoxDecoration(
        color: Color(AppColors.canvas),
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            18,
            10,
            18,
            14 + MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: .16),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  AppIconTile(app: app, size: 56, radius: AppRadius.md),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '安装到 iPhone',
                          style: AppType.title.copyWith(
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '${app.name} · v${app.version.isEmpty ? '—' : app.version} · ${app.packageLabel}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppType.micro.copyWith(
                            fontSize: 10.5,
                            color: const Color(AppColors.textTertiary),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.fromLTRB(13, 11, 13, 11),
                decoration: BoxDecoration(
                  color: const Color(AppColors.card).withValues(alpha: .58),
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  border: Border.all(color: const Color(AppColors.border)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(
                          Icons.security_rounded,
                          size: 15,
                          color: Color(AppColors.accent),
                        ),
                        const SizedBox(width: 7),
                        Text(
                          '交由 iOS 系统安装',
                          style: AppType.micro.copyWith(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                            color: const Color(AppColors.accent),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    _note('系统会先弹窗确认，再通过安全连接下载安装包。'),
                    _note('安装包必须已经签名，且证书在有效期内。'),
                    _note('未签名或证书失效时，系统会提示“无法安装”。'),
                    if (app.packageName.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        'Bundle ID · ${app.packageName}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppType.micro.copyWith(
                          fontSize: 9,
                          color: const Color(AppColors.textDisabled),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (_error.isNotEmpty) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
                  decoration: BoxDecoration(
                    color: const Color(AppColors.danger).withValues(alpha: .08),
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                    border: Border.all(
                      color: const Color(AppColors.danger).withValues(alpha: .22),
                    ),
                  ),
                  child: Text(
                    _error,
                    style: AppType.micro.copyWith(
                      fontSize: 10.5,
                      height: 1.55,
                      color: const Color(AppColors.danger),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              PillButton(
                label: _busy ? '正在准备安装…' : '开始安装',
                size: PillSize.lg,
                icon: Icons.system_update_alt_rounded,
                expand: true,
                glow: true,
                loading: _busy,
                enabled: !_busy,
                onTap: _install,
              ),
              const SizedBox(height: 8),
              PillButton(
                label: '下载 IPA 文件',
                size: PillSize.sm,
                icon: Icons.download_rounded,
                variant: PillVariant.ghost,
                expand: true,
                enabled: !_busy,
                onTap: () => Navigator.of(context).pop(AppIosInstallOutcome.download),
              ),
              const SizedBox(height: 10),
              TextButton(
                onPressed: _busy ? null : () => Navigator.of(context).pop(),
                child: Text(
                  '取消',
                  style: AppType.caption.copyWith(
                    color: const Color(AppColors.textTertiary),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _note(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: Container(
              width: 3,
              height: 3,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(AppColors.textTertiary),
              ),
            ),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              text,
              style: AppType.micro.copyWith(
                fontSize: 10,
                height: 1.6,
                color: const Color(AppColors.textSecondary),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
