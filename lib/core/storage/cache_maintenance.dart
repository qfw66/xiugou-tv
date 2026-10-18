import 'dart:io';

import 'package:path/path.dart' as p;

import '../config/windows_config_storage.dart';
import 'app_data_files.dart';

/// 用户数据文件的可读状态（只读 stat，不读内容）。
class AppDataFileStatus {
  final AppDataFile file;
  final int bytes;
  final DateTime modified;

  const AppDataFileStatus({
    required this.file,
    required this.bytes,
    required this.modified,
  });
}

/// 孤儿临时文件信息（只读 stat）。
class TempFileInfo {
  final String name;
  final String path;
  final int bytes;
  final DateTime modified;

  const TempFileInfo({
    required this.name,
    required this.path,
    required this.bytes,
    required this.modified,
  });
}

class CacheInventory {
  final List<AppDataFileStatus> userFiles;
  final List<TempFileInfo> tempFiles;

  /// 数据目录不存在 / 不可读时为 false；此时两个列表均为空。
  final bool directoryReadable;

  const CacheInventory({
    this.userFiles = const [],
    this.tempFiles = const [],
    this.directoryReadable = true,
  });

  int get userDataBytes =>
      userFiles.fold<int>(0, (sum, status) => sum + status.bytes);

  int get tempBytes =>
      tempFiles.fold<int>(0, (sum, info) => sum + info.bytes);

  int get userFileCount => userFiles.length;

  int get tempFileCount => tempFiles.length;
}

class TempCleanupResult {
  final int deleted;
  final int skipped;
  final int failed;

  const TempCleanupResult({
    this.deleted = 0,
    this.skipped = 0,
    this.failed = 0,
  });

  int get total => deleted + skipped + failed;
}

/// 分类清理缓存的底层服务（SET-09）。
///
/// 只处理「已核实的应用缓存」：
/// - 图片 / EPG 内存缓存由调用方通过回调清理（本服务不依赖 Flutter）；
/// - 孤儿临时文件必须同时满足：基名在 [appDataFiles] 中、严格匹配
///   `<name>.tmp-<pid>-<seq>` 或 `live_sources.json.tmp-<seq>`、普通文件、
///   修改时间超过 24 小时、非当前进程。
///
/// 本服务**不读取、不修改、不移动**任何用户数据文件。
class CacheMaintenance {
  static const Duration orphanAge = Duration(hours: 24);
  static final RegExp _tempPattern =
      RegExp(r'^(.+)\.tmp-(\d+)(?:-(\d+))?$');

  final Future<Directory> Function() _directory;
  final DateTime Function() _clock;
  final int _currentPid;

  CacheMaintenance({
    Future<Directory> Function()? directory,
    DateTime Function()? clock,
    int? currentPid,
  })  : _directory =
            directory ?? WindowsConfigStorage().getStorageDirectory,
        _clock = clock ?? DateTime.now,
        _currentPid = currentPid ?? pid;

  /// 只读盘点：用户数据文件大小 + 可清理的孤儿临时文件。
  Future<CacheInventory> inspect() async {
    final directory = await _resolveDirectory();
    if (directory == null) {
      return const CacheInventory(directoryReadable: false);
    }

    final userFiles = <AppDataFileStatus>[];
    for (final file in appDataFiles) {
      final path = p.join(directory.path, file.name);
      try {
        final stat = await File(path).stat();
        if (stat.type != FileSystemEntityType.file) continue;
        userFiles.add(AppDataFileStatus(
          file: file,
          bytes: stat.size,
          modified: stat.modified,
        ));
      } catch (_) {
        // 单个文件 stat 失败不影响其余盘点。
      }
    }

    final now = _clock();
    final tempFiles = <TempFileInfo>[];
    try {
      await for (final entity in directory.list(followLinks: false)) {
        final info = await _tempInfo(entity, now);
        if (info != null) tempFiles.add(info);
      }
    } catch (_) {
      return CacheInventory(
        userFiles: userFiles,
        directoryReadable: false,
      );
    }
    tempFiles.sort((a, b) => a.name.compareTo(b.name));

    return CacheInventory(
      userFiles: userFiles,
      tempFiles: tempFiles,
    );
  }

  /// 删除可清理的孤儿临时文件；逐个执行，单个失败不中断。
  Future<TempCleanupResult> cleanOrphanTempFiles() async {
    final inventory = await inspect();
    if (!inventory.directoryReadable) {
      return const TempCleanupResult(failed: 1);
    }

    var deleted = 0;
    var skipped = 0;
    var failed = 0;
    final now = _clock();
    for (final info in inventory.tempFiles) {
      try {
        final type =
            await FileSystemEntity.type(info.path, followLinks: false);
        if (type != FileSystemEntityType.file) {
          skipped++;
          continue;
        }
        // 删除前再次校验（缩小扫描后、删除前的 TOCTOU 窗口）。
        final rechecked = await _tempInfo(File(info.path), now);
        if (rechecked == null) {
          skipped++;
          continue;
        }
        await File(info.path).delete();
        deleted++;
      } catch (_) {
        failed++;
      }
    }
    return TempCleanupResult(
      deleted: deleted,
      skipped: skipped,
      failed: failed,
    );
  }

  Future<Directory?> _resolveDirectory() async {
    try {
      final directory = await _directory();
      if (!await directory.exists()) return null;
      return directory;
    } catch (_) {
      return null;
    }
  }

  Future<TempFileInfo?> _tempInfo(
      FileSystemEntity entity, DateTime now) async {
    final name = p.basename(entity.path);
    final match = _tempPattern.firstMatch(name);
    if (match == null) return null;
    final base = match.group(1);
    if (base == null || !isAppDataFileName(base)) return null;

    final firstNumber = int.tryParse(match.group(2) ?? '');
    final secondNumber = match.group(3);
    if (firstNumber == null) return null;
    if (base == 'live_sources.json') {
      // 直播源写入使用 `live_sources.json.tmp-<sequence>`，没有 pid 段。
      if (secondNumber != null) return null;
    } else {
      // 设置 / 配置写入使用 `<name>.tmp-<pid>-<sequence>`；单段格式语义不明，保留。
      if (secondNumber == null) return null;
      if (firstNumber == _currentPid) return null;
    }

    final type = await FileSystemEntity.type(entity.path, followLinks: false);
    if (type != FileSystemEntityType.file) return null;
    final stat = await File(entity.path).stat();
    if (stat.type != FileSystemEntityType.file) return null;
    if (!stat.modified.isBefore(now.subtract(orphanAge))) return null;

    return TempFileInfo(
      name: name,
      path: entity.path,
      bytes: stat.size,
      modified: stat.modified,
    );
  }
}
