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

  /// 默认目录：便携版是安装目录下的 `user_data`；安装目录不可写、或沿用了旧版数据时
  /// 是 `%APPDATA%/XiugouTV`。
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

  /// 当前用的就是旧版 `%APPDATA%/XiugouTV`（没有自定义目录）。
  ///
  /// 两种来源：安装目录不可写而回退（[unavailableReason] 会说明），
  /// 或旧版本已有数据、第一次用新版本时沿用旧目录。设置页据此提示可迁移到安装目录。
  bool get usesLegacyDefault =>
      !usesCustom &&
      _samePath(
          activePath,
          DataDirectoryManager._resolvedLegacyPath ??
              DataDirectoryManager.legacyDirectoryPath());

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

/// 用户数据目录解析与迁移（N-2 + 便携版）。
///
/// 设计要点：
/// - 默认目录是**安装目录下的 `user_data`**（便携 ZIP 解压即用）；安装目录不可写
///   （Program Files / 只读介质）时回退 `%APPDATA%/XiugouTV` 并给出中文原因；
/// - 旧版本已经把数据放在 `%APPDATA%/XiugouTV` 的用户**沿用旧目录**，不静默搬家
///   （搬迁要复制几十个文件，中途失败会留下半套数据；沿用零风险，想搬的用户可以在
///   设置页显式点「迁移到安装目录」，走既有的只复制不删除 + 安全副本流程）；
/// - 自定义目录优先于默认目录，指针与 pending 标记都放在**默认目录**，因此自定义
///   目录换了位置也能找回；
/// - 迁移只在启动、任何存储初始化之前执行，避免运行中双目录写入；
/// - 只复制、不删除源文件；覆盖前先写 `.migration-safety/<时间戳>/` 安全副本。
class DataDirectoryManager {
  DataDirectoryManager._();

  /// 已生效的自定义目录指针（位于默认目录）。
  static const String pointerFileName = 'data_location.json';

  /// 待下次启动执行的迁移（位于默认目录）。
  static const String pendingFileName = 'data_location_pending.json';

  /// 便携自动搬迁的结果标记（位于旧版目录）：存在即表示已经尝试过，不再自动重试。
  static const String autoMigrateFileName = 'data_location_auto_migrate.json';

  /// 覆盖前安全副本目录（位于目标目录）。
  static const String safetyDirName = '.migration-safety';

  /// 便携数据目录名（安装目录下）。
  static const String portableDirectoryName = 'user_data';

  /// 旧版本默认目录名（`%APPDATA%` 下）。
  static const String legacyDirectoryName = 'XiugouTV';

  /// 迁移范围：注册表里的数据文件 + 跟随根目录的子目录（不含 runtime）。
  ///
  /// `danmaku` 是弹幕缓存、`catvod` 是导入的本地猫源包：它们都由根目录派生，
  /// 换目录时必须一起搬，否则缓存与已注册的本地包会留在旧位置。
  static const List<String> migratedSubdirectories = [
    'wallpaper',
    'backups',
    'danmaku',
    'catvod',
  ];

  static const String markerFormat = 'xiugou-tv-data-location';
  static const int markerVersion = 1;

  static String? _activePath;
  static DataDirectoryStatus? _status;
  static int _temporarySequence = 0;

  /// 启动时解析出的默认目录（[initialize] 写入，[resetForTest] 清空）。
  static String? _resolvedDefaultPath;

  /// 默认目录回退到旧版 APPDATA 的原因；为空表示没回退。
  static String? _defaultFallbackReason;

  /// 最近一次解析使用的旧版目录（测试会注入临时目录，不能读环境变量）。
  static String? _resolvedLegacyPath;

  /// 测试注入的安装目录（默认取 exe 所在目录）。
  static String? _installDirectoryOverride;

  /// 旧版本默认目录：`%APPDATA%/XiugouTV`（缺失环境变量时 `%USERPROFILE%/.XiugouTV`）。
  static String legacyDirectoryPath() {
    final appData = Platform.environment['APPDATA'];
    if (appData != null && appData.isNotEmpty) {
      return p.join(appData, legacyDirectoryName);
    }
    final userProfile = Platform.environment['USERPROFILE'] ?? '.';
    return p.join(userProfile, '.$legacyDirectoryName');
  }

  /// 便携数据目录：安装目录（exe 所在目录）下的 `user_data`。
  static String portableDirectoryPath() =>
      p.join(_installDirectory(), portableDirectoryName);

  /// 默认目录：启动时解析的结果；未初始化时返回旧版目录（不探测磁盘，避免副作用）。
  ///
  /// 解析顺序见 [_resolveDefaultDirectory]：安装目录可写 → `user_data`；
  /// 安装目录不可写 → 回退 `%APPDATA%/XiugouTV`；旧版 APPDATA 已有数据 → 沿用旧目录。
  static String defaultDirectoryPath() =>
      _resolvedDefaultPath ?? legacyDirectoryPath();

  /// 当前数据目录（同步）。未初始化时返回默认目录，保持既有测试与工具的行为。
  static String get currentPath => _activePath ?? defaultDirectoryPath();

  static DataDirectoryStatus? get status => _status;

  /// 仅测试使用：清空静态状态。
  static void resetForTest() {
    _activePath = null;
    _status = null;
    _resolvedDefaultPath = null;
    _defaultFallbackReason = null;
    _resolvedLegacyPath = null;
    _installDirectoryOverride = null;
  }

  /// 启动时解析目录并执行待定迁移。不会抛异常（失败记录在 status 里）。
  ///
  /// 不传 [defaultDirectory] 时按便携优先规则解析默认目录（[portableDirectoryPath]）。
  /// [installDirectory] / [legacyDirectory] 仅供测试注入，避免依赖真实 exe 路径与 %APPDATA%。
  static Future<DataDirectoryStatus> initialize({
    String? defaultDirectory,
    String? installDirectory,
    String? legacyDirectory,
  }) async {
    if (installDirectory != null && installDirectory.trim().isNotEmpty) {
      _installDirectoryOverride = p.normalize(p.absolute(installDirectory));
    }
    final resolution = defaultDirectory == null
        ? await _resolveDefaultDirectory(legacyDirectory: legacyDirectory)
        : _DefaultDirectoryResolution(
            p.normalize(p.absolute(defaultDirectory)), null);
    _resolvedDefaultPath = resolution.path;
    _defaultFallbackReason = resolution.reason;
    final defaultPath = resolution.path;
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
          // 迁到安装目录下的 user_data 时也不写指针：便携目录一旦有数据，下次启动
          // 就会成为默认目录，留一个指向它的指针只会在之后变成孤儿标记。
          final targetIsPortable = _isPortableDirectory(pendingPath);
          if (_samePath(pendingPath, defaultPath) || targetIsPortable) {
            // 迁回默认目录：删除指针，避免留下「指向默认目录」的冗余标记
            _deleteMarker(defaultPath, pointerFileName);
          } else {
            _writeMarker(defaultPath, pointerFileName, pendingPath);
          }
          _deleteMarker(defaultPath, pendingFileName);
          active = pendingPath;
          customPath = (_samePath(active, defaultPath) || targetIsPortable)
              ? null
              : active;
          pendingPath = null;
          unavailable = null;
        } else {
          pendingError = result.message ?? '迁移失败';
        }
      }
    }

    // 便携搬迁：升级用户的数据还留在旧版 %APPDATA%/XiugouTV 时，自动搬一次到
    // 安装目录下的 user_data —— 这就是「数据跟着安装目录走」的实现路径。
    // 仍然只复制不删除、逐文件 sha256 校验，成功后才切换；失败保留旧目录，
    // 记下原因，之后不再自动重试（设置页还能手动迁移）。
    if (pendingPath == null &&
        unavailable == null &&
        !_samePath(active, portableDirectoryPath()) &&
        _samePath(active, _resolvedLegacyPath ?? legacyDirectoryPath()) &&
        !_containsUserData(portableDirectoryPath()) &&
        !_autoMigrateAttempted(defaultPath)) {
      final moved = await _migrate(
        from: active,
        to: portableDirectoryPath(),
        defaultPath: defaultPath,
      );
      if (moved.ok) {
        active = portableDirectoryPath();
        customPath = null;
      } else {
        _recordAutoMigrateFailure(
            defaultPath, moved.message ?? '迁移失败');
      }
    }

    _activePath = active;
    _status = DataDirectoryStatus(
      activePath: active,
      defaultPath: defaultPath,
      customPath: customPath,
      // 自定义目录失败时优先报自定义目录的原因；没有自定义目录时报
      // 「安装目录不可写、已回退 APPDATA」的原因，设置页据此显示提示。
      unavailableReason: unavailable ??
          (customPath == null ? _defaultFallbackReason : null),
      pendingPath: pendingPath,
      pendingError: pendingError,
    );
    return _status!;
  }

  // -------------------------------------------------------------------------
  // 默认目录解析（便携版）
  // -------------------------------------------------------------------------

  /// 解析默认目录：便携优先、旧数据沿用、只读安装目录回退。
  ///
  /// 顺序：
  /// 1. `user_data` 里已有数据（便携版用户）→ 校验可写后用便携目录；
  /// 2. 否则旧版 `%APPDATA%/XiugouTV` 有数据 → 先把旧目录当作默认目录，再由
  ///    [initialize] 的「便携搬迁」把它一次性搬到安装目录下的 `user_data`；
  /// 3. 全新安装 → 探测安装目录可写，可写用 `user_data`，否则回退 APPDATA 并
  ///    记录中文原因。
  ///
  /// 搬迁必须保命：只复制不删除、逐文件 sha256 校验、成功后才切换，旧目录原样
  /// 留着当回退；失败则保留旧目录并把原因记进 `data_location_auto_migrate.json`，
  /// 之后不再反复尝试（设置页仍可手动迁移）。
  static Future<_DefaultDirectoryResolution> _resolveDefaultDirectory({
    String? legacyDirectory,
  }) async {
    final portable = p.normalize(p.absolute(portableDirectoryPath()));
    final legacy =
        p.normalize(p.absolute(legacyDirectory ?? legacyDirectoryPath()));
    _resolvedLegacyPath = legacy;
    // 极端情况：安装目录就在 %APPDATA% 下，两个路径相同，直接用。
    if (_samePath(portable, legacy)) {
      return _DefaultDirectoryResolution(portable, null);
    }
    if (_containsUserData(portable)) {
      final reason = await _probeDefaultDirectory(portable, legacy: legacy);
      if (reason == null) return _DefaultDirectoryResolution(portable, null);
      return _DefaultDirectoryResolution(legacy, reason);
    }
    if (_containsUserData(legacy)) {
      return _DefaultDirectoryResolution(legacy, null);
    }
    final reason = await _probeDefaultDirectory(portable, legacy: legacy);
    if (reason == null) return _DefaultDirectoryResolution(portable, null);
    return _DefaultDirectoryResolution(legacy, reason);
  }

  /// 是否是安装目录下的便携目录（[portableDirectoryPath]）。
  static bool _isPortableDirectory(String path) => _samePath(
      p.normalize(p.absolute(path)),
      p.normalize(p.absolute(portableDirectoryPath())));

  /// 目录里是否已有本应用的数据（只看登记表、位置标记与随根目录派生的子目录）。
  ///
  /// 子目录只判断「存在且非空」：旧版可能只留下壁纸 / 备份 / 弹幕缓存，也要认成
  /// 已有数据，避免升级后被当成全新安装而换了默认目录。
  static bool _containsUserData(String directory) {
    for (final file in appDataFiles) {
      if (File(p.join(directory, file.name)).existsSync()) return true;
    }
    if (File(p.join(directory, pointerFileName)).existsSync() ||
        File(p.join(directory, pendingFileName)).existsSync()) {
      return true;
    }
    for (final name in migratedSubdirectories) {
      try {
        final child = Directory(p.join(directory, name));
        if (child.existsSync() && child.listSync().isNotEmpty) return true;
      } on FileSystemException {
        // 读不了就不当成数据，交给后续可写性探测给出明确原因。
      }
    }
    return false;
  }

  /// 探测默认目录可写性：缺失时创建，再写探针文件并删除。
  ///
  /// 返回 null 表示可写；否则返回中文原因（用于 status.unavailableReason 与设置页）。
  static Future<String?> _probeDefaultDirectory(
    String path, {
    required String legacy,
  }) async {
    try {
      final directory = Directory(path);
      if (FileSystemEntity.typeSync(path) == FileSystemEntityType.file) {
        return '安装目录不可写，已改用 $legacy（$path 是文件，不是目录）';
      }
      if (!directory.existsSync()) {
        await directory.create(recursive: true);
      }
      if (FileSystemEntity.typeSync(path) != FileSystemEntityType.directory) {
        return '安装目录不可写，已改用 $legacy（$path 不是目录）';
      }
      if (await _isWritable(path)) return null;
      return '安装目录不可写，已改用 $legacy（$path）';
    } on FileSystemException catch (error) {
      final detail = error.osError?.message ?? error.message;
      return '安装目录不可写，已改用 $legacy（$path：$detail）';
    } catch (error) {
      return '安装目录不可写，已改用 $legacy（$path：$error）';
    }
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

  /// 是否已经尝试过便携自动搬迁（无论成败都只试一次）。
  static bool _autoMigrateAttempted(String defaultPath) =>
      File(p.join(defaultPath, autoMigrateFileName)).existsSync();

  /// 记录自动搬迁失败原因：只留一行中文说明，下次启动不再自动重试。
  static void _recordAutoMigrateFailure(String defaultPath, String reason) {
    try {
      final file = File(p.join(defaultPath, autoMigrateFileName));
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        jsonEncode({
          'format': markerFormat,
          'version': markerVersion,
          'message': reason,
          'at': DateTime.now().toUtc().toIso8601String(),
        }),
        flush: true,
      );
    } catch (_) {
      // 记不下来也不影响启动：只是下次还会再试一次。
    }
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
    // 便携版默认目录就在安装目录下（`<exe>/user_data` 及其子目录），必须放行；
    // 安装目录本身与其它位置仍然拒绝，避免更新/卸载时被覆盖。
    final portable = p.normalize(p.absolute(portableDirectoryPath()));
    final insidePortable =
        _samePath(target, portable) || _isInside(target, portable);
    if (!insidePortable &&
        (_samePath(target, installDirectory) ||
            _isInside(target, installDirectory))) {
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
      _installDirectoryOverride ?? p.dirname(Platform.resolvedExecutable);

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

/// 默认目录解析结果：[reason] 非空表示从 `user_data` 回退到了旧版 APPDATA。
class _DefaultDirectoryResolution {
  const _DefaultDirectoryResolution(this.path, this.reason);

  final String path;
  final String? reason;
}
