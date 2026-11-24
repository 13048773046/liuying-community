/// 全屏维护遮罩：由后台 maintenance 配置驱动，不可手动关闭。
/// 服务层每 30 秒重试，后台一关掉维护，这里会自动退回正常首页。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../design/components.dart';
import '../services/hot_update.dart';

class HotMaintenancePage extends StatefulWidget {
  const HotMaintenancePage({super.key, required this.config});

  final HotConfig config;

  @override
  State<HotMaintenancePage> createState() => _HotMaintenancePageState();
}

class _HotMaintenancePageState extends State<HotMaintenancePage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  )..repeat(reverse: true);
  bool _checking = false;

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  Future<void> _retry() async {
    if (_checking) return;
    setState(() => _checking = true);
    await HotUpdateService.instance.refresh(force: true);
    if (!mounted) return;
    setState(() => _checking = false);
    if (!HotUpdateService.instance.config.value.maintenanceEnabled) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('仍在维护中，请稍后再试'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final eta = widget.config.maintenanceEta;
    return ImmersivePage(
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 顶部薄荷光晕，避免纯黑维护页显得像崩溃白屏。
          Positioned(
            top: -180,
            left: -120,
            right: -120,
            height: 480,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  colors: [
                    const Color(AppColors.accent).withValues(alpha: 0.18),
                    const Color(AppColors.accent).withValues(alpha: 0.04),
                    Colors.transparent,
                  ],
                  stops: const [0.0, 0.45, 1.0],
                ),
              ),
            ),
          ),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 28),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AnimatedBuilder(
                        animation: _pulse,
                        builder: (context, child) {
                          final t = Curves.easeInOut.transform(_pulse.value);
                          return Container(
                            width: 92,
                            height: 92,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: const Color(AppColors.canvas),
                              border: Border.all(
                                color: const Color(AppColors.accent)
                                    .withValues(alpha: 0.22 + 0.12 * t),
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(AppColors.accent)
                                      .withValues(alpha: 0.12 + 0.10 * t),
                                  blurRadius: 30 + 16 * t,
                                  spreadRadius: 2,
                                ),
                              ],
                            ),
                            padding: const EdgeInsets.all(18),
                            child: child,
                          );
                        },
                        child: Image.asset('assets/logo.png', fit: BoxFit.contain),
                      ),
                      const SizedBox(height: 24),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 11,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(AppColors.accentSoft),
                          borderRadius: AppRadius.rPill,
                          border: Border.all(
                            color: const Color(AppColors.accent)
                                .withValues(alpha: 0.26),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 6,
                              height: 6,
                              decoration: const BoxDecoration(
                                color: Color(AppColors.accent),
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 7),
                            Text(
                              'MAINTENANCE',
                              style: AppType.micro.copyWith(
                                color: const Color(AppColors.accent),
                                fontWeight: FontWeight.w700,
                                letterSpacing: 1.4,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 18),
                      Text(
                        widget.config.maintenanceTitle,
                        textAlign: TextAlign.center,
                        style: AppType.h1.copyWith(height: 1.35),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        widget.config.maintenanceMessage,
                        textAlign: TextAlign.center,
                        style: AppType.body.copyWith(
                          color: const Color(AppColors.textSecondary),
                          height: 1.75,
                        ),
                      ),
                      if (eta.isNotEmpty) ...[
                        const SizedBox(height: 18),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 9,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.04),
                            borderRadius: AppRadius.rSm,
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.07),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.schedule_rounded,
                                size: 15,
                                color: Color(AppColors.textTertiary),
                              ),
                              const SizedBox(width: 7),
                              Text(
                                eta,
                                style: AppType.caption.copyWith(
                                  color: const Color(AppColors.textSecondary),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 30),
                      SizedBox(
                        width: 190,
                        height: 44,
                        child: FilledButton(
                          onPressed: _checking ? null : _retry,
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(AppColors.accent),
                            foregroundColor: const Color(AppColors.onAccent),
                            disabledBackgroundColor: const Color(AppColors.accent)
                                .withValues(alpha: 0.35),
                            shape: RoundedRectangleBorder(
                              borderRadius: AppRadius.rSm,
                            ),
                          ),
                          child: _checking
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Color(AppColors.onAccent),
                                  ),
                                )
                              : const Text(
                                  '检查是否恢复',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        '你的数据不会丢失，恢复后会回到原来的页面。',
                        textAlign: TextAlign.center,
                        style: AppType.micro.copyWith(
                          color: const Color(AppColors.textTertiary),
                          height: 1.6,
                        ),
                      ),
                    ],
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
