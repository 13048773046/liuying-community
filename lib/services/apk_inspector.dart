/// Android APK 下载后的包身份校验。
///
/// 应用市场是 UGC 分发，不能让一个“扩展名为 .apk”的任意文件直接交给系统安装器。
/// 原生侧用 PackageManager 读取 APK 的包名/版本/签名证书；Dart 侧至少校验：
/// 1. 文件确实能被 Android 解析成 APK；
/// 2. APK 已签名；
/// 3. 包名与投稿元数据一致（有填写时）。
library;

import 'package:flutter/services.dart';

class ApkInspection {
  final String packageName;
  final int versionCode;
  final List<String> signatureSha256;

  const ApkInspection({
    required this.packageName,
    required this.versionCode,
    required this.signatureSha256,
  });

  bool get isSigned => signatureSha256.isNotEmpty;
}

class ApkInspector {
  ApkInspector._();

  static const _channel = MethodChannel(
    'com.community.community_app/apk_inspect',
  );

  static Future<ApkInspection> inspect(String path) async {
    final map = await _channel.invokeMapMethod<String, dynamic>(
      'inspect',
      path,
    );
    if (map == null) throw const ApkInspectionException('无法读取安装包信息');
    final pkg = (map['packageName'] ?? '').toString();
    final sigs = ((map['signatures'] ?? const []) as List)
        .map((e) => e.toString().toLowerCase())
        .where((e) => e.isNotEmpty)
        .toList();
    if (pkg.isEmpty) throw const ApkInspectionException('安装包没有有效包名');
    if (sigs.isEmpty) throw const ApkInspectionException('安装包未签名，已阻断');
    return ApkInspection(
      packageName: pkg,
      versionCode: (map['versionCode'] as num?)?.toInt() ?? 0,
      signatureSha256: sigs,
    );
  }

  static Future<void> verify(
    String path, {
    String expectedPackage = '',
  }) async {
    final info = await inspect(path);
    final expected = expectedPackage.trim();
    if (expected.isNotEmpty && info.packageName != expected) {
      throw ApkInspectionException(
        '安装包包名 ${info.packageName} 与投稿信息 $expected 不一致，已阻断',
      );
    }
  }
}

class ApkInspectionException implements Exception {
  final String message;
  const ApkInspectionException(this.message);
  @override
  String toString() => message;
}
