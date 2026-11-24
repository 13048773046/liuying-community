import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../api/client.dart';
import '../../services/user_data_bus.dart';
import '../../config.dart';
import '../../design/components.dart';
import '../../models/feed_item.dart' show boolOf, verifiedOf;
import '../../widgets/captcha_dialog.dart';

/// 编辑资料独立页（替代旧弹窗）
/// 字段：头像 / 昵称 / 签名 / 性别 / 年龄 / 地址 / 手机号 / 邮箱（验证码）
/// 数据与音乐端同库（共享 users 表），保存即同步。
class EditProfilePage extends StatefulWidget {
  final Map<String, dynamic> user;
  const EditProfilePage({super.key, required this.user});

  @override
  State<EditProfilePage> createState() => _EditProfilePageState();
}

class _EditProfilePageState extends State<EditProfilePage> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _sigCtrl;
  late final TextEditingController _ageCtrl;
  late final TextEditingController _cityCtrl;
  late final TextEditingController _emailCtrl;
  late final TextEditingController _codeCtrl;

  String _gender = '';
  String? _avatar; // 已上传的新头像文件名
  String _oldEmail = '';
  String _phoneMask = '';
  bool _phoneVerified = false;
  bool _saving = false;
  bool _sendingCode = false;
  int _resendWait = 0;

  @override
  void initState() {
    super.initState();
    final u = widget.user;
    _nameCtrl = TextEditingController(text: (u['name'] ?? '').toString());
    _sigCtrl = TextEditingController(text: (u['signature'] ?? '').toString());
    _gender = (u['gender'] ?? '').toString();
    final age = int.tryParse('${u['age'] ?? ''}') ?? 0;
    _ageCtrl = TextEditingController(text: age > 0 ? '$age' : '');
    _cityCtrl = TextEditingController(text: (u['city'] ?? '').toString());
    _oldEmail = (u['email'] ?? '').toString();
    _emailCtrl = TextEditingController(text: _oldEmail);
    _codeCtrl = TextEditingController();
    _phoneMask = (u['phoneMask'] ?? '').toString();
    _phoneVerified = boolOf(u['phoneVerified']) && _phoneMask.isNotEmpty;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _sigCtrl.dispose();
    _ageCtrl.dispose();
    _cityCtrl.dispose();
    _emailCtrl.dispose();
    _codeCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickAvatar() async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 1024,
    );
    if (picked == null || !mounted) return;
    try {
      final j = await ApiClient.uploadAvatar(File(picked.path));
      if (!mounted) return;
      setState(() => _avatar = (j['avatar'] ?? '').toString());
      UserDataBus.touch();
      showAppToast(context, '头像已上传');
    } catch (e) {
      if (!mounted) return;
      showAppToast(context, '头像上传失败：$e');
    }
  }

  Future<void> _sendCode() async {
    final email = ApiClient.normalizeEmail(_emailCtrl.text);
    if (email.isEmpty || !ApiClient.isValidEmail(email)) {
      showAppToast(context, '请输入正确的邮箱');
      return;
    }
    final captcha = await showCaptchaDialog(context);
    if (captcha == null) return;
    setState(() => _sendingCode = true);
    try {
      await ApiClient.sendEmailCodeCommunity(email, captcha);
      if (!mounted) return;
      setState(() {
        _sendingCode = false;
        _resendWait = 60;
      });
      showAppToast(context, '验证码已发送，5 分钟内有效');
      // 60 秒倒计时
      for (var i = 59; i > 0; i--) {
        await Future.delayed(const Duration(seconds: 1));
        if (!mounted) return;
        setState(() => _resendWait = i);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _sendingCode = false);
      showAppToast(context, '$e');
    }
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      showAppToast(context, '昵称不能为空');
      return;
    }
    final email = ApiClient.normalizeEmail(_emailCtrl.text);
    final code = _codeCtrl.text.trim();
    final emailDirty =
        email != _oldEmail.toLowerCase() && email.isNotEmpty;
    if (emailDirty && code.isEmpty) {
      showAppToast(context, '邮箱已变更，请先获取验证码');
      return;
    }
    setState(() => _saving = true);
    try {
      await ApiClient.updateProfile(
        name: name,
        signature: _sigCtrl.text.trim(),
        gender: _gender,
        age: int.tryParse(_ageCtrl.text.trim()) ?? 0,
        city: _cityCtrl.text.trim(),
        email: emailDirty ? email : null,
        code: emailDirty ? code : null,
      );
      if (!mounted) return;
      UserDataBus.touch();
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      showAppToast(context, '$e');
    }
  }

  Future<void> _openPhoneSheet() async {
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.55),
      builder: (ctx) => _PhoneBindSheet(
        maskedPhone: _phoneVerified ? _phoneMask : '',
        onBound: (mask) {
          if (!mounted) return;
          setState(() {
            _phoneMask = mask;
            _phoneVerified = mask.isNotEmpty;
          });
          UserDataBus.touch();
        },
      ),
    );
    if (changed == true && mounted) {
      showAppToast(context, _phoneVerified ? '手机号已更新' : '手机号已绑定');
    }
  }

  @override
  Widget build(BuildContext context) {
    final u = widget.user;
    return ImmersivePage(
      child: Column(
        children: [
          const GlassTopBar(title: '编辑资料', solid: true),
          Expanded(
            child: ListView(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(
                AppSpace.gutter,
                AppSpace.x2,
                AppSpace.gutter,
                AppSpace.x6,
              ),
              children: [
                const SizedBox(height: AppSpace.x2),
                _avatarBlock(u),
                const SizedBox(height: AppSpace.x5),
                _card([
                  _row('昵称', _input(_nameCtrl, maxLength: 20)),
                  const Hairline(indent: AppSpace.x4),
                  _row('签名', _input(_sigCtrl, maxLength: 80, maxLines: 2)),
                  const Hairline(indent: AppSpace.x4),
                  _genderRow(),
                  const Hairline(indent: AppSpace.x4),
                  _row(
                    '年龄',
                    _input(
                      _ageCtrl,
                      maxLength: 3,
                      keyboardType: TextInputType.number,
                    ),
                  ),
                  const Hairline(indent: AppSpace.x4),
                  _row('地址', _input(_cityCtrl, maxLength: 30)),
                ]),
                const SizedBox(height: AppSpace.x2),
                const SectionHeader(
                  title: '账号与安全',
                  subtitle: '手机号用于登录、邀请验证与提现；邮箱用于登录和通知',
                  padding: EdgeInsets.fromLTRB(
                    AppSpace.x1,
                    AppSpace.x5,
                    AppSpace.x1,
                    AppSpace.x2,
                  ),
                ),
                _card([
                  _phoneRow(),
                  const Hairline(indent: AppSpace.x4),
                  _emailRow(),
                  const Hairline(indent: AppSpace.x4),
                  _row(
                    '验证码',
                    _input(
                      _codeCtrl,
                      maxLength: 6,
                      keyboardType: TextInputType.number,
                    ),
                  ),
                ]),
                const SizedBox(height: AppSpace.x3),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpace.x1),
                  child: Text(
                    '邮箱验证码 5 分钟内有效；未变更邮箱时无需填写验证码。'
                    '手机号绑定成功后可用于手机号验证码登录。',
                    style: AppType.micro,
                  ),
                ),
              ],
            ),
          ),
          _saveBar(),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ 头像
  Widget _avatarBlock(Map<String, dynamic> u) {
    final raw = (u['avatar'] ?? '') as String;
    final url = _avatar?.isNotEmpty == true
        ? '${avatarUrlOf((u['id'] ?? '').toString())}?t=${DateTime.now().millisecondsSinceEpoch}'
        : (raw.isEmpty ? '' : avatarUrl(raw));
    return Column(
      children: [
        PressableScale(
          onTap: _pickAvatar,
          scale: 0.94,
          child: AppAvatar(
            url: url,
            name: (u['name'] ?? '') as String,
            size: 84,
            ring: true,
            verified:
                verifiedOf(u['verified']) ||
                (u['verifiedLabel'] ?? '').toString().trim().isNotEmpty,
            isAi:
                boolOf(u['isAi']) ||
                (u['verifiedLabel'] ?? '').toString().trim().toUpperCase() ==
                    'AI',
            badge: Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(AppColors.accent),
                border: Border.all(color: const Color(AppColors.bg), width: 2),
              ),
              alignment: Alignment.center,
              child: const Icon(
                Icons.photo_camera_rounded,
                size: 13,
                color: Color(AppColors.onAccent),
              ),
            ),
          ),
        ),
        const SizedBox(height: AppSpace.x2),
        Text('点击更换头像', style: AppType.caption),
      ],
    );
  }

  // ------------------------------------------------------------------ 表单
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

  Widget _row(String label, Widget child) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.x4,
        vertical: AppSpace.x3,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(width: 60, child: Text(label, style: AppType.bodySm)),
          Expanded(child: child),
        ],
      ),
    );
  }

  Widget _genderRow() {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.x4,
        vertical: AppSpace.x3,
      ),
      child: Row(
        children: [
          const SizedBox(width: 60, child: Text('性别', style: AppType.bodySm)),
          Expanded(
            child: Wrap(
              spacing: AppSpace.x2,
              runSpacing: AppSpace.x2,
              children: ['男', '女', '保密']
                  .map(
                    (g) => TagPill(
                      label: g,
                      active: _gender == g,
                      onTap: () => setState(() => _gender = g),
                    ),
                  )
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _phoneRow() {
    final bound = _phoneVerified && _phoneMask.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.x4,
        vertical: AppSpace.x3,
      ),
      child: Row(
        children: [
          const SizedBox(width: 60, child: Text('手机号', style: AppType.bodySm)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  bound ? _phoneMask : '未绑定',
                  style: AppType.body.copyWith(
                    color: bound
                        ? const Color(AppColors.textPrimary)
                        : const Color(AppColors.textTertiary),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  bound ? '已验证，可用于登录与提现' : '绑定后可用手机号登录，并满足邀请提现条件',
                  style: AppType.micro.copyWith(fontSize: 11),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpace.x2),
          PillButton(
            label: bound ? '更换' : '去绑定',
            size: PillSize.sm,
            variant: PillVariant.tonal,
            onTap: _openPhoneSheet,
          ),
        ],
      ),
    );
  }

  Widget _emailRow() {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.x4,
        vertical: AppSpace.x3,
      ),
      child: Column(
        children: [
          Row(
            children: [
              const SizedBox(
                width: 60,
                child: Text('邮箱', style: AppType.bodySm),
              ),
              Expanded(
                child: _input(
                  _emailCtrl,
                  hint: 'name@example.com',
                  keyboardType: TextInputType.emailAddress,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.x2),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              PillButton(
                label: _resendWait > 0 ? '$_resendWait s' : '获取验证码',
                size: PillSize.sm,
                variant: PillVariant.tonal,
                loading: _sendingCode,
                enabled: !_sendingCode && _resendWait == 0,
                onTap: _sendCode,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _input(
    TextEditingController ctrl, {
    String? hint,
    int? maxLength,
    int maxLines = 1,
    TextInputType? keyboardType,
  }) {
    return TextField(
      controller: ctrl,
      maxLength: maxLength,
      maxLines: maxLines,
      keyboardType: keyboardType,
      style: AppType.body,
      cursorColor: const Color(AppColors.accent),
      decoration: InputDecoration(
        isDense: true,
        filled: false,
        hintText: hint,
        hintStyle: AppType.bodySm.copyWith(
          color: const Color(AppColors.textTertiary),
        ),
        counterText: '',
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        contentPadding: EdgeInsets.zero,
      ),
    );
  }

  // ------------------------------------------------------------------ 底部
  Widget _saveBar() {
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: Color(AppColors.bg),
        border: Border(top: BorderSide(color: Color(AppColors.hairline))),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          AppSpace.gutter,
          AppSpace.x3,
          AppSpace.gutter,
          AppSpace.x3 + MediaQuery.paddingOf(context).bottom,
        ),
        child: PillButton(
          label: '保存',
          size: PillSize.lg,
          expand: true,
          glow: true,
          loading: _saving,
          onTap: _save,
        ),
      ),
    );
  }
}

/// 绑定/更换手机号弹层：手机号 + 短信验证码，成功后回传掩码。
class _PhoneBindSheet extends StatefulWidget {
  final String maskedPhone;
  final ValueChanged<String> onBound;

  const _PhoneBindSheet({required this.maskedPhone, required this.onBound});

  @override
  State<_PhoneBindSheet> createState() => _PhoneBindSheetState();
}

class _PhoneBindSheetState extends State<_PhoneBindSheet> {
  final _phone = TextEditingController();
  final _code = TextEditingController();
  bool _sending = false;
  bool _confirming = false;
  int _wait = 0;
  Timer? _timer;
  String? _error;

  bool get _validPhone => ApiClient.isValidPhone(_phone.text);

  @override
  void dispose() {
    _timer?.cancel();
    _phone.dispose();
    _code.dispose();
    super.dispose();
  }

  void _startCountdown() {
    _timer?.cancel();
    setState(() => _wait = 60);
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      if (_wait <= 1) {
        t.cancel();
        setState(() => _wait = 0);
      } else {
        setState(() => _wait--);
      }
    });
  }

  Future<void> _sendCode() async {
    final phone = ApiClient.normalizePhone(_phone.text);
    if (!ApiClient.isValidPhone(phone)) {
      setState(() => _error = '请输入正确的 11 位手机号');
      return;
    }
    final captcha = await showCaptchaDialog(context);
    if (captcha == null) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await ApiClient.sendBindPhoneCode(phone, captcha);
      if (!mounted) return;
      setState(() => _sending = false);
      _startCountdown();
      showAppToast(context, '验证码已发送，5 分钟内有效');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = e is ApiException ? e.message : '发送失败，请稍后重试';
      });
    }
  }

  Future<void> _confirm() async {
    final phone = ApiClient.normalizePhone(_phone.text);
    final code = _code.text.trim();
    if (!ApiClient.isValidPhone(phone)) {
      setState(() => _error = '请输入正确的 11 位手机号');
      return;
    }
    if (code.length != 6) {
      setState(() => _error = '请输入 6 位短信验证码');
      return;
    }
    setState(() {
      _confirming = true;
      _error = null;
    });
    try {
      final j = await ApiClient.confirmBindPhone(phone, code);
      final mask = (j['phone'] ?? '').toString();
      if (mask.isEmpty) {
        throw ApiException(0, '绑定成功但未返回手机号');
      }
      widget.onBound(mask);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _confirming = false;
        _error = e is ApiException ? e.message : '绑定失败，请稍后重试';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final bound = widget.maskedPhone.isNotEmpty;
    return SafeArea(
      top: false,
      child: Container(
        padding: EdgeInsets.fromLTRB(24, 10, 24, 20 + bottom + keyboard),
        decoration: const BoxDecoration(
          color: Color(AppColors.bg),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 18),
                decoration: BoxDecoration(
                  color: const Color(AppColors.textTertiary)
                      .withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Row(
              children: [
                Expanded(
                  child: Text(
                    bound ? '更换手机号' : '绑定手机号',
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: Color(AppColors.textPrimary),
                    ),
                  ),
                ),
                PressableScale(
                  onTap: () => Navigator.pop(context, false),
                  child: const Icon(
                    Icons.close_rounded,
                    size: 22,
                    color: Color(AppColors.textTertiary),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              bound
                  ? '当前 ${widget.maskedPhone}。更换后，旧号码将不再用于当前账号登录。'
                  : '绑定后可用手机号验证码登录，也用于邀请提现验证。',
              style: AppType.caption,
            ),
            const SizedBox(height: AppSpace.x5),
            Container(
              decoration: BoxDecoration(
                color: const Color(AppColors.card),
                borderRadius: BorderRadius.circular(AppRadius.sm),
                border: Border.all(color: const Color(AppColors.border)),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: TextField(
                controller: _phone,
                keyboardType: TextInputType.phone,
                textInputAction: TextInputAction.next,
                maxLength: 11,
                style: AppType.body,
                cursorColor: const Color(AppColors.accent),
                decoration: InputDecoration(
                  hintText: '输入手机号',
                  hintStyle: AppType.bodySm.copyWith(
                    color: const Color(AppColors.textTertiary),
                  ),
                  counterText: '',
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onChanged: (_) => setState(() => _error = null),
              ),
            ),
            const SizedBox(height: AppSpace.x3),
            Row(
              children: [
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: const Color(AppColors.card),
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                      border: Border.all(color: const Color(AppColors.border)),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: TextField(
                      controller: _code,
                      keyboardType: TextInputType.number,
                      textInputAction: TextInputAction.done,
                      maxLength: 6,
                      style: AppType.body,
                      cursorColor: const Color(AppColors.accent),
                      decoration: InputDecoration(
                        hintText: '6 位验证码',
                        hintStyle: AppType.bodySm.copyWith(
                          color: const Color(AppColors.textTertiary),
                        ),
                        counterText: '',
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(
                          vertical: 14,
                        ),
                      ),
                      onChanged: (_) => setState(() => _error = null),
                    ),
                  ),
                ),
                const SizedBox(width: AppSpace.x2),
                PillButton(
                  label: _wait > 0 ? '$_wait s' : '获取验证码',
                  size: PillSize.sm,
                  variant: PillVariant.tonal,
                  loading: _sending,
                  enabled: !_sending && _wait == 0 && _validPhone,
                  onTap: _sendCode,
                ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: AppSpace.x3),
              Text(
                _error!,
                style: AppType.caption.copyWith(
                  color: const Color(AppColors.danger),
                ),
              ),
            ],
            const SizedBox(height: AppSpace.x5),
            PillButton(
              label: bound ? '确认更换' : '确认绑定',
              size: PillSize.lg,
              expand: true,
              glow: true,
              loading: _confirming,
              enabled:
                  !_confirming && _validPhone && _code.text.trim().length == 6,
              onTap: _confirm,
            ),
            const SizedBox(height: AppSpace.x3),
            Text(
              '一个手机号只能绑定一个流萤社区账号；验证码 5 分钟内有效，请勿泄露给他人。',
              style: AppType.micro.copyWith(fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}
