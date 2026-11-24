/// 客户端版本检查与更新弹层。
///
/// - 启动时静默检查一次：有更新才弹，不打扰正常进入。
/// - 设置页手动检查：已是最新 / 检查失败 / 有新版本都有明确反馈。
/// - 强制更新：不可下滑关闭、不可点遮罩关闭、Android 返回键也被拦截。
library;

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/client.dart';
import '../config.dart';
import 'hot_update.dart';
import '../design/components.dart';
import '../design/system.dart';

class AppUpdateInfo {
  final String platform;
  final String version;
  final int build;
  final String downloadUrl;
  final String sha256;
  final String packageSize;
  final String notes;
  final String publishedAtText;
  final bool force;
  final bool hasUpdate;

  const AppUpdateInfo({
    required this.platform,
    required this.version,
    required this.build,
    required this.downloadUrl,
    this.sha256 = '',
    required this.packageSize,
    required this.notes,
    required this.publishedAtText,
    required this.force,
    required this.hasUpdate,
  });

  factory AppUpdateInfo.fromJson(Map<String, dynamic> j) {
    final raw = j['latest'];
    final latest = raw is Map ? Map<String, dynamic>.from(raw) : null;
    return AppUpdateInfo(
      platform: (j['platform'] ?? '').toString(),
      version: (latest?['version'] ?? '').toString(),
      build: int.tryParse('${latest?['build'] ?? 0}') ?? 0,
      downloadUrl: (j['downloadUrl'] ?? latest?['downloadUrl'] ?? '')
          .toString(),
      sha256: (j['sha256'] ?? latest?['sha256'] ?? '').toString(),
      packageSize: (j['packageSize'] ?? latest?['packageSize'] ?? '')
          .toString(),
      notes: (j['notes'] ?? latest?['notes'] ?? '').toString(),
      publishedAtText:
          (j['publishedAtText'] ?? latest?['publishedAtText'] ?? '').toString(),
      force: _truthy(j['force']),
      hasUpdate: _truthy(j['hasUpdate']),
    );
  }

  String get versionLabel =>
      build > 0 ? 'v$version · build $build' : 'v$version';
}

bool _truthy(dynamic v) =>
    v == true || v == 1 || '$v'.toLowerCase() == 'true' || '$v' == '1';

class AppUpdateService {
  static bool _busy = false;

  static String get platform {
    if (Platform.isIOS) return 'ios';
    if (Platform.isAndroid) return 'android';
    // 桌面端仅用于开发调试，按 Android 处理，避免误判。
    return 'android';
  }

  /// 检查更新。startup=true 时不提示“已是最新”和网络失败，避免启动打扰。
  static Future<void> checkForUpdate(
    BuildContext context, {
    bool startup = false,
  }) async {
    if (_busy) {
      if (!startup) showAppToast(context, '正在检查更新，请稍候');
      return;
    }
    _busy = true;
    try {
      final info = await _fetch();
      if (!context.mounted) return;
      if (info.hasUpdate) {
        await showUpdateSheet(context, info);
      } else if (!startup) {
        showAppToast(context, '已是最新版本 $kAppVersion');
      }
    } catch (_) {
      if (!startup && context.mounted) {
        showAppToast(context, '检查更新失败，请稍后重试');
      }
    } finally {
      _busy = false;
    }
  }

  static Future<AppUpdateInfo> _fetch() async {
    final j = await ApiClient.appVersion(
      platform: platform,
      version: kAppVersion,
      build: kAppBuild,
      channel: HotUpdateService.instance.channel,
      device: HotUpdateService.instance.deviceId,
    );
    return AppUpdateInfo.fromJson(j);
  }

  static Future<void> showUpdateSheet(
    BuildContext context,
    AppUpdateInfo info, {
    bool preview = false,
  }) async {
    final force = info.force && !preview;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      isDismissible: !force,
      enableDrag: !force,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => PopScope(
        canPop: !force,
        child: SheetShell(
          title: force ? '需要更新' : '发现新版本',
          subtitle: force ? '重要修复，完成更新后可继续使用' : '流萤社区有了新的版本',
          showGrabber: !force,
          showClose: !force,
          child: _UpdateBody(
            info: info,
            force: force,
            // 用弹层自己的 Navigator 关闭。不能用调用方页面的 context：
            // 启动检查时调用方可能是首页，设置页手动检查时则是设置页，
            // 一旦页面层级变深，maybePop 可能误关掉下层页面。
            onLater: force ? null : () => Navigator.of(sheetContext).maybePop(),
          ),
        ),
      ),
    );
  }
}

class _UpdateBody extends StatefulWidget {
  const _UpdateBody({
    required this.info,
    required this.force,
    required this.onLater,
  });

  final AppUpdateInfo info;
  final bool force;
  final VoidCallback? onLater;

  @override
  State<_UpdateBody> createState() => _UpdateBodyState();
}

class _UpdateIntegrityException implements Exception {
  final String message;
  const _UpdateIntegrityException(this.message);
}

class _UpdateBodyState extends State<_UpdateBody> {
  bool _opening = false;

  Future<void> _copyDownload() async {
    final raw = widget.info.downloadUrl.trim();
    if (raw.isEmpty) {
      showAppToast(context, '下载地址暂未配置');
      return;
    }
    await AppClipboard.copy(raw);
    if (mounted) showAppToast(context, '下载链接已复制');
  }

  static const _trustedHosts = {
    'www.dbmt999.asia',
    'dbmt999.asia',
    'www.yosar.cloud',
    'yosar.cloud',
  };

  Future<void> _openDownload() async {
    if (_opening) return;
    final raw = widget.info.downloadUrl.trim();
    if (raw.isEmpty) {
      showAppToast(context, '下载地址暂未配置，请联系管理员');
      return;
    }
    final uri = Uri.tryParse(raw);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        !_trustedHosts.contains(uri.host.toLowerCase())) {
      showAppToast(context, '下载地址不在受信任域名，已阻断');
      return;
    }
    setState(() => _opening = true);
    try {
      final digest = widget.info.sha256
          .replaceAll(':', '')
          .trim()
          .toLowerCase();
      if (Platform.isAndroid) {
        if (digest.isEmpty) {
          throw const _UpdateIntegrityException('更新包缺少 SHA-256 校验值，已阻断安装');
        }
        await _downloadVerifyInstall(uri, digest);
      } else {
        final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
        if (!ok && mounted) showAppToast(context, '打不开下载页，请复制链接到浏览器打开');
      }
    } on _UpdateIntegrityException catch (e) {
      if (mounted) showAppToast(context, e.message);
    } catch (_) {
      if (mounted) showAppToast(context, '更新失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  /// Android 在应用内下载更新包，先算 SHA-256 再交给系统安装器。
  /// iOS 不允许 App 安装 IPA，仍走系统浏览器；哈希由发布方在下载页展示。
  Future<void> _downloadVerifyInstall(Uri uri, String expected) async {
    final dir = await getTemporaryDirectory();
    final file = File(
      '${dir.path}/liuying-update-${widget.info.version}-${widget.info.build}.apk',
    );
    if (await file.exists()) await file.delete();
    final client = http.Client();
    try {
      final resp = await client
          .send(
            http.Request('GET', uri)
              ..headers['Accept'] = 'application/octet-stream',
          )
          .timeout(const Duration(seconds: 60));
      if (resp.statusCode != 200) {
        throw _UpdateIntegrityException('下载失败（HTTP ${resp.statusCode}）');
      }
      final sink = file.openWrite();
      try {
        await resp.stream.timeout(const Duration(seconds: 60)).pipe(sink);
      } finally {
        await sink.close();
      }
      if (!await file.exists() || await file.length() == 0) {
        throw const _UpdateIntegrityException('下载文件为空，已阻断安装');
      }
      final actual = (await sha256.bind(file.openRead()).first)
          .toString()
          .toLowerCase();
      if (actual != expected) {
        await file.delete();
        throw const _UpdateIntegrityException('安装包 SHA-256 校验失败，文件可能被替换，已删除');
      }
      final opened = await OpenFilex.open(file.path);
      if (opened.type != ResultType.done) {
        throw _UpdateIntegrityException('安装包已校验，但系统未能打开：${opened.message}');
      }
    } finally {
      client.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = widget.info;
    final hasUrl = info.downloadUrl.trim().isNotEmpty;
    final notes = info.notes.trim().isEmpty
        ? '本次更新以实际安装包为准。'
        : info.notes.trim();
    final bottom = MediaQuery.paddingOf(context).bottom;
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: EdgeInsets.fromLTRB(
        AppSpace.gutter,
        AppSpace.x1,
        AppSpace.gutter,
        AppSpace.x5 + bottom,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(
              AppSpace.x4,
              AppSpace.x4,
              AppSpace.x4,
              AppSpace.x4,
            ),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0x3345E0AE),
                  Color(0x153EE0FF),
                  Color(0x0AFFFFFF),
                ],
              ),
              borderRadius: AppRadius.rLg,
              border: Border.all(
                color: const Color(AppColors.accent).withValues(alpha: 0.22),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [
                            Color(AppColors.gradStart),
                            Color(AppColors.gradEnd),
                          ],
                        ),
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                      ),
                      alignment: Alignment.center,
                      child: const Icon(
                        Icons.system_update_alt_rounded,
                        color: Color(AppColors.onAccent),
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: AppSpace.x3),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.force ? '强制更新' : '更新已准备好',
                            style: AppType.label.copyWith(
                              color: const Color(AppColors.accent),
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '流萤社区 · ${info.platform.toUpperCase()}',
                            style: AppType.caption,
                          ),
                        ],
                      ),
                    ),
                    if (widget.force)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(AppColors.danger)
                              .withValues(alpha: 0.14),
                          borderRadius: AppRadius.rPill,
                          border: Border.all(
                            color: const Color(AppColors.danger)
                                .withValues(alpha: 0.35),
                          ),
                        ),
                        child: Text(
                          '必须更新',
                          style: AppType.caption.copyWith(
                            color: const Color(AppColors.danger),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: AppSpace.x4),
                Text(
                  'v${info.version}',
                  style: AppType.display.copyWith(
                    fontSize: 38,
                    letterSpacing: -1.4,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  [
                    if (info.build > 0) 'build ${info.build}',
                    if (info.packageSize.isNotEmpty) info.packageSize,
                    if (info.publishedAtText.isNotEmpty) info.publishedAtText,
                  ].join('  ·  '),
                  style: AppType.caption,
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpace.x4),
          if (widget.force) ...[
            Container(
              padding: const EdgeInsets.all(AppSpace.x3),
              decoration: BoxDecoration(
                color: const Color(AppColors.warning).withValues(alpha: 0.08),
                borderRadius: AppRadius.rMd,
                border: Border.all(
                  color: const Color(AppColors.warning).withValues(alpha: 0.2),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.lock_clock_rounded,
                    size: 18,
                    color: Color(AppColors.warning),
                  ),
                  const SizedBox(width: AppSpace.x2),
                  Expanded(
                    child: Text(
                      '这是一次强制更新。完成更新前，当前版本将无法继续使用，请先下载安装新版本。',
                      style: AppType.bodySm.copyWith(
                        color: const Color(AppColors.textSecondary),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpace.x4),
          ],
          Text('更新内容', style: AppType.label),
          const SizedBox(height: AppSpace.x2),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(AppSpace.x3),
            decoration: BoxDecoration(
              color: const Color(AppColors.card),
              borderRadius: AppRadius.rMd,
              border: Border.all(color: const Color(AppColors.border)),
            ),
            child: SelectableText(
              notes,
              style: AppType.bodySm.copyWith(
                color: const Color(AppColors.textSecondary),
                height: 1.65,
              ),
            ),
          ),
          const SizedBox(height: AppSpace.x4),
          Row(
            children: [
              Expanded(
                child: _metaChip('当前', 'v$kAppVersion · build $kAppBuild'),
              ),
              const SizedBox(width: AppSpace.x2),
              const Icon(
                Icons.arrow_forward_rounded,
                size: 16,
                color: Color(AppColors.textTertiary),
              ),
              const SizedBox(width: AppSpace.x2),
              Expanded(child: _metaChip('最新', info.versionLabel)),
            ],
          ),
          const SizedBox(height: AppSpace.x5),
          PillButton(
            label: hasUrl ? (widget.force ? '下载并更新' : '立即更新') : '更新地址暂未配置',
            icon: Icons.arrow_downward_rounded,
            size: PillSize.lg,
            expand: true,
            glow: hasUrl,
            enabled: hasUrl && !_opening,
            loading: _opening,
            onTap: _openDownload,
          ),
          if (hasUrl) ...[
            const SizedBox(height: AppSpace.x2),
            PillButton(
              label: '复制下载链接',
              icon: Icons.link_rounded,
              variant: PillVariant.ghost,
              size: PillSize.lg,
              expand: true,
              onTap: _copyDownload,
            ),
          ],
          if (widget.onLater != null) ...[
            const SizedBox(height: AppSpace.x2),
            PillButton(
              label: '稍后再说',
              variant: PillVariant.ghost,
              size: PillSize.lg,
              expand: true,
              onTap: widget.onLater,
            ),
          ],
          const SizedBox(height: AppSpace.x3),
          Text(
            '下载完成后按系统提示安装。iOS 需通过 TestFlight 或管理员提供的分发页安装；如无法更新，请联系社区管理员。',
            textAlign: TextAlign.center,
            style: AppType.caption.copyWith(
              color: const Color(AppColors.textTertiary),
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _metaChip(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.x3,
        vertical: AppSpace.x2,
      ),
      decoration: BoxDecoration(
        color: const Color(AppColors.card),
        borderRadius: AppRadius.rSm,
        border: Border.all(color: const Color(AppColors.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: AppType.caption),
          const SizedBox(height: 3),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppType.label.copyWith(fontSize: 12.5),
          ),
        ],
      ),
    );
  }
}
