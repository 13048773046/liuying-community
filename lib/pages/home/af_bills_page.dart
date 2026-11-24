import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../api/client.dart';
import '../../config.dart';
import '../../services/secure_store.dart';
import 'af_palette.dart';


String _n(num v) {
  final s = v.round().toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}

Map<String, dynamic> _asMap(dynamic v) =>
    v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

double _asDouble(dynamic v) {
  if (v is num) return v.toDouble();
  return double.tryParse('${v ?? ''}') ?? 0;
}

/// 账单明细：赠送额度消耗 + 余额充值 / 扣减流水（新版视觉）。
class AfBillsPage extends StatefulWidget {
  const AfBillsPage({super.key, this.client});

  final http.Client? client;

  @override
  State<AfBillsPage> createState() => _AfBillsPageState();
}

class _AfBillsPageState extends State<AfBillsPage> {
  late final http.Client _http = widget.client ?? http.Client();
  String? _token;
  List<Map<String, dynamic>> _rows = [];
  Map<String, dynamic> _sum = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    _token = ApiClient.token ?? await SecureStore.read(SecureStore.tokenKey);
    await _load();
  }

  Future<void> _load() async {
    if (_token == null || _token!.isEmpty) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      final r = await _http.get(Uri.parse('$kApiBase/af/bills'),
          headers: {'Authorization': 'Bearer $_token'});
      final j = _asMap(jsonDecode(r.body));
      final list = (j['list'] as List?) ?? const [];
      if (!mounted) return;
      setState(() {
        _rows = list.map(_asMap).toList();
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    var usedGift = 0.0, usedFen = 0.0, recharged = 0.0;
    for (final r in _rows) {
      final kind = (r['kind'] ?? '').toString();
      if (kind == 'recharge') {
        recharged += _asDouble(r['fen']);
      } else {
        usedGift += _asDouble(r['gift']);
        usedFen += _asDouble(r['fen']);
      }
    }
    _sum = {
      'gift': usedGift,
      'fen': usedFen,
      'recharge': recharged,
    };

    return Scaffold(
      backgroundColor: const Color(AfPalette.bg),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 8, 14, 10),
              child: Row(
                children: [
                  const Expanded(
                    child: Text('账单明细',
                        style: TextStyle(
                            fontSize: 19,
                            fontWeight: FontWeight.w700,
                            letterSpacing: .3,
                            color: Color(AfPalette.text))),
                  ),
                  GestureDetector(
                    onTap: () => Navigator.of(context).maybePop(),
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: const Color(AfPalette.card),
                        borderRadius: BorderRadius.circular(11),
                        border: Border.all(color: const Color(AfPalette.line)),
                      ),
                      child: const Icon(Icons.close_rounded,
                          size: 17, color: Color(AfPalette.text2)),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _loading
                  ? const Center(
                      child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Color(AfPalette.accent))))
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
                      children: [
                        _summary(),
                        const SizedBox(height: 16),
                        if (_rows.isEmpty) _empty(),
                        ..._grouped(),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _summary() {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
      decoration: BoxDecoration(
        color: const Color(AfPalette.card),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(AfPalette.line)),
      ),
      child: Row(children: [
        Expanded(child: _stat('已用赠送', _n(_sum['gift'] ?? 0), 'token')),
        Container(width: 1, height: 26, color: const Color(AfPalette.line)),
        Expanded(
            child: _stat('已用余额',
                '¥${((_sum['fen'] as double) / 100).toStringAsFixed(2)}', '')),
        Container(width: 1, height: 26, color: const Color(AfPalette.line)),
        Expanded(
            child: _stat('累计充值',
                '¥${((_sum['recharge'] as double) / 100).toStringAsFixed(2)}', '')),
      ]),
    );
  }

  Widget _stat(String label, String value, String unit) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label,
            style: const TextStyle(
                fontSize: 10, letterSpacing: .3, color: Color(AfPalette.text3))),
        const SizedBox(height: 5),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Flexible(
              child: Text(value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: Color(AfPalette.text))),
            ),
            if (unit.isNotEmpty)
              Text(' $unit',
                  style: const TextStyle(fontSize: 9, color: Color(AfPalette.text3))),
          ],
        ),
      ]),
    );
  }

  Widget _empty() {
    return Padding(
      padding: const EdgeInsets.only(top: 60),
      child: Column(children: const [
        Icon(Icons.receipt_long_outlined, size: 26, color: Color(AfPalette.text3)),
        SizedBox(height: 10),
        Text('还没有账单',
            style: TextStyle(fontSize: 11, color: Color(AfPalette.text3))),
      ]),
    );
  }

  String _label(String model) {
    if (model.startsWith('p:')) {
      final parts = model.split(':');
      return parts.length >= 3 && parts[2].isNotEmpty ? parts[2] : '自有 Key 模型';
    }
    return model == 'deepseek-v4-pro' ? '强力模型对话' : '快速模型对话';
  }

  List<Widget> _grouped() {
    final out = <Widget>[];
    String last = '';
    for (final r in _rows) {
      final t = DateTime.fromMillisecondsSinceEpoch(
          ((_asDouble(r['created'])) * 1000).toInt());
      final day = '${t.month} 月 ${t.day} 日';
      if (day != last) {
        last = day;
        out.add(Padding(
          padding: const EdgeInsets.fromLTRB(2, 14, 2, 7),
          child: Text(day,
              style: const TextStyle(
                  fontSize: 10, letterSpacing: .6, color: Color(AfPalette.text3))),
        ));
      }
      out.add(_row(r, t));
    }
    return out;
  }

  Widget _row(Map<String, dynamic> r, DateTime t) {
    final kind = (r['kind'] ?? 'chat').toString();
    final isRecharge = kind == 'recharge';
    final fen = _asDouble(r['fen']);
    final gift = _asDouble(r['gift']);
    final tin = _asDouble(r['tokens_in']);
    final tout = _asDouble(r['tokens_out']);
    final model = (r['model'] ?? '').toString();
    final byok = !isRecharge && model.startsWith('p:');
    final ts = '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}';
    final title = isRecharge
        ? ((r['note'] ?? '').toString().isEmpty ? '充值' : (r['note'] ?? '').toString())
        : _label(model);
    final sub = isRecharge
        ? '$ts · 额度到账'
        : '$ts · 输入 ${_n(tin)} / 输出 ${_n(tout)}';

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      decoration: BoxDecoration(
        color: const Color(AfPalette.card),
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: const Color(AfPalette.line)),
      ),
      child: Row(children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: isRecharge
                ? const Color(0x143AC9F5)
                : (byok ? const Color(0x1AFFB35C) : const Color(AfPalette.accentSoft)),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
                color: isRecharge
                    ? const Color(AfPalette.accentLine)
                    : (byok
                        ? const Color(0x33FFB35C)
                        : const Color(AfPalette.accentLine))),
          ),
          child: Icon(
            isRecharge
                ? Icons.add_rounded
                : (byok ? Icons.key_rounded : Icons.bolt_rounded),
            size: 15,
            color: isRecharge
                ? const Color(AfPalette.accent)
                : (byok ? const Color(AfPalette.warm) : const Color(AfPalette.accent)),
          ),
        ),
        const SizedBox(width: 11),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(
              children: [
                Flexible(
                  child: Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: Color(AfPalette.text))),
                ),
                if (byok) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: const Color(0x1AFFB35C),
                      borderRadius: BorderRadius.circular(5),
                      border: Border.all(color: const Color(0x33FFB35C)),
                    ),
                    child: const Text('自有 Key',
                        style: TextStyle(fontSize: 8.5, color: Color(AfPalette.warm))),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 4),
            Text(sub,
                style: const TextStyle(
                    fontSize: 10, letterSpacing: .2, color: Color(AfPalette.text3))),
          ]),
        ),
        const SizedBox(width: 8),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          if (isRecharge)
            Text('+¥${(fen / 100).toStringAsFixed(2)}',
                style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: Color(AfPalette.accent)))
          else ...[
            if (byok)
              const Text('不扣费',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: Color(AfPalette.warm)))
            else if (gift > 0)
              Text('-${_n(gift)}',
                  style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: Color(AfPalette.text)))
            else if (fen > 0)
              Text('-¥${(fen / 100).toStringAsFixed(2)}',
                  style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: Color(AfPalette.text))),
            Text(byok ? 'byok' : (gift > 0 ? 'token' : '余额'),
                style: const TextStyle(fontSize: 9, color: Color(AfPalette.text3))),
          ],
        ]),
      ]),
    );
  }
}
