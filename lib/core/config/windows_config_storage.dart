import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../api/models/vod_models.dart';
import '../storage/data_directory_manager.dart';
import '../storage/data_restore_guard.dart';
import 'models/desktop_window_config.dart';
import 'models/config_snapshot.dart';
import 'models/history_record.dart';
import 'models/home_site_preference.dart';
import 'models/vod_config.dart';

/// Windows 平台本地持久化文件存储驱动
class WindowsConfigStorage {
  static const String _windowConfigFileName = 'desktop_window.json';
  static const String _vodConfigCacheFileName = 'cached_vod_config.json';
  static const String _historyFileName = 'history.json';
  static const String _favoritesFileName = 'favorites.json';

  Directory? _baseDir;

  /// 存储目录路径（同步计算，不触盘）。
  ///
  /// N-2：默认仍是 `%APPDATA%/XiugouTV`（环境变量缺失时 `%USERPROFILE%/.XiugouTV`），
  /// 若用户在设置里选择了自定义目录，则由 [DataDirectoryManager] 在启动时解析并返回。
  /// 供不便等待异步 IO 的诊断展示等场景使用。
  static String storageDirectoryPath() => DataDirectoryManager.currentPath;

  /// 获取或初始化 Windows 专用数据目录 (%APPDATA%/XiugouTV)
  Future<Directory> getStorageDirectory() async {
    if (_baseDir != null) return _baseDir!;

    final dir = Directory(storageDirectoryPath());
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _baseDir = dir;
    return dir;
  }

  /// 读取 Windows 桌面窗口配置
  Future<DesktopWindowConfig> readWindowConfig() async {
    try {
      final dir = await getStorageDirectory();
      final file = File(p.join(dir.path, _windowConfigFileName));
      if (!await file.exists()) {
        return const DesktopWindowConfig();
      }

      final content = await file.readAsString();
      if (content.trim().isEmpty) {
        return const DesktopWindowConfig();
      }

      final map = jsonDecode(content) as Map<String, dynamic>;
      return DesktopWindowConfig.fromJson(map);
    } catch (_) {
      return const DesktopWindowConfig();
    }
  }

  /// 保存 Windows 桌面窗口配置（原子写入）
  Future<void> saveWindowConfig(DesktopWindowConfig config) async {
    final dir = await getStorageDirectory();
    final targetPath = p.join(dir.path, _windowConfigFileName);
    await _atomicWrite(targetPath, jsonEncode(config.toJson()));
  }

  /// 读取本地缓存的影视配置 (VodConfig)
  Future<VodConfig?> readCachedVodConfig() async {
    try {
      final dir = await getStorageDirectory();
      final file = File(p.join(dir.path, _vodConfigCacheFileName));
      if (!await file.exists()) return null;

      final content = await file.readAsString();
      return VodConfig.parseRawString(content);
    } catch (_) {
      return null;
    }
  }

  /// 读取本地缓存的影视配置原文（用于导出；不存在时返回 null）
  Future<String?> readCachedVodConfigRaw() async {
    try {
      final dir = await getStorageDirectory();
      final file = File(p.join(dir.path, _vodConfigCacheFileName));
      if (!await file.exists()) return null;
      final content = await file.readAsString();
      return content.trim().isEmpty ? null : content;
    } catch (_) {
      return null;
    }
  }

  /// 缓存影视配置到本地文件
  Future<void> saveCachedVodConfig(String rawConfigContent) async {
    final dir = await getStorageDirectory();
    final targetPath = p.join(dir.path, _vodConfigCacheFileName);
    await _atomicWrite(targetPath, rawConfigContent);
  }

  /// 仅文件不存在时回退旧格式；读取失败不能将旧订阅误判为当前来源。
  Future<ConfigSnapshot?> readCurrentConfig() async {
    final dir = await getStorageDirectory();
    final file = File(p.join(dir.path, 'current_config.json'));
    if (!await file.exists()) return null;
    return ConfigSnapshot.fromJson(jsonDecode(await file.readAsString()) as Map<String, dynamic>);
  }

  Future<void> saveCurrentConfig(ConfigSnapshot snapshot) async {
    final dir = await getStorageDirectory();
    await _atomicWrite(p.join(dir.path, 'current_config.json'), jsonEncode(snapshot.toJson()));
  }

  Future<Map<String, HomeSitePreference>> readHomeSitePreferences() async {
    final dir = await getStorageDirectory();
    final file = File(p.join(dir.path, 'home_site_preferences.json'));
    if (!await file.exists()) return {};
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map || decoded['version'] != 1 || decoded['sources'] is! Map) {
      throw const FormatException('首页站源偏好格式无效');
    }
    final preferences = <String, HomeSitePreference>{};
    for (final entry in (decoded['sources'] as Map).entries) {
      final identity = entry.key;
      final preference = HomeSitePreference.tryFromJson(entry.value);
      if (identity is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(identity) || preference == null) {
        throw const FormatException('首页站源偏好条目无效');
      }
      preferences[identity] = preference;
    }
    return preferences;
  }

  Future<void> saveHomeSitePreferences(Map<String, HomeSitePreference> preferences) async {
    final dir = await getStorageDirectory();
    await _atomicWrite(p.join(dir.path, 'home_site_preferences.json'), jsonEncode({
      'version': 1,
      'sources': preferences.map((key, value) => MapEntry(key, value.toJson())),
    }), throwWhenBlocked: true);
  }

  /// 读取播放历史记录列表
  Future<List<HistoryRecord>> readHistory() async {
    try {
      final dir = await getStorageDirectory();
      final file = File(p.join(dir.path, _historyFileName));
      if (!await file.exists()) return [];

      final content = await file.readAsString();
      if (content.trim().isEmpty) return [];

      final decoded = jsonDecode(content);
      if (decoded is! List) return [];

      return decoded
          .whereType<Map<String, dynamic>>()
          .map(HistoryRecord.fromJson)
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// 保存播放历史记录列表
  Future<void> saveHistory(List<HistoryRecord> records) async {
    final dir = await getStorageDirectory();
    final targetPath = p.join(dir.path, _historyFileName);
    final jsonList = records.map((e) => e.toJson()).toList();
    await _atomicWrite(targetPath, jsonEncode(jsonList));
  }

  /// 读取收藏列表
  Future<List<VodItem>> readFavorites() async {
    try {
      final dir = await getStorageDirectory();
      final file = File(p.join(dir.path, _favoritesFileName));
      if (!await file.exists()) return [];

      final content = await file.readAsString();
      if (content.trim().isEmpty) return [];

      final decoded = jsonDecode(content);
      if (decoded is! List) return [];

      return decoded
          .whereType<Map<String, dynamic>>()
          .map(VodItem.fromJson)
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// 保存收藏列表
  Future<void> saveFavorites(List<VodItem> items) async {
    final dir = await getStorageDirectory();
    final targetPath = p.join(dir.path, _favoritesFileName);
    final jsonList = items.map((e) => e.toJson()).toList();
    await _atomicWrite(targetPath, jsonEncode(jsonList), throwWhenBlocked: true);
  }

  static int _temporarySequence = 0;

  Future<void> _atomicWrite(String filePath, String content,
      {bool throwWhenBlocked = false}) async {
    // 数据恢复完成后禁止落盘，避免旧内存快照覆盖刚恢复的文件；重启后解除。
    // 收藏 / 首页站源是用户主动操作：抛出让调用方提示「本次修改未保存」；
    // 历史 / 窗口属于后台写入，保持静默跳过，不打断播放。
    if (dataRestorePendingRestart) {
      if (throwWhenBlocked) {
        throw const DataRestorePendingRestartException();
      }
      return;
    }
    final tempFile = File('$filePath.tmp-$pid-${++_temporarySequence}');
    try {
      await tempFile.writeAsString(content, flush: true);
      await tempFile.rename(filePath);
    } finally {
      try {
        if (await tempFile.exists()) await tempFile.delete();
      } catch (_) {
        // 清理失败不能掩盖原始保存异常。
      }
    }
  }
}
