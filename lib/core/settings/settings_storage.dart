import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../config/windows_config_storage.dart';
import '../player/models/player_settings.dart';
import '../storage/data_restore_guard.dart';
import 'models/config_source_entry.dart';
import 'models/appearance_preferences.dart';
import 'models/history_preferences.dart';
import 'models/play_skip_preferences.dart';
import 'models/search_preferences.dart';
import 'models/self_check_preferences.dart';
import 'models/startup_preferences.dart';

/// 设置中心持久化接口
abstract class SettingsStorage {
  /// 读取播放器设置；文件不存在时返回 null（便于从旧配置迁移）
  Future<PlayerSettings?> readPlayerSettings();
  Future<void> savePlayerSettings(PlayerSettings settings);

  /// 读取配置源历史；文件不存在时返回 null
  Future<List<ConfigSourceEntry>?> readConfigSources();
  Future<void> saveConfigSources(List<ConfigSourceEntry> entries);

  /// 读取启动偏好；文件不存在或内容为空时返回 null（首启按默认处理），
  /// 结构损坏 / 版本不符 / 字段类型非法时抛出 [FormatException]（调用方保留原文件并提示）
  Future<StartupPreferences?> readStartupPreferences();
  Future<void> saveStartupPreferences(StartupPreferences preferences);

  /// 读取搜索偏好；文件不存在或内容为空时返回 null（首启按默认处理），
  /// 结构损坏 / 版本不符 / 字段类型非法时抛出 [FormatException]（调用方保留原文件并提示）
  Future<SearchPreferences?> readSearchPreferences();
  Future<void> saveSearchPreferences(SearchPreferences preferences);

  /// 读取历史记录数量偏好；文件不存在或内容为空时返回 null（首启按默认处理），
  /// 结构损坏 / 版本不符 / 字段类型非法时抛出 [FormatException]（调用方保留原文件并提示）
  Future<HistoryPreferences?> readHistoryPreferences();
  Future<void> saveHistoryPreferences(HistoryPreferences preferences);

  /// 读取站点自检偏好；文件不存在或内容为空时返回 null（首启按默认「关闭」处理），
  /// 结构损坏 / 版本不符 / 字段类型非法时抛出 [FormatException]（调用方保留原文件并提示）
  Future<SelfCheckPreferences?> readSelfCheckPreferences();
  Future<void> saveSelfCheckPreferences(SelfCheckPreferences preferences);

  /// 读取片头 / 片尾偏好；文件不存在或内容为空时返回 null（首启按「开启、无记录」处理），
  /// 版本 / 顶层结构非法时抛出 [FormatException]（调用方保留原文件并提示）
  Future<PlaySkipPreferences?> readPlaySkipPreferences();
  Future<void> savePlaySkipPreferences(PlaySkipPreferences preferences);

  /// 读取外观偏好（SET-08：壁纸）；文件不存在或内容为空时返回 null（首启按默认外观处理），
  /// 版本 / 顶层结构 / 文件名字段非法时抛出 [FormatException]（调用方保留原文件并提示）
  Future<AppearancePreferences?> readAppearancePreferences();
  Future<void> saveAppearancePreferences(AppearancePreferences preferences);

  /// 缺省实现：写入 %APPDATA%/XiugouTV
  factory SettingsStorage.windows({Future<Directory> Function()? directory}) = FileSettingsStorage;
}

/// 基于 JSON 文件的设置存储（与其他配置同目录，各自独立文件）
class FileSettingsStorage implements SettingsStorage {
  static const String playerSettingsFileName = 'player_settings.json';
  static const String configSourcesFileName = 'config_sources.json';
  static const String startupPreferencesFileName = 'startup_preferences.json';
  static const String searchPreferencesFileName = 'search_preferences.json';
  static const String historyPreferencesFileName = 'history_preferences.json';
  static const String selfCheckPreferencesFileName = 'self_check_preferences.json';
  static const String playSkipPreferencesFileName = 'play_skip_preferences.json';
  static const String appearancePreferencesFileName = 'appearance_preferences.json';

  final Future<Directory> Function() _directory;
  static int _temporarySequence = 0;

  FileSettingsStorage({Future<Directory> Function()? directory})
      : _directory = directory ?? WindowsConfigStorage().getStorageDirectory;

  Future<File> _file(String name) async => File(p.join((await _directory()).path, name));

  Future<Object?> _readJson(String name) async {
    final file = await _file(name);
    if (!await file.exists()) return null;
    final content = await file.readAsString();
    if (content.trim().isEmpty) return null;
    return jsonDecode(content);
  }

  @override
  Future<PlayerSettings?> readPlayerSettings() async {
    try {
      final decoded = await _readJson(playerSettingsFileName);
      if (decoded == null) return null;
      if (decoded is! Map) return PlayerSettings.defaults;
      return PlayerSettings.fromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      // 文件损坏：使用默认值，下次保存时覆盖
      return PlayerSettings.defaults;
    }
  }

  @override
  Future<void> savePlayerSettings(PlayerSettings settings) async {
    await _atomicWrite(await _file(playerSettingsFileName), jsonEncode(settings.toJson()));
  }

  @override
  Future<List<ConfigSourceEntry>?> readConfigSources() async {
    try {
      final decoded = await _readJson(configSourcesFileName);
      if (decoded == null) return null;
      if (decoded is! List) return const [];
      return decoded.map(ConfigSourceEntry.tryFromJson).whereType<ConfigSourceEntry>().toList();
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<void> saveConfigSources(List<ConfigSourceEntry> entries) async {
    final json = jsonEncode(entries.map((e) => e.toJson()).toList());
    await _atomicWrite(await _file(configSourcesFileName), json);
  }

  @override
  Future<StartupPreferences?> readStartupPreferences() async {
    final decoded = await _readJson(startupPreferencesFileName);
    if (decoded == null) return null;
    if (decoded is! Map) throw const FormatException('启动偏好格式无效');
    final map = <String, dynamic>{};
    for (final entry in decoded.entries) {
      if (entry.key is! String) throw const FormatException('启动偏好格式无效');
      map[entry.key as String] = entry.value;
    }
    return StartupPreferences.fromJson(map);
  }

  @override
  Future<void> saveStartupPreferences(StartupPreferences preferences) async {
    await _atomicWrite(await _file(startupPreferencesFileName), jsonEncode(preferences.toJson()));
  }

  @override
  Future<SearchPreferences?> readSearchPreferences() async {
    final decoded = await _readJson(searchPreferencesFileName);
    if (decoded == null) return null;
    if (decoded is! Map) throw const FormatException('搜索偏好格式无效');
    final map = <String, dynamic>{};
    for (final entry in decoded.entries) {
      if (entry.key is! String) throw const FormatException('搜索偏好格式无效');
      map[entry.key as String] = entry.value;
    }
    return SearchPreferences.fromJson(map);
  }

  @override
  Future<void> saveSearchPreferences(SearchPreferences preferences) async {
    await _atomicWrite(await _file(searchPreferencesFileName), jsonEncode(preferences.toJson()));
  }

  @override
  Future<HistoryPreferences?> readHistoryPreferences() async {
    final decoded = await _readJson(historyPreferencesFileName);
    if (decoded == null) return null;
    if (decoded is! Map) throw const FormatException('历史偏好格式无效');
    final map = <String, dynamic>{};
    for (final entry in decoded.entries) {
      if (entry.key is! String) throw const FormatException('历史偏好格式无效');
      map[entry.key as String] = entry.value;
    }
    return HistoryPreferences.fromJson(map);
  }

  @override
  Future<void> saveHistoryPreferences(HistoryPreferences preferences) async {
    await _atomicWrite(await _file(historyPreferencesFileName), jsonEncode(preferences.toJson()));
  }

  @override
  Future<SelfCheckPreferences?> readSelfCheckPreferences() async {
    final decoded = await _readJson(selfCheckPreferencesFileName);
    if (decoded == null) return null;
    if (decoded is! Map) throw const FormatException('自检偏好格式无效');
    final map = <String, dynamic>{};
    for (final entry in decoded.entries) {
      if (entry.key is! String) throw const FormatException('自检偏好格式无效');
      map[entry.key as String] = entry.value;
    }
    return SelfCheckPreferences.fromJson(map);
  }

  @override
  Future<void> saveSelfCheckPreferences(SelfCheckPreferences preferences) async {
    await _atomicWrite(await _file(selfCheckPreferencesFileName), jsonEncode(preferences.toJson()));
  }

  @override
  Future<PlaySkipPreferences?> readPlaySkipPreferences() async {
    final decoded = await _readJson(playSkipPreferencesFileName);
    if (decoded == null) return null;
    if (decoded is! Map) throw const FormatException('片头片尾偏好格式无效');
    final map = <String, dynamic>{};
    for (final entry in decoded.entries) {
      if (entry.key is! String) throw const FormatException('片头片尾偏好格式无效');
      map[entry.key as String] = entry.value;
    }
    return PlaySkipPreferences.fromJson(map);
  }

  @override
  Future<void> savePlaySkipPreferences(PlaySkipPreferences preferences) async {
    await _atomicWrite(await _file(playSkipPreferencesFileName), jsonEncode(preferences.toJson()));
  }

  @override
  Future<AppearancePreferences?> readAppearancePreferences() async {
    final decoded = await _readJson(appearancePreferencesFileName);
    if (decoded == null) return null;
    if (decoded is! Map) throw const FormatException('外观偏好格式无效');
    final map = <String, dynamic>{};
    for (final entry in decoded.entries) {
      if (entry.key is! String) throw const FormatException('外观偏好格式无效');
      map[entry.key as String] = entry.value;
    }
    return AppearancePreferences.fromJson(map);
  }

  @override
  Future<void> saveAppearancePreferences(AppearancePreferences preferences) async {
    await _atomicWrite(await _file(appearancePreferencesFileName), jsonEncode(preferences.toJson()));
  }

  /// 同目录替换成功前不删除旧文件；失败时尽力清理临时文件。
  Future<void> _atomicWrite(File target, String content) async {
    // 数据恢复完成后禁止落盘，避免旧内存快照覆盖刚恢复的文件；重启后解除。
    // 设置都是用户主动修改：抛出让仓库记录失败并由横幅提示「未保存」。
    if (dataRestorePendingRestart) {
      throw const DataRestorePendingRestartException();
    }
    final temp = File('${target.path}.tmp-$pid-${++_temporarySequence}');
    try {
      await temp.writeAsString(content, flush: true);
      await temp.rename(target.path);
    } finally {
      try {
        if (await temp.exists()) await temp.delete();
      } on FileSystemException {
        // 清理失败不能掩盖原始保存错误，旧目标文件仍由替换操作保护。
      }
    }
  }
}
