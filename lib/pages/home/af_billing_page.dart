import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../api/client.dart';
import '../../config.dart';
import '../../services/secure_store.dart';
import 'af_bills_page.dart';
import 'af_palette.dart';

/// 二楼 · AI 工坊：额度与充值（新版视觉）。
///
/// 额度口径：全档按 token 计（5 小时窗口 / 7 天 / 月三档同时扣，取最小）。
/// 充值走兑换码；在线支付通道待接入时，页面给出明确说明而不是假装可用。
class AfBillingPage extends StatefulWidget {
  const AfBillingPage({super.key, this.client});

  final http.Client? client;

  @override
  State<AfBillingPage> createState() => _AfBillingPageState();
}

class _AfBillingPageState extends State<AfBillingPage> {
  late final http.Client _http = widget.client ?? http.Client();
  String? _token;
  Map<String, dynamic>? _q;
  final _code = TextEditingController();
  bool _busy = false;
  String _tip = '';

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    _token = ApiClient.token;
    final cached = await SecureStore.read(SecureStore.tokenKey);
    if ((_token == null || _token!.isEmpty) && cached != null && cached.isNotEmpty) {
      _token = cached;
      ApiClient.token = cached;
    }
    await _load();
  }

  Future<void> _load() async {
    if (_token == null) return;
    try {
      final r = await _http.get(Uri.parse('$kApiBase/af/quota'),
          headers: {'Authorization': 'Bearer $_token'}).timeout(const Duration(seconds: 15));
      final j = ((jsonDecode(r.body) is Map)
          ? Map<String, dynamic>.from(jsonDecode(r.body) as Map)
          : <String, dynamic>{});
      if (j['ok'] == true) setState(() => _q = j);
    } catch (_) {}
  }

  Future<void> _redeem() async {
    final code = _code.text.trim();
    if (code.isEmpty || _token == null) return;
    setState(() {
      _busy = true;
      _tip = '';
    });
    try {
      final r = await _http.post(Uri.parse('$kApiBase/af/redeem'),
          headers: {
            'Authorization': 'Bearer $_token',
            'Content-Type': 'application/json'
          },
          body: jsonEncode({'code': code}));
      final j = ((jsonDecode(r.body) is Map)
          ? Map<String, dynamic>.from(jsonDecode(r.body) as Map)
          : <String, dynamic>{});
      setState(() => _tip = j['ok'] == true
          ? '兑换成功，额度已到账'
          : '兑换失败：${j['error'] ?? '兑换码无效'}');
      if (j['ok'] == true) _code.clear();
      await _load();
    } catch (e) {
      setState(() => _tip = '兑换失败：$e');
    } finally {
      setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  String _fmt(double v) {
    if (v >= 100000000) return '${(v / 100000000).toStringAsFixed(1)} 亿';
    if (v >= 10000) return '${(v / 10000).toStringAsFixed(1)} 万';
    return v.toInt().toString();
  }

  @override
  Widget build(BuildContext context) {
    final left = (_q?['left'] ?? 0);
    final lim = (_q?['limit_w5h'] ?? 0);
    final plan = (_q?['plan'] ?? 'free').toString().toUpperCase();
    final pct =
        (lim is int && lim > 0 && left is int) ? (left / lim).clamp(0.0, 1.0) : 0.0;
    final bal = ((_q?['balance'] ?? 0) as num) / 100.0;

    return Scaffold(
      backgroundColor: const Color(AfPalette.bg),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 顶栏：标题 + 账单明细 + × 返回
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 6, 14, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('额度与账单',
                            style: TextStyle(
                                fontSize: 19,
                                fontWeight: FontWeight.w700,
                                letterSpacing: .3,
                                height: 1.2,
                                color: Color(AfPalette.text))),
                        const SizedBox(height: 3),
                        Text('$plan · 5 小时窗口余额',
                            style: const TextStyle(
                                fontSize: 11,
                                letterSpacing: .2,
                                color: Color(AfPalette.text3))),
                      ],
                    ),
                  ),
                  _iconBtn(Icons.receipt_long_outlined, () {
                    Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => const AfBillsPage()));
                  }),
                  const SizedBox(width: 8),
                  _iconBtn(Icons.close_rounded, () => Navigator.of(context).maybePop()),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(18, 4, 18, 24),
                children: [
                  // 余额大字
                  const Text('剩余额度',
                      style: TextStyle(
                          fontSize: 10.5,
                          letterSpacing: .5,
                          color: Color(AfPalette.text3))),
                  const SizedBox(height: 8),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(left is int ? _fmt(left.toDouble()) : '—',
                          style: const TextStyle(
                              fontSize: 34,
                              fontWeight: FontWeight.w700,
                              letterSpacing: .4,
                              height: 1.05,
                              color: Color(AfPalette.text))),
                      const SizedBox(width: 6),
                      Text('/ ${lim is int ? _fmt(lim.toDouble()) : '—'} token',
                          style: const TextStyle(
                              fontSize: 12, color: Color(AfPalette.text2))),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Text('余额 ¥${bal.toStringAsFixed(2)}',
                          style: const TextStyle(
                              fontSize: 11,
                              letterSpacing: .2,
                              color: Color(AfPalette.accent))),
                      const Spacer(),
                      Text('剩余 ${(pct * 100).toStringAsFixed(1)}%',
                          style: const TextStyle(
                              fontSize: 10.5, color: Color(AfPalette.text3))),
                    ],
                  ),
                  const SizedBox(height: 10),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: pct,
                      minHeight: 4,
                      backgroundColor: const Color(AfPalette.line),
                      valueColor:
                          const AlwaysStoppedAnimation(Color(AfPalette.accent)),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text('缓存命中按 1/10 计费，同一段上下文重复发问扣得会少一些。',
                      style: TextStyle(
                          fontSize: 10.5,
                          height: 1.6,
                          color: Color(AfPalette.text3))),

                  const SizedBox(height: 22),
                  const Text('套餐',
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          letterSpacing: .3,
                          color: Color(AfPalette.text))),
                  const SizedBox(height: 10),
                  _plan('FREE', '5 小时 20,000 token', '开通会员后额度大幅提升，且支持 7 天与月窗口',
                      plan == 'FREE'),
                  const SizedBox(height: 8),
                  _plan('VIP', '5h 8 万 / 7天 30 万 / 月 60 万', '适合日常整理文件、抓网页、写文档',
                      plan == 'VIP'),
                  const SizedBox(height: 8),
                  _plan('SVIP', '5h 20 万 / 7天 80 万 / 月 200 万', '重活多、常跑沙箱、需要长上下文',
                      plan == 'SVIP'),

                  const SizedBox(height: 22),
                  const Text('充值',
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          letterSpacing: .3,
                          color: Color(AfPalette.text))),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(AfPalette.card),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: const Color(AfPalette.line)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('兑换码充值',
                            style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: Color(AfPalette.text))),
                        const SizedBox(height: 6),
                        const Text('输入兑换码，额度立即到账。',
                            style: TextStyle(
                                fontSize: 11, color: Color(AfPalette.text3))),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 9),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF0E1117),
                                  borderRadius: BorderRadius.circular(10),
                                  border:
                                      Border.all(color: const Color(AfPalette.line)),
                                ),
                                child: TextField(
                                  controller: _code,
                                  style: const TextStyle(
                                      fontSize: 13, color: Color(AfPalette.text)),
                                  decoration: const InputDecoration(
                                    filled: false,
                                    border: InputBorder.none,
                                    enabledBorder: InputBorder.none,
                                    focusedBorder: InputBorder.none,
                                    disabledBorder: InputBorder.none,
                                    isDense: true,
                                    contentPadding: EdgeInsets.zero,
                                    hintText: '输入兑换码',
                                    hintStyle: TextStyle(
                                        fontSize: 13, color: Color(AfPalette.text3)),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            PressableBox(
                              onTap: _busy ? null : _redeem,
                              child: Container(
                                height: 38,
                                padding: const EdgeInsets.symmetric(horizontal: 18),
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  gradient: _busy ? null : AfPalette.accentGrad,
                                  color: _busy ? const Color(AfPalette.card2) : null,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text('兑换',
                                    style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                        color: _busy
                                            ? const Color(AfPalette.text3)
                                            : const Color(AfPalette.onAccent))),
                              ),
                            ),
                          ],
                        ),
                        if (_tip.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          Text(_tip,
                              style: TextStyle(
                                  fontSize: 11,
                                  color: _tip.contains('成功')
                                      ? const Color(AfPalette.accent)
                                      : const Color(AfPalette.danger))),
                        ],
                      ],
                    ),
                  ),

                  const SizedBox(height: 14),
                  const Text('在线支付通道还在对接中，目前只走兑换码。需要直接充值可以找管理员发码。',
                      style: TextStyle(
                          fontSize: 10.5,
                          height: 1.6,
                          color: Color(AfPalette.text3))),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _iconBtn(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: const Color(AfPalette.card),
          borderRadius: BorderRadius.circular(11),
          border: Border.all(color: const Color(AfPalette.line)),
        ),
        child: Icon(icon, size: 17, color: const Color(AfPalette.text2)),
      ),
    );
  }

  Widget _plan(String name, String quota, String desc, bool active) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: active ? const Color(0x143AC9F5) : const Color(AfPalette.card),
        borderRadius: BorderRadius.circular(13),
        border: Border.all(
            color: active
                ? const Color(AfPalette.accentLineStrong)
                : const Color(AfPalette.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(name,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      letterSpacing: .4,
                      color: active
                          ? const Color(AfPalette.accent)
                          : const Color(AfPalette.text))),
              const SizedBox(width: 8),
              if (active)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(color: const Color(AfPalette.accentLine)),
                  ),
                  child: const Text('当前',
                      style: TextStyle(
                          fontSize: 9.5, color: Color(AfPalette.accent))),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(quota,
              style: const TextStyle(
                  fontSize: 12.5, color: Color(AfPalette.text), height: 1.5)),
          const SizedBox(height: 4),
          Text(desc,
              style: const TextStyle(
                  fontSize: 10.5, height: 1.6, color: Color(AfPalette.text3))),
        ],
      ),
    );
  }
}

/// 轻量点按反馈（无 Material ink，避免弹层留下水波纹）。
class PressableBox extends StatefulWidget {
  const PressableBox({super.key, this.onTap, required this.child});

  final VoidCallback? onTap;
  final Widget child;

  @override
  State<PressableBox> createState() => _PressableBoxState();
}

class _PressableBoxState extends State<PressableBox> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      onTapDown: widget.onTap == null
          ? null
          : (_) => setState(() => _down = true),
      onTapCancel: () => setState(() => _down = false),
      onTapUp: (_) => setState(() => _down = false),
      child: AnimatedScale(
        scale: _down ? 0.97 : 1,
        duration: const Duration(milliseconds: 120),
        child: widget.child,
      ),
    );
  }
}
