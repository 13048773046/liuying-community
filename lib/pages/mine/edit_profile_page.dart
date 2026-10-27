import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../api/client.dart';
import '../../config.dart';
import '../../widgets/user_avatar.dart';

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
  bool _emailChanged = false;
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
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('头像已上传'),
          backgroundColor: Color(AppTheme.card)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('头像上传失败：$e'),
          backgroundColor: const Color(AppTheme.card)));
    }
  }

  Future<void> _sendCode() async {
    final email = ApiClient.normalizeEmail(_emailCtrl.text);
    if (email.isEmpty || !ApiClient.isValidEmail(email)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('请输入正确的邮箱'),
          backgroundColor: Color(AppTheme.card)));
      return;
    }
    setState(() => _sendingCode = true);
    try {
      await ApiClient.sendEmailCodeCommunity(email);
      if (!mounted) return;
      setState(() {
        _emailChanged = true;
        _sendingCode = false;
        _resendWait = 60;
      });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('验证码已发送，5 分钟内有效'),
          backgroundColor: Color(AppTheme.card)));
      // 60 秒倒计时
      for (var i = 59; i > 0; i--) {
        await Future.delayed(const Duration(seconds: 1));
        if (!mounted) return;
        setState(() => _resendWait = i);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _sendingCode = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('$e'),
          backgroundColor: const Color(AppTheme.card)));
    }
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('昵称不能为空'),
          backgroundColor: Color(AppTheme.card)));
      return;
    }
    final email = ApiClient.normalizeEmail(_emailCtrl.text);
    final code = _codeCtrl.text.trim();
    final emailDirty =
        email != (_oldEmail ?? '').toLowerCase() && email.isNotEmpty;
    if (emailDirty && code.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('邮箱已变更，请先获取验证码'),
          backgroundColor: Color(AppTheme.card)));
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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('$e'),
          backgroundColor: const Color(AppTheme.card)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final u = widget.user;
    return Scaffold(
      backgroundColor: const Color(AppTheme.bg),
      appBar: AppBar(
        backgroundColor: const Color(AppTheme.bg),
        foregroundColor: const Color(AppTheme.textPrimary),
        elevation: 0,
        centerTitle: true,
        title: const Text('编辑资料',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: GestureDetector(
              onTap: _saving ? null : _save,
              child: Container(
                width: 52,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: const Color(AppTheme.accent),
                  borderRadius: BorderRadius.circular(AppTheme.radiusPill),
                ),
                child: _saving
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.black))
                    : const Text('保存',
                        style: TextStyle(
                            color: Colors.black,
                            fontSize: 13,
                            fontWeight: FontWeight.bold)),
              ),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        children: [
          // 头像
          Center(
            child: GestureDetector(
              onTap: _pickAvatar,
              child: Stack(
                children: [
                  UserAvatar(
                      url: _avatar?.isNotEmpty == true
                          ? '$kMusicBase/api/avatar/${u['id']}?t=${DateTime.now().millisecondsSinceEpoch}'
                          : (u['avatar'] ?? '') as String,
                      name: (u['name'] ?? '') as String,
                      size: 84),
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      width: 26,
                      height: 26,
                      decoration: const BoxDecoration(
                        color: Color(AppTheme.accent),
                        shape: BoxShape.circle,
                      ),
                      alignment: Alignment.center,
                      child: const Icon(Icons.photo_camera,
                          size: 14, color: Colors.black),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          const Center(
            child: Text('点击更换头像',
                style: TextStyle(
                    color: Color(AppTheme.textTertiary), fontSize: 11)),
          ),
          const SizedBox(height: 24),
          _field('昵称', _nameCtrl, maxLength: 20),
          const SizedBox(height: 14),
          _field('签名', _sigCtrl, maxLength: 80, maxLines: 2),
          const SizedBox(height: 14),
          // 性别
          Row(
            children: [
              const SizedBox(
                  width: 60,
                  child: Text('性别',
                      style: TextStyle(
                          color: Color(AppTheme.textSecondary),
                          fontSize: 14))),
              Expanded(
                child: Row(
                  children: ['男', '女', '保密']
                      .map((g) => Padding(
                            padding: const EdgeInsets.only(right: 10),
                            child: GestureDetector(
                              onTap: () => setState(() => _gender = g),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 18, vertical: 8),
                                decoration: BoxDecoration(
                                  color: _gender == g
                                      ? const Color(AppTheme.accent)
                                      : const Color(AppTheme.elevated),
                                  borderRadius: BorderRadius.circular(18),
                                ),
                                child: Text(g,
                                    style: TextStyle(
                                        color: _gender == g
                                            ? Colors.black
                                            : const Color(
                                                AppTheme.textSecondary),
                                        fontSize: 13,
                                        fontWeight: _gender == g
                                            ? FontWeight.w600
                                            : FontWeight.w400)),
                              ),
                            ),
                          ))
                      .toList(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _field('年龄', _ageCtrl,
              keyboardType: TextInputType.number, maxLength: 3),
          const SizedBox(height: 14),
          _field('地址', _cityCtrl, maxLength: 30),
          const SizedBox(height: 14),
          // 邮箱
          TextField(
            controller: _emailCtrl,
            keyboardType: TextInputType.emailAddress,
            style: const TextStyle(color: Color(AppTheme.textPrimary)),
            cursorColor: const Color(AppTheme.accent),
            decoration: InputDecoration(
              labelText: '邮箱',
              labelStyle:
                  const TextStyle(color: Color(AppTheme.textSecondary)),
              filled: true,
              fillColor: const Color(AppTheme.elevated),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none),
              suffixIcon: _resendWait > 0
                  ? Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      child: Center(
                        child: Text('$_resendWait s',
                            style: const TextStyle(
                                color: Color(AppTheme.textTertiary),
                                fontSize: 12)),
                      ),
                    )
                  : GestureDetector(
                      onTap: _sendingCode ? null : _sendCode,
                      child: Padding(
                        padding:
                            const EdgeInsets.symmetric(horizontal: 14),
                        child: Center(
                          child: Text(
                            _sendingCode ? '发送中…' : '获取验证码',
                            style: const TextStyle(
                                color: Color(AppTheme.accent),
                                fontSize: 12,
                                fontWeight: FontWeight.w600),
                          ),
                        ),
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _codeCtrl,
            keyboardType: TextInputType.number,
            maxLength: 6,
            style: const TextStyle(color: Color(AppTheme.textPrimary)),
            cursorColor: const Color(AppTheme.accent),
            decoration: InputDecoration(
              labelText: '邮箱验证码',
              labelStyle:
                  const TextStyle(color: Color(AppTheme.textSecondary)),
              filled: true,
              fillColor: const Color(AppTheme.elevated),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none),
            ),
          ),
          const SizedBox(height: 6),
          const Text('修改邮箱需验证码；绑定后与音乐端邮箱同步。',
              style: TextStyle(
                  color: Color(AppTheme.textTertiary), fontSize: 11)),
        ],
      ),
    );
  }

  Widget _field(String label, TextEditingController ctrl,
      {int? maxLength, int maxLines = 1, TextInputType? keyboardType}) {
    return TextField(
      controller: ctrl,
      maxLength: maxLength,
      maxLines: maxLines,
      keyboardType: keyboardType,
      style: const TextStyle(color: Color(AppTheme.textPrimary)),
      cursorColor: const Color(AppTheme.accent),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Color(AppTheme.textSecondary)),
        filled: true,
        fillColor: const Color(AppTheme.elevated),
        counterText: '',
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
      ),
    );
  }
}
