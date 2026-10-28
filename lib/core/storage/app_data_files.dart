/// 应用数据目录中的持久化文件注册表。
///
/// 单一事实来源：缓存清理（SET-09）用它判断「哪些文件名可以出现在临时文件
/// 白名单里」，数据备份（SET-10）用它生成备份白名单。新增持久化文件时必须
/// 先在这里登记，再决定是否进入备份。
library;

/// 数据文件类别。备份默认排除 [AppDataCategory.window]。
enum AppDataCategory {
  configSnapshot,
  configSource,
  window,
  favorite,
  history,
  preference,
  live,
  player,
  /// 外观（SET-08）：偏好文件进备份没有意义——壁纸图片本体不在白名单里，
  /// 恢复后只会得到悬空引用；因此与窗口状态一样排除在备份之外。
  appearance,
}

class AppDataFile {
  final String name;
  final AppDataCategory category;

  /// 是否可能含订阅地址 / 请求头 / 令牌等敏感内容（用于备份提示）。
  final bool sensitive;

  const AppDataFile(this.name, this.category, {this.sensitive = false});
}

/// 应用数据目录中的 16 个持久化文件（2026-10-26 增补 §33 直播收藏）。
const List<AppDataFile> appDataFiles = [
  AppDataFile('appearance_preferences.json', AppDataCategory.appearance),
  AppDataFile('cached_vod_config.json', AppDataCategory.configSnapshot, sensitive: true),
  AppDataFile('config_sources.json', AppDataCategory.configSource, sensitive: true),
  AppDataFile('current_config.json', AppDataCategory.configSnapshot, sensitive: true),
  AppDataFile('desktop_window.json', AppDataCategory.window, sensitive: true),
  AppDataFile('favorites.json', AppDataCategory.favorite),
  AppDataFile('history.json', AppDataCategory.history),
  AppDataFile('history_preferences.json', AppDataCategory.preference),
  AppDataFile('home_site_preferences.json', AppDataCategory.preference),
  AppDataFile('live_sources.json', AppDataCategory.live, sensitive: true),
  // §33 直播收藏：与点播收藏分开存（模型不同），但同属「收藏」这一类，
  // 所以跟随 backupAppDataFiles 一起进备份 —— 用户换机后两个收藏都要在。
  AppDataFile('live_favorites.json', AppDataCategory.favorite),
  AppDataFile('play_skip_preferences.json', AppDataCategory.preference),
  AppDataFile('player_settings.json', AppDataCategory.player),
  AppDataFile('search_preferences.json', AppDataCategory.preference),
  AppDataFile('self_check_preferences.json', AppDataCategory.preference),
  AppDataFile('startup_preferences.json', AppDataCategory.preference),
];

/// 文件名集合，供临时文件基名白名单使用。
final Set<String> appDataFileNames =
    Set<String>.unmodifiable(appDataFiles.map((file) => file.name));

/// 备份白名单：排除窗口状态（恢复其他机器的位置可能把窗口放到不可见区域）
/// 与外观偏好（壁纸图片不在备份内，恢复只会得到失效引用）。
List<AppDataFile> get backupAppDataFiles => appDataFiles
    .where((file) =>
        file.category != AppDataCategory.window &&
        file.category != AppDataCategory.appearance)
    .toList(growable: false);

/// 备份白名单文件名集合。
final Set<String> backupAppDataFileNames = Set<String>.unmodifiable(
  backupAppDataFiles.map((file) => file.name),
);

bool isAppDataFileName(String name) => appDataFileNames.contains(name);

bool isBackupAppDataFileName(String name) =>
    backupAppDataFileNames.contains(name);
