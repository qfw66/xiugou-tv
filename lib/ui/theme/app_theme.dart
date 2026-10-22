import 'package:flutter/material.dart';

import 'app_palette.dart';

/// 由调色板生成两套 `ThemeData`。
///
/// 只覆盖真正影响观感的字段（配色 / 背景 / 字体），不改组件尺寸与交互，
/// 避免把主题工程变成视觉改版。
ThemeData buildAppTheme({
  required Brightness brightness,
  required AppPalette palette,
}) {
  final scheme = ColorScheme(
    brightness: brightness,
    primary: palette.accent,
    // 压品牌填充的墨色随明暗反转：深色主题是深底（#414A5B）配白字 8.92:1；
    // 浅色主题是浅底（#D8E3F8）配深蓝灰 #2A3550 9.44:1。白字压 #D8E3F8 只有 1.2，不可用。
    onPrimary:
        brightness == Brightness.dark ? Colors.white : const Color(0xFF2A3550),
    secondary: palette.accent,
    onSecondary:
        brightness == Brightness.dark ? Colors.white : const Color(0xFF2A3550),
    error: palette.danger,
    onError: Colors.white,
    surface: palette.card,
    onSurface: palette.textMain,
  );

  return ThemeData(
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: palette.background,
    canvasColor: palette.panel,
    dividerColor: palette.divider,
    fontFamily: 'Segoe UI',
    fontFamilyFallback: const [
      'Microsoft YaHei',
      'PingFang SC',
      'sans-serif',
    ],
    // 控件前景补丁（backlog §1 追加条目，已获准随 B 系列实施）：
    // M3 默认让 TextButton / OutlinedButton 的文字取 colorScheme.primary，
    // 即品牌色本身（深色下约 2.1:1，偏暗）；统一提亮为前景档 accentInk
    // （≥4.5:1）。显式设置前景的按钮（品牌底主按钮等）不受影响。
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: palette.accentInk),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(foregroundColor: palette.accentInk),
    ),
    // Tooltip 的退场动画归零（2026-10-22）：Tooltip 的浮层挂在整页 Overlay 上，
    // 若宿主（弹窗 / 抽屉 / 控制条）先被移除、浮层还在做退场动画，引擎会收到
    // 一棵「父节点已删除」的语义更新 —— 控制台就是那句
    // `Failed to update ui::AXTree, error: <id> will not be in the tree and is not the new root`。
    // 退场设为 0 后，Tooltip 随宿主一起立刻消失，不再留下悬空节点。
    tooltipTheme: const TooltipThemeData(exitDuration: Duration.zero),
    extensions: [palette],
  );
}
