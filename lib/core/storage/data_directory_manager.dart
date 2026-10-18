import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'app_data_files.dart';

/// 数据目录状态（启动时解析一次，供设置页展示）。
class DataDirectoryStatus {
  const DataDirectoryStatus({
    required this.activePath,
    required this.defaultPath,
    this.customPath,
    this.unavailableReason,
    this.pendingPath,
    this.pendingError,
  });

  /// 当前实际使用的数据目录。
  final String activePath;

  /// 默认目录（`%APPDATA%/XiugouTV`）。
  final String defaultPath;

  /// 指针文件里记录的自定义目录（即使当前不可用也保留，便于展示与修复）。
  final String? customPath;

  /// 自定义目录不可用的原因；为空表示正常。
  final String? unavailableReason;

  /// 已安排、等待下次启动执行的迁移目标。
  final String? pendingPath;

  /// 上次启动迁移失败的原因（保留 pending，等待重试或取消）。
  final String? pendingError;

  bool get usesCustom =>
      customPath != null && _samePath(activePath, customPath!);

  bool get migrationPending => pendingPath != null;

  DataDirectoryStatus copyWith({
    String? activePath,
    String? customPath,
    String? unavailableReason,
    String? pendingPath,
    String? pendingError,
    bool clearPending = false,
    bool clearUnavailable = false,
  }) {
    return DataDirectoryStatus(
      activePath: activePath ?? this.activePath,
      defaultPath: defaultPath,
      customPath: customPath ?? this.customPath,
      unavailableReason:
          clearUnavailable ? null : (unavailableReason ?? this.unavailableReason),
      pendingPath: clearPending ? null : (pendingPath ?? this.pendingPath),
      pendingError:
          clearPending ? null : (pendingError ?? this.pendingError),
    );
  }
}

/// 迁移结果。
class DataDirectoryMigrationResult {
  const DataDirectoryMigrationResult({
    required this.ok,
    required this.copied,
    this.skipped = 0,
    this.message,
  });

  final bool ok;
  final int copied;
  final int skipped;
  final String? message;
}

/// 数据目录不可用 / 校验失败。
class DataDirectoryException implements Exception {
  const DataDirectoryException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 用户自选数据目录（N-2）。
///
/// 设计要点：
/// - 指针与 pending 标记都放在**默认目录**，因此自定义目录换了位置也能找回；
/// - 迁移只在启动、任何存储初始化之前执行，避免运行中双目录写入；
/// - 只复制、不删除源文件；覆盖前先写 `.migration-safety/<时间戳>/` 安全副本。
class DataDirectoryManager {
  DataDirectoryManager._();

  /// 已生效的自定义目录指针（位于默认目录）。
  static const String pointerFileName = 'data_location.json';

  /// 待下次启动执行的迁移（位于默认目录）。
  static const String pendingFileName = 'data_location_pending.json';

  /// 覆盖前安全副本目录（位于目标目录）。
  static const String safetyDirName = '.migration-safety';

  /// 迁移范围：注册表里的数据文件 + 两个子目录（不含 runtime）。
  static const List<String> migratedSubdirectories = ['wallpaper', 'backups'];

  static const String markerFormat = 'xiugou-tv-data-location';
  static const int markerVersion = 1;

  static String? _activePath;
  static DataDirectoryStatus? _status;
  static int _temporarySequence = 0;

  /// 默认目录；沿用既有约定（%APPDATA%/XiugouTV，缺失时 %USERPROFILE%/.XiugouTV）。
  static String defaultDirectoryPath() {
    final appData = Platform.environment['APPDATA'];
    if (appData != null && appData.isNotEmpty) {
      return p.join(appData, 'XiugouTV');
    }
    final userProfile = Platform.environment['USERPROFILE'] ?? '.';
    return p.join(userProfile, '.XiugouTV');
  }

  /// 当前数据目录（同步）。未初始化时返回默认目录，保持既有测试与工具的行为。
  static String get currentPath => _activePath ?? defaultDirectoryPath();

  static DataDirectoryStatus? get status => _status;

  /// 仅测试使用：清空静态状态。
  static void resetForTest() {
    _activePath = null;
    _status = null;
  }

  /// 启动时解析目录并执行待定迁移。不会抛异常（失败记录在 status 里）。
  static Future<DataDirectoryStatus> initialize({String? defaultDirectory}) async {
    final defaultPath =
        p.normalize(p.absolute(defaultDirectory ?? defaultDirectoryPath()));
    var active = defaultPath;
    String? customPath;
    String? unavailable;
    String? pendingPath;
    String? pendingError;

    final pointer = _readMarker(defaultPath, pointerFileName);
    if (pointer != null) {
      if (_samePath(pointer, defaultPath)) {
        // 指回默认目录等价于没有指针。
        _deleteMarker(defaultPath, pointerFileName);
      } else {
        final check = await _validateTarget(
          pointer,
          source: defaultPath,
          defaultPath: defaultPath,
          requireExisting: true,
        );
        if (check.ok) {
          active = check.path!;
          customPath = active;
        } else {
          customPath = p.normalize(p.absolute(pointer));
          unavailable = check.message ?? '自定义数据目录不可用';
        }
      }
    }

    final pending = _readMarker(defaultPath, pendingFileName);
    if (pending != null) {
      pendingPath = p.normalize(p.absolute(pending));
      if (_samePath(pendingPath, active)) {
        _deleteMarker(defaultPath, pendingFileName);
        pendingPath = null;
      } else if (unavailable != null &&
          !_samePath(pendingPath, defaultPath)) {
        // 自定义目录不可用时，active 只是回退的默认目录；从这里迁移会把
        // 「零套/旧数据」当成完整数据写指针。暂停迁移，保留 pending 与提示。
        pendingError = '自定义数据目录不可用，已暂停迁移';
      } else {
        final result = await _migrate(
          from: active,
          to: pendingPath,
          defaultPath: defaultPath,
        );
        if (result.ok) {
          if (_samePath(pendingPath, defaultPath)) {
            // 迁回默认目录：删除指针，避免留下「指向默认目录」的冗余标记
            _deleteMarker(defaultPath, pointerFileName);
          } else {
            _writeMarker(defaultPath, pointerFileName, pendingPath);
          }
          _deleteMarker(defaultPath, pendingFileName);
          active = pendingPath;
          customPath = _samePath(active, defaultPath) ? null : active;
          pendingPath = null;
          unavailable = null;
        } else {
          pendingError = result.message ?? '迁移失败';
        }
      }
    }

    _activePath = active;
    _status = DataDirectoryStatus(
      activePath: active,
      defaultPath: defaultPath,
      customPath: customPath,
      unavailableReason: unavailable,
      pendingPath: pendingPath,
      pendingError: pendingError,
    );
    return _status!;
  }

  /// 安排一次迁移（下次启动执行）。只写 pending，不复制、不切换。
  static Future<DataDirectoryStatus> requestDirectory(
    String target, {
    String? defaultDirectory,
  }) async {
    final defaultPath = p.normalize(p.absolute(
        defaultDirectory ?? _status?.defaultPath ?? defaultDirectoryPath()));
    final source = currentPath;
    final check = await _validateTarget(
      target,
      source: source,
      defaultPath: defaultPath,
      requireExisting: false,
    );
    if (!check.ok) throw DataDirectoryException(check.message!);
    if (_samePath(check.path!, source)) {
      throw const DataDirectoryException('已经是当前数据目录');
    }

    _writeMarker(defaultPath, pendingFileName, check.path!);
    final base = _status ??
        DataDirectoryStatus(
          activePath: source,
          defaultPath: defaultPath,
        );
    _status = DataDirectoryStatus(
      activePath: base.activePath,
      defaultPath: base.defaultPath,
      customPath: base.customPath,
      unavailableReason: base.unavailableReason,
      pendingPath: check.path,
    );
    return _status!;
  }

  /// 取消待定迁移。
  static Future<DataDirectoryStatus> cancelPending({
    String? defaultDirectory,
  }) async {
    final defaultPath = p.normalize(p.absolute(
        defaultDirectory ?? _status?.defaultPath ?? defaultDirectoryPath()));
    _deleteMarker(defaultPath, pendingFileName);
    final base = _status ??
        DataDirectoryStatus(
          activePath: currentPath,
          defaultPath: defaultPath,
        );
    _status = base.copyWith(clearPending: true);
    return _status!;
  }

  /// 停用自定义目录（仅在自定义目录不可用时使用）：删除指针与 pending，回到默认目录。
  static Future<DataDirectoryStatus> forgetCustomDirectory({
    String? defaultDirectory,
  }) async {
    final defaultPath = p.normalize(p.absolute(
        defaultDirectory ?? _status?.defaultPath ?? defaultDirectoryPath()));
    _deleteMarker(defaultPath, pointerFileName);
    _deleteMarker(defaultPath, pendingFileName);
    _activePath = defaultPath;
    _status = DataDirectoryStatus(
      activePath: defaultPath,
      defaultPath: defaultPath,
    );
    return _status!;
  }

  // ---------------------------------------------------------------------
  // 标记文件
  // ---------------------------------------------------------------------

  static String? _readMarker(String defaultPath, String name) {
    try {
      final file = File(p.join(defaultPath, name));
      if (!file.existsSync()) return null;
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map) return null;
      if (decoded['format'] != markerFormat) return null;
      if (decoded['version'] != markerVersion) return null;
      final path = decoded['path'];
      if (path is! String || path.trim().isEmpty) return null;
      return p.normalize(p.absolute(path));
    } catch (_) {
      return null;
    }
  }

  static void _writeMarker(String defaultPath, String name, String target) {
    final file = File(p.join(defaultPath, name));
    file.parent.createSync(recursive: true);
    final content = jsonEncode({
      'format': markerFormat,
      'version': markerVersion,
      'path': target,
    });
    final tmp = File('${file.path}.tmp-$pid');
    tmp.writeAsStringSync(content, flush: true);
    try {
      // 与 WindowsConfigStorage._atomicWrite 一致：rename 直接覆盖旧文件，
      // 避免「先删后写」造成指针短暂缺失。
      tmp.renameSync(file.path);
    } finally {
      try {
        if (tmp.existsSync()) tmp.deleteSync();
      } catch (_) {}
    }
  }

  static void _deleteMarker(String defaultPath, String name) {
    try {
      final file = File(p.join(defaultPath, name));
      if (file.existsSync()) file.deleteSync();
    } catch (_) {}
  }

  // ---------------------------------------------------------------------
  // 校验
  // ---------------------------------------------------------------------

  static Future<_TargetCheck> _validateTarget(
    String rawPath, {
    required String source,
    required String defaultPath,
    required bool requireExisting,
  }) async {
    if (rawPath.trim().isEmpty) {
      return const _TargetCheck(false, message: '目录为空');
    }
    if (!p.isAbsolute(rawPath)) {
      return const _TargetCheck(false, message: '必须选择绝对路径');
    }
    final target = p.normalize(p.absolute(rawPath));
    if (_samePath(target, source)) {
      return const _TargetCheck(false, message: '不能与当前数据目录相同');
    }
    if (_isInside(target, source)) {
      return const _TargetCheck(false, message: '不能选择当前数据目录的子目录');
    }
    if (_isInside(source, target)) {
      return const _TargetCheck(false, message: '不能选择当前数据目录的上级目录');
    }
    final installDirectory = _installDirectory();
    if (_samePath(target, installDirectory) ||
        _isInside(target, installDirectory)) {
      return const _TargetCheck(false, message: '不能选择应用安装目录');
    }

    final type = FileSystemEntity.typeSync(target);
    if (type == FileSystemEntityType.file) {
      return const _TargetCheck(false, message: '目标路径是文件，不是目录');
    }
    if (type == FileSystemEntityType.directory) {
      if (!await _isWritable(target)) {
        return const _TargetCheck(false, message: '目标目录不可写');
      }
      if (!_samePath(target, defaultPath) &&
          File(p.join(target, pointerFileName)).existsSync()) {
        return const _TargetCheck(false, message: '目标已是另一个受管数据目录');
      }
    } else if (type == FileSystemEntityType.notFound) {
      if (requireExisting) {
        return const _TargetCheck(false, message: '目录不存在');
      }
      final parent = Directory(p.dirname(target));
      if (!parent.existsSync()) {
        return const _TargetCheck(false, message: '上级目录不存在');
      }
      if (!await _isWritable(parent.path)) {
        return const _TargetCheck(false, message: '上级目录不可写');
      }
    } else {
      return const _TargetCheck(false, message: '目标路径不可用');
    }
    return _TargetCheck(true, path: target);
  }

  static String _installDirectory() =>
      p.dirname(Platform.resolvedExecutable);

  static Future<bool> _isWritable(String directory) async {
    final probe = File(p.join(
        directory, '.xiugou-tv-write-test-$pid-${DateTime.now().microsecondsSinceEpoch}'));
    try {
      await probe.writeAsString('probe', flush: true);
      await probe.delete();
      return true;
    } catch (_) {
      try {
        if (await probe.exists()) await probe.delete();
      } catch (_) {}
      return false;
    }
  }

  // ---------------------------------------------------------------------
  // 迁移
  // ---------------------------------------------------------------------

  static Future<DataDirectoryMigrationResult> _migrate({
    required String from,
    required String to,
    required String defaultPath,
  }) async {
    final source = p.normalize(p.absolute(from));
    final check = await _validateTarget(
      to,
      source: source,
      defaultPath: defaultPath,
      requireExisting: false,
    );
    if (!check.ok) {
      return DataDirectoryMigrationResult(
          ok: false, copied: 0, message: check.message);
    }
    final target = check.path!;

    try {
      await Directory(target).create(recursive: true);
      final files = await _collectFiles(source);
      final stamp = DateTime.now()
          .toUtc()
          .toIso8601String()
          .replaceAll(RegExp(r'[:.]'), '-');
      final safetyRoot = p.join(target, safetyDirName, stamp);
      var copied = 0;

      for (final item in files) {
        final dest = File(p.join(target, item.relativePath));
        try {
          await dest.parent.create(recursive: true);
          if (await dest.exists()) {
            final safety = File(p.join(safetyRoot, item.relativePath));
            await safety.parent.create(recursive: true);
            await dest.copy(safety.path);
            if (await safety.length() != await dest.length()) {
              return DataDirectoryMigrationResult(
                ok: false,
                copied: copied,
                message: '安全副本校验失败：${item.relativePath}',
              );
            }
          }
          // 命名对齐 CacheMaintenance 的孤儿临时文件规则（*.tmp-<pid>-<seq>），
          // 迁移中断后残留的文件也能被「清理临时文件」收走。
          final tmp = File('${dest.path}.tmp-$pid-${++_temporarySequence}');
          await item.source.copy(tmp.path);
          final sourceHash = await _sha256(item.source);
          final tmpHash = await _sha256(tmp);
          if (sourceHash != tmpHash) {
            await _deleteQuietly(tmp);
            return DataDirectoryMigrationResult(
              ok: false,
              copied: copied,
              message: '复制校验失败：${item.relativePath}',
            );
          }
          if (await dest.exists()) await dest.delete();
          await tmp.rename(dest.path);
          copied++;
        } catch (e) {
          return DataDirectoryMigrationResult(
            ok: false,
            copied: copied,
            message: '复制失败：${item.relativePath}（$e）',
          );
        }
      }
      return DataDirectoryMigrationResult(ok: true, copied: copied);
    } catch (e) {
      return DataDirectoryMigrationResult(
          ok: false, copied: 0, message: '迁移失败：$e');
    }
  }

  static Future<List<_SourceFile>> _collectFiles(String source) async {
    final files = <_SourceFile>[];
    for (final file in appDataFiles) {
      final candidate = File(p.join(source, file.name));
      if (await candidate.exists()) {
        files.add(_SourceFile(file.name, candidate));
      }
    }
    for (final dirName in migratedSubdirectories) {
      final dir = Directory(p.join(source, dirName));
      if (!await dir.exists()) continue;
      await for (final entity
          in dir.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        final relative = p.join(dirName, p.relative(entity.path, from: dir.path));
        files.add(_SourceFile(relative, entity));
      }
    }
    return files;
  }

  static Future<String> _sha256(File file) async {
    final bytes = await file.readAsBytes();
    return sha256.convert(bytes).toString();
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}

bool _samePath(String a, String b) {
  final left = p.normalize(p.absolute(a));
  final right = p.normalize(p.absolute(b));
  if (Platform.isWindows) {
    return left.toLowerCase() == right.toLowerCase();
  }
  return left == right;
}

bool _isInside(String child, String parent) {
  final left = Platform.isWindows ? child.toLowerCase() : child;
  final right = Platform.isWindows ? parent.toLowerCase() : parent;
  return p.isWithin(
      p.normalize(p.absolute(right)), p.normalize(p.absolute(left)));
}

class _TargetCheck {
  const _TargetCheck(this.ok, {this.path, this.message});

  final bool ok;
  final String? path;
  final String? message;
}

class _SourceFile {
  const _SourceFile(this.relativePath, this.source);

  final String relativePath;
  final File source;
}
