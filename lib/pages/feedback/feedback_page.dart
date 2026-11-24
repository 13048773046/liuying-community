/// 意见反馈页：黑底表单卡片 + 类型胶囊 + PillButton 提交
library;

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../design/components.dart';
import '../mine/login_page.dart';

class FeedbackPage extends StatefulWidget {
  const FeedbackPage({super.key, this.initialContent});

  /// 预填内容（如错误页一键反馈携带的异常摘要）
  final String? initialContent;

  @override
  State<FeedbackPage> createState() => _FeedbackPageState();
}

class _FeedbackPageState extends State<FeedbackPage> {
  String _type = 'bug';
  late final TextEditingController _content =
      TextEditingController(text: widget.initialContent ?? '');
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
      showAppToast(context, '请填写反馈内容');
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
      showAppToast(context, '反馈已提交，感谢你的建议');
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      showAppToast(context, '提交失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return ImmersivePage(
      child: Column(
        children: [
          const GlassTopBar(title: '意见反馈', solid: true),
          Expanded(
            child: ListView(
              padding: EdgeInsets.fromLTRB(
                AppSpace.gutter,
                AppSpace.x4,
                AppSpace.gutter,
                AppSpace.x6 + MediaQuery.paddingOf(context).bottom,
              ),
              children: [
                _label('反馈类型'),
                const SizedBox(height: AppSpace.x2),
                Wrap(
                  spacing: AppSpace.x2,
                  runSpacing: AppSpace.x2,
                  children: [
                    for (final (v, label) in const [
                      ('bug', '问题反馈'),
                      ('suggestion', '建议'),
                      ('other', '其他'),
                    ])
                      TagPill(
                        label: label,
                        active: _type == v,
                        onTap: () => setState(() => _type = v),
                      ),
                  ],
                ),
                const SizedBox(height: AppSpace.x5),
                _label('反馈内容'),
                const SizedBox(height: AppSpace.x2),
                _card(
                  child: TextField(
                    controller: _content,
                    maxLines: 6,
                    maxLength: 2000,
                    style: AppType.body,
                    cursorColor: const Color(AppColors.accent),
                    decoration: _inputStyle(
                      '遇到什么问题、有什么建议，都可以告诉我们…',
                    ),
                  ),
                ),
                const SizedBox(height: AppSpace.x5),
                _label('联系方式（选填）'),
                const SizedBox(height: AppSpace.x2),
                _card(
                  child: TextField(
                    controller: _contact,
                    maxLength: 100,
                    style: AppType.body,
                    cursorColor: const Color(AppColors.accent),
                    keyboardType: TextInputType.emailAddress,
                    decoration: _inputStyle('邮箱 / 联系方式，便于我们回复你'),
                  ),
                ),
                const SizedBox(height: AppSpace.x6),
                PillButton(
                  label: '提交反馈',
                  size: PillSize.lg,
                  expand: true,
                  loading: _submitting,
                  enabled: !_submitting,
                  glow: true,
                  onTap: _submit,
                ),
                const SizedBox(height: AppSpace.x3),
                const Center(
                  child: Text('我们会在 1-3 个工作日内处理',
                      style: AppType.micro),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _label(String text) {
    return Padding(
      padding: const EdgeInsets.only(left: AppSpace.x1),
      child: Text(
        text,
        style: AppType.caption.copyWith(color: const Color(AppColors.textSecondary)),
      ),
    );
  }

  Widget _card({required Widget child}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.x4, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(AppColors.card),
        borderRadius: AppRadius.rLg,
        border: Border.all(color: const Color(AppColors.border)),
      ),
      child: child,
    );
  }

  InputDecoration _inputStyle(String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle: AppType.bodySm.copyWith(color: const Color(AppColors.textTertiary)),
      filled: false,
      border: InputBorder.none,
      enabledBorder: InputBorder.none,
      focusedBorder: InputBorder.none,
      contentPadding: const EdgeInsets.symmetric(vertical: AppSpace.x3),
      counterStyle: AppType.micro,
    );
  }
}
