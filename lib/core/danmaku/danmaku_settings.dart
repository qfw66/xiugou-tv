/// 弹幕外观与过滤设置（§43 二期）。持久化在 `player_settings.json` 的 `danmaku` 对象里。
///
/// 所有字段反序列化时做范围校验，非法 / 缺失回落默认值（与 [PlayerSettings] 同口径）。
class DanmakuSettings {
  const DanmakuSettings({
    this.blockScroll = false,
    this.blockTop = false,
    this.blockBottom = false,
    this.blockColorful = false,
    this.blockAdvanced = true,
    this.area = 0.75,
    this.pipArea = 1 / 3,
    this.opacity = 0.85,
    this.fontWeight = 600,
    this.strokeWidth = 1.0,
    this.fontSize = 22,
    this.fullscreenFontSize = 28,
    this.scrollDuration = 8.0,
    this.fixedDuration = 4.0,
    this.lineHeight = 1.4,
  });

  static const DanmakuSettings defaults = DanmakuSettings();

  // ---- 屏蔽（按类型）----
  final bool blockScroll;
  final bool blockTop;
  final bool blockBottom;

  /// 非白色弹幕
  final bool blockColorful;

  /// 高级弹幕（B 站 mode 7 定位 / 8 代码弹幕等，非滚动 / 顶 / 底的特殊类型）。
  /// 默认屏蔽：桌面端不支持其定位与动画脚本，按普通弹幕画会错位。
  final bool blockAdvanced;

  // ---- 显示 ----
  /// 弹幕可占用的画面比例（自上而下）
  final double area;

  /// 画中画小窗里的显示区域（默认上 1/3，小窗本就挤）
  final double pipArea;

  /// 不透明度 0.1–1.0
  final double opacity;

  /// 字体粗细 100–900（FontWeight 档位）
  final int fontWeight;

  /// 描边粗细（逻辑像素）0–4，0 = 不描边
  final double strokeWidth;

  /// 窗口模式字号
  final double fontSize;

  /// 全屏字号（全屏时画面大，字号单独设）
  final double fullscreenFontSize;

  /// 滚动弹幕横穿屏幕用时（秒，1x 播放）
  final double scrollDuration;

  /// 顶部 / 底部弹幕停留时长（秒）
  final double fixedDuration;

  /// 行高（字号的倍数）
  final double lineHeight;

  // ---- 取值范围（设置页滑块与校验共用）----
  static const double minArea = 0.1, maxArea = 1.0;
  static const double minOpacity = 0.1, maxOpacity = 1.0;
  static const int minFontWeight = 100, maxFontWeight = 900;
  static const double minStroke = 0, maxStroke = 4;
  static const double minFontSize = 12, maxFontSize = 48;
  static const double minScroll = 3, maxScroll = 20;
  static const double minFixed = 1, maxFixed = 10;
  static const double minLineHeight = 1.0, maxLineHeight = 2.5;

  /// 显示区域档位（设置页下拉）
  static const List<(double, String)> areaOptions = [
    (0.25, '1/4 屏'),
    (1 / 3, '1/3 屏'),
    (0.5, '半屏'),
    (0.75, '3/4 屏'),
    (1.0, '全屏'),
  ];

  /// 字体粗细档位（设置页下拉）
  static const List<(int, String)> fontWeightOptions = [
    (300, '细'),
    (400, '常规'),
    (500, '中等'),
    (600, '半粗'),
    (700, '粗'),
    (900, '特粗'),
  ];

  factory DanmakuSettings.fromJson(Object? raw) {
    if (raw is! Map) return defaults;
    double number(String k, double fallback, double min, double max) {
      final v = raw[k];
      final d = v is num ? v.toDouble() : double.tryParse('${v ?? ''}');
      if (d == null || !d.isFinite) return fallback;
      return d.clamp(min, max).toDouble();
    }

    bool flag(String k, bool fallback) {
      final v = raw[k];
      return v is bool ? v : fallback;
    }

    return DanmakuSettings(
      blockScroll: flag('blockScroll', false),
      blockTop: flag('blockTop', false),
      blockBottom: flag('blockBottom', false),
      blockColorful: flag('blockColorful', false),
      blockAdvanced: flag('blockAdvanced', true),
      area: number('area', 0.75, minArea, maxArea),
      pipArea: number('pipArea', 1 / 3, minArea, maxArea),
      opacity: number('opacity', 0.85, minOpacity, maxOpacity),
      fontWeight: (number('fontWeight', 600, minFontWeight.toDouble(), maxFontWeight.toDouble()) / 100).round() * 100,
      strokeWidth: number('strokeWidth', 1.0, minStroke, maxStroke),
      fontSize: number('fontSize', 22, minFontSize, maxFontSize),
      fullscreenFontSize: number('fullscreenFontSize', 28, minFontSize, maxFontSize),
      scrollDuration: number('scrollDuration', 8, minScroll, maxScroll),
      fixedDuration: number('fixedDuration', 4, minFixed, maxFixed),
      lineHeight: number('lineHeight', 1.4, minLineHeight, maxLineHeight),
    );
  }

  Map<String, dynamic> toJson() => {
        'blockScroll': blockScroll,
        'blockTop': blockTop,
        'blockBottom': blockBottom,
        'blockColorful': blockColorful,
        'blockAdvanced': blockAdvanced,
        'area': area,
        'pipArea': pipArea,
        'opacity': opacity,
        'fontWeight': fontWeight,
        'strokeWidth': strokeWidth,
        'fontSize': fontSize,
        'fullscreenFontSize': fullscreenFontSize,
        'scrollDuration': scrollDuration,
        'fixedDuration': fixedDuration,
        'lineHeight': lineHeight,
      };

  DanmakuSettings copyWith({
    bool? blockScroll,
    bool? blockTop,
    bool? blockBottom,
    bool? blockColorful,
    bool? blockAdvanced,
    double? area,
    double? pipArea,
    double? opacity,
    int? fontWeight,
    double? strokeWidth,
    double? fontSize,
    double? fullscreenFontSize,
    double? scrollDuration,
    double? fixedDuration,
    double? lineHeight,
  }) =>
      DanmakuSettings(
        blockScroll: blockScroll ?? this.blockScroll,
        blockTop: blockTop ?? this.blockTop,
        blockBottom: blockBottom ?? this.blockBottom,
        blockColorful: blockColorful ?? this.blockColorful,
        blockAdvanced: blockAdvanced ?? this.blockAdvanced,
        area: area ?? this.area,
        pipArea: pipArea ?? this.pipArea,
        opacity: opacity ?? this.opacity,
        fontWeight: fontWeight ?? this.fontWeight,
        strokeWidth: strokeWidth ?? this.strokeWidth,
        fontSize: fontSize ?? this.fontSize,
        fullscreenFontSize: fullscreenFontSize ?? this.fullscreenFontSize,
        scrollDuration: scrollDuration ?? this.scrollDuration,
        fixedDuration: fixedDuration ?? this.fixedDuration,
        lineHeight: lineHeight ?? this.lineHeight,
      );

  @override
  bool operator ==(Object other) =>
      other is DanmakuSettings &&
      other.blockScroll == blockScroll &&
      other.blockTop == blockTop &&
      other.blockBottom == blockBottom &&
      other.blockColorful == blockColorful &&
      other.blockAdvanced == blockAdvanced &&
      other.area == area &&
      other.pipArea == pipArea &&
      other.opacity == opacity &&
      other.fontWeight == fontWeight &&
      other.strokeWidth == strokeWidth &&
      other.fontSize == fontSize &&
      other.fullscreenFontSize == fullscreenFontSize &&
      other.scrollDuration == scrollDuration &&
      other.fixedDuration == fixedDuration &&
      other.lineHeight == lineHeight;

  @override
  int get hashCode => Object.hash(blockScroll, blockTop, blockBottom, blockColorful, blockAdvanced, area, pipArea,
      opacity, fontWeight, strokeWidth, fontSize, fullscreenFontSize, scrollDuration, fixedDuration, lineHeight);
}
