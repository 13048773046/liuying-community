/// 流萤社区 · 沉浸黑设计系统 —— 设计令牌
///
/// 方向：抖音式沉浸黑。纯黑画布、全幅媒体、玻璃浮层、极简描边、大字号标题、
/// 一档薄荷绿主色只用于强调（进度/选中/主按钮），其余全靠黑白灰层级。
///
/// 约定：
/// - 颜色一律用 `static const int`（保持 `Color(AppColors.x)` 的 const 可用性，
///   旧代码里大量 `Color(AppTheme.bg)` 依赖这一点）。
/// - 字号/字重/行高集中在 [AppType]，间距在 [AppSpace]，圆角在 [AppRadius]，
///   动效时长/曲线在 [AppMotion] —— 页面里不要写字面量。
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// ============================================================================
// 颜色
// ============================================================================
class AppColors {
  const AppColors._();

  // ---- 画布 / 表面（纯黑体系，靠白色透明度叠层级） ----
  /// 画布：纯黑（沉浸模式的主背景）
  static const int bg = 0xFF000000;

  /// 会话/输入这类需要一点区分的底：比纯黑亮一档
  static const int canvas = 0xFF070708;

  /// 卡片浮层（黑底上极浅的抬升）
  static const int card = 0xFF101012;

  /// 更高一档（弹层、悬浮卡、输入框）
  static const int elevated = 0xFF17171A;

  /// 玻璃层（配合 BackdropFilter，用做底色）
  static const int glass = 0xCC0A0A0B;

  /// 描边（白色 8%）
  static const int border = 0x14FFFFFF;

  /// 更淡的分割线（白色 5%）
  static const int hairline = 0x0DFFFFFF;

  // ---- 文字 ----
  static const int textPrimary = 0xFFFFFFFF;
  static const int textSecondary = 0xB3FFFFFF; // 70%
  static const int textTertiary = 0x73FFFFFF; // 45%
  static const int textDisabled = 0x40FFFFFF; // 25%

  // ---- 品牌主色：薄荷绿（黑底上提亮一档，保证对比度） ----
  static const int accent = 0xFF45E0AE;
  static const int accentPressed = 0xFF33C597;
  static const int accentSoft = 0xFF0E2A22; // 选中底色（深色）
  static const int onAccent = 0xFF04120D; // 主色按钮上的文字（近黑）

  // ---- 语义色 ----
  static const int heart = 0xFFFF3B5C; // 点赞 / 收藏（抖音红）
  static const int warning = 0xFFFFB020;
  static const int danger = 0xFFFF4D4F;
  static const int success = 0xFF45E0AE;
  static const int info = 0xFF5AA9FF;

  // ---- 旧色位（保留兼容：部分页面仍有引用，逐步替换） ----
  static const int lilac = 0xFF8F84C7;
  static const int peach = 0xFFC98870;
  static const int sky = 0xFF6FA3C9;

  // ---- 渐变 ----
  static const int gradStart = 0xFF45E0AE;
  static const int gradEnd = 0xFF2BA98B;

  // ---- 媒体遮罩：视频/大图上的可读性渐变 ----
  static const List<int> mediaScrim = [
    0x00000000,
    0x33000000,
    0xB3000000,
    0xE6000000,
  ];

  // ---- 骨架屏 ----
  static const int skeletonBase = 0xFF17171A;
  static const int skeletonHighlight = 0xFF232327;
}

// ============================================================================
// 圆角
// ============================================================================
class AppRadius {
  const AppRadius._();

  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 20;
  static const double xl = 28;
  static const double pill = 999;

  static const BorderRadius rXs = BorderRadius.all(Radius.circular(xs));
  static const BorderRadius rSm = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius rMd = BorderRadius.all(Radius.circular(md));
  static const BorderRadius rLg = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius rXl = BorderRadius.all(Radius.circular(xl));
  static const BorderRadius rPill = BorderRadius.all(Radius.circular(pill));

  static const BorderRadius sheetTop = BorderRadius.vertical(
    top: Radius.circular(24),
  );
}

// ============================================================================
// 间距（4 的倍数）
// ============================================================================
class AppSpace {
  const AppSpace._();

  static const double x1 = 4;
  static const double x2 = 8;
  static const double x3 = 12;
  static const double x4 = 16;
  static const double x5 = 20;
  static const double x6 = 24;
  static const double x7 = 32;
  static const double x8 = 40;

  /// 页面左右安全边距（社区内容统一 16）
  static const double gutter = 16;

  /// 列表项之间的呼吸
  static const double listGap = 12;
}

// ============================================================================
// 字阶
// ============================================================================
class AppType {
  const AppType._();

  static const TextStyle display = TextStyle(
    fontSize: 34,
    height: 1.15,
    fontWeight: FontWeight.w800,
    letterSpacing: -0.9,
    color: Color(AppColors.textPrimary),
  );

  static const TextStyle h1 = TextStyle(
    fontSize: 26,
    height: 1.2,
    fontWeight: FontWeight.w800,
    letterSpacing: -0.5,
    color: Color(AppColors.textPrimary),
  );

  static const TextStyle h2 = TextStyle(
    fontSize: 20,
    height: 1.25,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.2,
    color: Color(AppColors.textPrimary),
  );

  static const TextStyle title = TextStyle(
    fontSize: 17,
    height: 1.3,
    fontWeight: FontWeight.w600,
    color: Color(AppColors.textPrimary),
  );

  static const TextStyle body = TextStyle(
    fontSize: 15,
    height: 1.45,
    fontWeight: FontWeight.w400,
    color: Color(AppColors.textPrimary),
  );

  static const TextStyle bodySm = TextStyle(
    fontSize: 13.5,
    height: 1.4,
    fontWeight: FontWeight.w400,
    color: Color(AppColors.textSecondary),
  );

  static const TextStyle label = TextStyle(
    fontSize: 13,
    height: 1.25,
    fontWeight: FontWeight.w600,
    color: Color(AppColors.textPrimary),
  );

  static const TextStyle caption = TextStyle(
    fontSize: 12,
    height: 1.3,
    fontWeight: FontWeight.w500,
    color: Color(AppColors.textTertiary),
  );

  static const TextStyle micro = TextStyle(
    fontSize: 11,
    height: 1.25,
    fontWeight: FontWeight.w500,
    color: Color(AppColors.textTertiary),
  );

  /// 数字/统计用的等宽数字样式（点赞数、时长）
  static const TextStyle numeric = TextStyle(
    fontSize: 12,
    height: 1.2,
    fontWeight: FontWeight.w600,
    color: Color(AppColors.textPrimary),
    fontFeatures: [FontFeature.tabularFigures()],
  );
}

// ============================================================================
// 动效
// ============================================================================
class AppMotion {
  const AppMotion._();

  static const Duration fast = Duration(milliseconds: 140);
  static const Duration base = Duration(milliseconds: 200);
  static const Duration slow = Duration(milliseconds: 320);
  static const Duration page = Duration(milliseconds: 260);

  static const Curve standard = Curves.easeOutCubic;
  static const Curve emphasized = Curves.easeOutQuint;
  static const Curve enter = Curves.easeOut;
  static const Curve exit = Curves.easeIn;
}

// ============================================================================
// 阴影 / 光晕（黑底上少用阴影，多用光晕与描边）
// ============================================================================
class AppEffects {
  const AppEffects._();

  /// 主按钮的薄荷光晕
  static List<BoxShadow> accentGlow({double opacity = 0.35}) => [
        BoxShadow(
          color: const Color(AppColors.accent).withValues(alpha: opacity),
          blurRadius: 18,
          spreadRadius: 1,
        ),
      ];

  /// 浮层投影（弹层/悬浮卡）
  static const List<BoxShadow> overlay = [
    BoxShadow(color: Color(0x99000000), blurRadius: 28, offset: Offset(0, 12)),
  ];

  /// 顶/底媒体渐变（黑底上的可读性）
  static LinearGradient topScrim({double height = 0.28}) => LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          const Color(0xB3000000),
          const Color(0x00000000),
        ],
        stops: [0, height],
      );

  static LinearGradient bottomScrim({double start = 0.45}) => LinearGradient(
        begin: Alignment.bottomCenter,
        end: Alignment.topCenter,
        colors: [
          const Color(0xF2000000),
          const Color(0x00000000),
        ],
        stops: [0, 1 - start],
      );

  /// 底部导航栏的贴边渐变（内容穿过导航栏时用）
  static const LinearGradient navScrim = LinearGradient(
    begin: Alignment.bottomCenter,
    end: Alignment.topCenter,
    colors: [Color(0xF2000000), Color(0x00000000)],
    stops: [0.35, 1],
  );
}

// ============================================================================
// 全局 ThemeData
// ============================================================================
ThemeData buildImmersiveTheme() {
  const scheme = ColorScheme.dark(
    primary: Color(AppColors.accent),
    onPrimary: Color(AppColors.onAccent),
    secondary: Color(AppColors.accent),
    surface: Color(AppColors.bg),
    onSurface: Color(AppColors.textPrimary),
    error: Color(AppColors.danger),
    onError: Color(AppColors.textPrimary),
    outline: Color(AppColors.border),
  );

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: const Color(AppColors.bg),
    canvasColor: const Color(AppColors.bg),
    splashFactory: InkSparkle.splashFactory,
    fontFamily: null,
    textTheme: const TextTheme(
      displayLarge: AppType.display,
      headlineLarge: AppType.h1,
      headlineSmall: AppType.h2,
      titleMedium: AppType.title,
      bodyLarge: AppType.body,
      bodyMedium: AppType.bodySm,
      labelLarge: AppType.label,
      bodySmall: AppType.caption,
      labelSmall: AppType.micro,
    ).apply(
      bodyColor: const Color(AppColors.textPrimary),
      displayColor: const Color(AppColors.textPrimary),
    ),
    // 顶部/底部栏透明，由页面自己控制玻璃层
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: AppType.h2,
      iconTheme: IconThemeData(color: Color(AppColors.textPrimary), size: 22),
      systemOverlayStyle: SystemUiOverlayStyle.light,
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: Color(AppColors.canvas),
      surfaceTintColor: Colors.transparent,
      modalBackgroundColor: Color(AppColors.canvas),
      modalBarrierColor: Color(0xCC000000),
      shape: RoundedRectangleBorder(borderRadius: AppRadius.sheetTop),
      showDragHandle: false,
      elevation: 0,
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: Color(AppColors.elevated),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: AppRadius.rLg),
      titleTextStyle: AppType.h2,
      contentTextStyle: AppType.bodySm,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: const Color(AppColors.elevated),
      contentTextStyle: AppType.bodySm,
      behavior: SnackBarBehavior.floating,
      shape: const RoundedRectangleBorder(borderRadius: AppRadius.rPill),
    ),
    dividerTheme: const DividerThemeData(
      color: Color(AppColors.hairline),
      thickness: 0.5,
      space: 0.5,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: const Color(AppColors.elevated),
      hintStyle: AppType.bodySm.copyWith(color: const Color(AppColors.textTertiary)),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSpace.x4,
        vertical: AppSpace.x3,
      ),
      border: OutlineInputBorder(
        borderRadius: AppRadius.rPill,
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: AppRadius.rPill,
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: AppRadius.rPill,
        borderSide: const BorderSide(color: Color(AppColors.accent), width: 1),
      ),
    ),
    iconTheme: const IconThemeData(color: Color(AppColors.textPrimary), size: 22),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: Color(AppColors.accent),
      linearTrackColor: Color(AppColors.hairline),
      circularTrackColor: Color(AppColors.hairline),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected)
            ? const Color(AppColors.accent)
            : const Color(AppColors.textTertiary),
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected)
            ? const Color(AppColors.accent).withValues(alpha: 0.28)
            : const Color(AppColors.hairline),
      ),
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected)
            ? const Color(AppColors.accent)
            : const Color(AppColors.textTertiary),
      ),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected)
            ? const Color(AppColors.accent)
            : Colors.transparent,
      ),
      side: const BorderSide(color: Color(AppColors.textTertiary)),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: FadeUpwardsPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      },
    ),
  );
}
