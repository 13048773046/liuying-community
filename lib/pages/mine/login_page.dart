/// 邮箱验证码登录 / 注册页（与流萤音乐互通）：
/// 走音乐 /music/api/send-email-code + /music/api/login-email，
/// 新邮箱自动注册、老用户直接登录，成功后 token 双端可用。
library;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../api/client.dart';
import '../../config.dart';
import '../../services/notify_bus.dart';
import '../../services/auth_session.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _email = TextEditingController();
  final _code = TextEditingController();
  bool _sendingCode = false; // 发送验证码进行中
  bool _submitting = false; // 登录/注册进行中
  String? _error;
  int _countdown = 0; // 发送验证码倒计时（秒）
  bool _agreed = false;

  @override
  void dispose() {
    _email.dispose();
    _code.dispose();
    super.dispose();
  }

  bool get _canSendCode =>
      !_sendingCode &&
      !_submitting &&
      _countdown == 0 &&
      ApiClient.isValidEmail(ApiClient.normalizeEmail(_email.text));

  bool get _canSubmit {
    final code = _code.text.trim();
    return !_submitting &&
        !_sendingCode &&
        ApiClient.isValidEmail(ApiClient.normalizeEmail(_email.text)) &&
        code.length == 6 &&
        _agreed;
  }

  Future<void> _sendCode() async {
    final email = ApiClient.normalizeEmail(_email.text);
    if (!ApiClient.isValidEmail(email)) {
      setState(() {
        _error = '邮箱格式不正确：仅支持字母、数字和 . _ + -，请检查是否含全角字符或空格';
      });
      return;
    }
    setState(() {
      _sendingCode = true;
      _error = null;
    });
    try {
      await ApiClient.sendEmailCode(email);
      if (!mounted) return;
      setState(() {
        _countdown = 60;
        _sendingCode = false;
      });
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text('验证码已发送至 $email，请查收',
              style: const TextStyle(fontSize: 13)),
          backgroundColor: const Color(AppTheme.card),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          duration: const Duration(seconds: 3),
        ));
      // 倒计时
      Future.doWhile(() async {
        await Future.delayed(const Duration(seconds: 1));
        if (!mounted) return false;
        setState(() => _countdown--);
        return _countdown > 0;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is ApiException ? e.message : '发送失败，请检查网络';
        _sendingCode = false;
      });
    }
  }

  Future<void> _login() async {
    if (!_agreed) {
      setState(() => _error = '请先阅读并同意用户协议和隐私政策');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final email = ApiClient.normalizeEmail(_email.text);
      final j = await ApiClient.loginEmail(email, _code.text);
      final tok = (j['token'] ?? '') as String;
      if (tok.isEmpty) {
        throw ApiException(0, '登录未返回 token');
      }
      // 存本地 + 注入全局 + 拉起实时通知
      final sp = await SharedPreferences.getInstance();
      await sp.setString('community_token', tok);
      ApiClient.token = tok;
      NotifyBus.shared.connect(tok);
      // 保存到历史账号（切换账号用）
      await AuthSession.saveAccount(j, tok);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is ApiException ? e.message : '登录失败，请检查网络';
        _submitting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(AppTheme.bg),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 40),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 30),
              // Logo 区：萤火虫图标 + 名称
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(AppTheme.gradStart), Color(AppTheme.gradEnd)],
                  ),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: const Icon(Icons.local_fire_department,
                    color: Colors.white, size: 34),
              ),
              const SizedBox(height: 18),
              const Text('流萤社区',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              const Text('登录 / 注册',
                  style: TextStyle(
                      color: Color(AppTheme.textSecondary), fontSize: 13)),
              const SizedBox(height: 40),
              // 邮箱
              TextField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                autocorrect: false,
                onChanged: (_) => setState(() {}), // 驱动发送按钮可用态
                style: const TextStyle(color: Colors.white),
                decoration: _input('邮箱地址', Icons.mail_outline),
              ),
              const SizedBox(height: 14),
              // 验证码 + 发送按钮
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _code,
                      keyboardType: TextInputType.number,
                      maxLength: 6,
                      onChanged: (_) => setState(() {}), // 驱动登录按钮可用态
                      style: const TextStyle(color: Colors.white),
                      decoration: _input('验证码', Icons.verified_outlined)
                          .copyWith(counterText: ''),
                    ),
                  ),
                  const SizedBox(width: 10),
                  GestureDetector(
                    onTap: _canSendCode ? _sendCode : null,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 14),
                      decoration: BoxDecoration(
                        color: _canSendCode
                            ? const Color(AppTheme.accent)
                            : const Color(AppTheme.card),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: _sendingCode
                          ? const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                SizedBox(
                                  width: 13,
                                  height: 13,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 1.8,
                                      color: Color(AppTheme.textSecondary)),
                                ),
                                SizedBox(width: 6),
                                Text('发送中',
                                    style: TextStyle(
                                        color: Color(AppTheme.textSecondary),
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600)),
                              ],
                            )
                          : Text(
                              _countdown > 0 ? '${_countdown}s' : '发送验证码',
                              style: TextStyle(
                                color: _canSendCode
                                    ? const Color(AppTheme.bg)
                                    : const Color(AppTheme.textSecondary),
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // 协议勾选
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  GestureDetector(
                    onTap: () => setState(() => _agreed = !_agreed),
                    child: Icon(
                      _agreed
                          ? Icons.check_circle
                          : Icons.radio_button_unchecked,
                      size: 18,
                      color: _agreed
                          ? const Color(AppTheme.accent)
                          : const Color(AppTheme.textSecondary),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        const Text('我已阅读并同意',
                            style: TextStyle(
                                color: Color(AppTheme.textSecondary),
                                fontSize: 12)),
                        GestureDetector(
                          onTap: () => _openAgreement(context),
                          child: const Text('《用户协议》',
                              style: TextStyle(
                                  color: Color(AppTheme.accent),
                                  fontSize: 12)),
                        ),
                        const Text('和',
                            style: TextStyle(
                                color: Color(AppTheme.textSecondary),
                                fontSize: 12)),
                        GestureDetector(
                          onTap: () => _openPrivacy(context),
                          child: const Text('《隐私政策》',
                              style: TextStyle(
                                  color: Color(AppTheme.accent),
                                  fontSize: 12)),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!,
                    style: const TextStyle(
                        color: Color(0xFFFF4D6D), fontSize: 13)),
              ],
              const SizedBox(height: 26),
              // 登录按钮
              GestureDetector(
                onTap: _canSubmit ? _login : null,
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  decoration: BoxDecoration(
                    color: _canSubmit
                        ? const Color(AppTheme.accent)
                        : const Color(AppTheme.card),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  alignment: Alignment.center,
                  child: _submitting
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2.2, color: Colors.white))
                      : Text(
                          _canSubmit ? '登录 / 注册' : '登录 / 注册',
                          style: TextStyle(
                              color: _canSubmit
                                  ? const Color(AppTheme.bg)
                                  : const Color(AppTheme.textSecondary),
                              fontSize: 16,
                              fontWeight: FontWeight.w600),
                        ),
                ),
              ),
              const SizedBox(height: 14),
              Center(
                child: Text(
                  '验证码将发送至邮箱，新用户自动注册 · 账号与流萤音乐互通',
                  style: TextStyle(
                      color: Colors.white.withOpacity(0.5), fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openAgreement(BuildContext context) {
    // 与音乐项目共用官网协议页
    _openUrl(context, 'https://www.dbmt999.asia/user-agreement.html');
  }

  void _openPrivacy(BuildContext context) {
    _openUrl(context, 'https://www.dbmt999.asia/privacy-policy.html');
  }

  void _openUrl(BuildContext context, String url) {
    // 无 url_launcher 依赖时用系统弹窗提示；后续可接入浏览器插件
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(AppTheme.card),
        title: const Text('打开协议',
            style: TextStyle(color: Color(AppTheme.textPrimary))),
        content: Text(url,
            style: const TextStyle(color: Color(AppTheme.textSecondary))),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('知道了',
                style: TextStyle(color: Color(AppTheme.accent))),
          ),
        ],
      ),
    );
  }

  InputDecoration _input(String hint, IconData icon) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: Color(0xFF6E6E7A)),
      prefixIcon: Icon(icon, size: 20, color: const Color(AppTheme.textSecondary)),
      filled: true,
      fillColor: const Color(AppTheme.card),
      contentPadding: const EdgeInsets.symmetric(vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
    );
  }
}
