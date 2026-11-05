import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../api/client.dart';
import '../../config.dart';
import '../../design/components.dart';

/// 编辑资料独立页（替代旧弹窗）
/// 字段：头像 / 昵称 / 签名 / 性别 / 年龄 / 地址 / 邮箱（验证码）
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
  String? _oldEmail;
  bool _saving = false;
  bool _sendingCode = false;
  int _resendWait = 0;

  @override
  void initState() {
    super.initState();
    final u = widget.user;
    _nameCtrl = TextEditingController(text: (u['name'] ?? '') as String);
    _sigCtrl = TextEditingController(text: (u['signature'] ?? '') as String);
    _gender = (u['gender'] ?? '') as String;
    _ageCtrl = TextEditingController(
        text: (u['age'] ?? 0) is num && (u['age'] ?? 0) > 0 ? '${u['age']}' : '');
    _cityCtrl = TextEditingController(text: (u['city'] ?? '') as String);
    _oldEmail = (u['email'] ?? '') as String;
    _emailCtrl = TextEditingController(text: _oldEmail ?? '');
    _codeCtrl = TextEditingController();
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
    final picked =
        await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1024);
    if (picked == null || !mounted) return;
    try {
      final j = await ApiClient.uploadAvatar(File(picked.path));
      if (!mounted) return;
      setState(() => _avatar = (j['avatar'] ?? '') as String);
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
    setState(() => _sendingCode = true);
    try {
      await ApiClient.sendEmailCodeCommunity(email);
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
        email != (_oldEmail ?? '').toLowerCase() && email.isNotEmpty;
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
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      showAppToast(context, '$e');
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
                  subtitle: '修改邮箱需验证码，绑定后与音乐端同步',
                  padding: EdgeInsets.fromLTRB(
                      AppSpace.x1, AppSpace.x5, AppSpace.x1, AppSpace.x2),
                ),
                _card([
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
                    '邮箱验证码 5 分钟内有效；未变更邮箱时无需填写验证码。',
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
        ? '$kMusicBase/api/avatar/${u['id']}?t=${DateTime.now().millisecondsSinceEpoch}'
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
            badge: Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(AppColors.accent),
                border: Border.all(color: const Color(AppColors.bg), width: 2),
              ),
              alignment: Alignment.center,
              child: const Icon(Icons.photo_camera_rounded,
                  size: 13, color: Color(AppColors.onAccent)),
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
          SizedBox(
            width: 60,
            child: Text(label, style: AppType.bodySm),
          ),
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
          const SizedBox(
            width: 60,
            child: Text('性别', style: AppType.bodySm),
          ),
          Expanded(
            child: Wrap(
              spacing: AppSpace.x2,
              runSpacing: AppSpace.x2,
              children: ['男', '女', '保密']
                  .map((g) => TagPill(
                        label: g,
                        active: _gender == g,
                        onTap: () => setState(() => _gender = g),
                      ))
                  .toList(),
            ),
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
        hintStyle:
            AppType.bodySm.copyWith(color: const Color(AppColors.textTertiary)),
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
