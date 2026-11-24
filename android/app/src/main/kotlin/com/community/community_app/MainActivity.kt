package com.community.community_app

import android.app.AlertDialog
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Debug
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.security.MessageDigest

class MainActivity : FlutterActivity() {
    private val secureScreenChannel = "com.community.community_app/secure_screen"
    private val apkInspectChannel = "com.community.community_app/apk_inspect"

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (BuildConfig.DEBUG) return
        // 运行时校验 APK 签名证书：二次打包/替换 so 后用其他证书重签会在这里被拦住。
        if (!signatureMatches()) {
            AlertDialog.Builder(this)
                .setTitle("安装包校验失败")
                .setMessage("当前安装包签名与官方版本不一致，可能被篡改或二次打包。请从官方渠道重新下载安装。")
                .setCancelable(false)
                .setPositiveButton("退出") { _, _ -> finishAffinity() }
                .show()
            return
        }
        if (Debug.isDebuggerConnected()) {
            // 调试器附加时立即退出，降低动态脱壳/抓 token 的可行性。
            finishAffinity()
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 登录、设置、支付、AI 工作台等敏感页面打开时由 Dart 侧调用。
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            secureScreenChannel,
        ).setMethodCallHandler { call, result ->
            if (call.method != "setSecure") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val secure = call.arguments as? Boolean ?: false
            if (secure) {
                window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
            } else {
                window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
            }
            result.success(null)
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            apkInspectChannel,
        ).setMethodCallHandler { call, result ->
            if (call.method != "inspect") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val path = call.arguments as? String ?: ""
            if (path.isBlank()) {
                result.error("bad_path", "安装包路径为空", null)
                return@setMethodCallHandler
            }
            try {
                val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    PackageManager.GET_SIGNING_CERTIFICATES
                } else {
                    @Suppress("DEPRECATION")
                    PackageManager.GET_SIGNATURES
                }
                val info = packageManager.getPackageArchiveInfo(path, flags)
                if (info == null) {
                    result.error("invalid_apk", "无法解析安装包", null)
                    return@setMethodCallHandler
                }
                val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    info.signingInfo?.apkContentsSigners ?: emptyArray()
                } else {
                    @Suppress("DEPRECATION")
                    info.signatures ?: emptyArray()
                }
                val digest = MessageDigest.getInstance("SHA-256")
                val sigs = signatures.map { sig ->
                    digest.digest(sig.toByteArray())
                        .joinToString("") { "%02x".format(it) }
                }
                result.success(mapOf(
                    "packageName" to (info.packageName ?: ""),
                    "versionCode" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                        info.longVersionCode
                    } else {
                        @Suppress("DEPRECATION")
                        info.versionCode.toLong()
                    },
                    "signatures" to sigs,
                ))
            } catch (e: Exception) {
                result.error("inspect_failed", e.message ?: "读取安装包失败", null)
            }
        }
    }

    private fun signatureMatches(): Boolean {
        val expected = BuildConfig.EXPECTED_SIGNATURE_SHA256
            .replace(":", "").lowercase().trim()
        if (expected.isEmpty()) return true
        return try {
            val pm = packageManager
            val info = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                pm.getPackageInfo(packageName, PackageManager.GET_SIGNING_CERTIFICATES)
            } else {
                @Suppress("DEPRECATION")
                pm.getPackageInfo(packageName, PackageManager.GET_SIGNATURES)
            }
            val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                info.signingInfo?.apkContentsSigners ?: emptyArray()
            } else {
                @Suppress("DEPRECATION")
                info.signatures ?: emptyArray()
            }
            // 官方包只允许一个签名者；多签名包即使第一个证书匹配也拒绝。
            if (signatures.size != 1) return false
            val digest = MessageDigest.getInstance("SHA-256")
            val actual = digest.digest(signatures[0].toByteArray())
                .joinToString("") { "%02x".format(it) }
            actual == expected
        } catch (_: Exception) {
            false
        }
    }
}
