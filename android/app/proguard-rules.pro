# 流萤社区 Android Release R8 规则
# Flutter/插件大量使用运行时反射与 JNI，保留插件入口与安全存储实现，避免混淆后崩溃。

-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-keep class com.community.community_app.** { *; }
-keep class com.it_nomads.fluttersecurestorage.** { *; }
-keep class androidx.security.crypto.** { *; }
-keep class androidx.security.crypto.MasterKey { *; }
-keep class androidx.security.crypto.EncryptedSharedPreferences { *; }

# flutter_secure_storage / Tink 的反射与 Provider
-keep class com.google.crypto.tink.** { *; }
-dontwarn com.google.crypto.tink.**
-dontwarn org.bouncycastle.**

# 文件选择、分享、打开安装器等通过 Intent/反射回传
-keep class io.flutter.plugins.filepicker.** { *; }
-keep class io.flutter.plugins.share.** { *; }
-keep class io.flutter.plugins.openfilex.** { *; }
-keep class io.flutter.plugins.imagepicker.** { *; }
-keep class io.flutter.plugins.videoplayer.** { *; }
-keep class io.flutter.plugins.pathprovider.** { *; }

# Kotlin/Android 基础
-keepattributes *Annotation*, Signature, InnerClasses, EnclosingMethod
-dontwarn kotlin.**

# Flutter 引擎自带 Play Store deferred components 引用；本应用不使用动态特性，
# 不引入 play-core，仅让 R8 忽略这些不可达的缺失类。
-dontwarn com.google.android.play.core.**
-dontwarn io.flutter.embedding.engine.deferredcomponents.**
