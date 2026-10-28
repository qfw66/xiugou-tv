import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../config/windows_config_storage.dart';
import '../player/models/player_settings.dart';
import '../settings/models/history_preferences.dart';
import '../settings/models/play_skip_preferences.dart';
import '../settings/models/search_preferences.dart';
import '../settings/models/self_check_preferences.dart';
import '../settings/models/startup_preferences.dart';
import 'app_data_files.dart';
import 'models/data_backup.dart';

/// 备份 / 恢复失败：消息可直接展示给用户。
class DataBackupException implements Exception {
  final String message;
  const DataBackupException(this.message);

  @override
  String toString() => message;
}

/// 恢复结果：已恢复文件与恢复前自动备份路径。
class DataRestoreResult {
  final List<String> restoredFiles;
  final String preRestorePath;

  /// 恢复前存在、但因过大或不可读而没能进入恢复前备份的文件名。
  final List<String> preRestoreSkipped;

  const DataRestoreResult({
    required this.restoredFiles,
    required this.preRestorePath,
    this.preRestoreSkipped = const [],
  });
}

/// 单文件写入器（测试可注入以模拟部分写入失败）。
typedef BackupFileWriter = Future<void> Function(String path, String content);

/// 数据备份与恢复服务（SET-10）。
///
/// 格式：单文件 JSON 信封 v1，只存 13 个备份白名单文件的原文 + UTF-8 字节数
/// + SHA-256；不含窗口状态、JRE/JAR、缓存、日志或备份自身。
class DataBackupService {
  static const int maxTotalBytes = 20 * 1024 * 1024;
  static const int maxEntryBytes = 10 * 1024 * 1024;
  static const int maxCachedConfigBytes = 5 * 1024 * 1024;
  /// 备份条目上限 = 白名单长度：注册表扩容后不会出现「能导出、不能恢复」的备份。
  static int get maxFiles => backupAppDataFiles.length;
  static const int maxPreRestoreBackups = 10;
  static const Duration flushTimeoutDefault = Duration(seconds: 5);

  final Future<Directory> Function() _directory;
  final DateTime Function() _clock;
  final String Function()? _appVersion;
  final Future<void> Function()? _flushPendingWrites;
  final BackupFileWriter? _writer;
  final int _currentPid;
  final Duration _flushTimeout;

  int _sequence = 0;

  DataBackupService({
    Future<Directory> Function()? directory,
    DateTime Function()? clock,
    String Function()? appVersion,
    Future<void> Function()? flushPendingWrites,
    BackupFileWriter? writer,
    int? currentPid,
    Duration flushTimeout = flushTimeoutDefault,
  })  : _directory =
            directory ?? WindowsConfigStorage().getStorageDirectory,
        _clock = clock ?? DateTime.now,
        _appVersion = appVersion,
        _flushPendingWrites = flushPendingWrites,
        _writer = writer,
        _currentPid = currentPid ?? pid,
        _flushTimeout = flushTimeout;


  /// 读取当前 13 个数据文件并生成备份对象；不写盘。
  ///
  /// [allowInvalid] 为 true 时用于「恢复前自动备份」：即使当前数据为空 /
  /// 结构损坏 / 单文件不可读，也尽量保留原文，避免因坏数据而无法恢复。
  Future<DataBackup> buildBackup(
      {String? appVersion, bool allowInvalid = false}) async {
    await _flush();
    final directory = await _directory();
    if (!await directory.exists()) {
      throw const DataBackupException('数据目录不存在，没有可备份的数据');
    }

    var consistent = true;
    final files = <String, DataBackupEntry>{};
    var totalBytes = 0;

    for (final file in backupAppDataFiles) {
      final path = p.join(directory.path, file.name);
      final entity = File(path);
      final firstStat = await _statOrNull(entity);
      if (firstStat == null) continue; // 未创建的文件不生成空条目

      try {
        var bytes = await entity.readAsBytes();
        var stat = await _statOrNull(entity);
        if (stat == null ||
            stat.size != firstStat.size ||
            stat.modified != firstStat.modified) {
          // 读取期间被写入：重读一次；仍变化则标记为可能不一致。
          bytes = await entity.readAsBytes();
          stat = await _statOrNull(entity);
          if (stat == null ||
              stat.size != bytes.length ||
              stat.modified != firstStat.modified) {
            consistent = false;
          }
        }

        final content = _decodeUtf8(bytes, file.name);
        if (!allowInvalid) {
          _validateEntry(file.name, content);
        }
        if (bytes.length > maxEntryBytes) {
          throw DataBackupException('${file.name} 超过单文件备份上限');
        }
        totalBytes += bytes.length;
        if (totalBytes > maxTotalBytes) {
          throw const DataBackupException('数据总大小超过备份上限');
        }
        files[file.name] = DataBackupEntry(
          name: file.name,
          size: bytes.length,
          sha256: sha256.convert(bytes).toString(),
          content: content,
        );
      } catch (_) {
        if (!allowInvalid) rethrow;
        // 恢复前备份：单文件读不出原文时跳过，至少保留其余文件。
      }
    }

    if (files.isEmpty && !allowInvalid) {
      throw const DataBackupException('没有可备份的数据文件');
    }
    return DataBackup(
      createdAt: _clock(),
      appVersion: appVersion ?? _appVersion?.call(),
      consistent: consistent,
      files: Map.unmodifiable(files),
    );
  }

  /// 生成备份并写入 [targetPath]；目标不得位于应用数据目录内。
  Future<void> exportBackup(String targetPath, {String? appVersion}) async {
    final backup = await buildBackup(appVersion: appVersion);
    final directory = await _directory();
    final base = p.normalize(p.absolute(directory.path));
    final target = p.normalize(p.absolute(targetPath));
    if (p.equals(target, base) || p.isWithin(base, target)) {
      throw const DataBackupException('备份不能保存到应用数据目录内，请换一个位置');
    }
    final parent = Directory(p.dirname(target));
    if (!await parent.exists()) {
      throw const DataBackupException('备份保存目录不存在');
    }
    await _write(target, backup.encode());
  }

  /// 读取并校验备份文件；任一条目不合格整份拒绝。
  Future<DataBackup> readBackupFile(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw const DataBackupException('备份文件不存在');
    }
    final length = await file.length();
    if (length > maxTotalBytes) {
      throw const DataBackupException('备份文件超过 20 MB 上限');
    }
    final raw = await file.readAsBytes();
    final content = _decodeUtf8(raw, '备份文件');
    Object? decoded;
    try {
      decoded = jsonDecode(content);
    } catch (_) {
      throw const DataBackupException('备份文件不是有效 JSON');
    }
    if (decoded is! Map) {
      throw const DataBackupException('备份文件结构无效');
    }
    final DataBackup backup;
    try {
      backup = DataBackup.fromJson(Map<String, dynamic>.from(decoded));
    } on FormatException catch (error) {
      throw DataBackupException(error.message);
    }
    if (backup.files.length > maxFiles) {
      throw const DataBackupException('备份条目数超过上限');
    }

    var total = 0;
    for (final entry in backup.files.values) {
      if (!backupAppDataFileNames.contains(entry.name)) {
        throw DataBackupException('备份包含不允许的文件：${entry.name}');
      }
      final bytes = utf8.encode(entry.content);
      if (bytes.length != entry.size) {
        throw DataBackupException('${entry.name} 大小校验失败');
      }
      if (sha256.convert(bytes).toString() != entry.sha256) {
        throw DataBackupException('${entry.name} 校验失败，备份可能损坏');
      }
      if (entry.size > maxEntryBytes) {
        throw DataBackupException('${entry.name} 超过单文件上限');
      }
      total += entry.size;
      if (total > maxTotalBytes) {
        throw const DataBackupException('备份内容超过 20 MB 上限');
      }
      _validateEntry(entry.name, entry.content);
    }
    if (backup.files.isEmpty) {
      throw const DataBackupException('备份不包含任何数据文件');
    }
    return backup;
  }

  /// 恢复备份：先自动备份当前数据，再逐文件原子写入；失败时回滚已写入文件。
  ///
  /// [expected] 为确认框中已校验过的备份对象；传入时不再重读文件，
  /// 避免确认期间文件被替换导致「看到的」与「写入的」不一致。
  Future<DataRestoreResult> restoreBackup(String path,
      {DataBackup? expected}) async {
    final backup = expected ?? await readBackupFile(path);
    await _flush();

    final directory = await _directory();
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }

    final preRestore = await _createPreRestoreBackup();
    final applied = <String>[];

    for (final entry in backup.files.values) {
      try {
        final target = await _targetPath(directory, entry.name);
        await _write(target, entry.content);
        applied.add(entry.name);
      } catch (error) {
        final rollbackFailures = await _rollback(applied, preRestore);
        final detail = rollbackFailures.isEmpty
            ? '已自动回滚到恢复前状态'
            : '自动回滚未完成：${rollbackFailures.join('；')}';
        throw DataBackupException(
          '恢复失败（${entry.name} 写入失败），$detail。'
          '恢复前备份：${preRestore.path}',
        );
      }
    }

    await _prunePreRestoreBackups();
    final skipped = preRestore.existedNames
        .difference(preRestore.backup.files.keys.toSet())
        .toList()
      ..sort();
    return DataRestoreResult(
      restoredFiles: List.unmodifiable(applied),
      preRestorePath: preRestore.path,
      preRestoreSkipped: List.unmodifiable(skipped),
    );
  }

  Future<void> _flush() async {
    final flush = _flushPendingWrites;
    if (flush == null) return;
    try {
      await flush().timeout(_flushTimeout);
    } on TimeoutException {
      throw const DataBackupException('有数据正在写入，请稍后重试');
    } catch (error) {
      throw DataBackupException('等待数据写入失败：$error');
    }
  }

  Future<_PreRestoreBackup> _createPreRestoreBackup() async {
    final directory = await _directory();
    // 先记录「恢复前已存在」的文件：前置备份是尽力而为的，过大/不可读的文件
    // 可能没有被捕获进 backup.files；回滚时必须区分「本来不存在」与「存在但未备份」，
    // 后者绝不能删除，否则会丢掉用户数据。
    final existed = <String>{};
    for (final file in backupAppDataFiles) {
      final type = await FileSystemEntity.type(
        p.join(directory.path, file.name),
        followLinks: false,
      );
      if (type == FileSystemEntityType.file ||
          type == FileSystemEntityType.link) {
        existed.add(file.name);
      }
    }
    final backup = await buildBackup(allowInvalid: true);
    final backups = Directory(p.join(directory.path, 'backups'));
    if (!await backups.exists()) {
      await backups.create(recursive: true);
    }
    final stamp = _timestamp(_clock());
    final path = p.join(backups.path, 'pre-restore-$stamp.json');
    await _write(path, backup.encode());
    return _PreRestoreBackup(
        backup: backup, path: path, existedNames: existed);
  }

  Future<List<String>> _rollback(
      List<String> applied, _PreRestoreBackup preRestore) async {
    final directory = await _directory();
    final failures = <String>[];
    for (final name in applied.reversed) {
      final entry = preRestore.backup.files[name];
      final target = p.join(directory.path, name);
      try {
        if (entry == null) {
          if (preRestore.existedNames.contains(name)) {
            // 恢复前存在却没被前置备份捕获（过大/不可读）：保留现状，绝不删除。
            failures.add('$name: 恢复前未备份，已保留恢复写入的内容');
            continue;
          }
          // 恢复前不存在：回滚应删除新建文件。
          final file = File(target);
          if (await file.exists()) await file.delete();
        } else {
          await _write(target, entry.content);
        }
      } catch (error) {
        failures.add('$name: $error');
      }
    }
    return failures;
  }

  Future<void> _prunePreRestoreBackups() async {
    try {
      final directory = await _directory();
      final backups = Directory(p.join(directory.path, 'backups'));
      if (!await backups.exists()) return;
      final files = <File>[];
      await for (final entity in backups.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        if (name.startsWith('pre-restore-') && name.endsWith('.json')) {
          files.add(entity);
        }
      }
      files.sort((a, b) => a.path.compareTo(b.path));
      final removeCount = files.length - maxPreRestoreBackups;
      for (var i = 0; i < removeCount; i++) {
        try {
          await files[i].delete();
        } catch (_) {
          // 清理旧备份失败不影响本次恢复结果。
        }
      }
    } catch (_) {
      // 备份目录不可读时忽略清理。
    }
  }

  Future<String> _targetPath(Directory directory, String name) async {
    if (!backupAppDataFileNames.contains(name)) {
      throw DataBackupException('不允许恢复到 $name');
    }
    if (!RegExp(r'^[a-z_]+\.json$').hasMatch(name) ||
        name.contains('..') ||
        name.contains('/') ||
        name.contains('\\') ||
        name.contains(':')) {
      throw DataBackupException('备份文件名不合法：$name');
    }
    final base = p.normalize(directory.path);
    final target = p.normalize(p.join(base, name));
    if (p.dirname(target) != base) {
      throw DataBackupException('目标路径越界：$name');
    }
    final type = await FileSystemEntity.type(target, followLinks: false);
    if (type == FileSystemEntityType.link) {
      throw DataBackupException('目标是链接，拒绝覆盖：$name');
    }
    return target;
  }

  Future<void> _write(String target, String content) async {
    final writer = _writer;
    if (writer != null) {
      await writer(target, content);
      return;
    }
    final temp = File('$target.tmp-$_currentPid-${++_sequence}');
    try {
      await temp.writeAsString(content, flush: true);
      await temp.rename(target);
    } finally {
      try {
        if (await temp.exists()) await temp.delete();
      } catch (_) {
        // 清理失败不能掩盖原始写入异常。
      }
    }
  }

  Future<FileStat?> _statOrNull(File file) async {
    try {
      final stat = await file.stat();
      return stat.type == FileSystemEntityType.file ? stat : null;
    } catch (_) {
      return null;
    }
  }

  String _decodeUtf8(List<int> bytes, String label) {
    try {
      return utf8.decode(bytes);
    } catch (_) {
      throw DataBackupException('$label 不是有效 UTF-8 文本');
    }
  }

  void _validateEntry(String name, String content) {
    try {
      switch (name) {
        case 'history.json':
          _validateList(content, name, maxItems: 10000);
          break;
        case 'favorites.json':
          _validateList(content, name, maxItems: 5000);
          break;
        case 'live_favorites.json':
          // 直播频道没有海报，单条体积小；上限对齐收藏量级即可。
          _validateList(content, name, maxItems: 2000);
          break;
        case 'live_sources.json':
          _validateList(content, name, maxItems: 1000);
          break;
        case 'config_sources.json':
          _validateList(content, name, maxItems: 500);
          break;
        case 'current_config.json':
          final map = _map(content, name);
          if (map['version'] != 1 || map['rawContent'] is! String) {
            throw const FormatException('当前配置快照格式无效');
          }
          final kind = map['sourceKind'];
          if (kind != null && kind != 'url' && kind != 'file' && kind != 'paste') {
            throw const FormatException('当前配置来源类型无效');
          }
          if (kind == 'url' || kind == 'file') {
            final location = map['sourceLocation'];
            if (location is! String || location.trim().isEmpty) {
              throw const FormatException('当前配置来源位置缺失');
            }
          }
          break;
        case 'cached_vod_config.json':
          if (content.trim().isEmpty ||
              utf8.encode(content).length > maxCachedConfigBytes) {
            throw const FormatException('配置缓存为空或过大');
          }
          break;
        case 'home_site_preferences.json':
          final map = _map(content, name);
          if (map['version'] != 1 || map['sources'] is! Map) {
            throw const FormatException('首页站源偏好格式无效');
          }
          for (final key in (map['sources'] as Map).keys) {
            if (key is! String ||
                !RegExp(r'^[a-f0-9]{64}$').hasMatch(key)) {
              throw const FormatException('首页站源偏好条目无效');
            }
          }
          break;
        case 'play_skip_preferences.json':
          PlaySkipPreferences.fromJson(_map(content, name));
          break;
        case 'player_settings.json':
          PlayerSettings.fromJson(_map(content, name));
          break;
        case 'history_preferences.json':
          HistoryPreferences.fromJson(_map(content, name));
          break;
        case 'search_preferences.json':
          SearchPreferences.fromJson(_map(content, name));
          break;
        case 'self_check_preferences.json':
          SelfCheckPreferences.fromJson(_map(content, name));
          break;
        case 'startup_preferences.json':
          StartupPreferences.fromJson(_map(content, name));
          break;
        default:
          throw FormatException('不允许的备份文件：$name');
      }
    } on FormatException catch (error) {
      throw DataBackupException('${error.message}（$name）');
    }
  }

  Map<String, dynamic> _map(String content, String name) {
    final decoded = jsonDecode(content);
    if (decoded is! Map) {
      throw FormatException('$name 结构无效');
    }
    return Map<String, dynamic>.from(decoded);
  }

  void _validateList(String content, String name, {required int maxItems}) {
    final decoded = jsonDecode(content);
    if (decoded is! List) {
      throw FormatException('$name 结构无效');
    }
    if (decoded.length > maxItems) {
      throw FormatException('$name 条数超过上限');
    }
    for (final item in decoded) {
      if (item is! Map) {
        throw FormatException('$name 条目无效');
      }
    }
  }
}

String _timestamp(DateTime time) {
  final utc = time.toUtc();
  String two(int value) => value.toString().padLeft(2, '0');
  String three(int value) => value.toString().padLeft(3, '0');
  return '${utc.year}${two(utc.month)}${two(utc.day)}-'
      '${two(utc.hour)}${two(utc.minute)}${two(utc.second)}-'
      '${three(utc.millisecond)}';
}

class _PreRestoreBackup {
  final DataBackup backup;
  final String path;

  /// 恢复开始前实际存在的白名单文件名（含未进 [backup.files] 的跳过项）。
  final Set<String> existedNames;

  const _PreRestoreBackup({
    required this.backup,
    required this.path,
    required this.existedNames,
  });
}
