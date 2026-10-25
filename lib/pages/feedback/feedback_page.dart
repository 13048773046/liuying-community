/// 意见反馈页：类型选择 + 内容 + 联系方式，提交至 /feedback
library;

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../config.dart';
import '../mine/login_page.dart';

class FeedbackPage extends StatefulWidget {
  const FeedbackPage({super.key});

  @override
  State<FeedbackPage> createState() => _FeedbackPageState();
}

class _FeedbackPageState extends State<FeedbackPage> {
  String _type = 'bug';
  final TextEditingController _content = TextEditingController();
  final TextEditingController _contact = TextEditingController();
  bool _submitting = false;

  @override
  void dispose() {
    _content.dispose();
    _contact.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final text = _content.text.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('请填写反馈内容'),
          backgroundColor: Color(AppTheme.card),
          behavior: SnackBarBehavior.floating));
      return;
    }
    if (ApiClient.token == null) {
      final ok = await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => const LoginPage()),
      );
      if (ok != true || !mounted) return;
    }
    setState(() => _submitting = true);
    try {
      await ApiClient.submitFeedback(
        type: _type,
        content: text,
        contact: _contact.text.trim(),
      );
      if (!mounted) return;
      setState(() => _submitting = false);
      Navigator.of(context).pop(true);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('反馈已提交，感谢你的建议'),
          backgroundColor: Color(AppTheme.card),
          behavior: SnackBarBehavior.floating));
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('提交失败：$e'),
          backgroundColor: const Color(AppTheme.card),
          behavior: SnackBarBehavior.floating));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(AppTheme.bg),
      appBar: AppBar(
        backgroundColor: const Color(AppTheme.bg),
        foregroundColor: const Color(AppTheme.textPrimary),
        elevation: 0,
        title: const Text('意见反馈'),
        centerTitle: true,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 类型选择
          const Padding(
            padding: EdgeInsets.only(left: 4, bottom: 8),
            child: Text('反馈类型',
                style: TextStyle(
                    color: Color(AppTheme.textSecondary), fontSize: 12)),
          ),
          Row(
            children: [
              _typeSeg('bug', '问题反馈'),
              const SizedBox(width: 8),
              _typeSeg('suggestion', '建议'),
              const SizedBox(width: 8),
              _typeSeg('other', '其他'),
            ],
          ),
          const SizedBox(height: 16),
          // 内容
          const Padding(
            padding: EdgeInsets.only(left: 4, bottom: 8),
            child: Text('反馈内容',
                style: TextStyle(
                    color: Color(AppTheme.textSecondary), fontSize: 12)),
          ),
          Container(
            decoration: BoxDecoration(
              color: const Color(AppTheme.card),
              borderRadius: BorderRadius.circular(12),
            ),
            child: TextField(
              controller: _content,
              maxLines: 6,
              maxLength: 2000,
              style: const TextStyle(color: Colors.white, fontSize: 14),
              decoration: const InputDecoration(
                hintText: '遇到什么问题、有什么建议，都可以告诉我们…',
                hintStyle: TextStyle(
                    color: Color(AppTheme.textTertiary), fontSize: 13.5),
                border: InputBorder.none,
                contentPadding: EdgeInsets.all(14),
              ),
            ),
          ),
          const SizedBox(height: 16),
          // 联系方式
          const Padding(
            padding: EdgeInsets.only(left: 4, bottom: 8),
            child: Text('联系方式（选填）',
                style: TextStyle(
                    color: Color(AppTheme.textSecondary), fontSize: 12)),
          ),
          Container(
            decoration: BoxDecoration(
              color: const Color(AppTheme.card),
              borderRadius: BorderRadius.circular(12),
            ),
            child: TextField(
              controller: _contact,
              maxLength: 100,
              style: const TextStyle(color: Colors.white, fontSize: 14),
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(
                hintText: '邮箱 / 联系方式，便于我们回复你',
                hintStyle: TextStyle(
                    color: Color(AppTheme.textTertiary), fontSize: 13.5),
                border: InputBorder.none,
                contentPadding: EdgeInsets.all(14),
              ),
            ),
          ),
          const SizedBox(height: 24),
          // 提交
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(AppTheme.accent),
              foregroundColor: Colors.black,
              minimumSize: const Size.fromHeight(48),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
            ),
            onPressed: _submitting ? null : _submit,
            child: _submitting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.black))
                : const Text('提交反馈',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
          ),
          const SizedBox(height: 12),
          const Center(
            child: Text('我们会在 1-3 个工作日内处理',
                style: TextStyle(
                    color: Color(AppTheme.textTertiary), fontSize: 11.5)),
          ),
        ],
      ),
    );
  }

  Widget _typeSeg(String v, String label) {
    final sel = _type == v;
    return GestureDetector(
      onTap: () => setState(() => _type = v),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: sel ? const Color(AppTheme.accent) : const Color(AppTheme.card),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: sel ? Colors.black : const Color(AppTheme.textSecondary),
            fontSize: 13,
            fontWeight: sel ? FontWeight.bold : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}
