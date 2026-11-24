/// 应用投稿 / 修改投稿。
///
/// 表单字段严格对齐后端 normalize_payload：名称、图标、包类型、包名、大类、
/// 子类、3–9 张截图、介绍、分享感言、下载链接、版本号、系统版本、可选提取码。
library;

import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../api/app_market_api.dart';
import '../../api/client.dart';
import '../../design/components.dart';
import '../../models/app_market.dart';
import '../../services/app_market_bus.dart';
import '../mine/login_page.dart';

const _packageTypes = <(String, String, String)>[
  ('apk', 'APK', 'Android'),
  ('ipa', 'IPA', 'iOS'),
  ('store', 'App Store', 'iOS'),
  ('hap', 'HAP', '鸿蒙'),
  ('app', 'APP', '鸿蒙'),
  ('exe', 'EXE', 'Windows'),
  ('msi', 'MSI', 'Windows'),
];

String _platformOfType(String type) {
  return switch (type) {
    'apk' => 'Android',
    'ipa' || 'store' => 'iOS',
    'hap' || 'app' => '鸿蒙',
    'exe' || 'msi' => 'Windows',
    _ => '未知',
  };
}

class _Shot {
  String? localPath;
  String? serverPath;
  _Shot({this.localPath, this.serverPath});
}

class AppSubmitPage extends StatefulWidget {
  const AppSubmitPage({super.key, this.existing});

  final MarketApp? existing;

  @override
  State<AppSubmitPage> createState() => _AppSubmitPageState();
}

class _AppSubmitPageState extends State<AppSubmitPage> {
  final _name = TextEditingController();
  final _packageName = TextEditingController();
  final _versionName = TextEditingController();
  final _osVersion = TextEditingController();
  final _downloadUrl = TextEditingController();
  final _description = TextEditingController();
  final _shareReason = TextEditingController();
  final _shareCode = TextEditingController();

  String _packageType = 'apk';
  String? _iconLocal;
  String _iconServer = '';
  final List<_Shot> _shots = [];
  List<AppCategory> _categories = const [];
  AppCategory? _major;
  AppCategory? _sub;
  bool _categoriesLoading = true;
  bool _categoriesFailed = false;
  bool _appliedExistingCategories = false;

  bool _submitting = false;
  String _uploadLabel = '';
  String? _validationError;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) {
      _name.text = e.name;
      _packageType = e.packageType.isEmpty
          ? 'apk'
          : e.packageType.toLowerCase();
      _packageName.text = e.packageName;
      _versionName.text = e.version;
      _osVersion.text = e.osVersion;
      _downloadUrl.text = e.downloadUrl;
      // 我的投稿接口出于安全只返回原始下载链接，分享感言/介绍正常回填。
      _description.text = e.description;
      _shareReason.text = e.shareReason;
      if (e.icon.isNotEmpty) _iconServer = e.icon;
      for (final s in e.screenshots) {
        _shots.add(_Shot(serverPath: s));
      }
    }
    _loadCategories();
  }

  @override
  void dispose() {
    _name.dispose();
    _packageName.dispose();
    _versionName.dispose();
    _osVersion.dispose();
    _downloadUrl.dispose();
    _description.dispose();
    _shareReason.dispose();
    _shareCode.dispose();
    super.dispose();
  }

  Future<void> _loadCategories() async {
    if (mounted) {
      setState(() {
        _categoriesLoading = true;
        _categoriesFailed = false;
      });
    }
    try {
      final list = await AppMarketApi.categories();
      if (!mounted) return;
      setState(() {
        _categories = list;
        _categoriesLoading = false;
        _applyExistingCategories();
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _categoriesLoading = false;
        _categoriesFailed = true;
      });
    }
  }

  void _applyExistingCategories() {
    if (_appliedExistingCategories) return;
    final e = widget.existing;
    if (e == null) {
      _appliedExistingCategories = true;
      return;
    }
    for (final major in _categories) {
      if (major.id != e.categoryId) continue;
      _major = major;
      for (final sub in major.children) {
        if (sub.id == e.subCategoryId) {
          _sub = sub;
          break;
        }
      }
      break;
    }
    _appliedExistingCategories = true;
  }

  Future<bool> _ensureLogin() async {
    if (ApiClient.token != null && ApiClient.token!.isNotEmpty) return true;
    final ok = await Navigator.of(context)
        .push<bool>(MaterialPageRoute(builder: (_) => const LoginPage()));
    return ok == true && ApiClient.token != null;
  }

  Future<void> _pickIcon() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 1200,
      maxHeight: 1200,
      imageQuality: 88,
    );
    if (picked == null || !mounted) return;
    final f = File(picked.path);
    if (await f.length() > 10 * 1024 * 1024) {
      if (mounted) showAppToast(context, '图标必须小于 10 MB');
      return;
    }
    setState(() {
      _iconLocal = picked.path;
      _iconServer = '';
    });
  }

  Future<void> _pickScreenshots() async {
    if (_shots.length >= 9) {
      showAppToast(context, '最多 9 张截图');
      return;
    }
    final picker = ImagePicker();
    final picked = await picker.pickMultiImage(
      maxWidth: 1800,
      imageQuality: 88,
    );
    if (picked.isEmpty || !mounted) return;
    final remain = 9 - _shots.length;
    if (picked.length > remain) {
      showAppToast(context, '最多 9 张截图，已加入前 $remain 张');
    }
    for (final x in picked.take(remain)) {
      final f = File(x.path);
      if (await f.length() > 10 * 1024 * 1024) {
        if (mounted) showAppToast(context, '单张截图必须小于 10 MB');
        continue;
      }
      _shots.add(_Shot(localPath: x.path));
    }
    if (mounted) setState(() {});
  }

  void _removeShot(int index) {
    setState(() => _shots.removeAt(index));
  }

  Future<String> _uploadImage(String path) async {
    final j = await AppMarketApi.uploadImage(path);
    final url = (j['url'] ?? '').toString();
    if (url.isEmpty) throw _FormError('图片上传没有返回地址');
    return url;
  }

  Future<void> _pickMajor() async {
    if (_categoriesLoading) {
      showAppToast(context, '分类还在加载中');
      return;
    }
    if (_categoriesFailed) {
      await _loadCategories();
      return;
    }
    final picked = await _showCategorySheet(
      title: '选择应用大类',
      items: _categories,
      selectedId: _major?.id ?? '',
    );
    if (picked == null || !mounted) return;
    setState(() {
      _major = picked;
      _sub = null;
    });
  }

  Future<void> _pickSub() async {
    if (_major == null) {
      showAppToast(context, '请先选择应用大类');
      return;
    }
    final picked = await _showCategorySheet(
      title: '选择子分类',
      items: _major!.children,
      selectedId: _sub?.id ?? '',
    );
    if (picked == null || !mounted) return;
    setState(() => _sub = picked);
  }

  Future<AppCategory?> _showCategorySheet({
    required String title,
    required List<AppCategory> items,
    required String selectedId,
  }) {
    return showModalBottomSheet<AppCategory>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(ctx).height * 0.72,
        ),
        decoration: const BoxDecoration(
          color: Color(AppColors.canvas),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: const Color(0xFF313136),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 12, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: AppType.title.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconCircleButton(
                    icon: Icons.close_rounded,
                    size: 30,
                    iconSize: 16,
                    onTap: () => Navigator.of(ctx).pop(),
                  ),
                ],
              ),
            ),
            Flexible(
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 18),
                itemCount: items.length,
                separatorBuilder: (_, _) =>
                    const Divider(height: 1, color: Color(AppColors.hairline)),
                itemBuilder: (_, i) {
                  final item = items[i];
                  final active = item.id == selectedId;
                  return ListTile(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                    ),
                    title: Text(
                      item.name,
                      style: AppType.body.copyWith(
                        color: active
                            ? const Color(AppColors.accent)
                            : const Color(AppColors.textPrimary),
                      ),
                    ),
                    trailing: active
                        ? const Icon(
                            Icons.check_rounded,
                            color: Color(AppColors.accent),
                          )
                        : null,
                    onTap: () => Navigator.of(ctx).pop(item),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  String? _validate() {
    final name = _name.text.trim();
    if (name.length < 2 || name.length > 40) return '应用名称需为 2–40 个字符';
    if (_iconLocal == null && _iconServer.isEmpty) return '请上传应用图标';
    if (!_packageTypes.any((e) => e.$1 == _packageType)) return '请选择安装包类型';
    final package = _packageName.text.trim();
    if (!RegExp(r'^[A-Za-z0-9._-]{2,128}$').hasMatch(package)) {
      return '包名/应用标识需为 2–128 位字母、数字、点、下划线或短横线';
    }
    if (_versionName.text.trim().isEmpty) return '请填写应用版本号';
    if (_major == null || _sub == null) return '请选择应用大类和子分类';
    if (_shots.length < 3) return '至少需要 3 张应用截图';
    if (_shots.length > 9) return '最多 9 张应用截图';
    final shotKeys = <String>{};
    for (final s in _shots) {
      final key = s.serverPath ?? s.localPath ?? '';
      if (key.isNotEmpty && !shotKeys.add(key)) return '截图不能重复';
    }
    final desc = _description.text.trim();
    if (desc.length < 20) return '应用介绍至少 20 个字';
    if (desc.length > 3000) return '应用介绍最多 3000 个字';
    final share = _shareReason.text.trim();
    if (share.length < 10) return '分享感言至少 10 个字';
    if (share.length > 500) return '分享感言最多 500 个字';
    final url = _downloadUrl.text.trim();
    if (url.isEmpty || url.length > 2048) {
      return _packageType == 'store'
          ? 'App Store 链接不能为空且不超过 2048 字'
          : '下载链接不能为空且不超过 2048 字';
    }
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !(uri.scheme == 'http' || uri.scheme == 'https') ||
        uri.host.isEmpty) {
      return _packageType == 'store'
          ? 'App Store 链接必须是 https 完整地址'
          : '下载链接只支持 http/https 完整地址';
    }
    if (uri.userInfo.isNotEmpty) return '链接不能包含账号密码';
    final host = uri.host.toLowerCase();
    if (_packageType == 'store') {
      if (uri.scheme != 'https' ||
          !(host == 'apps.apple.com' || host == 'itunes.apple.com') ||
          !uri.path.contains('/app/') ||
          !RegExp(r'id\d{6,}').hasMatch(url)) {
        return '请填写具体的 App Store 应用页链接（apps.apple.com/…/id…）';
      }
    } else if (host == 'localhost' ||
        host == '127.0.0.1' ||
        host.startsWith('192.168.') ||
        host.startsWith('10.') ||
        RegExp(r'^172\.(1[6-9]|2[0-9]|3[0-1])\.').hasMatch(host)) {
      return '下载链接不能指向本机或内网地址';
    }
    if (_packageType != 'store' && _shareCode.text.trim().length > 64) {
      return '提取码最多 64 个字符';
    }
    return null;
  }

  Future<void> _submit() async {
    if (_submitting) return;
    if (!await _ensureLogin() || !mounted) return;
    final error = _validate();
    if (error != null) {
      setState(() => _validationError = error);
      showAppToast(context, error);
      return;
    }
    setState(() {
      _submitting = true;
      _validationError = null;
      _uploadLabel = '准备上传…';
    });
    try {
      // 先上传本地图标/截图，再提交；任何上传失败都会中止，避免产生半套投稿。
      final icon = _iconLocal != null
          ? await _uploadImage(_iconLocal!)
          : _iconServer;
      if (_iconLocal != null) {
        if (!mounted) return;
        setState(() {
          _iconServer = icon;
          _iconLocal = null;
        });
      }
      final shots = <String>[];
      for (var i = 0; i < _shots.length; i++) {
        final s = _shots[i];
        if (!mounted) return;
        if (s.serverPath != null && s.serverPath!.isNotEmpty) {
          shots.add(s.serverPath!);
          continue;
        }
        final local = s.localPath;
        if (local == null) continue;
        setState(() => _uploadLabel = '正在上传截图 ${i + 1}/${_shots.length}…');
        final url = await _uploadImage(local);
        if (!mounted) return;
        setState(() {
          s.serverPath = url;
          s.localPath = null;
        });
        shots.add(url);
      }
      if (shots.length < 3 || shots.length > 9) {
        throw _FormError('应用截图必须为 3–9 张');
      }
      if (shots.toSet().length != shots.length) {
        throw _FormError('应用截图不能重复');
      }
      if (!mounted) return;
      setState(() => _uploadLabel = '正在提交审核…');

      final draft = AppSubmissionDraft(
        name: _name.text.trim(),
        icon: icon,
        packageType: _packageType,
        packageName: _packageName.text.trim(),
        categoryId: _major!.id,
        subCategoryId: _sub!.id,
        screenshots: shots,
        description: _description.text.trim(),
        shareReason: _shareReason.text.trim(),
        downloadUrl: _downloadUrl.text.trim(),
        versionName: _versionName.text.trim(),
        osVersion: _osVersion.text.trim(),
        shareCode: _shareCode.text.trim(),
        appId: widget.existing?.id,
        versionId: widget.existing?.versionId,
      );

      final existing = widget.existing;
      if (existing == null) {
        final j = await AppMarketApi.create(draft);
        if (!mounted) return;
        final id = (j['id'] ?? '').toString();
        if (id.isEmpty) throw _FormError('投稿没有返回应用 ID');
      } else {
        final j = await AppMarketApi.update(existing.id, draft);
        final versionId = (j['versionId'] ?? existing.versionId ?? '')
            .toString();
        if (versionId.isEmpty) throw _FormError('保存投稿没有返回版本 ID');
        await AppMarketApi.submit(existing.id, versionId: versionId);
      }
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _uploadLabel = '';
      });
      AppMarketBus.touch();
      showAppToast(context, '投稿已提交，等待人工审核');
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _uploadLabel = '';
      });
      showAppToast(context, '提交失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return ImmersivePage(
      child: Column(
        children: [
          GlassTopBar(
            title: _isEdit ? '修改投稿' : '投稿应用',
            subtitle: '提交后进入人工审核，默认待审核',
            solid: true,
          ),
          Expanded(
            child: ListView(
              padding: EdgeInsets.fromLTRB(
                AppSpace.gutter,
                AppSpace.x3,
                AppSpace.gutter,
                28,
              ),
              physics: const BouncingScrollPhysics(),
              children: [
                _reviewBanner(),
                const SizedBox(height: AppSpace.x5),
                _section('应用图标'),
                _iconPicker(),
                const SizedBox(height: AppSpace.x5),
                _section('基本信息'),
                _field(
                  label: '应用名称',
                  controller: _name,
                  hint: '2–40 个字，用户看到的名字',
                  maxLength: 40,
                ),
                _field(
                  label: '包名 / 应用标识',
                  controller: _packageName,
                  hint: _packageType == 'apk'
                      ? '例如 com.example.app'
                      : _packageType == 'ipa' || _packageType == 'store'
                      ? 'Bundle ID，例如 com.example.app'
                      : '应用唯一标识，例如 com.example.app',
                  maxLength: 128,
                ),
                _section('安装包类型'),
                _packageTypePicker(),
                const SizedBox(height: AppSpace.x3),
                _field(
                  label: '应用版本号',
                  controller: _versionName,
                  hint: '例如 1.2.0',
                  maxLength: 32,
                ),
                _field(
                  label: '系统 / 兼容版本',
                  controller: _osVersion,
                  hint: '例如 Android 10+ / iOS 15+ / HarmonyOS 4+',
                  maxLength: 64,
                ),
                _section('分类'),
                _selector(
                  label: '应用大类',
                  value: _major?.name ?? '',
                  hint: '选择大类',
                  onTap: _categoriesFailed ? _loadCategories : _pickMajor,
                ),
                const SizedBox(height: AppSpace.x2),
                _selector(
                  label: '应用子分类',
                  value: _sub?.name ?? '',
                  hint: _major == null ? '请先选择大类' : '选择子分类',
                  enabled: _major != null,
                  onTap: _pickSub,
                ),
                if (_categoriesFailed)
                  Padding(
                    padding: const EdgeInsets.only(top: 6, left: 4),
                    child: GestureDetector(
                      onTap: _loadCategories,
                      child: Text(
                        '分类加载失败，点击重试',
                        style: AppType.micro.copyWith(
                          color: const Color(AppColors.danger),
                        ),
                      ),
                    ),
                  ),
                _section('应用截图'),
                _screenshots(),
                const SizedBox(height: AppSpace.x5),
                _section(_packageType == 'store' ? 'App Store 链接' : '下载链接'),
                _field(
                  label: _packageType == 'store' ? 'App Store 应用页' : '外部下载地址',
                  controller: _downloadUrl,
                  hint: _packageType == 'store'
                      ? 'https://apps.apple.com/cn/app/…/id…'
                      : '官网直链 / GitHub Releases / 网盘分享页',
                  maxLength: 2048,
                  keyboardType: TextInputType.url,
                  maxLines: 2,
                ),
                if (_packageType != 'store')
                  _field(
                    label: '提取码（选填）',
                    controller: _shareCode,
                    hint: '蓝奏云、123 云盘等需要提取码时填写',
                    maxLength: 64,
                  ),
                const SizedBox(height: AppSpace.x3),
                _downloadHint(),
                _section('介绍与分享感言'),
                _field(
                  label: '应用介绍',
                  controller: _description,
                  hint: '它是什么、能做什么、适合谁用（至少 20 字）',
                  maxLength: 3000,
                  maxLines: 6,
                  minLines: 4,
                  showCounter: true,
                ),
                _field(
                  label: '分享感言',
                  controller: _shareReason,
                  hint: '你为什么想推荐它（至少 10 字）',
                  maxLength: 500,
                  maxLines: 5,
                  minLines: 3,
                  showCounter: true,
                ),
                const SizedBox(height: AppSpace.x4),
                if (_validationError != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpace.x3),
                    child: Text(
                      _validationError!,
                      style: AppType.bodySm.copyWith(
                        color: const Color(AppColors.danger),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          _submitBar(),
        ],
      ),
    );
  }

  Widget _reviewBanner() {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: const Color(AppColors.card).withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: const Color(AppColors.border)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.verified_user_outlined,
            size: 18,
            color: Color(AppColors.accent),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              '应用市场所有投稿都会人工审核，默认进入待审核。请如实填写，'
              '不要提交破解、盗版或来源不明的安装包。',
              style: AppType.bodySm.copyWith(
                fontSize: 12,
                height: 1.55,
                color: const Color(AppColors.textSecondary),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _section(String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: AppSpace.x2),
      child: Text(
        text,
        style: AppType.caption.copyWith(
          color: const Color(AppColors.textSecondary),
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
        ),
      ),
    );
  }

  Widget _iconPicker() {
    final local = _iconLocal;
    final server = _iconServer;
    return Row(
      children: [
        PressableScale(
          onTap: _pickIcon,
          child: Container(
            width: 82,
            height: 82,
            decoration: BoxDecoration(
              color: const Color(AppColors.card),
              borderRadius: BorderRadius.circular(AppRadius.md),
              border: Border.all(color: const Color(AppColors.border)),
            ),
            clipBehavior: Clip.antiAlias,
            child: local != null
                ? Image.file(File(local), fit: BoxFit.cover)
                : server.isNotEmpty
                ? CachedNetworkImage(
                    imageUrl: AppMarketApi.mediaPathToUrl(server),
                    fit: BoxFit.cover,
                    placeholder: (_, _) => const ImagePlaceholder(),
                    errorWidget: (_, _, _) => const ImagePlaceholder(
                      icon: Icons.broken_image_outlined,
                    ),
                  )
                : const Center(
                    child: Icon(
                      Icons.add_photo_alternate_outlined,
                      size: 28,
                      color: Color(AppColors.textTertiary),
                    ),
                  ),
          ),
        ),
        const SizedBox(width: AppSpace.x4),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _iconLocal != null || _iconServer.isNotEmpty
                    ? '点击更换图标'
                    : '上传应用图标',
                style: AppType.body.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              Text(
                '正方形图片，建议 1024×1024，支持 JPG/PNG/WebP，≤10 MB',
                style: AppType.caption.copyWith(height: 1.4),
              ),
              const SizedBox(height: 8),
              TagPill(
                label: '选择图片',
                compact: true,
                icon: Icons.photo_library_outlined,
                onTap: _pickIcon,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _packageTypePicker() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: AppSpace.x2,
          runSpacing: AppSpace.x2,
          children: [
            for (final (value, label, _) in _packageTypes)
              TagPill(
                label: label,
                active: _packageType == value,
                onTap: () => setState(() => _packageType = value),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          '将以 ${_platformOfType(_packageType)} 应用展示',
          style: AppType.micro.copyWith(
            color: const Color(AppColors.textTertiary),
          ),
        ),
      ],
    );
  }

  Widget _screenshots() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '至少 3 张，最多 9 张；建议展示首页、核心功能和设置页。',
          style: AppType.caption.copyWith(height: 1.4),
        ),
        const SizedBox(height: AppSpace.x3),
        LayoutBuilder(
          builder: (context, constraints) {
            final width = (constraints.maxWidth - 16) / 3;
            return Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var i = 0; i < _shots.length; i++)
                  SizedBox(
                    width: width,
                    height: width * 1.32,
                    child: _shotTile(i, width),
                  ),
                if (_shots.length < 9)
                  SizedBox(
                    width: width,
                    height: width * 1.32,
                    child: PressableScale(
                      onTap: _pickScreenshots,
                      child: Container(
                        decoration: BoxDecoration(
                          color: const Color(AppColors.card)
                              .withValues(alpha: 0.42),
                          borderRadius: BorderRadius.circular(AppRadius.sm),
                          border: Border.all(
                            color: const Color(AppColors.border),
                          ),
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(
                              Icons.add_rounded,
                              size: 24,
                              color: Color(AppColors.textTertiary),
                            ),
                            const SizedBox(height: 4),
                            Text('${_shots.length}/9', style: AppType.micro),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _shotTile(int index, double width) {
    final shot = _shots[index];
    final local = shot.localPath;
    final server = shot.serverPath;
    return Stack(
      children: [
        Positioned.fill(
          child: Container(
            decoration: BoxDecoration(
              color: const Color(AppColors.card),
              borderRadius: BorderRadius.circular(AppRadius.sm),
              border: Border.all(color: const Color(AppColors.border)),
            ),
            clipBehavior: Clip.antiAlias,
            child: local != null
                ? Image.file(File(local), fit: BoxFit.cover)
                : server != null
                ? CachedNetworkImage(
                    imageUrl: AppMarketApi.mediaPathToUrl(server),
                    fit: BoxFit.cover,
                    placeholder: (_, _) =>
                        const ImagePlaceholder(radius: AppRadius.sm),
                    errorWidget: (_, _, _) => const ImagePlaceholder(
                      icon: Icons.broken_image_outlined,
                      radius: AppRadius.sm,
                    ),
                  )
                : const ImagePlaceholder(radius: AppRadius.sm),
          ),
        ),
        Positioned(
          top: 4,
          right: 4,
          child: GestureDetector(
            onTap: () => _removeShot(index),
            child: Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.62),
                shape: BoxShape.circle,
                border: Border.all(color: const Color(AppColors.border)),
              ),
              child: const Icon(
                Icons.close_rounded,
                size: 13,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _downloadHint() {
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpace.x5),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(AppColors.card).withValues(alpha: 0.38),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: const Color(AppColors.hairline)),
      ),
      child: Text(
        _packageType == 'store'
            ? '只接受 App Store 具体应用页链接。客户端会显示“前往 App Store”，'
                  '下载、更新与内购都由 Apple 提供；不要填网页版或搜索页。'
            : '客户端只展示你填写的公开分享链接；下载时由服务端实时解析，'
                  '不会把网盘账号或 Cookie 下发。官网/GitHub 直链体验最好；'
                  '登录型网盘可能需要授权解析服务，失败时会有明确提示。',
        style: AppType.micro.copyWith(
          fontSize: 10.5,
          height: 1.55,
          color: const Color(AppColors.textTertiary),
        ),
      ),
    );
  }

  Widget _field({
    required String label,
    required TextEditingController controller,
    required String hint,
    int? maxLength,
    int maxLines = 1,
    int minLines = 1,
    bool showCounter = false,
    TextInputType? keyboardType,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.x3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 5),
            child: Text(
              label,
              style: AppType.micro.copyWith(
                color: const Color(AppColors.textSecondary),
                fontSize: 11,
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 2),
            decoration: BoxDecoration(
              color: const Color(AppColors.card),
              borderRadius: BorderRadius.circular(AppRadius.md),
              border: Border.all(color: const Color(AppColors.border)),
            ),
            child: TextField(
              controller: controller,
              maxLines: maxLines,
              minLines: minLines,
              maxLength: maxLength,
              keyboardType: keyboardType,
              cursorColor: const Color(AppColors.accent),
              style: AppType.body.copyWith(fontSize: 13.5, height: 1.45),
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: hint,
                hintStyle: AppType.bodySm.copyWith(
                  color: const Color(AppColors.textTertiary),
                  fontSize: 12.5,
                ),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                counterText: '',
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 11),
              ),
            ),
          ),
          if (showCounter && maxLength != null)
            Align(
              alignment: Alignment.centerRight,
              child: Text(
                '${controller.text.length}/$maxLength',
                style: AppType.micro.copyWith(fontSize: 10),
              ),
            ),
        ],
      ),
    );
  }

  Widget _selector({
    required String label,
    required String value,
    required String hint,
    required VoidCallback onTap,
    bool enabled = true,
  }) {
    return PressableScale(
      onTap: enabled ? onTap : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 13),
        decoration: BoxDecoration(
          color: const Color(AppColors.card),
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: const Color(AppColors.border)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: AppType.micro.copyWith(
                      fontSize: 10.5,
                      color: const Color(AppColors.textTertiary),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    value.isEmpty ? hint : value,
                    style: AppType.body.copyWith(
                      fontSize: 13.5,
                      color: value.isEmpty
                          ? const Color(AppColors.textTertiary)
                          : const Color(AppColors.textPrimary),
                    ),
                  ),
                ],
              ),
            ),
            const Icon(
              Icons.keyboard_arrow_right_rounded,
              size: 19,
              color: Color(AppColors.textTertiary),
            ),
          ],
        ),
      ),
    );
  }

  Widget _submitBar() {
    return Container(
      padding: EdgeInsets.fromLTRB(
        AppSpace.gutter,
        10,
        AppSpace.gutter,
        MediaQuery.paddingOf(context).bottom + 10,
      ),
      decoration: const BoxDecoration(
        color: Color(AppColors.bg),
        border: Border(top: BorderSide(color: Color(AppColors.hairline))),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_submitting && _uploadLabel.isNotEmpty) ...[
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _uploadLabel,
                style: AppType.micro.copyWith(
                  color: const Color(AppColors.accent),
                ),
              ),
            ),
            const SizedBox(height: 6),
          ],
          PillButton(
            label: _isEdit ? '保存并重新提交' : '提交审核',
            size: PillSize.lg,
            expand: true,
            glow: true,
            loading: _submitting,
            enabled: !_submitting,
            onTap: _submit,
          ),
        ],
      ),
    );
  }
}

class _FormError implements Exception {
  final String message;
  const _FormError(this.message);
  @override
  String toString() => message;
}
