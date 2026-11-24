import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../design/tokens.dart';

/// 自定义模型显示名：内置两项给中文名，`p:<pid>:<model>` 显示模型 id
String afModelLabel(String m) {
  if (m == 'deepseek-flash') return '快速';
  if (m == 'deepseek-v4-pro') return '强力';
  if (m.startsWith('p:')) {
    final parts = m.split(':');
    if (parts.length >= 3) return parts[2];
  }
  return m.isEmpty ? '快速' : m;
}

bool afIsByok(String m) => m.startsWith('p:');

/// V4 Pro 是纯文本模型（官方能力表里 Vision 标 Not supported），
/// 带图消息必须临时交给带视觉的 Flash，否则上游会直接回 Unsupported Image。
/// 这不是图片格式问题：DeepSeek 按文件内容识别格式，jpg/png/webp 都行。
String afModelForTurn(String model, {required bool hasImage}) {
  if (hasImage && model == 'deepseek-v4-pro') return 'deepseek-flash';
  return model;
}

/// 给用户看的解释，避免「我明明选的是强力，怎么偷偷换了」的疑惑。
String afVisionRouteNote(String model, {required bool hasImage}) {
  if (hasImage && model == 'deepseek-v4-pro') {
    return '带图这一轮会切到「快速」视觉模型；下一条不带图仍用「强力」';
  }
  return '';
}

class AfProviderModel {
  const AfProviderModel({
    required this.id,
    required this.model,
    required this.enabled,
  });
  final String id;
  final String model;
  final bool enabled;

  factory AfProviderModel.fromJson(Map<String, dynamic> j) => AfProviderModel(
    id: (j['id'] ?? '') as String,
    model: (j['model'] ?? '') as String,
    enabled: (j['enabled'] ?? 1) == 1 || j['enabled'] == true,
  );
}

class AfProvider {
  const AfProvider({
    required this.id,
    required this.name,
    required this.base,
    required this.models,
    this.keyHint = '',
  });
  final String id;
  final String name;
  final String base;
  final List<AfProviderModel> models;

  /// 后端下发的脱敏 Key（如 sk-4****cf53），编辑时只做展示
  final String keyHint;

  factory AfProvider.fromJson(Map<String, dynamic> j) => AfProvider(
    id: (j['id'] ?? '') as String,
    name: (j['name'] ?? '') as String,
    base: (j['base'] ?? '') as String,
    keyHint: (j['key_hint'] ?? '').toString(),
    models: ((j['models'] as List?) ?? const [])
        .map((e) => AfProviderModel.fromJson(Map<String, dynamic>.from(e)))
        .toList(),
  );
}

Future<List<AfProvider>> loadAfProviders() async {
  try {
    final j = await ApiClient.get('/af/providers');
    return ((j['list'] as List?) ?? const [])
        .map((e) => AfProvider.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  } catch (_) {
    return const [];
  }
}

/// 添加 API 表单：API 名称 / Base URL / API Key / 类型 +「获取可用模型」→ 勾选 → 保存
Future<AfProvider?> showAfAddProviderSheet(
  BuildContext context, {
  AfProvider? edit,
}) {
  return showModalBottomSheet<AfProvider>(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(AppColors.card),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
    ),
    builder: (_) => _AddProviderSheet(edit: edit),
  );
}

/// 常见服务商的 OpenAI 兼容地址（点一下就填好）
const _afPresets = <List<String>>[
  ['OpenAI', 'https://api.openai.com/v1'],
  ['DeepSeek', 'https://api.deepseek.com/v1'],
  ['Gemini', 'https://generativelanguage.googleapis.com/v1beta/openai'],
  ['通义千问', 'https://dashscope.aliyuncs.com/compatible-mode/v1'],
  ['智谱 GLM', 'https://open.bigmodel.cn/api/paas/v4'],
  ['月之暗面', 'https://api.moonshot.cn/v1'],
  ['火山方舟', 'https://ark.cn-beijing.volces.com/api/v3'],
  ['OpenRouter', 'https://openrouter.ai/api/v1'],
  ['Groq', 'https://api.groq.com/openai/v1'],
  ['xAI', 'https://api.x.ai/v1'],
  ['Mistral', 'https://api.mistral.ai/v1'],
];

class _AddProviderSheet extends StatefulWidget {
  const _AddProviderSheet({this.edit});

  /// 传入即进入「编辑已有 API」模式
  final AfProvider? edit;

  @override
  State<_AddProviderSheet> createState() => _AddProviderSheetState();
}

class _AddProviderSheetState extends State<_AddProviderSheet> {
  final _name = TextEditingController();
  final _base = TextEditingController();
  final _key = TextEditingController();

  bool _probing = false;
  String? _err;
  List<String> _models = const [];
  final Set<String> _checked = {};
  bool _saving = false;

  bool get _isEdit => widget.edit != null;

  @override
  void initState() {
    super.initState();
    final e = widget.edit;
    if (e != null) {
      _name.text = e.name;
      _base.text = e.base;
      _models = e.models.map((m) => m.model).toList();
      _checked.addAll(e.models.where((m) => m.enabled).map((m) => m.model));
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _base.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _probe() async {
    final base = _base.text.trim();
    final key = _key.text.trim();
    if (base.isEmpty) {
      setState(() => _err = '先填 Base URL，例如 https://api.deepseek.com/v1');
      return;
    }
    if (key.isEmpty && !_isEdit) {
      setState(() => _err = '再填 API Key');
      return;
    }
    setState(() {
      _err = null;
      _probing = true;
    });
    try {
      final j = await ApiClient.post(
        '/af/providers/probe',
        body: {
          'base': base,
          'key': key,
          if (_isEdit && key.isEmpty) 'id': widget.edit!.id,
        },
      );
      final ids = ((j['models'] as List?) ?? const [])
          .map((e) => '$e')
          .toList();
      setState(() {
        _models = ids;
        _checked
          ..clear()
          ..addAll(ids);
        _base.text = (j['base'] ?? base) as String;
      });
      if (ids.isEmpty) {
        setState(() => _err = '这个 API 没有返回可用模型，检查地址或密钥');
      }
    } catch (e) {
      setState(() => _err = '获取失败：${e.toString()}');
    } finally {
      if (mounted) setState(() => _probing = false);
    }
  }

  Future<void> _save() async {
    if (_checked.isEmpty) return;
    setState(() => _saving = true);
    try {
      final name = _name.text.trim().isEmpty ? '我的 API' : _name.text.trim();
      final body = <String, dynamic>{
        'name': name,
        'base': _base.text.trim(),
        'models': _checked.toList(),
      };
      if (_key.text.trim().isNotEmpty) body['key'] = _key.text.trim();
      if (_isEdit) {
        body['id'] = widget.edit!.id;
        await ApiClient.put('/af/providers', body: body);
        if (mounted) {
          Navigator.of(context).pop(
            AfProvider(
              id: widget.edit!.id,
              name: name,
              base: _base.text.trim(),
              keyHint: widget.edit!.keyHint,
              models: _checked
                  .map((m) => AfProviderModel(id: m, model: m, enabled: true))
                  .toList(),
            ),
          );
        }
        return;
      }
      final j = await ApiClient.post('/af/providers', body: body);
      final p = AfProvider(
        id: (j['id'] ?? '') as String,
        name: (j['name'] ?? name) as String,
        base: (j['base'] ?? _base.text.trim()) as String,
        models: _checked
            .map((m) => AfProviderModel(id: m, model: m, enabled: true))
            .toList(),
      );
      if (mounted) Navigator.of(context).pop(p);
    } catch (e) {
      setState(() => _err = '保存失败：${e.toString()}');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    final e = widget.edit;
    if (e == null) return;
    setState(() => _saving = true);
    try {
      await ApiClient.delete('/af/providers?id=${e.id}');
      if (mounted) Navigator.of(context).pop();
    } catch (err) {
      setState(() => _err = '删除失败：${err.toString()}');
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * .82,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
              child: Row(
                children: [
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _isEdit ? '编辑 API' : '添加 API',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(
                      Icons.close_rounded,
                      size: 18,
                      color: Color(AppColors.textTertiary),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: Color(AppColors.hairline)),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _label('API 名称'),
                    _field(_name, '给这个 API 起个名字，如「我的 DeepSeek」'),
                    const SizedBox(height: 12),
                    _label('Base URL', trailing: '以 /v1 结尾'),
                    _field(_base, 'https://api.deepseek.com/v1'),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 30,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: _afPresets.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 8),
                        itemBuilder: (_, i) {
                          final pr = _afPresets[i];
                          final on = _base.text.trim() == pr[1];
                          return InkWell(
                            borderRadius: BorderRadius.circular(8),
                            onTap: () => setState(() {
                              _base.text = pr[1];
                              if (_name.text.trim().isEmpty) _name.text = pr[0];
                            }),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                              ),
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(8),
                                color: on
                                    ? const Color(0x1A45E0AE)
                                    : const Color(AppColors.elevated),
                                border: Border.all(
                                  color: on
                                      ? const Color(0x7345E0AE)
                                      : const Color(AppColors.hairline),
                                ),
                              ),
                              child: Text(
                                pr[0],
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: on
                                      ? const Color(AppColors.accent)
                                      : const Color(AppColors.textSecondary),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 12),
                    _label(
                      'API Key',
                      trailing: _isEdit && widget.edit!.keyHint.isNotEmpty
                          ? '已保存 ${widget.edit!.keyHint} · 留空不改'
                          : null,
                    ),
                    _field(_key, _isEdit ? '留空表示不修改' : 'sk-…', obscure: true),
                    const SizedBox(height: 12),
                    _label('类型'),
                    Container(
                      height: 42,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: const Color(AppColors.elevated),
                        borderRadius: BorderRadius.circular(11),
                        border: Border.all(
                          color: const Color(AppColors.hairline),
                        ),
                      ),
                      child: Row(
                        children: [
                          const Text(
                            'OpenAI 兼容',
                            style: TextStyle(fontSize: 13),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              'OpenAI-API-compatible',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppType.micro.copyWith(
                                color: const Color(AppColors.textTertiary),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      height: 44,
                      child: OutlinedButton(
                        onPressed: _probing ? null : _probe,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(AppColors.accent),
                          side: const BorderSide(color: Color(0x7345E0AE)),
                          backgroundColor: const Color(0x1445E0AE),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: _probing
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Color(AppColors.accent),
                                ),
                              )
                            : Text(
                                _models.isEmpty ? '获取可用模型' : '重新获取',
                                style: const TextStyle(fontSize: 13.5),
                              ),
                      ),
                    ),
                    if (_err != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Text(
                          _err!,
                          style: const TextStyle(
                            fontSize: 11.5,
                            color: Color(0xFFFF7A7A),
                          ),
                        ),
                      ),
                    if (_models.isNotEmpty) ...[
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Text(
                            '拉到 ${_models.length} 个模型',
                            style: AppType.micro.copyWith(
                              color: const Color(AppColors.textTertiary),
                            ),
                          ),
                          const Spacer(),
                          Text(
                            '默认全选 · 点一下取消',
                            style: AppType.micro.copyWith(
                              color: const Color(AppColors.textTertiary),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      for (final m in _models) _modelLine(m),
                    ],
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Row(
                children: [
                  if (_isEdit) ...[
                    SizedBox(
                      height: 46,
                      child: TextButton(
                        onPressed: _saving ? null : _delete,
                        style: TextButton.styleFrom(
                          foregroundColor: const Color(0xFFFF7A7A),
                        ),
                        child: const Text('删除', style: TextStyle(fontSize: 13)),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: SizedBox(
                      height: 46,
                      child: ElevatedButton(
                        onPressed: (_checked.isEmpty || _saving) ? null : _save,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(AppColors.accent),
                          disabledBackgroundColor: const Color(0x6645E0AE),
                          foregroundColor: const Color(0xFF03140F),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(13),
                          ),
                        ),
                        child: const Text(
                          '保存',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _label(String t, {String? trailing}) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(
      children: [
        Text(
          t,
          style: AppType.micro.copyWith(
            color: const Color(AppColors.textSecondary),
          ),
        ),
        const Spacer(),
        if (trailing != null)
          Text(
            trailing,
            style: AppType.micro.copyWith(
              color: const Color(AppColors.textTertiary),
            ),
          ),
      ],
    ),
  );

  Widget _field(TextEditingController c, String hint, {bool obscure = false}) {
    return TextField(
      controller: c,
      obscureText: obscure,
      style: const TextStyle(fontSize: 13),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(
          fontSize: 12.5,
          color: Color(AppColors.textTertiary),
        ),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 12,
        ),
        filled: true,
        fillColor: const Color(AppColors.elevated),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(11),
          borderSide: const BorderSide(color: Color(AppColors.hairline)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(11),
          borderSide: const BorderSide(color: Color(0x7345E0AE)),
        ),
      ),
    );
  }

  Widget _modelLine(String m) {
    final on = _checked.contains(m);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(11),
        onTap: () => setState(() {
          if (on) {
            _checked.remove(m);
          } else {
            _checked.add(m);
          }
        }),
        child: Container(
          height: 42,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: const Color(AppColors.elevated),
            borderRadius: BorderRadius.circular(11),
            border: Border.all(color: const Color(AppColors.hairline)),
          ),
          child: Row(
            children: [
              Container(
                width: 17,
                height: 17,
                decoration: BoxDecoration(
                  color: on
                      ? const Color(AppColors.accent)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(
                    color: on
                        ? const Color(AppColors.accent)
                        : const Color(0x40FFFFFF),
                  ),
                ),
                child: on
                    ? const Icon(
                        Icons.check_rounded,
                        size: 13,
                        color: Color(0xFF03140F),
                      )
                    : null,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  m,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: const Color(AppColors.hairline)),
                ),
                child: Text(
                  'LLM',
                  style: AppType.micro.copyWith(
                    fontSize: 9.5,
                    color: const Color(AppColors.textTertiary),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 模型选择弹窗（底部 sheet）：一级 快速/强力 + 各自定义 API；二级 该 API 的模型 id
class AfModelPickerSheet extends StatefulWidget {
  const AfModelPickerSheet({
    super.key,
    required this.current,
    required this.onPick,
    this.initialProviders,
  });

  final String current;
  final ValueChanged<String> onPick;
  final List<AfProvider>? initialProviders;

  @override
  State<AfModelPickerSheet> createState() => _AfModelPickerSheetState();
}

class _AfModelPickerSheetState extends State<AfModelPickerSheet> {
  List<AfProvider> _providers = const [];
  String? _apiView;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _providers = widget.initialProviders ?? const [];
    _refresh(initial: widget.initialProviders != null);
  }

  Future<void> _refresh({bool initial = false}) async {
    if (initial) {
      setState(() => _loading = false);
      return;
    }
    setState(() => _loading = true);
    final list = await loadAfProviders();
    if (!mounted) return;
    setState(() {
      _providers = list;
      _loading = false;
      if (_apiView != null && !list.any((x) => x.id == _apiView)) {
        _apiView = null; // 被删掉了，回到一级
      }
    });
  }

  Future<void> _add() async {
    final p = await showAfAddProviderSheet(context);
    if (p == null) return;
    await _refresh();
    if (!mounted) return;
    setState(() => _apiView = p.id);
  }

  Future<void> _edit(AfProvider p) async {
    final r = await showAfAddProviderSheet(context, edit: p);
    if (!mounted) return;
    await _refresh();
    if (!mounted) return;
    if (r == null) {
      // 可能是删除了：_refresh 已把 _apiView 归位
      return;
    }
    setState(() => _apiView = r.id);
  }

  String _modelKey(AfProvider p, String m) => 'p:${p.id}:$m';

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: _apiView == null ? _firstLevel(context) : _secondLevel(context),
      ),
    );
  }

  Widget _firstLevel(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('选择模型', style: AppType.title),
        const SizedBox(height: 12),
        _builtinCard('deepseek-flash', '快速', const [
          '日常够用、便宜',
          '支持看图',
          '约 1 元 / 16 万 token',
        ]),
        const SizedBox(height: 10),
        _builtinCard('deepseek-v4-pro', '强力', const [
          '推理更深、能扛复杂活',
          '配合 Agent 模式最稳',
          '约 1 元 / 5 万 token',
        ]),
        if (_loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 10),
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Color(AppColors.textTertiary),
              ),
            ),
          )
        else ...[
          for (final p in _providers) ...[
            const SizedBox(height: 10),
            _providerRow(p),
          ],
        ],
        const SizedBox(height: 12),
        InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: _add,
          child: Container(
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0x4D45E0AE)),
              color: const Color(0x0F45E0AE),
            ),
            child: const Text(
              '＋ 添加 API',
              style: TextStyle(
                fontSize: 13,
                color: Color(AppColors.accent),
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _builtinCard(String key, String title, List<String> lines) {
    final on = widget.current == key;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () {
        widget.onPick(key);
        Navigator.of(context).pop();
      },
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: const Color(AppColors.elevated),
          border: Border.all(
            color: on
                ? const Color(AppColors.accent)
                : const Color(AppColors.hairline),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: AppType.body),
                  const SizedBox(height: 4),
                  for (final l in lines)
                    Text(
                      l,
                      style: AppType.micro.copyWith(
                        color: const Color(AppColors.textTertiary),
                      ),
                    ),
                ],
              ),
            ),
            if (on)
              const Text(
                '✓',
                style: TextStyle(fontSize: 14, color: Color(AppColors.accent)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _providerRow(AfProvider p) {
    final on = _isCurrentProvider(p);
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => setState(() => _apiView = p.id),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: const Color(AppColors.elevated),
          border: Border.all(
            color: on
                ? const Color(AppColors.accent)
                : const Color(AppColors.hairline),
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 28,
              height: 28,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: const Color(0x1A45E0AE),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0x4045E0AE)),
              ),
              child: Text(
                p.name.isEmpty ? 'A' : p.name.substring(0, 1),
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Color(AppColors.accent),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(p.name, style: AppType.body),
                  const SizedBox(height: 3),
                  Text(
                    '${p.models.length} 个模型 · 自己的 Key',
                    style: AppType.micro.copyWith(
                      color: const Color(AppColors.textTertiary),
                    ),
                  ),
                ],
              ),
            ),
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => _edit(p),
              child: const Padding(
                padding: EdgeInsets.all(6),
                child: Icon(
                  Icons.edit_rounded,
                  size: 15,
                  color: Color(AppColors.textTertiary),
                ),
              ),
            ),
            const Text(
              '›',
              style: TextStyle(
                fontSize: 14,
                color: Color(AppColors.textTertiary),
              ),
            ),
          ],
        ),
      ),
    );
  }

  bool _isCurrentProvider(AfProvider p) {
    final c = widget.current;
    if (!c.startsWith('p:')) return false;
    final parts = c.split(':');
    return parts.length >= 3 && parts[1] == p.id;
  }

  Widget _secondLevel(BuildContext context) {
    final p = _providers.firstWhere(
      (x) => x.id == _apiView,
      orElse: () => AfProvider(id: '', name: '', base: '', models: const []),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            InkWell(
              onTap: () => setState(() => _apiView = null),
              borderRadius: BorderRadius.circular(8),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                child: Text(
                  '‹',
                  style: TextStyle(
                    fontSize: 18,
                    color: Color(AppColors.textTertiary),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                p.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => _edit(p),
              child: const Padding(
                padding: EdgeInsets.all(6),
                child: Icon(
                  Icons.edit_rounded,
                  size: 15,
                  color: Color(AppColors.textTertiary),
                ),
              ),
            ),
            Text(
              '${p.models.length}',
              style: AppType.micro.copyWith(
                color: const Color(AppColors.textTertiary),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 300),
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final m in p.models.where((x) => x.enabled))
                _modelIdRow(p, m.model),
            ],
          ),
        ),
        const SizedBox(height: 10),
        InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: _add,
          child: Container(
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0x4D45E0AE)),
              color: const Color(0x0F45E0AE),
            ),
            child: const Text(
              '＋ 添加 API',
              style: TextStyle(
                fontSize: 13,
                color: Color(AppColors.accent),
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _modelIdRow(AfProvider p, String m) {
    final key = _modelKey(p, m);
    final on = widget.current == key;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(11),
        onTap: () {
          widget.onPick(key);
          Navigator.of(context).pop();
        },
        child: Container(
          height: 46,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: const Color(AppColors.elevated),
            borderRadius: BorderRadius.circular(11),
            border: Border.all(
              color: on
                  ? const Color(AppColors.accent)
                  : const Color(AppColors.hairline),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      m,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12.5),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      p.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.micro.copyWith(
                        fontSize: 10,
                        color: const Color(AppColors.textTertiary),
                      ),
                    ),
                  ],
                ),
              ),
              if (on)
                const Text(
                  '✓',
                  style: TextStyle(
                    fontSize: 13,
                    color: Color(AppColors.accent),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
