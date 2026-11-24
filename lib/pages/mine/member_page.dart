/// 会员开通 · 会员中心
///
/// 设计规则（V4）：
/// - 黑底 + 薄荷单色，层级只靠留白与白色透明度，不再堆叠渐变光斑；
/// - 一屏三段：身份卡 → 档位 + 时长（同一区块选完）→ 权益对照；
/// - 金额只露一次主数字，其余全部降为脚注；
/// - 底部结算条常驻，弹层里完成「支付方式 + 凭证 + 联系方式」，凭证支持图片/PDF。
library;

import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../api/client.dart';
import '../../services/secure_screen.dart';
import '../../services/secure_links.dart';
import '../../services/user_data_bus.dart';
import '../../design/components.dart';
import '../../design/system.dart';

const _mint = Color(AppColors.accent);
const _mintDim = Color(0x3345E0AE);
const _surface = Color(0xFF0A0B0B);
const _surface2 = Color(0xFF101112);

class MemberPage extends StatefulWidget {
  const MemberPage({super.key, this.seed});

  /// 调试/预览用：直接注入 {plans, me}，跳过网络请求。
  final Map<String, dynamic>? seed;

  @override
  State<MemberPage> createState() => _MemberPageState();
}

class _MemberPageState extends State<MemberPage>
    with SecureScreenMixin<MemberPage> {
  bool _loading = true;
  String? _error;

  List<Map<String, dynamic>> _plans = [];
  Map<String, dynamic> _me = {};

  /// 当前档位：svip / member
  String _tier = 'svip';

  /// 当前时长（天）
  int _days = 365;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    if (widget.seed != null) {
      _applyPayload(widget.seed!);
      return;
    }
    try {
      final j = await ApiClient.memberPlans();
      _applyPayload(j);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e is ApiException ? e.message : '加载失败，请稍后重试';
      });
    }
  }

  void _applyPayload(Map<String, dynamic> j) {
    final list = (j['plans'] as List? ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final me = Map<String, dynamic>.from((j['me'] as Map?) ?? const {});
    if (!mounted) return;
    setState(() {
      _plans = list;
      _me = me;
      _loading = false;
      if (_isVip && !_isSvip) _tier = 'svip';
      final days = _daysOf(_tier);
      if (days.isNotEmpty) _days = days.last;
    });
  }

  // ---------- 数据 ----------

  String get _level => (_me['level'] ?? '') as String;

  bool get _isSvip => _level == 'svip';

  bool get _isVip => _level == 'member';

  bool get _isMember => _isSvip || _isVip;

  String get _label => (_me['label'] ?? '') as String;

  int get _daysLeft => ((_me['daysLeft'] ?? 0) as num).toInt();

  int get _expire => ((_me['expire'] ?? 0) as num).toInt();

  bool get _expiring => (_me['expiring'] ?? false) as bool;

  List<int> _daysOf(String level) =>
      _plans
          .where((p) => p['level'] == level)
          .map((p) => ((p['days'] ?? 0) as num).toInt())
          .toList()
        ..sort();

  Map<String, dynamic>? _planOf(String level, int days) {
    for (final p in _plans) {
      if (p['level'] == level && ((p['days'] ?? 0) as num).toInt() == days) {
        return p;
      }
    }
    return null;
  }

  Map<String, dynamic>? get _plan => _planOf(_tier, _days);

  int _priceOf(String level, int days) {
    final p = _planOf(level, days);
    return p == null ? 0 : ((p['price'] ?? 0) as num).toInt();
  }

  String _yuan(int fen) {
    if (fen <= 0) return '—';
    final y = fen / 100;
    return y == y.roundToDouble() ? y.toStringAsFixed(0) : y.toStringAsFixed(1);
  }

  /// 档位按钮的「¥x 起」由后台套餐实时算出，不再写死。
  String _tierHint(String level) {
    final prices = _plans
        .where((p) => p['level'] == level)
        .map((p) => ((p['price'] ?? 0) as num).toInt())
        .where((p) => p > 0)
        .toList();
    if (prices.isEmpty) return '未配置';
    final min = prices.reduce((a, b) => a < b ? a : b);
    return '¥${_yuan(min)} 起';
  }

  /// 展示后台配置的套餐名（如「VIP · 月卡」取「月卡」），不再按月/季/年写死。
  String _planNameOf(int days) {
    final p = _planOf(_tier, days);
    final raw = (p?['name'] ?? '').toString().trim();
    if (raw.isNotEmpty) {
      final parts = raw.split('·');
      final tail = parts.last.trim();
      return tail.isEmpty ? raw : tail;
    }
    return '$days 天';
  }

  /// 单价最低的套餐打「最划算」，不依赖天数阈值。
  String _planTag(int days, int save) {
    final list = _daysOf(_tier);
    if (list.length < 2) return '';
    int best = list.first;
    double bestUnit = double.infinity;
    for (final d in list) {
      final price = _priceOf(_tier, d);
      if (price <= 0 || d <= 0) continue;
      final unit = price / d;
      if (unit < bestUnit) {
        bestUnit = unit;
        best = d;
      }
    }
    if (days == best) return '最划算';
    return save > 0 ? '省 $save%' : '';
  }

  int _saveOf(String level, int days) {
    final base = _daysOf(level).first;
    if (days <= base) return 0;
    final unitNow = _priceOf(level, days) / days;
    final unitBase = _priceOf(level, base) / base;
    if (unitBase <= 0) return 0;
    final save = (1 - unitNow / unitBase) * 100;
    return save >= 5 ? save.round() : 0;
  }

  double _perMonth(String level, int days) {
    final p = _priceOf(level, days);
    if (p <= 0 || days <= 0) return 0;
    return (p / 100) / (days / 30);
  }

  String _expireText() {
    if (_expire <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(_expire * 1000);
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  String get _tierName => _tier == 'svip' ? 'SVIP' : 'VIP';

  String get _ctaLabel {
    if (_isSvip) return '续费 SVIP';
    if (_isVip) return _tier == 'svip' ? '升级 SVIP' : '续费 VIP';
    return '立即开通 $_tierName';
  }

  // ---------- 交互 ----------

  Future<void> _redeemSheet() async {
    if (ApiClient.token == null || ApiClient.token!.isEmpty) {
      _toast('登录后才能兑换');
      return;
    }
    final ctrl = TextEditingController();
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _SheetShell(
        title: '兑换码开通',
        subtitle: '同档续期会叠加在到期时间之后',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: ctrl,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 18,
                letterSpacing: 2,
                fontWeight: FontWeight.w700,
              ),
              decoration: const InputDecoration(
                hintText: 'LYVP-XXXX-XXXX-XXXX',
              ),
            ),
            const SizedBox(height: 18),
            PillButton(
              label: '立即兑换',
              size: PillSize.lg,
              expand: true,
              glow: true,
              onTap: () => Navigator.pop(ctx, true),
            ),
            SizedBox(height: MediaQuery.viewInsetsOf(ctx).bottom),
          ],
        ),
      ),
    );
    final code = ctrl.text.trim();
    if (ok != true || code.isEmpty) return;
    try {
      final j = await ApiClient.memberRedeem(code);
      final lv = (j['level'] ?? '') as String;
      final days = ((j['days'] ?? 0) as num).toInt();
      _toast('兑换成功：${lv == 'svip' ? 'SVIP' : 'VIP'} · $days 天');
      await _load();
      UserDataBus.touch();
    } on ApiException catch (e) {
      _toast(e.message);
    } catch (_) {
      _toast('兑换失败，请稍后重试');
    }
  }

  Future<void> _applySheet() async {
    if (ApiClient.token == null || ApiClient.token!.isEmpty) {
      _toast('登录后才能开通');
      return;
    }
    final plan = _plan;
    if (plan == null) {
      _toast('套餐未配置，请联系管理员');
      return;
    }
    final price = ((plan['price'] ?? 0) as num).toInt();
    final pay = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _PaySheet(
        planId: (plan['id'] ?? '') as String,
        tier: _tierName,
        days: _days,
        priceText: '¥${_yuan(price)}',
        planName: (plan['name'] ?? '') as String,
        priceFen: price,
      ),
    );
    if (pay == null || !mounted) return;
    if (pay['paid'] == true) {
      _toast('支付成功，会员已开通');
      await _load();
      UserDataBus.touch();
      return;
    }
    if (pay['manual'] == true) {
      await _manualApply(plan);
    }
  }

  /// 易支付不可用时的兜底：上传凭证，管理员人工开通。
  Future<void> _manualApply(Map<String, dynamic> plan) async {
    final price = ((plan['price'] ?? 0) as num).toInt();
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _ApplySheet(
        tier: _tierName,
        days: _days,
        priceText: '¥${_yuan(price)}',
        planName: (plan['name'] ?? '') as String,
      ),
    );
    if (result == null || !mounted) return;
    try {
      await ApiClient.memberApply(
        planId: (plan['id'] ?? '') as String,
        contact: (result['contact'] ?? '') as String,
        note: (result['note'] ?? '') as String,
        proof: (result['proof'] ?? '') as String,
      );
      _toast('申请已提交，管理员核验凭证后立即生效');
    } on ApiException catch (e) {
      _toast(e.message);
    } catch (_) {
      _toast('提交失败，请稍后重试');
    }
  }

  Future<void> _ordersSheet() async {
    if (ApiClient.token == null || ApiClient.token!.isEmpty) {
      _toast('登录后才能查看');
      return;
    }
    List<Map<String, dynamic>> list;
    try {
      final j = await ApiClient.memberOrders();
      list = (j['list'] as List? ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } catch (e) {
      _toast(e is ApiException ? e.message : '加载失败');
      return;
    }
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _SheetShell(
        title: '开通记录',
        subtitle: '兑换码、申请与后台发放都会留痕',
        child: list.isEmpty
            ? const Padding(
                padding: EdgeInsets.symmetric(vertical: 28),
                child: Center(
                  child: Text(
                    '还没有开通记录',
                    style: TextStyle(
                      fontSize: 12,
                      color: Color(AppColors.textTertiary),
                    ),
                  ),
                ),
              )
            : ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(ctx).height * .54,
                ),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: list.length,
                  separatorBuilder: (_, _) => const Hairline(),
                  itemBuilder: (_, i) {
                    final o = list[i];
                    final st = ((o['status'] ?? 0) as num).toInt();
                    final ch = '${o['channel'] ?? ''}';
                    final isEpay = ch.startsWith('epay');
                    final stText = st == 1
                        ? '已生效'
                        : (st == 0 ? (isEpay ? '待支付' : '审核中') : '已拒绝');
                    final chText = ch == 'code'
                        ? '兑换码'
                        : (ch == 'apply'
                              ? '申请开通'
                              : (ch.endsWith('alipay')
                                    ? '支付宝支付'
                                    : (isEpay ? '微信支付' : '后台发放')));
                    final color = st == 1
                        ? _mint
                        : (st == 0
                              ? const Color(AppColors.warning)
                              : const Color(AppColors.textTertiary));
                    final created = ((o['created'] ?? 0) as num).toInt();
                    final dt = DateTime.fromMillisecondsSinceEpoch(
                      created * 1000,
                    );
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Row(
                        children: [
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${o['label'] ?? ''} · ${o['days'] ?? 0} 天',
                                style: const TextStyle(
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} · $chText',
                                style: const TextStyle(
                                  fontSize: 10.5,
                                  color: Color(AppColors.textTertiary),
                                ),
                              ),
                            ],
                          ),
                          const Spacer(),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: color.withValues(alpha: .10),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              stText,
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w600,
                                color: color,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
      ),
    );
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  // ---------- 构建 ----------

  @override
  Widget build(BuildContext context) {
    return ImmersivePage(
      child: Column(
        children: [
          GlassTopBar(
            title: '会员中心',
            subtitle: '独立于音乐会员',
            actions: [
              PressableScale(
                onTap: _ordersSheet,
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  child: Text(
                    '开通记录',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: Color(AppColors.textTertiary),
                    ),
                  ),
                ),
              ),
            ],
          ),
          Expanded(
            child: _loading
                ? const Center(
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : _error != null
                ? ErrorState(message: _error!, onRetry: _load)
                : ListView(
                    padding: const EdgeInsets.fromLTRB(20, 6, 20, 18),
                    children: [
                      _identityCard(),
                      const SizedBox(height: 20),
                      _tierSwitch(),
                      const SizedBox(height: 10),
                      _planCards(),
                      const SizedBox(height: 22),
                      _benefitsCard(),
                      const SizedBox(height: 16),
                      _finePrint(),
                      const SizedBox(height: 18),
                      _faqCard(),
                    ],
                  ),
          ),
          _footer(),
        ],
      ),
    );
  }

  // ---------- 身份卡 ----------

  Widget _identityCard() {
    return Container(
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0x12FFFFFF)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Stack(
          children: [
            Positioned(
              top: -70,
              right: -60,
              child: IgnorePointer(
                child: Container(
                  width: 200,
                  height: 200,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        _mint.withValues(alpha: .10),
                        Colors.transparent,
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(5),
                          border: Border.all(color: _mintDim),
                        ),
                        child: const Text(
                          'MEMBER',
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.6,
                            color: _mint,
                          ),
                        ),
                      ),
                      const Spacer(),
                      if (_isMember)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: _statusDot(
                            _expiring ? '即将到期' : '生效中',
                            color: _expiring
                                ? const Color(AppColors.warning)
                                : _mint,
                          ),
                        ),
                      Text(
                        _isMember ? _label : '未开通',
                        style: const TextStyle(
                          fontSize: 10.5,
                          color: Color(AppColors.textTertiary),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  if (!_isMember) ...[
                    const Text(
                      '把身份，亮出来。',
                      style: TextStyle(
                        fontSize: 27,
                        height: 1.12,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -1.0,
                        color: Color(AppColors.textPrimary),
                      ),
                    ),
                    const SizedBox(height: 7),
                    const Text(
                      '头像框 · 专属表情 · 昵称高亮 · Agent 赠送额度',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: Color(AppColors.textTertiary),
                      ),
                    ),
                  ] else ...[
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          '$_daysLeft',
                          style: const TextStyle(
                            fontSize: 38,
                            height: 1,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -1.4,
                            color: Color(AppColors.textPrimary),
                          ),
                        ),
                        const SizedBox(width: 5),
                        const Padding(
                          padding: EdgeInsets.only(bottom: 3),
                          child: Text(
                            '天',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Color(AppColors.textSecondary),
                            ),
                          ),
                        ),
                        const Spacer(),
                        Expanded(
                          flex: 3,
                          child: Padding(
                            padding: const EdgeInsets.only(bottom: 3),
                            child: Text(
                              '${_expireText()} 到期',
                              maxLines: 1,
                              textAlign: TextAlign.right,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 10,
                                color: _expiring
                                    ? const Color(AppColors.warning)
                                    : const Color(AppColors.textTertiary),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: (_daysLeft / 365.0).clamp(0.0, 1.0),
                        minHeight: 3,
                        backgroundColor: const Color(0x14FFFFFF),
                        valueColor: AlwaysStoppedAnimation(
                          _expiring ? const Color(AppColors.warning) : _mint,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusDot(String text, {required Color color}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 5,
          height: 5,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(
          text,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            color: color,
          ),
        ),
      ],
    );
  }

  // ---------- 档位 ----------

  Widget _tierSwitch() {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: const Color(0xFF080909),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0x0FFFFFFF)),
      ),
      child: Row(
        children: [
          Expanded(
            child: _tierTab('svip', 'SVIP', _tierHint('svip'), badge: '推荐'),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: _tierTab(
              'member',
              'VIP',
              _tierHint('member'),
              enabled: !_isSvip,
            ),
          ),
        ],
      ),
    );
  }

  Widget _tierTab(
    String level,
    String name,
    String hint, {
    bool enabled = true,
    String? badge,
  }) {
    final selected = _tier == level;
    return PressableScale(
      onTap: enabled
          ? () {
              HapticFeedback.selectionClick();
              setState(() {
                _tier = level;
                final days = _daysOf(level);
                if (!days.contains(_days)) {
                  _days = days.isEmpty ? 30 : days.last;
                }
              });
            }
          : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        height: 46,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: selected ? _mint.withValues(alpha: .10) : Colors.transparent,
          border: Border.all(
            color: selected ? _mint.withValues(alpha: .55) : Colors.transparent,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              name,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                letterSpacing: .3,
                color: !enabled
                    ? const Color(AppColors.textDisabled)
                    : (selected ? _mint : const Color(AppColors.textPrimary)),
              ),
            ),
            if (badge != null) ...[
              const SizedBox(width: 5),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 4,
                  vertical: 1.5,
                ),
                decoration: BoxDecoration(
                  color: _mint.withValues(alpha: selected ? .18 : .08),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  badge,
                  style: TextStyle(
                    fontSize: 8.5,
                    fontWeight: FontWeight.w700,
                    color: _mint.withValues(alpha: enabled ? 1 : .4),
                  ),
                ),
              ),
            ],
            const SizedBox(width: 7),
            Text(
              enabled ? hint : '已含',
              style: TextStyle(
                fontSize: 9.5,
                color: enabled
                    ? const Color(AppColors.textTertiary)
                    : const Color(AppColors.textDisabled),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _planCards() {
    final days = _daysOf(_tier);
    if (days.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Text(
          '套餐未配置',
          style: TextStyle(fontSize: 12, color: Color(AppColors.textTertiary)),
        ),
      );
    }
    final row = days.length <= 3
        ? Row(
            children: [
              for (var i = 0; i < days.length; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                Expanded(child: _planCard(days[i])),
              ],
            ],
          )
        : SizedBox(
            height: 128,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.zero,
              itemCount: days.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (_, i) =>
                  SizedBox(width: 116, child: _planCard(days[i])),
            ),
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text(
              '选择套餐',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: Color(AppColors.textPrimary),
              ),
            ),
            const Spacer(),
            const Text(
              '名称 / 天数 / 价格由后台配置',
              style: TextStyle(
                fontSize: 9.5,
                color: Color(AppColors.textTertiary),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        row,
      ],
    );
  }

  Widget _planCard(int d) {
    final selected = _days == d;
    final price = _priceOf(_tier, d);
    final save = _saveOf(_tier, d);
    final perMonth = _perMonth(_tier, d);
    final tag = _planTag(d, save);
    return PressableScale(
      onTap: () {
        HapticFeedback.selectionClick();
        setState(() => _days = d);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        height: 128,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: selected
              ? _mint.withValues(alpha: .07)
              : const Color(0xFF080909),
          border: Border.all(
            color: selected
                ? _mint.withValues(alpha: .60)
                : const Color(0x0DFFFFFF),
          ),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: _mint.withValues(alpha: .10),
                    blurRadius: 18,
                    offset: const Offset(0, 6),
                  ),
                ]
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  _planNameOf(d),
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: selected
                        ? _mint
                        : const Color(AppColors.textSecondary),
                  ),
                ),
                const Spacer(),
                if (tag.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 1.5,
                    ),
                    decoration: BoxDecoration(
                      color: _mint.withValues(alpha: .12),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      tag,
                      style: const TextStyle(
                        fontSize: 8.5,
                        fontWeight: FontWeight.w700,
                        color: _mint,
                      ),
                    ),
                  ),
              ],
            ),
            const Spacer(),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                const Text(
                  '¥',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: _mint,
                  ),
                ),
                const SizedBox(width: 2),
                Text(
                  _yuan(price),
                  style: const TextStyle(
                    fontSize: 30,
                    height: 1,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -1.4,
                    color: Color(AppColors.textPrimary),
                  ),
                ),
                const SizedBox(width: 2),
                const Text(
                  '元',
                  style: TextStyle(
                    fontSize: 9,
                    color: Color(AppColors.textTertiary),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '$d 天 · ¥${perMonth.toStringAsFixed(1)}/月',
              style: const TextStyle(
                fontSize: 9,
                color: Color(AppColors.textTertiary),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------- 权益 ----------

  Widget _benefitsCard() {
    final svip = _tier == 'svip';
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0x0FFFFFFF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                '会员权益',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: .3,
                ),
              ),
              const Spacer(),
              Text(
                svip ? '当前选择 SVIP' : '当前选择 VIP',
                style: const TextStyle(
                  fontSize: 9.5,
                  color: Color(AppColors.textTertiary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            svip ? 'SVIP 包含 VIP 全部权益，会员期内持续有效' : '开通后立即生效，会员期内持续有效',
            style: const TextStyle(
              fontSize: 10,
              height: 1.5,
              color: Color(AppColors.textTertiary),
            ),
          ),
          const SizedBox(height: 9),
          Row(
            children: [
              const SizedBox(width: 112),
              Expanded(
                child: Center(
                  child: Text(
                    'VIP',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: svip ? const Color(AppColors.textTertiary) : _mint,
                    ),
                  ),
                ),
              ),
              Expanded(
                child: Center(
                  child: Text(
                    'SVIP',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: svip ? _mint : const Color(AppColors.textTertiary),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          _benefitRow(Icons.account_box_outlined, '头像框', '7 款', '12 款', svip),
          _benefitRow(
            Icons.emoji_emotions_outlined,
            '表情收藏',
            '2000',
            '5000',
            svip,
          ),
          _benefitRow(Icons.badge_outlined, '昵称标识', '普通', '薄荷高亮', svip),
          _benefitRow(Icons.cloud_outlined, 'Agent 云沙箱', '可用', '可用', svip),
          _benefitRow(
            Icons.auto_awesome_outlined,
            'Agent 额度',
            '100 万 token',
            '300 万 token',
            svip,
            last: true,
          ),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(10, 9, 10, 10),
            decoration: BoxDecoration(
              color: _mint.withValues(alpha: .045),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: _mint.withValues(alpha: .14)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  svip ? '开通 SVIP 后可以做什么' : '开通 VIP 后可以做什么',
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    color: _mint,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  svip
                      ? '• 社区：SVIP 标识、可用 12 款头像框、5000 个表情收藏、昵称高亮\n'
                            '• AI Agent：赠送 300 万 token，聊天模式和 Agent 模式都可使用，可开云沙箱做完整任务\n'
                            '• 会员期内持续有效，到期自动收回'
                      : '• 社区：VIP 标识、可用 7 款头像框、2000 个表情收藏、昵称高亮\n'
                            '• AI Agent：赠送 100 万 token，聊天模式和 Agent 模式都可使用，可开云沙箱做完整任务\n'
                            '• 会员期内持续有效，到期自动收回',
                  style: const TextStyle(
                    fontSize: 10,
                    height: 1.75,
                    color: Color(AppColors.textSecondary),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _benefitRow(
    IconData icon,
    String name,
    String vipV,
    String svipV,
    bool highlightSvip, {
    bool last = false,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        border: last
            ? null
            : const Border(bottom: BorderSide(color: Color(0x08FFFFFF))),
      ),
      child: Row(
        children: [
          Icon(icon, size: 13, color: const Color(AppColors.textTertiary)),
          const SizedBox(width: 7),
          SizedBox(
            width: 92,
            child: Text(
              name,
              style: const TextStyle(
                fontSize: 11.5,
                color: Color(AppColors.textSecondary),
              ),
            ),
          ),
          Expanded(
            child: Center(
              child: Text(
                vipV,
                style: TextStyle(
                  fontSize: 11,
                  color: highlightSvip
                      ? const Color(AppColors.textTertiary)
                      : const Color(AppColors.textPrimary),
                ),
              ),
            ),
          ),
          Expanded(
            child: Center(
              child: Text(
                svipV,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: highlightSvip ? FontWeight.w700 : FontWeight.w500,
                  color: highlightSvip
                      ? _mint
                      : const Color(AppColors.textTertiary),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------- 脚注 ----------

  Widget _finePrint() {
    final lines = _isSvip
        ? ['续费天数叠加在到期时间之后，不影响剩余天数。', 'SVIP 已含 VIP 全部权益；到期后权益自动收回。']
        : _isVip
        ? ['升级后剩余 $_daysLeft 天按 1:1 顺延，不会清零。', '虚拟服务一经开通不支持退款；兑换码可在「开通记录」查。']
        : ['会员到期后权益自动收回，已发布内容与数据不受影响。', '虚拟服务不支持退款；开通记录随时可查。'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final l in lines)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 3,
                  height: 3,
                  margin: const EdgeInsets.only(top: 6, right: 7),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: .20),
                    shape: BoxShape.circle,
                  ),
                ),
                Expanded(
                  child: Text(
                    l,
                    style: const TextStyle(
                      fontSize: 10,
                      height: 1.5,
                      color: Color(AppColors.textTertiary),
                    ),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 2),
        PressableScale(
          onTap: _redeemSheet,
          child: Row(
            children: [
              const Text(
                '已有兑换码？',
                style: TextStyle(
                  fontSize: 10.5,
                  color: Color(AppColors.textTertiary),
                ),
              ),
              const SizedBox(width: 4),
              Text(
                '去兑换',
                style: TextStyle(
                  fontSize: 10.5,
                  color: _mint,
                  decoration: TextDecoration.underline,
                  decorationColor: _mint.withValues(alpha: .5),
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                size: 12,
                color: _mint.withValues(alpha: .8),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _faqCard() {
    const items = [
      ('支付后多久生效？', '在线支付成功后自动开通，通常几秒内；改用凭证人工开通的，管理员核验后 10 分钟内生效。'),
      ('会自动续费吗？', '不会。到期自动收回权益，需要手动再开通。'),
      ('换手机还生效吗？', '会员绑定账号，同一账号换设备登录即可继续使用。'),
    ];
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0x0FFFFFFF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '常见问题',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: .3,
            ),
          ),
          for (var i = 0; i < items.length; i++) ...[
            Padding(
              padding: const EdgeInsets.only(top: 10, bottom: 2),
              child: Text(
                items[i].$1,
                style: const TextStyle(
                  fontSize: 11.5,
                  color: Color(AppColors.textSecondary),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                items[i].$2,
                style: const TextStyle(
                  fontSize: 10,
                  height: 1.5,
                  color: Color(AppColors.textTertiary),
                ),
              ),
            ),
            if (i != items.length - 1) const Hairline(),
          ],
        ],
      ),
    );
  }

  // ---------- 结算条 ----------

  Widget _footer() {
    final plan = _plan;
    final price = plan == null ? 0 : ((plan['price'] ?? 0) as num).toInt();
    return Container(
      padding: EdgeInsets.fromLTRB(
        20,
        12,
        20,
        12 + MediaQuery.paddingOf(context).bottom,
      ),
      decoration: const BoxDecoration(
        color: Color(AppColors.bg),
        border: Border(top: BorderSide(color: Color(0x0DFFFFFF))),
      ),
      child: Row(
        children: [
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${_tier == 'svip' ? 'SVIP' : 'VIP'} · ${_planNameOf(_days)}',
                style: const TextStyle(
                  fontSize: 9,
                  color: Color(AppColors.textTertiary),
                ),
              ),
              const SizedBox(height: 2),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  const Text(
                    '¥',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: _mint,
                    ),
                  ),
                  const SizedBox(width: 2),
                  Text(
                    _yuan(price),
                    style: const TextStyle(
                      fontSize: 26,
                      height: 1,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -1.0,
                      color: Color(AppColors.textPrimary),
                    ),
                  ),
                  const SizedBox(width: 3),
                  Text(
                    '/${_planNameOf(_days)}',
                    style: const TextStyle(
                      fontSize: 9.5,
                      color: Color(AppColors.textTertiary),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(width: 14),
          Expanded(
            child: SizedBox(
              height: 50,
              child: PillButton(
                label: _ctaLabel,
                size: PillSize.lg,
                expand: true,
                glow: true,
                onTap: _loading || _error != null ? null : _applySheet,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// =====================================================================
// 底部弹层外壳 & 开通申请表
// =====================================================================

class _SheetShell extends StatelessWidget {
  const _SheetShell({
    required this.title,
    required this.child,
    this.subtitle = '',
  });

  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 34,
                  height: 4,
                  decoration: BoxDecoration(
                    color: const Color(0x26FFFFFF),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (subtitle.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontSize: 10.5,
                    color: Color(AppColors.textTertiary),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              child,
            ],
          ),
        ),
      ),
    );
  }
}

class _PaySheet extends StatefulWidget {
  const _PaySheet({
    required this.planId,
    required this.tier,
    required this.days,
    required this.priceText,
    required this.planName,
    required this.priceFen,
  });

  final String planId;
  final String tier;
  final int days;
  final String priceText;
  final String planName;
  final int priceFen;

  @override
  State<_PaySheet> createState() => _PaySheetState();
}

class _PaySheetState extends State<_PaySheet> {
  String _channel = 'wxpay';
  bool _busy = false;
  bool _finishing = false;
  String? _error;
  String? _orderId;
  String? _payUrl;
  String _payType = '';
  String? _payQr;
  Timer? _poll;
  int _tries = 0;

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  void _snack(String m) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _payNow() async {
    if (_busy || _finishing) return;
    if (_payQr != null) {
      // 二维码已经展示，按钮只负责提示扫码，不重复下单。
      _snack('请使用微信/支付宝扫一扫上方二维码完成支付');
      return;
    }
    if (_payUrl != null && _payUrl!.isNotEmpty) {
      await _open(_payUrl!, payType: _payType);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final j = await ApiClient.memberPayCreate(
        planId: widget.planId,
        channel: _channel,
      );
      if (!mounted) return;
      final url = (j['payUrl'] ?? '').toString().trim();
      final type = (j['payType'] ?? '').toString().trim();
      if (url.isEmpty) {
        setState(() {
          _busy = false;
          _error = '网关未返回支付链接，请稍后重试或改用凭证人工开通';
        });
        return;
      }
      setState(() {
        _busy = false;
        _orderId = (j['orderId'] ?? '') as String;
        _payUrl = url;
        _payType = type;
        _payQr = type == 'qrcode' ? url : null;
      });
      if (type == 'qrcode') {
        _startPoll();
        _snack('二维码已生成，请使用微信/支付宝扫码支付');
        return;
      }
      await _open(url, payType: type);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '下单失败，请稍后重试';
      });
    }
  }

  Future<void> _open(String url, {String payType = ''}) async {
    final uri = Uri.tryParse(url);
    final isHttps = SecureLinks.httpsUri(url) != null;
    // 文档：mapi.php 的 payurl 只用于页面跳转，urlscheme 只用于唤起 App，
    // qrcode 是扫码内容。不能把三者都当成普通 URL 塞进 WebView。
    if (isHttps && payType != 'scheme') {
      await Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => _EpayWebView(url: url)));
      await _check();
      _startPoll();
      return;
    }
    if (uri != null &&
        (uri.scheme == 'weixin' ||
            uri.scheme == 'alipays' ||
            uri.scheme == 'alipay' ||
            uri.scheme == 'douyin')) {
      try {
        final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
        if (!ok) {
          _snack('未找到对应的支付 App，请改用其他支付方式');
          return;
        }
      } catch (_) {
        _snack('无法唤起支付 App，请改用其他支付方式');
        return;
      }
      _startPoll();
      return;
    }
    // 剩余情况（未知 scheme / 纯文本）：复制给用户，避免静默失败。
    try {
      await AppClipboard.copy(url);
      _snack('支付信息已复制，请在支付 App 中打开');
    } catch (_) {}
    _startPoll();
  }

  void _startPoll() {
    _poll?.cancel();
    _tries = 0;
    _poll = Timer.periodic(const Duration(seconds: 3), (t) {
      _tries++;
      if (_tries > 40) {
        t.cancel();
        return;
      }
      _check(silent: true);
    });
  }

  Future<void> _check({bool silent = false}) async {
    if (_orderId == null || _orderId!.isEmpty || _finishing) return;
    try {
      final j = await ApiClient.memberPayStatus(_orderId!);
      if (!mounted) return;
      if (j['paid'] == true) {
        _finishing = true;
        _poll?.cancel();
        setState(() => _busy = false);
        await Future<void>.delayed(const Duration(milliseconds: 500));
        if (mounted) Navigator.pop(context, {'paid': true});
        return;
      }
      if (!silent && mounted) {
        _snack('还没有收到支付结果，完成支付后稍等几秒');
      }
    } catch (_) {
      if (!silent && mounted) _snack('查询失败，请稍后再试');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 34,
                  height: 4,
                  decoration: BoxDecoration(
                    color: const Color(0x26FFFFFF),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '开通 ${widget.tier}',
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${widget.planName} · ${widget.days} 天 · 支付成功自动开通',
                          style: const TextStyle(
                            fontSize: 10.5,
                            color: Color(AppColors.textTertiary),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Text(
                    widget.priceText,
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -.8,
                      color: _mint,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              const Hairline(),
              const SizedBox(height: 16),
              const _FieldLabel('支付方式'),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: _channelChip(
                      '微信支付',
                      'wxpay',
                      Icons.chat_bubble_outline_rounded,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _channelChip(
                      '支付宝',
                      'alipay',
                      Icons.account_balance_wallet_outlined,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                decoration: BoxDecoration(
                  color: _mint.withValues(alpha: .04),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: _mint.withValues(alpha: .14)),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.shield_outlined, size: 14, color: _mint),
                    SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        '将打开易支付收银台，支付完成后自动回到本页，无需上传截图。',
                        style: TextStyle(
                          fontSize: 10,
                          height: 1.5,
                          color: Color(AppColors.textTertiary),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (_payQr != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: QrImageView(
                    data: _payQr!,
                    version: QrVersions.auto,
                    size: 190,
                    backgroundColor: Colors.white,
                    eyeStyle: const QrEyeStyle(
                      eyeShape: QrEyeShape.square,
                      color: Color(0xFF111111),
                    ),
                    dataModuleStyle: const QrDataModuleStyle(
                      dataModuleShape: QrDataModuleShape.square,
                      color: Color(0xFF111111),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  '请使用微信 / 支付宝扫一扫完成支付，支付成功后自动开通',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 10,
                    height: 1.5,
                    color: Color(AppColors.textTertiary),
                  ),
                ),
              ],
              if (_orderId != null) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.6,
                        valueColor: AlwaysStoppedAnimation<Color>(_mint),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _finishing ? '支付成功，正在开通…' : '等待支付结果，完成后自动开通',
                        style: const TextStyle(
                          fontSize: 10,
                          color: Color(AppColors.textTertiary),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(
                  _error!,
                  style: const TextStyle(
                    fontSize: 10.5,
                    height: 1.5,
                    color: Color(AppColors.danger),
                  ),
                ),
              ],
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: PillButton(
                  label: _busy
                      ? '正在下单…'
                      : (_payQr != null
                            ? '请扫码支付 · ${widget.priceText}'
                            : (_payUrl == null
                                  ? '去支付 · ${widget.priceText}'
                                  : '继续支付 · ${widget.priceText}')),
                  size: PillSize.lg,
                  expand: true,
                  glow: !_busy,
                  loading: _busy,
                  onTap: _busy ? null : _payNow,
                ),
              ),
              const SizedBox(height: 12),
              Center(
                child: TextButton(
                  onPressed: _busy
                      ? null
                      : () => Navigator.pop(context, {'manual': true}),
                  child: const Text(
                    '支付遇到问题？改用凭证人工开通',
                    style: TextStyle(
                      fontSize: 10.5,
                      color: Color(AppColors.textTertiary),
                      decoration: TextDecoration.underline,
                      decorationColor: Color(0x33FFFFFF),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _channelChip(String name, String key, IconData icon) {
    final selected = _channel == key;
    return PressableScale(
      onTap: () => setState(() => _channel = key),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: selected
              ? _mint.withValues(alpha: .08)
              : const Color(0xFF080909),
          border: Border.all(
            color: selected
                ? _mint.withValues(alpha: .5)
                : const Color(0x0FFFFFFF),
          ),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 15,
              color: selected ? _mint : const Color(AppColors.textTertiary),
            ),
            const SizedBox(width: 6),
            Text(
              name,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: selected
                    ? const Color(AppColors.textPrimary)
                    : const Color(AppColors.textSecondary),
              ),
            ),
            const Spacer(),
            Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected ? _mint : const Color(0x33FFFFFF),
                  width: 1.2,
                ),
                color: selected
                    ? _mint.withValues(alpha: .15)
                    : Colors.transparent,
              ),
              child: selected
                  ? const Icon(Icons.check_rounded, size: 9, color: _mint)
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}

class _EpayWebView extends StatefulWidget {
  const _EpayWebView({required this.url});

  final String url;

  @override
  State<_EpayWebView> createState() => _EpayWebViewState();
}

class _EpayWebViewState extends State<_EpayWebView> {
  late final WebViewController _web;

  bool _closed = false;

  @override
  void initState() {
    super.initState();
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF070808))
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (req) {
            final uri = Uri.tryParse(req.url);
            if (uri == null) return NavigationDecision.prevent;
            final scheme = uri.scheme.toLowerCase();
            // 收银台页面里的「打开微信/支付宝」是自定义 scheme，WebView 默认会
            // 直接拦下，表现为点了支付没反应。这里只放行已知支付 App。
            if (scheme == 'weixin' ||
                scheme == 'alipays' ||
                scheme == 'alipay' ||
                scheme == 'douyin') {
              unawaited(launchUrl(uri, mode: LaunchMode.externalApplication));
              return NavigationDecision.prevent;
            }
            if (req.url.contains('/member/epay/return')) {
              _closeOnce();
              return NavigationDecision.prevent;
            }
            // 收银台主文档与跳转只允许 HTTPS；阻断 http、file、intent、
            // javascript、tel 等 scheme，防止跳到任意 App 或本地内容。
            if (scheme == 'https') return NavigationDecision.navigate;
            if (scheme == 'about' && uri.toString() == 'about:blank') {
              return NavigationDecision.navigate;
            }
            return NavigationDecision.prevent;
          },
          onPageStarted: (u) {
            if (u.contains('/member/epay/return')) _closeOnce();
          },
        ),
      )
      ..loadRequest(Uri.parse(widget.url));
  }

  void _closeOnce() {
    if (_closed || !mounted) return;
    _closed = true;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF070808),
      appBar: AppBar(
        backgroundColor: const Color(AppColors.bg),
        elevation: 0,
        title: const Text(
          '易支付收银台',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        leading: IconButton(
          icon: const Icon(Icons.close_rounded, size: 20),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: WebViewWidget(controller: _web),
    );
  }
}

class _ApplySheet extends StatefulWidget {
  const _ApplySheet({
    required this.tier,
    required this.days,
    required this.priceText,
    required this.planName,
  });

  final String tier;
  final int days;
  final String priceText;
  final String planName;

  @override
  State<_ApplySheet> createState() => _ApplySheetState();
}

class _ApplySheetState extends State<_ApplySheet> {
  final _contact = TextEditingController();
  final _note = TextEditingController();

  String _pay = '微信支付';
  String? _proofUrl;
  String? _proofName;
  String? _proofPath;
  bool _proofIsImage = true;
  bool _uploading = false;
  bool _submitting = false;

  @override
  void dispose() {
    _contact.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _pickProof() async {
    final source = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => SafeArea(
        child: Container(
          margin: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: _surface2,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(
                  Icons.photo_library_outlined,
                  size: 20,
                  color: _mint,
                ),
                title: const Text('从相册选择图片', style: TextStyle(fontSize: 14)),
                onTap: () => Navigator.pop(ctx, 'image'),
              ),
              const Hairline(),
              ListTile(
                leading: const Icon(
                  Icons.attach_file_rounded,
                  size: 20,
                  color: _mint,
                ),
                title: const Text(
                  '选择文件（图片 / PDF）',
                  style: TextStyle(fontSize: 14),
                ),
                onTap: () => Navigator.pop(ctx, 'file'),
              ),
            ],
          ),
        ),
      ),
    );
    if (source == null) return;

    String? path;
    if (source == 'image') {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 1600,
        imageQuality: 88,
      );
      path = picked?.path;
    } else {
      final res = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['jpg', 'jpeg', 'png', 'webp', 'pdf'],
      );
      path = res?.files.single.path;
    }
    if (path == null) return;

    final p = path;
    final ext = p.split('.').last.toLowerCase();
    setState(() {
      _uploading = true;
      _proofPath = p;
      _proofName = p.split('/').last;
      _proofIsImage = ext != 'pdf';
    });
    try {
      final j = await ApiClient.uploadProof(p);
      if (!mounted) return;
      setState(() {
        _proofUrl = (j['url'] ?? '') as String;
        _uploading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _uploading = false;
        _proofPath = null;
        _proofName = null;
      });
      _snack(e.message);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _uploading = false;
        _proofPath = null;
        _proofName = null;
      });
      _snack('上传失败，请重试');
    }
  }

  void _snack(String m) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m)));
  }

  void _submit() {
    if (_uploading) {
      _snack('凭证正在上传，稍等一下');
      return;
    }
    if ((_proofUrl ?? '').isEmpty) {
      _snack('请先上传支付截图或凭证');
      return;
    }
    if (_contact.text.trim().isEmpty) {
      _snack('留个联系方式，方便管理员核对');
      return;
    }
    if (_submitting) return;
    setState(() => _submitting = true);
    final note = [
      '支付方式：$_pay',
      if (_note.text.trim().isNotEmpty) _note.text.trim(),
    ].join(' · ');
    Navigator.pop(context, {
      'contact': _contact.text.trim(),
      'note': note,
      'proof': _proofUrl,
    });
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .9,
      ),
      child: Container(
        decoration: const BoxDecoration(
          color: _surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: EdgeInsets.only(bottom: bottom),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(
                        child: Container(
                          width: 34,
                          height: 4,
                          decoration: BoxDecoration(
                            color: const Color(0x26FFFFFF),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '开通 ${widget.tier}',
                                  style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '${widget.planName} · ${widget.days} 天 · 凭证核验后生效',
                                  style: const TextStyle(
                                    fontSize: 10.5,
                                    color: Color(AppColors.textTertiary),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Text(
                            widget.priceText,
                            style: const TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -.8,
                              color: _mint,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                const Hairline(),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const _FieldLabel('支付方式'),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: _payChip(
                                '微信支付',
                                Icons.chat_bubble_outline_rounded,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: _payChip(
                                '支付宝',
                                Icons.account_balance_wallet_outlined,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          '转账后上传支付凭证，管理员核对即开通（一般 10 分钟内）。',
                          style: TextStyle(
                            fontSize: 9.5,
                            color: Color(AppColors.textTertiary),
                          ),
                        ),
                        const SizedBox(height: 18),
                        const _FieldLabel('支付凭证'),
                        const SizedBox(height: 8),
                        _proofBox(),
                        const SizedBox(height: 18),
                        const _FieldLabel('联系方式'),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _contact,
                          style: const TextStyle(fontSize: 13.5),
                          decoration: const InputDecoration(
                            hintText: '微信号 / QQ，方便管理员联系你',
                            prefixIcon: Icon(
                              Icons.alternate_email_rounded,
                              size: 17,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _note,
                          style: const TextStyle(fontSize: 13.5),
                          maxLines: 2,
                          decoration: const InputDecoration(
                            hintText: '备注（选填）',
                            prefixIcon: Icon(Icons.edit_note_rounded, size: 17),
                          ),
                        ),
                        const SizedBox(height: 8),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    20,
                    8,
                    20,
                    12 + MediaQuery.paddingOf(context).bottom,
                  ),
                  child: SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: PillButton(
                      label: _uploading
                          ? '凭证上传中…'
                          : '提交申请 · ${widget.priceText}',
                      size: PillSize.lg,
                      expand: true,
                      glow: !_uploading,
                      loading: _uploading || _submitting,
                      onTap: _uploading ? null : _submit,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _payChip(String name, IconData icon) {
    final selected = _pay == name;
    return PressableScale(
      onTap: () => setState(() => _pay = name),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        height: 42,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: selected
              ? _mint.withValues(alpha: .08)
              : const Color(0xFF080909),
          border: Border.all(
            color: selected
                ? _mint.withValues(alpha: .5)
                : const Color(0x0FFFFFFF),
          ),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 15,
              color: selected ? _mint : const Color(AppColors.textTertiary),
            ),
            const SizedBox(width: 6),
            Text(
              name,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: selected
                    ? const Color(AppColors.textPrimary)
                    : const Color(AppColors.textSecondary),
              ),
            ),
            const Spacer(),
            Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected ? _mint : const Color(0x33FFFFFF),
                  width: 1.2,
                ),
                color: selected
                    ? _mint.withValues(alpha: .15)
                    : Colors.transparent,
              ),
              child: selected
                  ? const Icon(Icons.check_rounded, size: 9, color: _mint)
                  : null,
            ),
          ],
        ),
      ),
    );
  }

  Widget _proofBox() {
    final has = _proofPath != null;
    return PressableScale(
      onTap: _uploading ? null : _pickProof,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: _mint.withValues(alpha: .03),
          border: Border.all(color: _mint.withValues(alpha: .22)),
        ),
        child: has
            ? Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox(
                      width: 46,
                      height: 46,
                      child: _proofIsImage
                          ? Image.file(File(_proofPath!), fit: BoxFit.cover)
                          : Container(
                              color: const Color(0xFF15171A),
                              child: const Icon(
                                Icons.picture_as_pdf_outlined,
                                size: 20,
                                color: _mint,
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _proofName ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11.5),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          _uploading
                              ? '上传中…'
                              : (_proofUrl == null ? '待上传' : '已上传 · 点击可更换'),
                          style: TextStyle(
                            fontSize: 9.5,
                            color: _uploading
                                ? const Color(AppColors.warning)
                                : Color(AppColors.textTertiary),
                          ),
                        ),
                      ],
                    ),
                  ),
                  PressableScale(
                    onTap: () => setState(() {
                      _proofPath = null;
                      _proofName = null;
                      _proofUrl = null;
                      _uploading = false;
                    }),
                    child: const Padding(
                      padding: EdgeInsets.all(4),
                      child: Icon(
                        Icons.close_rounded,
                        size: 16,
                        color: Color(AppColors.textTertiary),
                      ),
                    ),
                  ),
                ],
              )
            : Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _mint.withValues(alpha: .08),
                    ),
                    child: const Icon(
                      Icons.add_photo_alternate_outlined,
                      size: 19,
                      color: _mint,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('上传支付截图', style: TextStyle(fontSize: 12.5)),
                        SizedBox(height: 3),
                        Text(
                          '支持图片或 PDF，≤10MB',
                          style: TextStyle(
                            fontSize: 9.5,
                            color: Color(AppColors.textTertiary),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 16,
                    color: _mint.withValues(alpha: .7),
                  ),
                ],
              ),
      ),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 10.5,
        fontWeight: FontWeight.w600,
        letterSpacing: .4,
        color: Color(AppColors.textTertiary),
      ),
    );
  }
}
