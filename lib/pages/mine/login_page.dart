/// 登录 / 注册页（与流萤音乐账号互通）
///
/// 两种方式二选一：
/// - 账号密码：音乐 /music/api/login（multipart：account + password），
///   账号位支持填邮箱，服务端按 account 或 email 命中用户。
/// - 邮箱验证码：/music/api/send-email-code + /music/api/login-email，
///   新邮箱自动注册，老用户直接登录。
/// 成功后 token 双端可用，并写入本地历史账号。
library;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../api/client.dart';
import '../../design/components.dart';
import '../../services/notify_bus.dart';
import '../../services/auth_session.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  /// 0 = 账号密码登录，1 = 邮箱验证码登录
  int _mode = 0;

  // 密码登录
  final _account = TextEditingController();
  final _password = TextEditingController();
  bool _obscure = true;

  // 验证码登录
  final _email = TextEditingController();
  final _code = TextEditingController();
  bool _sendingCode = false;
  int _countdown = 0;

  bool _submitting = false;
  String? _error;
  bool _agreed = false;

  @override
  void dispose() {
    _account.dispose();
    _password.dispose();
    _email.dispose();
    _code.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- 可用态
  bool get _canSendCode =>
      !_sendingCode &&
      !_submitting &&
      _countdown == 0 &&
      ApiClient.isValidEmail(ApiClient.normalizeEmail(_email.text));

  bool get _canSubmit {
    if (_submitting || !_agreed) return false;
    if (_mode == 0) {
      return _account.text.trim().isNotEmpty && _password.text.isNotEmpty;
    }
    return ApiClient.isValidEmail(ApiClient.normalizeEmail(_email.text)) &&
        _code.text.trim().length == 6;
  }

  void _switchMode(int m) {
    if (_mode == m) return;
    setState(() {
      _mode = m;
      _error = null;
    });
  }

  // ---------------------------------------------------------------- 验证码
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
      showAppToast(context, '验证码已发送至 $email，请查收');
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

  // ---------------------------------------------------------------- 提交
  Future<void> _submit() async {
    if (!_agreed) {
      setState(() => _error = '请先阅读并同意用户协议和隐私政策');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final Map<String, dynamic> j = _mode == 0
          ? await ApiClient.login(_account.text.trim(), _password.text)
          : await ApiClient.loginEmail(
              ApiClient.normalizeEmail(_email.text),
              _code.text,
            );
      final tok = (j['token'] ?? '') as String;
      if (tok.isEmpty) {
        throw ApiException(0, '登录未返回 token');
      }
      // 存本地 + 注入全局 + 拉起实时通知
      final sp = await SharedPreferences.getInstance();
      await sp.setString('community_token', tok);
      ApiClient.token = tok;
      NotifyBus.shared.connect(tok);
      await AuthSession.saveAccount(j, tok);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      var msg = e is ApiException ? e.message : '登录失败，请检查网络';
      // 密码登录失败且填的是邮箱：多半是这个邮箱还没设置过密码
      if (_mode == 0 &&
          _account.text.contains('@') &&
          msg.contains('密码错误')) {
        msg = '$msg（该邮箱可能尚未设置密码，可切换到「邮箱验证码登录」）';
      }
      setState(() {
        _error = msg;
        _submitting = false;
      });
    }
  }

  // ---------------------------------------------------------------- UI
  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    return ImmersivePage(
      child: SafeArea(
        bottom: false,
        child: Stack(
          children: [
            SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              padding: EdgeInsets.fromLTRB(24, 76, 24, 24 + bottom),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _brand(),
                  const SizedBox(height: 40),
                  _modeSwitch(),
                  const SizedBox(height: 24),
                  ...(_mode == 0 ? _passwordFields() : _codeFields()),
                  const SizedBox(height: 12),
                  _agreement(),
                  if (_error != null) ...[
                    const SizedBox(height: AppSpace.x3),
                    _errorBox(_error!),
                  ],
                  const SizedBox(height: 24),
                  _cta(),
                  const SizedBox(height: 14),
                  _helperRow(),
                  const SizedBox(height: 22),
                  Text(
                    '继续即表示同意《用户协议》与《隐私政策》',
                    textAlign: TextAlign.center,
                    style: AppType.micro.copyWith(fontSize: 11),
                  ),
                ],
              ),
            ),
            Positioned(
              left: 6,
              top: 6,
              child: IconCircleButton(
                icon: Icons.arrow_back_ios_new_rounded,
                size: 34,
                iconSize: 16,
                onTap: () => Navigator.pop(context),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _brand() {
    return Column(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: const Color(AppColors.accent).withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(14),
          ),
          child: const Icon(Icons.flare_rounded,
              size: 22, color: Color(AppColors.accent)),
        ),
        const SizedBox(height: 14),
        const Text(
          '流萤社区',
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.44,
            color: Color(AppColors.textPrimary),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '和兴趣相同的人，在黑夜里发光。',
          style: TextStyle(
            fontSize: 13,
            color: const Color(AppColors.textTertiary),
          ),
        ),
      ],
    );
  }

  /// 文字级登录方式切换（V16：选中项带薄荷下划线）
  Widget _modeSwitch() {
    return Row(
      children: [
        _modeTab('密码登录', 0),
        const SizedBox(width: 26),
        _modeTab('验证码登录', 1),
      ],
    );
  }

  Widget _modeTab(String label, int idx) {
    final on = _mode == idx;
    return PressableScale(
      onTap: () => _switchMode(idx),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 15,
              height: 1.2,
              fontWeight: on ? FontWeight.w700 : FontWeight.w500,
              color: on
                  ? const Color(AppColors.textPrimary)
                  : const Color(AppColors.textTertiary),
            ),
          ),
          const SizedBox(height: 6),
          AnimatedContainer(
            duration: AppMotion.base,
            curve: AppMotion.standard,
            width: on ? 18 : 0,
            height: 2,
            decoration: BoxDecoration(
              color: const Color(AppColors.accent),
              borderRadius: BorderRadius.circular(1),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _passwordFields() {
    return [
      TextField(
        controller: _account,
        autocorrect: false,
        onChanged: (_) => setState(() {}),
        style: AppType.body,
        cursorColor: const Color(AppColors.accent),
        decoration: _input('账号或邮箱', Icons.person_outline_rounded),
      ),
      const SizedBox(height: AppSpace.x3),
      TextField(
        controller: _password,
        obscureText: _obscure,
        autocorrect: false,
        enableSuggestions: false,
        onChanged: (_) => setState(() {}),
        style: AppType.body,
        cursorColor: const Color(AppColors.accent),
        decoration: _input('密码', Icons.lock_outline_rounded).copyWith(
          suffixIcon: IconButton(
            onPressed: () => setState(() => _obscure = !_obscure),
            icon: Icon(
              _obscure
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
              size: 20,
              color: const Color(AppColors.textTertiary),
            ),
          ),
        ),
      ),
    ];
  }

  List<Widget> _codeFields() {
    return [
      TextField(
        controller: _email,
        keyboardType: TextInputType.emailAddress,
        autocorrect: false,
        onChanged: (_) => setState(() {}),
        style: AppType.body,
        cursorColor: const Color(AppColors.accent),
        decoration: _input('邮箱地址', Icons.mail_outline_rounded),
      ),
      const SizedBox(height: AppSpace.x3),
      Row(
        children: [
          Expanded(
            child: TextField(
              controller: _code,
              keyboardType: TextInputType.number,
              maxLength: 6,
              onChanged: (_) => setState(() {}),
              style: AppType.body,
              cursorColor: const Color(AppColors.accent),
              decoration: _input('验证码', Icons.verified_outlined),
            ),
          ),
          const SizedBox(width: AppSpace.x2),
          PillButton(
            label: _countdown > 0 ? '${_countdown}s' : '发送验证码',
            size: PillSize.md,
            variant: _canSendCode ? PillVariant.primary : PillVariant.tonal,
            loading: _sendingCode,
            enabled: _canSendCode,
            onTap: _sendCode,
          ),
        ],
      ),
    ];
  }

  Widget _agreement() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PressableScale(
          onTap: () => setState(() => _agreed = !_agreed),
          scale: 0.9,
          child: Icon(
            _agreed
                ? Icons.check_circle_rounded
                : Icons.radio_button_unchecked_rounded,
            size: 18,
            color: _agreed
                ? const Color(AppColors.accent)
                : const Color(AppColors.textTertiary),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('我已阅读并同意', style: AppType.caption),
              PressableScale(
                onTap: () => _openUrl(
                    context, 'https://www.dbmt999.asia/user-agreement.html'),
                child: Text('《用户协议》',
                    style: AppType.caption
                        .copyWith(color: const Color(AppColors.accent))),
              ),
              Text('和', style: AppType.caption),
              PressableScale(
                onTap: () => _openUrl(
                    context, 'https://www.dbmt999.asia/privacy-policy.html'),
                child: Text('《隐私政策》',
                    style: AppType.caption
                        .copyWith(color: const Color(AppColors.accent))),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _errorBox(String msg) {
    return Container(
      padding: const EdgeInsets.all(AppSpace.x3),
      decoration: BoxDecoration(
        color: const Color(AppColors.danger).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline_rounded,
              size: 16, color: Color(AppColors.danger)),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              msg,
              style: AppType.caption
                  .copyWith(color: const Color(AppColors.danger)),
            ),
          ),
        ],
      ),
    );
  }

  void _openUrl(BuildContext context, String url) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('打开协议'),
        content: Text(url, style: AppType.bodySm),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  InputDecoration _input(String hint, IconData icon) {
    const side = BorderSide(color: Color(AppColors.hairline));
    return InputDecoration(
      hintText: hint,
      hintStyle:
          AppType.bodySm.copyWith(color: const Color(AppColors.textTertiary)),
      prefixIcon: Icon(icon, size: 18, color: const Color(AppColors.textTertiary)),
      prefixIconConstraints: const BoxConstraints(minWidth: 32, minHeight: 0),
      counterText: '',
      filled: false,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(vertical: 13),
      border: const UnderlineInputBorder(borderSide: side),
      enabledBorder: const UnderlineInputBorder(borderSide: side),
      focusedBorder: const UnderlineInputBorder(
        borderSide: BorderSide(color: Color(AppColors.accent), width: 1.4),
      ),
    );
  }

  Widget _cta() {
    return PressableScale(
      onTap: _canSubmit ? _submit : null,
      scale: 0.985,
      child: Container(
        height: 48,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: const Color(AppColors.accent)
              .withValues(alpha: _canSubmit ? 1 : 0.35),
          borderRadius: BorderRadius.circular(12),
        ),
        child: _submitting
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Color(AppColors.onAccent)),
              )
            : Text(
                _mode == 0 ? '登录' : '登录 / 注册',
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: Color(AppColors.onAccent),
                ),
              ),
      ),
    );
  }

  Widget _helperRow() {
    return Row(
      children: [
        Text('忘记密码',
            style: TextStyle(
                fontSize: 13, color: const Color(AppColors.textTertiary))),
        const Spacer(),
        Text('注册新账号',
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: const Color(AppColors.accent))),
      ],
    );
  }
}
