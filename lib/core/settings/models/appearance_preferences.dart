/// 主题模式（持久化用 `dark|light|system`）。
enum AppThemeMode {
  dark('深色'),
  light('浅色'),
  system('跟随系统');

  const AppThemeMode(this.label);

  final String label;

  static AppThemeMode? tryParse(Object? raw) {
    if (raw is! String) return null;
    for (final mode in AppThemeMode.values) {
      if (mode.name == raw) return mode;
    }
    return null;
  }
}

/// 外观偏好：主题 + 壁纸（SET-08 / 主题）。
///
/// 持久化于应用数据目录的 `appearance_preferences.json`。
/// **version 2** 起新增 `themeMode`；读取时兼容 version 1（视为深色），
/// 写入一律为 version 2。
///
/// 壁纸只存**文件名**（形如 `current.jpg`）：图片本体由 `WallpaperStore`
/// 复制到 `wallpaper/` 子目录，因此用户移动 / 删除原图不会让壁纸失效；
/// 「恢复默认」只删副本，**不触碰用户原图**。
///
/// 读取规则：版本 / 顶层结构 / 字段类型非法时抛出 [FormatException]（调用方保留原文件）。
class AppearancePreferences {
  static const int formatVersion = 2;

  /// 可读取的历史版本：1 没有主题字段（按深色处理）。
  static const Set<int> readableVersions = {1, 2};

  /// 文件名允许的字符集：不含路径分隔符，配合 `WallpaperStore` 的目录约束。
  static final RegExp fileNamePattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$');

  /// 当前壁纸副本的文件名（相对 `wallpaper/` 目录）；null 表示使用默认背景。
  final String? wallpaperFileName;

  /// 主题模式；默认深色（与改造前一致）。
  final AppThemeMode themeMode;

  const AppearancePreferences({
    this.wallpaperFileName,
    this.themeMode = AppThemeMode.dark,
  });

  /// 未设置壁纸（默认外观）。
  static const AppearancePreferences none = AppearancePreferences();

  bool get hasWallpaper =>
      wallpaperFileName != null && wallpaperFileName!.isNotEmpty;

  AppearancePreferences withWallpaper(String? fileName) => AppearancePreferences(
        wallpaperFileName: fileName,
        themeMode: themeMode,
      );

  AppearancePreferences withThemeMode(AppThemeMode mode) => AppearancePreferences(
        wallpaperFileName: wallpaperFileName,
        themeMode: mode,
      );

  static AppearancePreferences fromJson(Map<String, dynamic> json) {
    final version = json['version'];
    if (version is! int || !readableVersions.contains(version)) {
      throw const FormatException('外观偏好格式无效');
    }
    final rawMode = json['themeMode'];
    if (rawMode != null && rawMode is! String) {
      throw const FormatException('外观偏好格式无效');
    }
    // version 1 没有该字段：按深色处理，保证旧文件无损
    AppThemeMode themeMode;
    if (rawMode == null) {
      themeMode = AppThemeMode.dark;
    } else {
      final parsed = AppThemeMode.tryParse(rawMode);
      if (parsed == null) throw const FormatException('外观偏好格式无效');
      themeMode = parsed;
    }

    final raw = json['wallpaperFileName'];
    if (raw == null) {
      return AppearancePreferences(themeMode: themeMode);
    }
    if (raw is! String) throw const FormatException('外观偏好格式无效');
    final name = raw.trim();
    if (name.isEmpty) return AppearancePreferences(themeMode: themeMode);
    if (!fileNamePattern.hasMatch(name)) {
      throw const FormatException('外观偏好格式无效');
    }
    return AppearancePreferences(
      wallpaperFileName: name,
      themeMode: themeMode,
    );
  }

  Map<String, dynamic> toJson() => {
        'version': formatVersion,
        'wallpaperFileName': wallpaperFileName,
        'themeMode': themeMode.name,
      };

  @override
  bool operator ==(Object other) =>
      other is AppearancePreferences &&
      other.wallpaperFileName == wallpaperFileName &&
      other.themeMode == themeMode;

  @override
  int get hashCode => Object.hash(wallpaperFileName, themeMode);

  @override
  String toString() =>
      'AppearancePreferences(wallpaperFileName: $wallpaperFileName, '
      'themeMode: ${themeMode.name})';
}
