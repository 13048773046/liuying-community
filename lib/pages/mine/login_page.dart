/// 登录页：账号互通（走音乐登录接口，同一份 token 双端可用）
library;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../api/client.dart';
import '../../config.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _account = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _account.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (_account.text.trim().isEmpty || _password.text.isEmpty) {
      setState(() => _error = '请输入账号和密码');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final j = await ApiClient.login(_account.text.trim(), _password.text);
      final tok = (j['token'] ?? '') as String;
      if (tok.isEmpty) {
        throw ApiException(0, '登录未返回 token');
      }
      // 存本地 + 注入全局
      final sp = await SharedPreferences.getInstance();
      await sp.setString('community_token', tok);
      ApiClient.token = tok;
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is ApiException ? e.message : '登录失败，请检查网络';
        _busy = false;
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
              const Text('账号与流萤音乐互通 · 登录一次双端可用',
                  style: TextStyle(
                      color: Color(AppTheme.textSecondary), fontSize: 13)),
              const SizedBox(height: 40),
              // 账号
              TextField(
                controller: _account,
                style: const TextStyle(color: Colors.white),
                decoration: _input('账号 / 手机号', Icons.person_outline),
              ),
              const SizedBox(height: 14),
              // 密码
              TextField(
                controller: _password,
                obscureText: true,
                style: const TextStyle(color: Colors.white),
                decoration: _input('密码', Icons.lock_outline),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!,
                    style: const TextStyle(color: Color(0xFFFF4D6D), fontSize: 13)),
              ],
              const SizedBox(height: 26),
              // 登录按钮
              GestureDetector(
                onTap: _busy ? null : _login,
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(AppTheme.gradStart), Color(AppTheme.gradEnd)],
                    ),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  alignment: Alignment.center,
                  child: _busy
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2.2, color: Colors.white))
                      : const Text('登 录',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w600)),
                ),
              ),
              const SizedBox(height: 14),
              Center(
                child: Text(
                  '未注册？请先在流萤音乐 App 注册，社区自动互通',
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
