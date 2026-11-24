import 'package:flutter/material.dart';

import '../api/client.dart';
import '../design/tokens.dart';
import 'cap_captcha_page.dart';
import 'tencent_captcha_page.dart';

/// 人机验证入口：Cap 自托管挑战（默认），腾讯密钥完整时走腾讯。
/// 用户取消返回 null；调用方必须在发送验证码时携带返回值。
Future<CaptchaAnswer?> showCaptchaDialog(BuildContext context) async {
  CaptchaConfig config;
  try {
    config = await ApiClient.fetchCaptchaConfig();
  } catch (e) {
    if (!context.mounted) return null;
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(AppColors.card),
        content: Text(
          e is ApiException ? e.message : '人机验证加载失败，请检查网络后重试',
          style: const TextStyle(color: Color(AppColors.textSecondary), height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
    return null;
  }
  if (!context.mounted) return null;
  if (config.isTencent) {
    return Navigator.of(context).push<CaptchaAnswer>(
      MaterialPageRoute(builder: (_) => const TencentCaptchaPage()),
    );
  }
  return Navigator.of(context).push<CaptchaAnswer>(
    MaterialPageRoute(builder: (_) => const CapCaptchaPage()),
  );
}
