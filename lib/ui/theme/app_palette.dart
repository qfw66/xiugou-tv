import 'package:flutter/material.dart';

/// 应用语义调色板。
///
/// UI 层不再直接写 `Color(0x…)`：所有颜色都从这里取，切换主题时整棵树一起变。
/// 深色表取现有界面的实际色值（同一语义的多个近似值已归并到最常见的一个）；
/// 浅色表是新增的一套中性灰 + 品牌暖橙。
///
/// **品牌色 2026-10-19 二轮：冷色两级**（backlog §11 / `docs/ACCENT_COLOR_PLAN.md` §11）。
/// 深色填充 `#414A5B` / 前景 `#94A3B8`；浅色填充 `#D8E3F8`（浅蓝）/ 前景 `#334155`。
///
/// 规则：**填充用 `accent`，前景（图标 / 文字 / 进度条 / 选中描边）用 `accentInk`。**
/// 冷色填充两头都不能当文字：深色 `#414A5B` 在深底上只有 2.23:1（看不见），
/// 浅色 `#D8E3F8` 在浅底上只有 1.29:1（同样看不见）——所以前景必须单独一层。
/// 压在填充上的文字走 `colorScheme.onPrimary`：深色主题白（8.92:1）、浅色主题深蓝灰
/// `#2A3550`（9.44:1，浅底深字）。
/// 红只保留给「危险」与「直播中」（复用 `danger`），海报角标等装饰性标签与品牌色解耦。
@immutable
class AppPalette extends ThemeExtension<AppPalette> {
  /// 窗口 / 页面底色
  final Color background;

  /// 分区面板底（设置页左栏、页面容器）
  final Color panel;

  /// 卡片底
  final Color card;

  /// 比卡片更高一层的浮起块（输入框、列表项）
  final Color raised;

  /// 边框
  final Color border;

  /// 更强的分隔线 / 选中描边
  final Color borderStrong;

  /// 细分割线
  final Color divider;

  /// 标题文字（白）
  final Color textTitle;

  /// 正文主色
  final Color textMain;

  /// 次级正文
  final Color textBody;

  /// 说明文字
  final Color textSub;

  /// 弱提示
  final Color textDim;

  /// 品牌色（**填充**用）：主按钮底、选中胶囊底、播放按钮底
  final Color accent;

  /// 品牌色（**前景**用）：图标 / 链接 / 进度条 / 选中描边
  ///
  /// 冷灰填充太暗（深色下 `#414A5B` 在页面底上只有 2.23:1），当文字/图标会直接消失，
  /// 所以品牌色分两级：填充 [`accent`] + 前景 [`accentInk`]（同一色相、亮一档）。
  final Color accentInk;

  /// 品牌底色纹（选中行背景 / 图标块）
  final Color accentWash;

  /// 危险 / 错误
  final Color danger;

  /// 成功
  final Color success;

  /// 警告
  final Color warning;

  /// hover 底
  final Color hover;

  /// 按下 / 选中底
  final Color pressed;

  /// 壁纸遮罩（深色黑 / 浅色白）
  final Color scrim;

  /// 播放器 OSD 面板
  final Color playerChrome;

  /// 播放器 OSD 文字
  final Color playerText;

  const AppPalette({
    required this.background,
    required this.panel,
    required this.card,
    required this.raised,
    required this.border,
    required this.borderStrong,
    required this.divider,
    required this.textTitle,
    required this.textMain,
    required this.textBody,
    required this.textSub,
    required this.textDim,
    required this.accent,
    required this.accentInk,
    required this.accentWash,
    required this.danger,
    required this.success,
    required this.warning,
    required this.hover,
    required this.pressed,
    required this.scrim,
    required this.playerChrome,
    required this.playerText,
  });

  static const AppPalette dark = AppPalette(
    background: Color(0xFF101014),
    panel: Color(0xFF15151E),
    card: Color(0xFF1B1B25),
    raised: Color(0xFF202026),
    border: Color(0xFF262634),
    borderStrong: Color(0xFF2E2E3C),
    divider: Color(0xFF242430),
    textTitle: Color(0xFFFFFFFF),
    textMain: Color(0xFFE6E6F0),
    textBody: Color(0xFFB0B0C0),
    textSub: Color(0xFF888898),
    textDim: Color(0xFF66667A),
    accent: Color(0xFF414A5B),
    accentInk: Color(0xFF94A3B8),
    accentWash: Color(0xFF232632),
    danger: Color(0xFFEF4444),
    success: Color(0xFF4CAF50),
    warning: Color(0xFFFFB300),
    hover: Color(0xFF2A2A38),
    pressed: Color(0xFF323242),
    scrim: Color(0x8C000000),
    playerChrome: Color(0xCC000000),
    playerText: Color(0xFFFFFFFF),
  );

  static const AppPalette light = AppPalette(
    background: Color(0xFFF5F5F8),
    panel: Color(0xFFFFFFFF),
    card: Color(0xFFFFFFFF),
    raised: Color(0xFFF0F0F5),
    border: Color(0xFFE2E2EA),
    borderStrong: Color(0xFFD2D2DC),
    divider: Color(0xFFE8E8EF),
    textTitle: Color(0xFF14141A),
    textMain: Color(0xFF1B1B22),
    textBody: Color(0xFF3A3A46),
    textSub: Color(0xFF5B5B6C),
    textDim: Color(0xFF8A8A9A),
    accent: Color(0xFFD8E3F8),
    accentInk: Color(0xFF334155),
    accentWash: Color(0xFFE4EBFA),
    danger: Color(0xFFC62828),
    success: Color(0xFF2E7D32),
    warning: Color(0xFFB26A00),
    hover: Color(0xFFEDEDF3),
    pressed: Color(0xFFE3E3EC),
    scrim: Color(0x8CFFFFFF),
    playerChrome: Color(0xE6FFFFFF),
    playerText: Color(0xFF1B1B22),
  );

  /// 取当前主题的调色板；没有注入时回退深色（避免测试与半初始化场景崩溃）。
  static AppPalette of(BuildContext context) =>
      Theme.of(context).extension<AppPalette>() ?? dark;

  @override
  AppPalette copyWith() => this;

  @override
  AppPalette lerp(covariant AppPalette? other, double t) {
    if (other == null) return this;
    Color mix(Color a, Color b) => Color.lerp(a, b, t)!;
    return AppPalette(
      background: mix(background, other.background),
      panel: mix(panel, other.panel),
      card: mix(card, other.card),
      raised: mix(raised, other.raised),
      border: mix(border, other.border),
      borderStrong: mix(borderStrong, other.borderStrong),
      divider: mix(divider, other.divider),
      textTitle: mix(textTitle, other.textTitle),
      textMain: mix(textMain, other.textMain),
      textBody: mix(textBody, other.textBody),
      textSub: mix(textSub, other.textSub),
      textDim: mix(textDim, other.textDim),
      accent: mix(accent, other.accent),
      accentInk: mix(accentInk, other.accentInk),
      accentWash: mix(accentWash, other.accentWash),
      danger: mix(danger, other.danger),
      success: mix(success, other.success),
      warning: mix(warning, other.warning),
      hover: mix(hover, other.hover),
      pressed: mix(pressed, other.pressed),
      scrim: mix(scrim, other.scrim),
      playerChrome: mix(playerChrome, other.playerChrome),
      playerText: mix(playerText, other.playerText),
    );
  }
}

/// 取色简写：`context.palette.textMain`。
///
/// 大文件里逐处写 `AppPalette.of(context)` 太长，统一用这个入口；
/// 语义与 [`AppPalette.of`] 完全一致（无注入时回退深色）。
extension AppPaletteContext on BuildContext {
  AppPalette get palette => AppPalette.of(this);
}
