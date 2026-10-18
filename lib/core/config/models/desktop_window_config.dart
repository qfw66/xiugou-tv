/// Windows 桌面窗口与环境配置模型
class DesktopWindowConfig {
  final double width;
  final double height;
  final double? posX;
  final double? posY;
  final bool isMaximized;
  final bool isFullScreen;
  final bool alwaysOnTop;
  final String playerEngine; // 'mpv' | 'native'
  final String hardwareDecoding; // 'auto' | 'd3d11va' | 'no'
  final double volume;
  final String? lastConfigUrl;

  /// 多仓（Depot）逐层选择链：记录用户在各层挑选的条目 URL。
  /// 用于启动时按用户上次的选择重放，避免回落到第一个条目。
  final List<String> depotPath;

  final String themeMode; // 'system' | 'dark' | 'light'

  const DesktopWindowConfig({
    this.width = 1280.0,
    this.height = 720.0,
    this.posX,
    this.posY,
    this.isMaximized = false,
    this.isFullScreen = false,
    this.alwaysOnTop = false,
    this.playerEngine = 'mpv',
    this.hardwareDecoding = 'auto',
    this.volume = 100.0,
    this.lastConfigUrl,
    this.depotPath = const [],
    this.themeMode = 'dark',
  });

  factory DesktopWindowConfig.fromJson(Map<String, dynamic> json) {
    return DesktopWindowConfig(
      width: (json['width'] as num?)?.toDouble() ?? 1280.0,
      height: (json['height'] as num?)?.toDouble() ?? 720.0,
      posX: (json['posX'] as num?)?.toDouble(),
      posY: (json['posY'] as num?)?.toDouble(),
      isMaximized: json['isMaximized'] as bool? ?? false,
      isFullScreen: json['isFullScreen'] as bool? ?? false,
      alwaysOnTop: json['alwaysOnTop'] as bool? ?? false,
      playerEngine: json['playerEngine']?.toString() ?? 'mpv',
      hardwareDecoding: json['hardwareDecoding']?.toString() ?? 'auto',
      volume: (json['volume'] as num?)?.toDouble() ?? 100.0,
      lastConfigUrl: json['lastConfigUrl']?.toString(),
      depotPath: (json['depotPath'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? const [],
      themeMode: json['themeMode']?.toString() ?? 'dark',
    );
  }

  Map<String, dynamic> toJson() => {
    'width': width,
    'height': height,
    if (posX != null) 'posX': posX,
    if (posY != null) 'posY': posY,
    'isMaximized': isMaximized,
    'isFullScreen': isFullScreen,
    'alwaysOnTop': alwaysOnTop,
    'playerEngine': playerEngine,
    'hardwareDecoding': hardwareDecoding,
    'volume': volume,
    if (lastConfigUrl != null) 'lastConfigUrl': lastConfigUrl,
    if (depotPath.isNotEmpty) 'depotPath': depotPath,
    'themeMode': themeMode,
  };

  DesktopWindowConfig copyWith({
    double? width,
    double? height,
    double? posX,
    double? posY,
    bool? isMaximized,
    bool? isFullScreen,
    bool? alwaysOnTop,
    String? playerEngine,
    String? hardwareDecoding,
    double? volume,
    String? lastConfigUrl,
    bool clearLastConfigUrl = false,
    List<String>? depotPath,
    String? themeMode,
  }) {
    return DesktopWindowConfig(
      width: width ?? this.width,
      height: height ?? this.height,
      posX: posX ?? this.posX,
      posY: posY ?? this.posY,
      isMaximized: isMaximized ?? this.isMaximized,
      isFullScreen: isFullScreen ?? this.isFullScreen,
      alwaysOnTop: alwaysOnTop ?? this.alwaysOnTop,
      playerEngine: playerEngine ?? this.playerEngine,
      hardwareDecoding: hardwareDecoding ?? this.hardwareDecoding,
      volume: volume ?? this.volume,
      lastConfigUrl: clearLastConfigUrl ? null : lastConfigUrl ?? this.lastConfigUrl,
      depotPath: depotPath ?? this.depotPath,
      themeMode: themeMode ?? this.themeMode,
    );
  }
}
