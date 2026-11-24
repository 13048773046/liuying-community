import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../design/tokens.dart';
import 'af_providers.dart';

/// 推理档位：LOW / MEDIUM / HIGH / XHIGH / ULTRA
/// 第五档 ULTRA = max 推理 + 允许多轮工具自检
class AfEffort {
  const AfEffort(this.key, this.cn, this.coef, this.speed);

  final String key;    // 传给后端的 effort 值（小写）
  final String cn;     // 中文说明用字
  final double coef;   // 计费倍率
  final double speed;  // 白点流动一圈秒数

  String get label => key.toUpperCase();

  static const List<AfEffort> all = [
    AfEffort('low', '低', 1.0, 2.86),
    AfEffort('medium', '中', 1.15, 2.38),
    AfEffort('high', '高', 1.35, 1.96),
    AfEffort('xhigh', '极高', 1.6, 1.61),
    AfEffort('ultra', '最高', 2.0, 1.31),
  ];

  static AfEffort of(String key) =>
      all.firstWhere((e) => e.key == key, orElse: () => all[1]);
}

const _kModeNames = {'chat': '聊天模式', 'work': 'Agent 模式'};

/// 打开推理设置卡片（贴着输入框上方浮出，不占满屏）
Future<void> showAfEffortCard(
  BuildContext context, {
  required String mode,
  required String model,
  required String effort,
  required ValueChanged<String> onMode,
  required ValueChanged<String> onModel,
  required ValueChanged<String> onEffort,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.42),
    isScrollControlled: true,
    builder: (_) => AfEffortSheet(
      mode: mode,
      model: model,
      effort: effort,
      onMode: onMode,
      onModel: onModel,
      onEffort: onEffort,
    ),
  );
}

class AfEffortSheet extends StatefulWidget {
  const AfEffortSheet({
    super.key,
    required this.mode,
    required this.model,
    required this.effort,
    required this.onMode,
    required this.onModel,
    required this.onEffort,
    this.initialProviders,
  });

  final String mode;
  final String model;
  final String effort;
  final ValueChanged<String> onMode;
  final ValueChanged<String> onModel;
  final ValueChanged<String> onEffort;

  /// 仅测试/预览用：注入已加载的 API 列表，跳过网络请求
  final List<AfProvider>? initialProviders;

  @override
  State<AfEffortSheet> createState() => _AfEffortSheetState();
}

class _AfEffortSheetState extends State<AfEffortSheet> {
  late String _mode = widget.mode;
  late String _model = widget.model;
  late String _effort = widget.effort;

  /// 当前弹出的二级小浮层：mode | model | effort | null
  String? _pop;

  /// 二级浮层锚点（相对卡片）
  Rect? _popAnchor;

  /// 用户自建 API（BYOK）
  List<AfProvider> _providers = const [];

  /// 模型浮层（Overlay 实现，浮在卡片上方且可点）
  OverlayEntry? _modelOverlay;
  final GlobalKey _cardKey = GlobalKey();
  bool _disposed = false;

  /// 刚添加完的 API：浮层重建时直接进它的二级列表
  String? _pendingApiId;

  @override
  void initState() {
    super.initState();
    final seed = widget.initialProviders;
    if (seed != null) {
      _providers = seed;
    } else {
      _loadProviders();
    }
  }

  Future<void> _loadProviders() async {
    final list = await loadAfProviders();
    if (!mounted) return;
    setState(() => _providers = list);
  }

  Future<void> _addApi() async {
    final p = await showAfAddProviderSheet(context);
    if (p == null) return;
    await _loadProviders();
    _pendingApiId = p.id;
    _modelOverlay?.markNeedsBuild();
  }

  /// 编辑已添加的 API：名称、接口地址、Key（留空不改）、模型勾选
  Future<void> _editApi(AfProvider p) async {
    final r = await showAfAddProviderSheet(context, edit: p);
    if (r == null) return;
    await _loadProviders();
    _modelOverlay?.markNeedsBuild();
    // 正在用的模型如果被这次编辑删掉了，回退到内置模型，避免发请求时悬空
    if (_model.startsWith('p:${p.id}:')) {
      final parts = _model.split(':');
      final still = _providers.any((x) =>
          x.id == p.id &&
          x.models.any((m) => m.enabled && m.model == parts[2]));
      if (!still) {
        setState(() => _model = 'deepseek-flash');
        widget.onModel('deepseek-flash');
      }
    }
  }

  void _pickModelValue(String v) {
    _closeModelPop();
    setState(() {
      _model = v;
      _pop = null;
    });
    widget.onModel(v);
  }

  Future<void> _openModelPop() async {
    if (_modelOverlay != null) {
      _closeModelPop();
      return;
    }
    if (widget.initialProviders == null && _providers.isEmpty) {
      await _loadProviders();
    }
    if (!mounted) return;
    setState(() => _pop = null);

    final box = _cardKey.currentContext?.findRenderObject() as RenderBox?;
    final media = MediaQuery.of(context).size;
    final rect = (box != null && box.hasSize)
        ? box.localToGlobal(Offset.zero) & box.size
        : Rect.fromLTWH(0, media.height * .5, media.width, 52);
    const w = 216.0;
    final maxH = math.max(120.0, math.min(358.0, rect.top - 56));
    final bottom = media.height - rect.top + 8;

    _modelOverlay = OverlayEntry(builder: (_) {
      return Stack(children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _closeModelPop,
          ),
        ),
        Positioned(
          right: 20,
          bottom: bottom,
          width: w,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxH),
            child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: const Duration(milliseconds: 170),
            curve: Curves.easeOutCubic,
            builder: (_, v, child) => Transform.scale(
              scale: .94 + .06 * v,
              alignment: Alignment.bottomRight,
              child: Opacity(opacity: v, child: child),
            ),
            child: Material(
              color: Colors.transparent,
              child: Container(
                padding: const EdgeInsets.all(5),
                decoration: BoxDecoration(
                  color: const Color(0xFF1B1B1F),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: const Color(0x29FFFFFF)),
                  boxShadow: const [
                    BoxShadow(color: Color(0xE6000000), blurRadius: 38, offset: Offset(0, 14)),
                  ],
                ),
                child: SingleChildScrollView(
                  physics: const ClampingScrollPhysics(),
                  child: _AfModelPopPanel(
                    providers: _providers,
                    current: _model,
                    openApiId: _pendingApiId,
                    onEditProvider: _editApi,
                    onPick: _pickModelValue,
                    onAddApi: _addApi,
                  ),
                ),
              ),
            ),
          ),
          ),
        ),
      ]);
    });
    Overlay.of(context).insert(_modelOverlay!);
    setState(() {});
  }

  void _closeModelPop() {
    final had = _modelOverlay != null;
    _modelOverlay?.remove();
    _modelOverlay = null;
    _pendingApiId = null;
    if (had && mounted && !_disposed) setState(() {});
  }

  @override
  void dispose() {
    _disposed = true;
    _closeModelPop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
  final e = AfEffort.of(_effort);
  final bottom = MediaQuery.of(context).viewInsets.bottom;

  return PopScope(
    canPop: _pop == null && _modelOverlay == null,
    onPopInvokedWithResult: (didPop, _) {
      if (didPop) return;
      if (_modelOverlay != null) {
        _closeModelPop();
        return;
      }
      setState(() => _pop = null);
    },
    child: Padding(
      padding: EdgeInsets.only(bottom: bottom + 134),
      child: LayoutBuilder(builder: (_, box) => Stack(
        clipBehavior: Clip.none,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              if (_pop != null) setState(() => _pop = null);
            },
            child: Container(
              key: _cardKey,
              margin: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: const Color(AppColors.card),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0x24FFFFFF)),
            boxShadow: const [
              BoxShadow(color: Color(0xCC000000), blurRadius: 44, offset: Offset(0, 16)),
            ],
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            _row(
              key: 'mode',
              label: '模式',
              value: _kModeNames[_mode] ?? '聊天模式',
              extra: 52,
            ),
            _divider(),
            _row(
              key: 'model',
              label: '模型',
              value: afModelLabel(_model),
              extra: 104,
            ),
            _divider(),
            _row(
              key: 'effort',
              label: '推理等级',
              value: e.label,
              extra: 156,
              accent: true,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
              child: _EffortSlider(
                index: AfEffort.all.indexOf(e),
                onChanged: (i) {
                  setState(() => _effort = AfEffort.all[i].key);
                  widget.onEffort(AfEffort.all[i].key);
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Row(children: [
                Flexible(
                  child: Text(afModelLabel(_model),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.micro.copyWith(color: const Color(0x99FFFFFF))),
                ),
                const SizedBox(width: 7),
                Text('·',
                    style: AppType.micro.copyWith(color: const Color(AppColors.textTertiary))),
                const SizedBox(width: 7),
                Text(e.label,
                    style: AppType.micro.copyWith(
                        color: const Color(AppColors.accent),
                        fontWeight: FontWeight.w600,
                        letterSpacing: .6)),
                const Spacer(),
                Text('×${e.coef}',
                    style: AppType.micro.copyWith(color: const Color(AppColors.textTertiary))),
              ]),
            ),
            ]),
            ),
          ),
          if (_pop != null && _popAnchor != null) _popLayer(box.maxHeight),
        ],
      )),
    ),
  );
}

Widget _divider() => Container(
      height: 1,
      margin: const EdgeInsets.symmetric(horizontal: 14),
      color: const Color(0x14FFFFFF),
    );

/// 一行：左标签 / 右值 + 箭头
Widget _row({
  required String key,
  required String label,
  required String value,
  required double extra,
  bool accent = false,
}) {
  return InkWell(
    borderRadius: BorderRadius.circular(14),
    onTap: () {
      if (key == 'model') {
        _openModelPop();
        return;
      }
      setState(() {
        if (_pop == key) {
          _pop = null;
        } else {
          _pop = key;
          _popAnchor = Rect.fromLTWH(0, extra, 1, 1);
        }
      });
    },
    child: SizedBox(
      height: 52,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(children: [
          Text(label, style: AppType.body.copyWith(fontSize: 13)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: AppType.body.copyWith(
                    fontSize: 13,
                    color: accent ? const Color(AppColors.accent) : null,
                    fontWeight: accent ? FontWeight.w600 : FontWeight.w400,
                    letterSpacing: accent ? .6 : 0)),
          ),
          const SizedBox(width: 6),
          Text('›',
              style: AppType.micro.copyWith(
                  fontSize: 14, color: const Color(AppColors.textTertiary))),
        ]),
      ),
    ),
  );
}

/// 二级小浮层：贴着对应行弹出，不是大弹窗
Widget _popLayer(double cardH) {
  final items = switch (_pop) {
    'mode' => [
        ('chat', '聊天模式', '问一句答一句，轻快'),
        ('work', 'Agent 模式', '先拆步骤，再动手交付')
      ],
    _ => AfEffort.all
        .map((e) => (e.key, '${e.label}  ${e.cn}', '×${e.coef}'))
        .toList(),
  };
  final cur = _pop == 'mode' ? _mode : _effort;
  final anchorY = _popAnchor!.top;

  return Positioned(
    top: anchorY + 4,
    right: 18,
    child: TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 170),
      curve: Curves.easeOutCubic,
      builder: (_, v, child) => Transform.scale(
        scale: 0.92 + 0.08 * v,
        alignment: Alignment.topRight,
        child: Opacity(opacity: v, child: child),
      ),
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 178,
          padding: const EdgeInsets.all(5),
          decoration: BoxDecoration(
            color: const Color(0xFF1B1B1F),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0x29FFFFFF)),
            boxShadow: const [
              BoxShadow(color: Color(0xCC000000), blurRadius: 34, offset: Offset(0, 12)),
            ],
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (final it in items)
              InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () {
                  setState(() {
                    if (_pop == 'mode') {
                      _mode = it.$1;
                      widget.onMode(it.$1);
                    } else {
                      _effort = it.$1;
                      widget.onEffort(it.$1);
                    }
                    _pop = null;
                  });
                },
                child: SizedBox(
                  height: 44,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 11),
                    child: Row(children: [
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(it.$2,
                                style: AppType.micro.copyWith(
                                    fontSize: 12.5,
                                    color: it.$1 == cur
                                        ? const Color(AppColors.accent)
                                        : const Color(0xFFFFFFFF))),
                            if (it.$3.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Text(it.$3,
                                    style: AppType.micro.copyWith(
                                        fontSize: 10.5,
                                        color: const Color(AppColors.textTertiary))),
                              ),
                          ],
                        ),
                      ),
                      if (it.$1 == cur)
                        const Text('✓',
                            style: TextStyle(
                                fontSize: 13,
                                height: 1,
                                color: Color(AppColors.accent))),
                    ]),
                  ),
                ),
              ),
          ]),
        ),
      ),
    ),
  );
}

}

/// 模型浮层面板：一级 快速/强力 + 自建 API；二级 该 API 的模型 id + ＋添加 API
class _AfModelPopPanel extends StatefulWidget {
  const _AfModelPopPanel({
    required this.providers,
    required this.current,
    required this.onPick,
    required this.onAddApi,
    required this.onEditProvider,
    this.openApiId,
  });

  final List<AfProvider> providers;
  final String current;
  final String? openApiId;
  final ValueChanged<String> onPick;
  final Future<void> Function() onAddApi;
  final Future<void> Function(AfProvider) onEditProvider;

  @override
  State<_AfModelPopPanel> createState() => _AfModelPopPanelState();
}

class _AfModelPopPanelState extends State<_AfModelPopPanel> {
  String? _apiView;

  @override
  void initState() {
    super.initState();
    _apiView = widget.openApiId;
  }

  bool _inProvider(AfProvider p) {
    if (!widget.current.startsWith('p:')) return false;
    final parts = widget.current.split(':');
    return parts.length >= 3 && parts[1] == p.id;
  }

  @override
  Widget build(BuildContext context) =>
      _apiView == null ? _first() : _second();

  Widget _first() {
    return Column(mainAxisSize: MainAxisSize.min, children: [
      _tile(
        title: '快速',
        sub: '响应快，适合日常',
        selected: widget.current == 'deepseek-flash',
        onTap: () => widget.onPick('deepseek-flash'),
      ),
      _tile(
        title: '强力',
        sub: '更深的推理，适合硬任务',
        selected: widget.current == 'deepseek-v4-pro',
        onTap: () => widget.onPick('deepseek-v4-pro'),
      ),
      for (final p in widget.providers)
        _tile(
          title: p.name,
          sub: '${p.models.length} 个模型 · 自己的 Key',
          selected: _inProvider(p),
          trailingArrow: true,
          onTap: () => setState(() => _apiView = p.id),
        ),
      _addTile(),
    ]);
  }

  Widget _second() {
    AfProvider p;
    try {
      p = widget.providers.firstWhere((x) => x.id == _apiView);
    } catch (_) {
      p = AfProvider(id: _apiView ?? '', name: '', base: '', models: const []);
    }
    return Column(mainAxisSize: MainAxisSize.min, children: [
      InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => setState(() => _apiView = null),
        child: SizedBox(
          height: 38,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 9),
            child: Row(children: [
              const Text('‹',
                  style: TextStyle(fontSize: 16, color: Color(AppColors.textTertiary))),
              const SizedBox(width: 5),
              Expanded(
                child: Text(p.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.micro
                        .copyWith(fontSize: 12.5, fontWeight: FontWeight.w600)),
              ),
              InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: () => widget.onEditProvider(p),
                child: const Padding(
                  padding: EdgeInsets.fromLTRB(6, 4, 2, 4),
                  child: Icon(Icons.edit_outlined,
                      size: 14, color: Color(AppColors.textTertiary)),
                ),
              ),
              const SizedBox(width: 2),
              Text('${p.models.length}',
                  style: AppType.micro.copyWith(
                      fontSize: 10.5, color: const Color(AppColors.textTertiary))),
            ]),
          ),
        ),
      ),
      if (p.models.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Text('还没有模型',
              style: AppType.micro
                  .copyWith(fontSize: 10.5, color: const Color(AppColors.textTertiary))),
        ),
      for (final m in p.models.where((x) => x.enabled))
        _tile(
          title: m.model,
          sub: p.name,
          selected: widget.current == 'p:${p.id}:${m.model}',
          onTap: () => widget.onPick('p:${p.id}:${m.model}'),
        ),
      _addTile(),
    ]);
  }

  Widget _tile({
    required String title,
    required String sub,
    required bool selected,
    required VoidCallback onTap,
    bool trailingArrow = false,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: SizedBox(
        height: 46,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 11),
          child: Row(children: [
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.micro.copyWith(
                          fontSize: 12.5,
                          color: selected
                              ? const Color(AppColors.accent)
                              : const Color(0xFFFFFFFF))),
                  if (sub.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(sub,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppType.micro.copyWith(
                              fontSize: 10.5, color: const Color(AppColors.textTertiary))),
                    ),
                ],
              ),
            ),
            if (selected)
              const Text('✓',
                  style: TextStyle(fontSize: 13, height: 1, color: Color(AppColors.accent)))
            else if (trailingArrow)
              const Text('›',
                  style: TextStyle(fontSize: 13, height: 1, color: Color(AppColors.textTertiary))),
          ]),
        ),
      ),
    );
  }

  Widget _addTile() => InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => widget.onAddApi(),
        child: SizedBox(
          height: 44,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 11),
            child: Row(children: [
              const Text('＋',
                  style: TextStyle(
                      fontSize: 13,
                      height: 1,
                      fontWeight: FontWeight.w500,
                      color: Color(AppColors.accent))),
              const SizedBox(width: 6),
              Text('添加 API',
                  style: AppType.micro.copyWith(
                      fontSize: 12.5,
                      color: const Color(AppColors.accent),
                      fontWeight: FontWeight.w500)),
            ]),
          ),
        ),
      );
}

/// 五档吸附滑块：圆角方块钮 + 青色发光填充 + 白点从右往左流（左端渐隐）
class _EffortSlider extends StatefulWidget {
  const _EffortSlider({required this.index, required this.onChanged});

  final int index;
  final ValueChanged<int> onChanged;

  @override
  State<_EffortSlider> createState() => _EffortSliderState();
}

class _EffortSliderState extends State<_EffortSlider>
    with TickerProviderStateMixin {
  static const double _knobSize = 34;
  static const double _trackH = 34;

  double _pos = .5;          // 0..1
  bool _dragging = false;
  late final AnimationController _dots = AnimationController(vsync: this, duration: _dur);
  late final AnimationController _snap = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 300));
  double _snapFrom = .5, _snapTo = .5;
  double _width = 300;

  Duration get _dur => Duration(
      milliseconds: (AfEffort.all[widget.index].speed * 1000).round());

  @override
  void initState() {
    super.initState();
    _pos = widget.index / 4;
    _dots.repeat();
    _snap.addListener(() {
      final t = Curves.easeOutBack.transform(_snap.value.clamp(0.0, 1.0));
      setState(() => _pos = _snapFrom + (_snapTo - _snapFrom) * t.clamp(0.0, 1.0));
    });
  }

  @override
  void didUpdateWidget(covariant _EffortSlider old) {
    super.didUpdateWidget(old);
    if (old.index != widget.index) {
      _dots.duration = _dur;
      _dots.repeat();
      if (!_dragging) {
        _snapFrom = _pos;
        _snapTo = widget.index / 4;
        _snap.forward(from: 0);
      }
    }
  }

  @override
  void dispose() {
    _dots.dispose();
    _snap.dispose();
    super.dispose();
  }

  int _idxAt(double pos) => (pos * 4).round().clamp(0, 4);

  void _onDrag(double dx) {
    final w = _width - _knobSize;
    if (w <= 0) return;
    setState(() => _pos = (_pos + dx / w).clamp(0.0, 1.0));
    final i = _idxAt(_pos);
    if (i != widget.index) widget.onChanged(i);
  }

  void _settle() {
    _dragging = false;
    _snapFrom = _pos;
    _snapTo = _idxAt(_pos) / 4;
    _snap.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (_, box) {
      _width = box.maxWidth;
      final w = _width - _knobSize;
      final fillW = _knobSize + w * _pos;
      final hot = widget.index >= 3;

      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (_) {
          _snap.stop();
          setState(() => _dragging = true);
        },
        onHorizontalDragUpdate: (d) => _onDrag(d.delta.dx),
        onHorizontalDragEnd: (_) => _settle(),
        onHorizontalDragCancel: _settle,
        onTapDown: (d) {
          final x = (d.localPosition.dx - _knobSize / 2).clamp(0.0, w);
          setState(() => _pos = w <= 0 ? 0 : x / w);
          widget.onChanged(_idxAt(_pos));
          _settle();
        },
        child: SizedBox(
          height: _trackH + 6,
          child: Stack(clipBehavior: Clip.none, children: [
            // 轨道 + 填充 + 白点
            Positioned(
              left: 0,
              right: 0,
              top: 3,
              height: _trackH,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(_trackH / 2),
                child: Stack(children: [
                  Container(color: const Color(0xFF1A1A1D)),
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    width: fillW,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(_trackH / 2),
                        gradient: LinearGradient(colors: hot
                            ? [const Color(0xFF45E0AE).withValues(alpha: .55),
                               const Color(0xFF45E0AE)]
                            : [const Color(0xFF45E0AE).withValues(alpha: .30 + .06 * widget.index),
                               const Color(0xFF45E0AE).withValues(alpha: .66 + .05 * widget.index)]),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFF45E0AE)
                                .withValues(alpha: hot ? .35 : .12),
                            blurRadius: hot ? 16 : 8,
                          ),
                        ],
                      ),
                      child: AnimatedBuilder(
                        animation: _dots,
                        builder: (_, _) => CustomPaint(
                          painter: _DotsPainter(
                            t: _dots.value,
                            level: widget.index,
                            loop: fillW + 70,
                          ),
                        ),
                      ),
                    ),
                  ),
                  // 刻度点
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _TicksPainter(pos: _pos, color: const Color(0x57FFFFFF)),
                    ),
                  ),
                ]),
              ),
            ),
            // 圆钮（圆角正方形）
            Positioned(
              left: w * _pos,
              top: 3,
              child: GestureDetector(
                onHorizontalDragStart: (_) {
                  _snap.stop();
                  setState(() => _dragging = true);
                },
                onHorizontalDragUpdate: (d) => _onDrag(d.delta.dx),
                onHorizontalDragEnd: (_) => _settle(),
                child: AnimatedScale(
                  scale: _dragging ? 1.06 : 1,
                  duration: const Duration(milliseconds: 140),
                  child: Container(
                    width: _knobSize,
                    height: _knobSize,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(10),
                      boxShadow: const [
                        BoxShadow(color: Color(0x73000000), blurRadius: 10, offset: Offset(0, 3)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ]),
        ),
      );
    });
  }
}

/// 轨道里的白点：从右往左匀速流，左端渐隐（alpha 随 x 递增）
class _DotsPainter extends CustomPainter {
  _DotsPainter({required this.t, required this.level, required this.loop});

  final double t;      // 0..1 循环
  final int level;     // 0..4
  final double loop;   // 循环距离（px）

  static final List<Offset> _seeds = List.generate(12, (i) {
    final r = math.Random(i * 977 + 13);
    return Offset(i * 34 + r.nextDouble() * 22, 0.34 + r.nextDouble() * 0.32);
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..style = PaintingStyle.fill;
    final baseAlpha = 0.78 + level * 0.055;

    for (final s in _seeds) {
      final span = loop + 40;
      var x = (s.dx - t * span) % span;
      if (x < 0) x += span;
      x -= 20;
      if (x > size.width) continue;

      // 左端渐隐：x=0 全透明，靠右逐渐到 1
      final fade = (x / math.max(size.width, 1)).clamp(0.0, 1.0);
      final a = baseAlpha * (fade * fade * 0.95 + 0.03);
      if (a <= 0.02) continue;

      final y = s.dy * size.height;
      final r = 1.5 + (s.dx % 3) * 0.28;
      paint.color = Colors.white.withValues(alpha: a.clamp(0.0, 1.0));
      canvas.drawCircle(Offset(x, y), r, paint);

      paint.color = const Color(0xFF45E0AE).withValues(alpha: a * 0.35);
      canvas.drawCircle(Offset(x, y), r * 2.4, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _DotsPainter old) =>
      old.t != t || old.level != level || old.loop != loop;
}

/// 五档刻度：淡点，当前档位点亮
class _TicksPainter extends CustomPainter {
  _TicksPainter({required this.pos, required this.color});

  final double pos;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..style = PaintingStyle.fill;
    final active = (pos * 4).round();
    for (int i = 0; i < 5; i++) {
      final x = 17 + (size.width - 34) * (i / 4);
      final on = i == active;
      paint.color = on
          ? const Color(0xFF45E0AE).withValues(alpha: .85)
          : color.withValues(alpha: .34);
      canvas.drawCircle(Offset(x, size.height / 2), on ? 3.2 : 1.6, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _TicksPainter old) => old.pos != pos;
}
