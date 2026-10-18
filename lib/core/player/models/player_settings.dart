/// 可选项：显示名 + mpv 取值
class PlayerOption {
  final String value;
  final String label;

  const PlayerOption(this.value, this.label);
}

/// 播放器与解码首选项（持久化于 %APPDATA%/XiugouTV/player_settings.json）。
///
/// 所有字段在反序列化时做白名单 / 范围校验，非法或缺失值回落默认值，
/// 保证旧版本或手工编辑的文件不会导致崩溃。
class PlayerSettings {
  /// mpv `hwdec` 取值
  final String hwdec;

  /// 启动时的默认音量 (0 ~ 100)
  final double defaultVolume;

  /// 启动时的默认倍速 (0.5 ~ 3.0)
  final double defaultRate;

  /// mpv `audio-channels`：auto / stereo / 5.1 / 7.1
  final String audioChannels;

  /// 音画同步偏置（毫秒，正值表示音频延后）
  final int audioDelayMs;

  /// mpv `tone-mapping`：HDR → SDR 色调映射算法
  final String toneMapping;

  /// 画面缩放模式：`fit` / `fill` / `crop` / `16:9` / `4:3`。
  ///
  /// 比例模式经 mpv `video-aspect-override` 强制显示比例；
  /// 其余模式复位为该属性默认态（`-1`），与既有行为一致。
  final String scale;

  /// 画面色彩补偿 (-100 ~ 100)
  final int brightness;
  final int contrast;
  final int saturation;
  final int gamma;

  /// 网络缓冲时长（秒），mpv `cache-secs`
  final int cacheSecs;

  const PlayerSettings({
    this.hwdec = 'auto-safe',
    this.defaultVolume = 100,
    this.defaultRate = 1.0,
    this.audioChannels = 'auto',
    this.audioDelayMs = 0,
    this.toneMapping = 'auto',
    this.scale = 'fit',
    this.brightness = 0,
    this.contrast = 0,
    this.saturation = 0,
    this.gamma = 0,
    this.cacheSecs = 30,
  });

  static const PlayerSettings defaults = PlayerSettings();

  static const List<PlayerOption> hwdecOptions = [
    PlayerOption('auto-safe', '自动（推荐）'),
    PlayerOption('d3d11va', 'D3D11VA 硬解'),
    PlayerOption('d3d11va-copy', 'D3D11VA 硬解（拷回模式）'),
    PlayerOption('dxva2', 'DXVA2 硬解（旧显卡）'),
    PlayerOption('nvdec', 'NVIDIA NVDEC'),
    PlayerOption('cuda', 'NVIDIA CUDA / CUVID'),
    PlayerOption('no', '软件解码'),
  ];

  static const List<PlayerOption> audioChannelOptions = [
    PlayerOption('auto', '自动（跟随音源）'),
    PlayerOption('stereo', '双声道混音'),
    PlayerOption('5.1', '5.1 环绕声'),
    PlayerOption('7.1', '7.1 环绕声'),
  ];

  static const List<PlayerOption> toneMappingOptions = [
    PlayerOption('auto', '自动'),
    PlayerOption('bt.2390', 'BT.2390（标准）'),
    PlayerOption('hable', 'Hable（电影感）'),
    PlayerOption('mobius', 'Mobius（保留细节）'),
    PlayerOption('reinhard', 'Reinhard'),
    PlayerOption('clip', 'Clip（硬裁切）'),
  ];

  /// 画面缩放选项（对齐上游 TVBox「缩放比例」：适应窗口 / 填充 / 裁剪 / 16:9 / 4:3）
  static const List<PlayerOption> scaleOptions = [
    PlayerOption('fit', '适应窗口'),
    PlayerOption('fill', '填充'),
    PlayerOption('crop', '裁剪'),
    PlayerOption('16:9', '16:9'),
    PlayerOption('4:3', '4:3'),
  ];

  static const double minRate = 0.5;
  static const double maxRate = 3.0;
  static const int minAudioDelayMs = -5000;
  static const int maxAudioDelayMs = 5000;
  static const int minCacheSecs = 5;
  static const int maxCacheSecs = 300;
  static const int minPicture = -100;
  static const int maxPicture = 100;

  static bool _allowed(List<PlayerOption> options, String value) =>
      options.any((o) => o.value == value);

  static String labelOf(List<PlayerOption> options, String value) {
    for (final option in options) {
      if (option.value == value) return option.label;
    }
    return value;
  }

  /// 兼容旧 DesktopWindowConfig.hardwareDecoding（'auto' | 'd3d11va' | 'no'）
  static String normalizeHwdec(String? raw) {
    final value = raw?.trim().toLowerCase() ?? '';
    if (value == 'auto' || value.isEmpty) return 'auto-safe';
    return _allowed(hwdecOptions, value) ? value : 'auto-safe';
  }

  factory PlayerSettings.fromJson(Map<String, dynamic> json) {
    String pick(String key, List<PlayerOption> options, String fallback) {
      final value = json[key]?.toString().trim().toLowerCase();
      return value != null && _allowed(options, value) ? value : fallback;
    }

    double number(String key, double fallback, double min, double max) {
      final raw = json[key];
      final parsed = raw is num ? raw.toDouble() : double.tryParse(raw?.toString() ?? '');
      if (parsed == null || !parsed.isFinite) return fallback;
      return parsed.clamp(min, max).toDouble();
    }

    int integer(String key, int fallback, int min, int max) =>
        number(key, fallback.toDouble(), min.toDouble(), max.toDouble()).round();

    return PlayerSettings(
      hwdec: normalizeHwdec(json['hwdec']?.toString()),
      defaultVolume: number('defaultVolume', 100, 0, 100),
      defaultRate: number('defaultRate', 1.0, minRate, maxRate),
      audioChannels: pick('audioChannels', audioChannelOptions, 'auto'),
      audioDelayMs: integer('audioDelayMs', 0, minAudioDelayMs, maxAudioDelayMs),
      toneMapping: pick('toneMapping', toneMappingOptions, 'auto'),
      scale: pick('scale', scaleOptions, 'fit'),
      brightness: integer('brightness', 0, minPicture, maxPicture),
      contrast: integer('contrast', 0, minPicture, maxPicture),
      saturation: integer('saturation', 0, minPicture, maxPicture),
      gamma: integer('gamma', 0, minPicture, maxPicture),
      cacheSecs: integer('cacheSecs', 30, minCacheSecs, maxCacheSecs),
    );
  }

  Map<String, dynamic> toJson() => {
        'hwdec': hwdec,
        'defaultVolume': defaultVolume,
        'defaultRate': defaultRate,
        'audioChannels': audioChannels,
        'audioDelayMs': audioDelayMs,
        'toneMapping': toneMapping,
        'scale': scale,
        'brightness': brightness,
        'contrast': contrast,
        'saturation': saturation,
        'gamma': gamma,
        'cacheSecs': cacheSecs,
      };

  /// 画面缩放对应的 mpv 属性取值：比例模式强制对应比例，其余复位默认态。
  ///
  /// 复位值 `-1` 与 mpv 出厂默认回读一致（实测 mpv v0.36：默认 `-1.000000`；
  /// `no` 字符串映射为 `0.000000`，非默认态，故不采用），保证未启用比例时与现状零差异。
  String get mpvAspectOverride => switch (scale) {
        '16:9' => '16:9',
        '4:3' => '4:3',
        _ => '-1',
      };

  /// 可在播放中即时生效的 mpv 属性（音量 / 倍速仅作为启动默认值，不在此列）
  Map<String, String> toMpvProperties() => {
        'hwdec': hwdec,
        'audio-channels': audioChannels,
        'audio-delay': (audioDelayMs / 1000).toStringAsFixed(3),
        'tone-mapping': toneMapping,
        'video-aspect-override': mpvAspectOverride,
        'brightness': '$brightness',
        'contrast': '$contrast',
        'saturation': '$saturation',
        'gamma': '$gamma',
        'cache-secs': '$cacheSecs',
      };

  /// 经 JSON 往返的规范化副本（用于对 UI 输入做同样的校验）
  PlayerSettings normalized() => PlayerSettings.fromJson(toJson());

  PlayerSettings copyWith({
    String? hwdec,
    double? defaultVolume,
    double? defaultRate,
    String? audioChannels,
    int? audioDelayMs,
    String? toneMapping,
    String? scale,
    int? brightness,
    int? contrast,
    int? saturation,
    int? gamma,
    int? cacheSecs,
  }) {
    return PlayerSettings(
      hwdec: hwdec ?? this.hwdec,
      defaultVolume: defaultVolume ?? this.defaultVolume,
      defaultRate: defaultRate ?? this.defaultRate,
      audioChannels: audioChannels ?? this.audioChannels,
      audioDelayMs: audioDelayMs ?? this.audioDelayMs,
      toneMapping: toneMapping ?? this.toneMapping,
      scale: scale ?? this.scale,
      brightness: brightness ?? this.brightness,
      contrast: contrast ?? this.contrast,
      saturation: saturation ?? this.saturation,
      gamma: gamma ?? this.gamma,
      cacheSecs: cacheSecs ?? this.cacheSecs,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PlayerSettings &&
      other.hwdec == hwdec &&
      other.defaultVolume == defaultVolume &&
      other.defaultRate == defaultRate &&
      other.audioChannels == audioChannels &&
      other.audioDelayMs == audioDelayMs &&
      other.toneMapping == toneMapping &&
      other.scale == scale &&
      other.brightness == brightness &&
      other.contrast == contrast &&
      other.saturation == saturation &&
      other.gamma == gamma &&
      other.cacheSecs == cacheSecs;

  @override
  int get hashCode => Object.hash(hwdec, defaultVolume, defaultRate, audioChannels, audioDelayMs,
      toneMapping, scale, brightness, contrast, saturation, gamma, cacheSecs);
}
