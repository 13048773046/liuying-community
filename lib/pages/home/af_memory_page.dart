import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../config.dart';
import '../../design/tokens.dart';
import '../../services/secure_store.dart';

/// AI 工坊 · 记忆库。展示长期记忆，可单条删除。
class AfMemoryPage extends StatefulWidget {
  const AfMemoryPage({super.key, this.client});

  /// 测试时可注入；正式运行留空即用默认 client。
  final http.Client? client;

  @override
  State<AfMemoryPage> createState() => _AfMemoryPageState();
}

class _AfMemoryPageState extends State<AfMemoryPage> {
  bool _loading = true;
  String? _err;
  String? _token;
  late final http.Client _http = widget.client ?? http.Client();
  bool _ownClient = false;
  List<Map<String, dynamic>> _items = const [];

  static Map<String, dynamic> _asMap(dynamic v) {
    if (v is Map<String, dynamic>) return v;
    if (v is Map) {
      final out = <String, dynamic>{};
      v.forEach((k, val) => out[k.toString()] = val);
      return out;
    }
    return <String, dynamic>{};
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _token = await SecureStore.read(SecureStore.tokenKey);
    if (_token == null) {
      if (mounted) {
        setState(() {
          _loading = false;
          _err = '登录后可用';
        });
      }
      return;
    }
    try {
      _ownClient = widget.client == null;
      final r = await _http.get(
        Uri.parse('$kApiBase/af/memory'),
        headers: {'Authorization': 'Bearer $_token'},
      );
      final j = _asMap(jsonDecode(r.body));
      final list = (j['list'] as List?) ?? const [];
      if (!mounted) return;
      setState(() {
        _items = list.map(_asMap).toList();
        _loading = false;
        _err = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _err = '读取失败：$e';
      });
    }
  }

  Future<void> _delete(String id) async {
    if (_token == null || id.isEmpty) return;
    try {
      final r = await _http.delete(
        Uri.parse('$kApiBase/af/memory'),
        headers: {
          'Authorization': 'Bearer $_token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'id': id}),
      );
      if (r.statusCode == 200) await _load();
    } catch (_) {}
  }

  @override
  void dispose() {
    if (_ownClient) _http.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(AppColors.bg),
      appBar: AppBar(
        backgroundColor: const Color(AppColors.bg),
        elevation: 0,
        title: const Text('记忆库', style: AppType.h2),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded,
              size: 18, color: Color(AppColors.textPrimary)),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SafeArea(
        child: _loading
            ? const Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Color(AppColors.accent)),
                ),
              )
            : _err != null
                ? Center(
                    child: Text(_err!,
                        style: AppType.body
                            .copyWith(color: const Color(AppColors.textSecondary)),
                        textAlign: TextAlign.center),
                  )
                : _items.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.psychology_alt_outlined,
                                size: 40, color: Color(AppColors.textTertiary)),
                            const SizedBox(height: 12),
                            Text('还没有记忆',
                                style: AppType.body.copyWith(
                                    color: const Color(AppColors.textSecondary))),
                            const SizedBox(height: 6),
                            Text('跟小萤说“记住…”，它就会存在这里',
                                style: AppType.micro
                                    .copyWith(color: const Color(AppColors.textTertiary))),
                          ],
                        ),
                      )
                    : ListView.separated(
                        padding: EdgeInsets.fromLTRB(AppSpace.gutter, AppSpace.x2,
                            AppSpace.gutter, AppSpace.x6),
                        itemCount: _items.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 10),
                        itemBuilder: (_, i) {
                          final m = _items[i];
                          return Container(
                            padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
                            decoration: BoxDecoration(
                              color: const Color(AppColors.card),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: const Color(AppColors.hairline)),
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        (m['kind'] ?? 'fact').toString(),
                                        style: AppType.micro.copyWith(
                                            color: const Color(AppColors.textTertiary)),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        (m['content'] ?? '').toString(),
                                        style: AppType.body.copyWith(
                                            color: const Color(AppColors.textPrimary)),
                                      ),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.close_rounded,
                                      size: 16, color: Color(AppColors.textTertiary)),
                                  onPressed: () => _delete((m['id'] ?? '').toString()),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
      ),
    );
  }
}
