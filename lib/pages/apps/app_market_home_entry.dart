/// 首页推荐区的应用市场入口。
///
/// 不伪造应用封面或下载量；这里只做“带路”，真实内容在应用市场页加载。
library;

import 'package:flutter/material.dart';

import '../../design/components.dart';

class AppMarketHomeEntry extends StatelessWidget {
  const AppMarketHomeEntry({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '进入应用市场',
      child: PressableScale(
        onTap: onTap,
        scale: 0.985,
        child: Container(
          height: 112,
          padding: const EdgeInsets.fromLTRB(15, 13, 14, 13),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.lg),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF10241F), Color(0xFF0C1418), Color(0xFF0A0D11)],
              stops: [0, 0.52, 1],
            ),
            border: Border.all(
              color: const Color(AppColors.accent).withValues(alpha: 0.18),
            ),
          ),
          child: Stack(
            children: [
              Positioned(
                right: -8,
                top: -24,
                child: Icon(
                  Icons.apps_rounded,
                  size: 104,
                  color: const Color(AppColors.accent).withValues(alpha: 0.055),
                ),
              ),
              Row(
                children: [
                  Container(
                    width: 54,
                    height: 54,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      gradient: const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Color(0xFF1B6B52), Color(0xFF3DDC97)],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(AppColors.accent)
                              .withValues(alpha: 0.22),
                          blurRadius: 18,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.grid_view_rounded,
                      size: 27,
                      color: Color(AppColors.onAccent),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              '社区应用市场',
                              style: AppType.micro.copyWith(
                                color: const Color(AppColors.accent),
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.5,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.055),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                '人工审核',
                                style: AppType.micro.copyWith(
                                  fontSize: 8.5,
                                  color: const Color(AppColors.textTertiary),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '把真正好用的应用，带进社区',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppType.title.copyWith(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.2,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Row(
                          children: [
                            for (final (label, color) in const [
                              ('APK', Color(AppColors.accent)),
                              ('IPA', Color(AppColors.lilac)),
                              ('HAP', Color(AppColors.peach)),
                              ('EXE', Color(AppColors.sky)),
                            ]) ...[
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 5,
                                  vertical: 1.5,
                                ),
                                decoration: BoxDecoration(
                                  color: color.withValues(alpha: 0.09),
                                  borderRadius: BorderRadius.circular(3),
                                ),
                                child: Text(
                                  label,
                                  style: AppType.micro.copyWith(
                                    fontSize: 8.5,
                                    color: color,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 4),
                            ],
                            const SizedBox(width: 2),
                            Flexible(
                              child: Text(
                                '投稿 · 精选 · 断点下载',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppType.micro.copyWith(
                                  fontSize: 9.5,
                                  color: const Color(AppColors.textTertiary),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: const Color(AppColors.accent)
                          .withValues(alpha: 0.10),
                      border: Border.all(
                        color: const Color(AppColors.accent)
                            .withValues(alpha: 0.22),
                      ),
                    ),
                    child: const Icon(
                      Icons.arrow_forward_rounded,
                      size: 18,
                      color: Color(AppColors.accent),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
