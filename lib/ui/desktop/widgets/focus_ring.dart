import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';

/// 键盘焦点环（backlog §1 · B1）。
///
/// skill 把 `focus-states` 列为 CRITICAL：**键盘焦点必须可见**。本项目里大量可点区域
/// 是 `GestureDetector` 直接监听 `onTap`，既进不了 Tab 顺序，也没有任何焦点反馈。
/// 这个组件把两件事一次补齐：
///
/// 1. 进入 Tab 顺序，Enter / Space 等价于点按（键鼠同一套能力，符合 `keyboard-nav`）；
/// 2. 聚焦时在控件外描一圈 2px 的 `accentInk`（颜色随主题，深浅都可见）。
///
/// 环用**叠加**绘制而不是加边框，避免聚焦瞬间产生布局跳动
/// （skill 的 `layout-shift-avoid`）。
///
/// 用法：包在既有的可点区域外面即可，不需要改内部结构。
/// ```dart
/// FocusRing(
///   onTap: () => open(item),
///   borderRadius: BorderRadius.circular(AppRadii.md),
///   child: existingCard,
/// )
/// ```
class FocusRing extends StatefulWidget {
  /// 被包裹的内容（尺寸由它决定，组件本身不改变布局）
  final Widget child;

  /// 点按 / Enter / Space 触发的动作；为 null 时该区域不可聚焦（等同于纯展示）
  final VoidCallback? onTap;

  /// 焦点环的圆角，应与被包裹控件保持一致
  final BorderRadius borderRadius;

  /// 无障碍名称（图标按钮这类没有可见文字的场景应当提供）
  final String? semanticLabel;

  const FocusRing({
    super.key,
    required this.child,
    this.onTap,
    this.borderRadius = const BorderRadius.all(Radius.circular(AppRadii.md)),
    this.semanticLabel,
  });

  @override
  State<FocusRing> createState() => _FocusRingState();
}

class _FocusRingState extends State<FocusRing> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final enabled = widget.onTap != null;

    return FocusableActionDetector(
      enabled: enabled,
      onShowFocusHighlight: (value) {
        if (value != _focused) setState(() => _focused = value);
      },
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
      },
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap?.call();
            return null;
          },
        ),
      },
      mouseCursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
      child: Stack(
        children: [
          widget.child,
          if (_focused)
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  key: const ValueKey('focus-ring'),
                  decoration: BoxDecoration(
                    borderRadius: widget.borderRadius,
                    border: Border.all(
                      color: palette.accentInk,
                      width: AppFocus.ringWidth,
                    ),
                  ),
                ),
              ),
            ),
          if (widget.semanticLabel != null)
            Positioned.fill(
              child: IgnorePointer(
                child: Semantics(
                  button: true,
                  label: widget.semanticLabel,
                  child: const SizedBox.expand(),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 弹窗内 Material 按钮的聚焦可见性（backlog §1 · B4）。
///
/// M3 默认聚焦视觉只是主题色约 12% 的叠加，深色底上难以辨认；`focus-states`
/// 属 CRITICAL 且明确覆盖 modal 内控件。统一改为：聚焦时描 `accentInk` 1.5
/// 边框；其余状态回落到按钮原有描边 [base]。
///
/// 用法：`styleFrom(...).copyWith(side: focusedBorderSide(context, base: 原边框))`
/// 或 `style: ButtonStyle(side: focusedBorderSide(context))`。
WidgetStateProperty<BorderSide?> focusedBorderSide(
  BuildContext context, {
  BorderSide? base,
}) {
  final accentInk = AppPalette.of(context).accentInk;
  return WidgetStateProperty.resolveWith((states) {
    if (states.contains(WidgetState.focused)) {
      return BorderSide(color: accentInk, width: 1.5);
    }
    return base;
  });
}

/// 键盘焦点描边（B5 从播放器提升为共享组件，B6 扩展到弹窗与设置中心）。
///
/// 叠画在控件上，不参与布局、不改变子树结构（与 [FocusRing] 同一
/// 「环不挤压布局」范式；skill `focus-states` 属 CRITICAL）。
///
/// 与 [FocusRing] 的分工：`FocusRing` 是「组件即控件」（自带 onTap 与语义）；
/// 本组件监听**子树里已存在控件**的焦点（Material 按钮、InkWell 等），
/// 只负责「可见焦点指示」，不改变控件自身的按键与语义行为。
///
/// 背景：实测 `ButtonStyle(side:)` 在应用内不产生可见像素（元素树里 shape
/// 已带描边、截图逐像素无变化；同一按钮在隔离场景却可渲染），故播放器
/// 控制层（B5）与弹窗按钮（B4 复核后改，B6）统一用叠画。
class FocusOutline extends StatefulWidget {
  const FocusOutline({
    super.key,
    required this.child,
    this.radius = AppRadii.sm,
    this.inset = EdgeInsets.zero,
    this.color,
    this.outlineKey = const ValueKey('focus-outline'),
  });

  /// 被包裹的控件（自身负责焦点与交互）。
  final Widget child;

  /// 描边圆角，应与被包裹控件一致（胶囊按钮用 [AppRadii.pill]）。
  final double radius;

  /// 描边相对控件边缘的内缩（面板行不贴面板边缘）。
  final EdgeInsets inset;

  /// 描边颜色；缺省取主题 `accentInk`。
  final Color? color;

  /// 描边自身的 Key（供测试与像素探针定位）。
  final Key outlineKey;

  @override
  State<FocusOutline> createState() => _FocusOutlineState();
}

class _FocusOutlineState extends State<FocusOutline> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? AppPalette.of(context).accentInk;
    return Focus(
      // 纯焦点信号监听：不进 Tab 顺序、不进语义树（与底栏焦点跟踪同范式）。
      canRequestFocus: false,
      skipTraversal: true,
      includeSemantics: false,
      onFocusChange: (value) {
        if (value != _focused) setState(() => _focused = value);
      },
      child: Stack(
        children: [
          widget.child,
          if (_focused)
            Positioned.fill(
              child: IgnorePointer(
                child: Padding(
                  padding: widget.inset,
                  child: DecoratedBox(
                    key: widget.outlineKey,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(widget.radius),
                      border: Border.all(color: color, width: 1.5),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
