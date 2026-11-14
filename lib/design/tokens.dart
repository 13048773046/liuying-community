/// 流萤社区 · 温润米白设计系统 —— 设计令牌
///
/// 方向：温润米白。米白/暖灰画布、纯白卡片、深墨文字、大留白、极细描边、
/// 一档薄荷绿主色只用于强调（选中/主按钮/进度），层级全靠明度与留白区分。
/// 短视频流与全屏播放页仍走深色沉浸（mediaScrim 保持不变），这是内容形态需要，
/// 不是风格倒退。
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

  // ---- 画布 / 表面（米白体系，靠明度与描边叠层级） ----
  /// 画布：米白（整页主背景）
  static const int bg = 0xFFFAF8F4;

  /// 会话/输入这类需要一点区分的底：比画布沉一档
  static const int canvas = 0xFFF2EFE8;

  /// 卡片：纯白（米白底上最亮的一层）
  static const int card = 0xFFFFFFFF;

  /// 更高一档（弹层、悬浮卡、输入框）
  static const int elevated = 0xFFF7F4EE;

  /// 玻璃层（配合 BackdropFilter，用做底色）
  static const int glass = 0xE6FCFAF6;

  /// 描边（黑色 8%）
  static const int border = 0x14000000;

  /// 更淡的分割线（黑色 6%）
  static const int hairline = 0x0F000000;

  // ---- 文字（深墨体系） ----
  static const int textPrimary = 0xFF1C1B19;
  static const int textSecondary = 0x99000000; // 60%
  static const int textTertiary = 0x61000000; // 38%
  static const int textDisabled = 0x33000000; // 20%

  // ---- 品牌主色：薄荷绿（米白底上压深，保证文字对比度） ----
  static const int accent = 0xFF0E9F76;
  static const int accentPressed = 0xFF0A8462;
  static const int accentSoft = 0xFFE3F5EE; // 选中底色（浅薄荷）
  static const int onAccent = 0xFFFFFFFF; // 主色按钮上的文字（白）

  // ---- 语义色（亮底上整体压深一档） ----
  static const int heart = 0xFFE23A50; // 点赞 / 收藏
  static const int warning = 0xFFDE8A00;
  static const int danger = 0xFFD8392F;
  static const int success = 0xFF0E9F76;
  static const int info = 0xFF2E7BC4;

  // ---- 旧色位（保留兼容：部分页面仍有引用，逐步替换） ----
  static const int lilac = 0xFF7C71B8;
  static const int peach = 0xFFC07A5F;
  static const int sky = 0xFF5A8FB0;

  // ---- 渐变 ----
  static const int gradStart = 0xFF17B98A;
  static const int gradEnd = 0xFF0E9F76;

  // ---- 媒体遮罩：视频/大图上的可读性渐变（媒体页仍深色沉浸，勿改亮） ----
  static const List<int> mediaScrim = [
    0x00000000,
    0x33000000,
    0xB3000000,
    0xE6000000,
  ];

  // ---- 骨架屏 ----
  static const int skeletonBase = 0xFFEAE6DE;
  static const int skeletonHighlight = 0xFFF5F2EB;
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
    fontSize: 32,
    height: 1.2,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.6,
    color: Color(AppColors.textPrimary),
  );

  static const TextStyle h1 = TextStyle(
    fontSize: 25,
    height: 1.25,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.4,
    color: Color(AppColors.textPrimary),
  );

  static const TextStyle h2 = TextStyle(
    fontSize: 19,
    height: 1.3,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.2,
    color: Color(AppColors.textPrimary),
  );

  static const TextStyle title = TextStyle(
    fontSize: 17,
    height: 1.35,
    fontWeight: FontWeight.w600,
    color: Color(AppColors.textPrimary),
  );

  static const TextStyle body = TextStyle(
    fontSize: 15,
    height: 1.55,
    fontWeight: FontWeight.w400,
    color: Color(AppColors.textPrimary),
  );

  static const TextStyle bodySm = TextStyle(
    fontSize: 13.5,
    height: 1.5,
    fontWeight: FontWeight.w400,
    color: Color(AppColors.textSecondary),
  );

  static const TextStyle label = TextStyle(
    fontSize: 13,
    height: 1.3,
    fontWeight: FontWeight.w600,
    color: Color(AppColors.textPrimary),
  );

  static const TextStyle caption = TextStyle(
    fontSize: 12,
    height: 1.35,
    fontWeight: FontWeight.w500,
    color: Color(AppColors.textTertiary),
  );

  static const TextStyle micro = TextStyle(
    fontSize: 11,
    height: 1.3,
    fontWeight: FontWeight.w500,
    color: Color(AppColors.textTertiary),
  );

  /// 数字/统计用的等宽数字样式（点赞数、时长）
  static const TextStyle numeric = TextStyle(
    fontSize: 12,
    height: 1.2,
    fontWeight: FontWeight.w500,
    color: Color(AppColors.textSecondary),
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
// 阴影 / 渐变（米白底上靠极淡投影与描边分层，不用光晕）
// ============================================================================
class AppEffects {
  const AppEffects._();

  /// 主按钮的薄荷光晕（亮底只留极淡一层，避免脏边）
  static List<BoxShadow> accentGlow({double opacity = 0.16}) => [
        BoxShadow(
          color: const Color(AppColors.accent).withValues(alpha: opacity),
          blurRadius: 14,
          offset: const Offset(0, 4),
        ),
      ];

  /// 浮层投影（弹层/悬浮卡）
  static const List<BoxShadow> overlay = [
    BoxShadow(color: Color(0x14000000), blurRadius: 24, offset: Offset(0, 8)),
  ];

  /// 卡片投影（列表卡片的轻微抬升）
  static const List<BoxShadow> cardShadow = [
    BoxShadow(color: Color(0x0A000000), blurRadius: 10, offset: Offset(0, 2)),
  ];

  /// 媒体页顶部渐变（深色，保证视频上的白字可读）
  static LinearGradient topScrim({double height = 0.28}) => LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          const Color(0xB3000000),
          const Color(0x00000000),
        ],
        stops: [0, height],
      );

  /// 媒体页底部渐变（深色，保证视频上的白字可读）
  static LinearGradient bottomScrim({double start = 0.45}) => LinearGradient(
        begin: Alignment.bottomCenter,
        end: Alignment.topCenter,
        colors: [
          const Color(0xF2000000),
          const Color(0x00000000),
        ],
        stops: [0, 1 - start],
      );

  /// 底部导航栏贴边渐变 · 内容页（米白，内容穿过导航栏时收口）
  static const LinearGradient navScrim = LinearGradient(
    begin: Alignment.bottomCenter,
    end: Alignment.topCenter,
    colors: [Color(0xF7FAF8F4), Color(0x00FAF8F4)],
    stops: [0.4, 1],
  );

  /// 底部导航栏贴边渐变 · 沉浸页（短视频页，黑）
  static const LinearGradient navScrimDark = LinearGradient(
    begin: Alignment.bottomCenter,
    end: Alignment.topCenter,
    colors: [Color(0xF2000000), Color(0x00000000)],
    stops: [0.35, 1],
  );
}

// ============================================================================
// 全局 ThemeData（温润米白）
// ============================================================================
ThemeData buildWarmTheme() {
  const scheme = ColorScheme.light(
    primary: Color(AppColors.accent),
    onPrimary: Color(AppColors.onAccent),
    secondary: Color(AppColors.accent),
    surface: Color(AppColors.card),
    onSurface: Color(AppColors.textPrimary),
    error: Color(AppColors.danger),
    onError: Color(AppColors.onAccent),
    outline: Color(AppColors.border),
  );

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    colorScheme: scheme,
    scaffoldBackgroundColor: const Color(AppColors.bg),
    canvasColor: const Color(AppColors.bg),
    splashFactory: InkRipple.splashFactory,
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
      systemOverlayStyle: SystemUiOverlayStyle.dark,
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: Color(AppColors.bg),
      surfaceTintColor: Colors.transparent,
      modalBackgroundColor: Color(AppColors.bg),
      modalBarrierColor: Color(0x66000000),
      shape: RoundedRectangleBorder(borderRadius: AppRadius.sheetTop),
      showDragHandle: false,
      elevation: 0,
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: Color(AppColors.card),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: AppRadius.rLg),
      titleTextStyle: AppType.h2,
      contentTextStyle: AppType.bodySm,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: const Color(AppColors.textPrimary),
      contentTextStyle: AppType.bodySm.copyWith(
        color: const Color(0xFFFAF8F4),
      ),
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
      fillColor: const Color(AppColors.canvas),
      hintStyle: AppType.bodySm.copyWith(
        color: const Color(AppColors.textTertiary),
      ),
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
            : const Color(AppColors.card),
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected)
            ? const Color(AppColors.accent).withValues(alpha: 0.85)
            : const Color(AppColors.border),
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
      checkColor: const WidgetStatePropertyAll(Color(AppColors.onAccent)),
      side: const BorderSide(color: Color(AppColors.border)),
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
