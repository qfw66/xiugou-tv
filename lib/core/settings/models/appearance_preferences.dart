/// 外观偏好（SET-08）：目前只有壁纸。
///
/// 持久化于应用数据目录的 `appearance_preferences.json`（version 1）。
/// 这里只存**文件名**（形如 `current.jpg`）：图片本体由 `WallpaperStore` 复制到
/// `wallpaper/` 子目录，因此用户移动 / 删除原图不会让壁纸失效；「恢复默认」
/// 只删副本，**不触碰用户原图**。
///
/// 读取规则：版本 / 顶层结构 / 字段类型非法时抛出 [FormatException]（调用方保留原文件）。
class AppearancePreferences {
  static const int formatVersion = 1;

  /// 文件名允许的字符集：不含路径分隔符，配合 `WallpaperStore` 的目录约束。
  static final RegExp fileNamePattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$');

  /// 当前壁纸副本的文件名（相对 `wallpaper/` 目录）；null 表示使用默认深色背景。
  final String? wallpaperFileName;

  const AppearancePreferences({this.wallpaperFileName});

  /// 未设置壁纸（默认外观）。
  static const AppearancePreferences none = AppearancePreferences();

  bool get hasWallpaper =>
      wallpaperFileName != null && wallpaperFileName!.isNotEmpty;

  AppearancePreferences withWallpaper(String? fileName) =>
      AppearancePreferences(wallpaperFileName: fileName);

  static AppearancePreferences fromJson(Map<String, dynamic> json) {
    if (json['version'] != formatVersion) {
      throw const FormatException('外观偏好格式无效');
    }
    final raw = json['wallpaperFileName'];
    if (raw == null) return none;
    if (raw is! String) throw const FormatException('外观偏好格式无效');
    final name = raw.trim();
    if (name.isEmpty) return none;
    if (!fileNamePattern.hasMatch(name)) {
      throw const FormatException('外观偏好格式无效');
    }
    return AppearancePreferences(wallpaperFileName: name);
  }

  Map<String, dynamic> toJson() => {
        'version': formatVersion,
        'wallpaperFileName': wallpaperFileName,
      };

  @override
  bool operator ==(Object other) =>
      other is AppearancePreferences &&
      other.wallpaperFileName == wallpaperFileName;

  @override
  int get hashCode => wallpaperFileName.hashCode;

  @override
  String toString() =>
      'AppearancePreferences(wallpaperFileName: $wallpaperFileName)';
}
