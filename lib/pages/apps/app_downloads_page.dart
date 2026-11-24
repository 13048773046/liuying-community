/// 我的下载：本地应用安装包列表。
///
/// 下载任务由 [AppDownloadManager] 持有，退出详情页/列表页不会中断；这里读取
/// 本地落盘记录，并把正在下载的任务进度合并进来。页面不依赖后端接口。
library;

import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../api/app_market_api.dart';
import '../../design/components.dart';
import '../../services/app_download_manager.dart';
import 'app_market_page.dart';

class AppDownloadsPage extends StatefulWidget {
  const AppDownloadsPage({super.key});

  @override
  State<AppDownloadsPage> createState() => _AppDownloadsPageState();
}

class _AppDownloadsPageState extends State<AppDownloadsPage> {
  List<AppDownloadRecord> _records = const [];
  bool _loaded = false;
  bool _refreshing = false;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    AppDownloadManager.I.revision.addListener(_onRevision);
    _refresh();
    _ticker = Timer.periodic(const Duration(seconds: 2), (_) {
      if (mounted) _refresh(silent: true);
    });
  }

  @override
  void dispose() {
    AppDownloadManager.I.revision.removeListener(_onRevision);
    _ticker?.cancel();
    super.dispose();
  }

  void _onRevision() {
    if (mounted) _refresh(silent: true);
  }

  Future<void> _refresh({bool silent = false}) async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      final list = await AppDownloadManager.I.listRecords();
      if (!mounted) return;
      setState(() {
        _records = list;
        _loaded = true;
      });
    } catch (_) {
      if (!mounted) return;
      if (!silent) setState(() => _loaded = true);
    } finally {
      _refreshing = false;
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _open(AppDownloadRecord r) async {
    final error = await AppDownloadManager.I.openRecord(r);
    if (error != null) _toast(error);
  }

  Future<void> _share(AppDownloadRecord r) async {
    await AppDownloadManager.I.shareRecord(r);
  }

  Future<void> _delete(AppDownloadRecord r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(AppColors.card),
        title: const Text('删除本地安装包？', style: AppType.title),
        content: Text(
          '《${r.appName}》的本地文件会被删除，之后需要重新下载。',
          style: AppType.bodySm,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              '删除',
              style: TextStyle(color: Color(AppColors.danger)),
            ),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await AppDownloadManager.I.deleteRecord(r.appId);
    _refresh();
  }

  void _resume(AppDownloadRecord r) {
    unawaited(AppDownloadManager.I.resumeRecord(r));
    _refresh(silent: true);
  }

  void _pause(AppDownloadRecord r) {
    AppDownloadManager.I.pause(r.appId);
    _refresh(silent: true);
  }

  Future<void> _cancel(AppDownloadRecord r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(AppColors.card),
        title: const Text('取消这次下载？', style: AppType.title),
        content: const Text('已下载的临时文件会被清理，之后可以重新开始。', style: AppType.bodySm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('继续下载'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              '取消下载',
              style: TextStyle(color: Color(AppColors.danger)),
            ),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await AppDownloadManager.I.cancel(r.appId);
    _refresh(silent: true);
  }

  @override
  Widget build(BuildContext context) {
    final totalBytes = _records.fold<int>(0, (sum, e) => sum + e.receivedBytes);
    final done = _records.where((e) => e.isDone).length;
    return ImmersivePage(
      child: Column(
        children: [
          GlassTopBar(
            title: '下载列表',
            subtitle: _loaded && _records.isNotEmpty
                ? '${_records.length} 个应用 · $done 个已完成'
                : '离线安装包',
            solid: true,
            actions: [
              IconCircleButton(
                icon: Icons.refresh_rounded,
                size: 36,
                iconSize: 18,
                background: Colors.transparent,
                onTap: _refresh,
              ),
            ],
          ),
          Expanded(child: _body(totalBytes, done)),
        ],
      ),
    );
  }

  Widget _body(int totalBytes, int done) {
    if (!_loaded) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: const [
          SkeletonBox(height: 78, radius: 16),
          SizedBox(height: 10),
          SkeletonBox(height: 78, radius: 16),
          SizedBox(height: 10),
          SkeletonBox(height: 78, radius: 16),
        ],
      );
    }
    if (_records.isEmpty) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          EmptyState(
            icon: Icons.download_for_offline_outlined,
            title: '还没有下载过应用',
            message: '在应用市场下载的安装包会保存在这里，支持断点续传和本地打开。',
            actionLabel: '去应用市场',
            onAction: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const AppMarketPage()),
            ),
          ),
        ],
      );
    }
    return RefreshIndicator(
      color: const Color(AppColors.accent),
      backgroundColor: const Color(AppColors.card),
      onRefresh: _refresh,
      child: ListView(
        padding: EdgeInsets.fromLTRB(
          AppSpace.gutter,
          8,
          AppSpace.gutter,
          MediaQuery.paddingOf(context).bottom + 28,
        ),
        children: [
          _summary(totalBytes, done),
          const SizedBox(height: AppSpace.x3),
          for (final r in _records) ...[
            _DownloadCard(
              record: r,
              onOpen: () => _open(r),
              onShare: () => _share(r),
              onDelete: () => _delete(r),
              onResume: () => _resume(r),
              onPause: () => _pause(r),
              onCancel: () => _cancel(r),
            ),
            const SizedBox(height: AppSpace.x2),
          ],
        ],
      ),
    );
  }

  Widget _summary(int totalBytes, int done) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: const Color(AppColors.card).withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: const Color(AppColors.border)),
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: const Color(AppColors.accent).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(
              Icons.offline_bolt_outlined,
              size: 18,
              color: Color(AppColors.accent),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('本地安装包', style: AppType.label),
                const SizedBox(height: 2),
                Text(
                  '已完成 $done 个 · 共占用 ${_bytes(totalBytes)}',
                  style: AppType.caption.copyWith(fontSize: 11.5),
                ),
              ],
            ),
          ),
          Text(
            '${_records.length} 个',
            style: AppType.caption.copyWith(
              color: const Color(AppColors.accent),
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  static String _bytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }
}

class _DownloadCard extends StatelessWidget {
  const _DownloadCard({
    required this.record,
    required this.onOpen,
    required this.onShare,
    required this.onDelete,
    required this.onResume,
    required this.onPause,
    required this.onCancel,
  });

  final AppDownloadRecord record;
  final VoidCallback onOpen;
  final VoidCallback onShare;
  final VoidCallback onDelete;
  final VoidCallback onResume;
  final VoidCallback onPause;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final active = record.isActive;
    final done = record.isDone;
    final failed = record.status == AppDownloadStatus.failed;
    final statusColor = done
        ? const Color(AppColors.accent)
        : failed
        ? const Color(AppColors.warning)
        : record.status == AppDownloadStatus.paused
        ? const Color(AppColors.textSecondary)
        : const Color(AppColors.accent);
    final subtitle = [
      if (record.versionName.isNotEmpty) 'v${record.versionName}',
      if (record.platform.isNotEmpty) record.platform.toUpperCase(),
      if (record.packageType.isNotEmpty) record.packageType.toUpperCase(),
    ].join(' · ');
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      decoration: BoxDecoration(
        color: const Color(AppColors.card).withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: const Color(AppColors.border)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              _icon(record),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      record.appName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.title.copyWith(fontSize: 16),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle.isEmpty ? record.fileName : subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.caption.copyWith(fontSize: 11.5),
                    ),
                    const SizedBox(height: 5),
                    Row(
                      children: [
                        Container(
                          width: 5,
                          height: 5,
                          decoration: BoxDecoration(
                            color: statusColor,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 5),
                        Text(
                          _statusText(record),
                          style: AppType.caption.copyWith(
                            fontSize: 11.5,
                            color: statusColor,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (record.totalBytes > 0) ...[
                          const SizedBox(width: 8),
                          Text(
                            _DownloadListBytes.of(record.receivedBytes),
                            style: AppType.caption.copyWith(fontSize: 11),
                          ),
                        ],
                      ],
                    ),
                    if (active || failed) ...[
                      const SizedBox(height: 8),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(99),
                        child: LinearProgressIndicator(
                          minHeight: 3,
                          value: active
                              ? (record.totalBytes > 0 ? record.progress : null)
                              : (record.totalBytes > 0 ? record.progress : 0),
                          backgroundColor: Colors.white.withValues(alpha: 0.08),
                          valueColor: AlwaysStoppedAnimation<Color>(
                            failed
                                ? const Color(AppColors.warning)
                                : statusColor,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _trailing(done: done, active: active, failed: failed),
            ],
          ),
          if (failed && record.error.isNotEmpty) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                record.error,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppType.micro.copyWith(
                  fontSize: 11,
                  color: const Color(AppColors.warning),
                  height: 1.35,
                ),
              ),
            ),
          ],
          if (!active) ...[
            const SizedBox(height: 10),
            const Divider(height: 1, color: Color(AppColors.hairline)),
            const SizedBox(height: 5),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (done) ...[
                  _textAction(context, '打开', onOpen, primary: true),
                  _textAction(context, '分享', onShare),
                ] else ...[
                  _textAction(
                    context,
                    failed ? '重试' : '继续下载',
                    onResume,
                    primary: true,
                  ),
                ],
                _textAction(context, '删除', onDelete, danger: true),
              ],
            ),
          ] else ...[
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                _textAction(context, '暂停', onPause),
                _textAction(context, '取消', onCancel, danger: true),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _trailing({
    required bool done,
    required bool active,
    required bool failed,
  }) {
    if (active) {
      return SizedBox(
        width: 34,
        height: 34,
        child: Center(
          child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(
                const Color(AppColors.accent),
              ),
            ),
          ),
        ),
      );
    }
    return Icon(
      done
          ? Icons.check_circle_rounded
          : failed
          ? Icons.error_outline_rounded
          : Icons.pause_circle_outline_rounded,
      size: 20,
      color: done
          ? const Color(AppColors.accent)
          : failed
          ? const Color(AppColors.warning)
          : const Color(AppColors.textTertiary),
    );
  }

  Widget _textAction(
    BuildContext context,
    String label,
    VoidCallback onTap, {
    bool primary = false,
    bool danger = false,
  }) {
    final family = Theme.of(context).textTheme.bodyMedium?.fontFamily;
    return TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        foregroundColor: danger
            ? const Color(AppColors.danger)
            : primary
            ? const Color(AppColors.accent)
            : const Color(AppColors.textSecondary),
        minimumSize: const Size(0, 32),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        textStyle: AppType.caption.copyWith(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          fontFamily: family,
        ),
      ),
      child: Text(label),
    );
  }

  Widget _icon(AppDownloadRecord r) {
    final fallback = Container(
      width: 54,
      height: 54,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1B6B52), Color(0xFF0C1714)],
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        r.appName.isEmpty ? '?' : r.appName.characters.first,
        style: const TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w800,
          color: Color(AppColors.textPrimary),
        ),
      ),
    );
    if (r.appIcon.isEmpty) return fallback;
    final url = AppMarketApi.mediaPathToUrl(r.appIcon);
    if (url.isEmpty) return fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: CachedNetworkImage(
        imageUrl: url,
        width: 54,
        height: 54,
        fit: BoxFit.cover,
        placeholder: (_, _) => fallback,
        errorWidget: (_, _, _) => fallback,
      ),
    );
  }

  String _statusText(AppDownloadRecord r) {
    switch (r.status) {
      case AppDownloadStatus.idle:
        return '待下载';
      case AppDownloadStatus.resolving:
        return '正在解析下载地址';
      case AppDownloadStatus.downloading:
        return '下载中';
      case AppDownloadStatus.paused:
        return '已暂停';
      case AppDownloadStatus.completed:
        return '下载完成';
      case AppDownloadStatus.failed:
        return '下载未完成';
      case AppDownloadStatus.installing:
        return '等待系统安装';
    }
  }
}

class _DownloadListBytes {
  static String of(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }
}
