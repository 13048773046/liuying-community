/// 输入面板宿主（抖音/小红书/QQ 式丝滑切换）
///
/// 借鉴成熟实现：输入栏固定在底部，键盘与功能面板只占据底部同一块空间。
/// 关键机制：
///  - 打开面板瞬间锁定键盘高度，面板高度与键盘一致，输入栏位置稳定不动
///  - 隐藏键盘用 TextInput.hide（保留输入框焦点与光标），不用 unfocus
///  - 键盘退场/升起期间用背景色占位，不透出后面内容
///  - [panel] 为 null 表示键盘态；非 null 显示自定义面板（表情/图片/好友等）
library;

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class InputPanelHost extends StatefulWidget {
  const InputPanelHost({
    super.key,
    required this.inputBar,
    this.panel,
    this.surfaceColor,
    this.fallbackHeight = 260,
  });

  /// 输入栏（固定在面板/键盘上方，位置不动）
  final Widget inputBar;

  /// 当前要显示的自定义面板；null = 键盘态
  final Widget? panel;

  /// 面板/占位背景色（与输入栏背景一致，避免键盘升起时透出内容）
  final Color? surfaceColor;

  /// 无键盘历史时面板兜底高度
  final double fallbackHeight;

  @override
  State<InputPanelHost> createState() => _InputPanelHostState();
}

class _InputPanelHostState extends State<InputPanelHost> {
  double? _lockedHeight;

  @override
  void didUpdateWidget(covariant InputPanelHost old) {
    super.didUpdateWidget(old);
    final oldPanel = old.panel;
    final newPanel = widget.panel;
    if (newPanel != null && oldPanel == null) {
      // 键盘态 → 面板态：锁定高度 + 隐藏系统键盘（保留焦点）
      final insets = MediaQuery.of(context).viewInsets.bottom;
      _lockedHeight =
          insets > 80 ? insets : (_lockedHeight ?? widget.fallbackHeight);
      unawaited(SystemChannels.textInput.invokeMethod('TextInput.hide'));
    } else if (newPanel == null && oldPanel != null) {
      // 面板态 → 键盘态：清除锁定，占位交给键盘 inset；唤回键盘
      _lockedHeight = null;
      unawaited(SystemChannels.textInput.invokeMethod('TextInput.show'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final insets = MediaQuery.of(context).viewInsets.bottom;
    final panelH = widget.panel != null
        ? (_lockedHeight ?? widget.fallbackHeight)
        : 0.0;
    final reserve = insets > panelH ? insets : panelH;
    final gap = reserve - (widget.panel != null ? panelH : 0.0);
    final surface = widget.surfaceColor ?? const Color(0xFF161622);
    // 面板高度与内容的过渡动画：能看到过程、不拖沓（约 300ms 柔和缓动）
    const anim = Duration(milliseconds: 300);
    const curve = Curves.easeOutCubic;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        widget.inputBar,
        // 键盘态↔面板态：面板区域高度平滑变化（0 → 面板高度）
        AnimatedSize(
          duration: anim,
          curve: curve,
          alignment: Alignment.topCenter,
          child: widget.panel == null
              ? const SizedBox(width: double.infinity)
              : SizedBox(
                  height: panelH,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 240),
                    switchInCurve: curve,
                    switchOutCurve: Curves.easeInOut,
                    child: KeyedSubtree(
                      key: ValueKey(_panelKey()),
                      child: widget.panel!,
                    ),
                  ),
                ),
        ),
        if (gap > 0)
          AnimatedContainer(
            duration: anim,
            curve: curve,
            color: surface,
            child: SizedBox(width: double.infinity, height: gap),
          ),
      ],
    );
  }

  /// 面板内容变化时生成 key，触发 AnimatedSwitcher 淡入淡出
  int _panelKey() {
    return widget.panel.runtimeType.hashCode;
  }
}
