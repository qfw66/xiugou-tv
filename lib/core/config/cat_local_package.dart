import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../storage/data_directory_manager.dart';
import 'config_decoder.dart';

/// 猫源本地包（`catvod-local.zip` 这类压缩包）导入。
///
/// 包内有 JSON 配置文件和 JAR 即可导入，不要求固定名称、爬虫声明或 MD5。
/// 1. 读取 ZIP 中央目录，检查路径越界、符号链接及条目数与体积上限；
/// 2. 用系统 tar 解压到数据目录 `catvod/.staging-*`；
/// 3. 检查解压完整性，选择 JSON 和 JAR，保留包内文件原文；
/// 4. 原子发布到正式目录，配置内容由 `ConfigRepository.loadFromFile` 解析。
///
/// 任何一步失败都会清掉临时目录，不会留下半套包。
class CatLocalPackageImporter {
  CatLocalPackageImporter({
    String? dataDirectory,
    CatPackageExtractor? extractor,
  }) : _dataRoot = dataDirectory,
       _unzip = extractor;

  /// 解压函数（默认系统 tar）：测试可注入，避免依赖本机 tar。
  final CatPackageExtractor? _unzip;

  /// 数据目录根（其下的 `catvod/` 存本地包）；默认当前数据目录。
  final String? _dataRoot;

  /// 压缩包内条目数上限（正常猫源包只有 3~10 个文件）。
  static const int maxEntries = 64;

  /// 单个条目解压后大小上限。
  static const int maxEntryBytes = 128 * 1024 * 1024;

  /// 整个包解压后大小上限。
  static const int maxTotalBytes = 256 * 1024 * 1024;

  /// 压缩包自身大小上限（防止把超大文件读进内存）。
  static const int maxArchiveBytes = 256 * 1024 * 1024;

  /// 条目路径长度上限（Windows 路径限制内）。
  static const int maxPathLength = 200;

  /// 导入压缩包，成功返回选中的 JSON 文件路径。
  ///
  /// 失败抛 [CatLocalPackageException]，message 是给用户看的中文原因。
  Future<CatLocalPackageResult> import(String zipPath) async {
    final archive = File(zipPath);
    if (!await archive.exists()) {
      throw const CatLocalPackageException('找不到猫源包文件，请重新选择');
    }
    if (p.extension(zipPath).toLowerCase() != '.zip') {
      throw const CatLocalPackageException('请选择 .zip 格式的猫源本地包');
    }
    final length = await archive.length();
    if (length == 0) {
      throw const CatLocalPackageException('猫源包是空文件，无法导入');
    }
    if (length > maxArchiveBytes) {
      throw const CatLocalPackageException('猫源包过大（超过 256 MB），已拒绝导入');
    }
    final bytes = await archive.readAsBytes();
    final entries = _ZipDirectory.read(bytes);
    _validateEntries(entries);

    final root = Directory(p.join(_rootPath(), 'catvod'));
    await root.create(recursive: true);
    final id = _packageId(zipPath, bytes);
    final staging = Directory(p.join(root.path, '.staging-$pid-${_stamp()}'));
    await staging.create(recursive: true);
    try {
      await (_unzip ?? extractWithSystemTar)(archive, staging);
      final verified = await _verify(staging, entries: entries);
      final target = Directory(p.join(root.path, id));
      await _publish(staging, target);
      return CatLocalPackageResult(
        id: id,
        directory: target.path,
        configPath: p.join(target.path, _toPlatform(verified.configRelative)),
        jarPath: p.join(target.path, _toPlatform(verified.jarRelative)),
        jarMd5: verified.jarMd5,
        siteCount: verified.siteCount,
      );
    } finally {
      if (await staging.exists()) {
        await staging.delete(recursive: true).catchError((_) => staging);
      }
    }
  }

  String _rootPath() {
    final root = _dataRoot?.trim();
    if (root != null && root.isNotEmpty) return p.normalize(p.absolute(root));
    return DataDirectoryManager.currentPath;
  }

  /// 目录名：`<包名>-<内容哈希前 10 位>`，同一压缩包重复导入落到同一目录。
  static String _packageId(String zipPath, Uint8List bytes) {
    final base = p.basenameWithoutExtension(zipPath);
    final safe = base
        .replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    final digest = sha256.convert(bytes).toString().substring(0, 10);
    final prefix = safe.isEmpty ? 'catvod' : safe;
    return '${prefix.length > 40 ? prefix.substring(0, 40) : prefix}-$digest';
  }

  static int _stamp() => DateTime.now().microsecondsSinceEpoch;

  static String _toPlatform(String relativePosix) =>
      relativePosix.split('/').join(p.separator);

  // ---------------------------------------------------------------------
  // 安全校验（解压前）
  // ---------------------------------------------------------------------

  static void _validateEntries(List<_ZipEntry> entries) {
    if (entries.isEmpty) {
      throw const CatLocalPackageException('猫源包是空的（没有任何文件）');
    }
    final files = entries.where((entry) => !entry.isDirectory).toList();
    if (files.isEmpty) {
      throw const CatLocalPackageException('猫源包里没有文件，只有目录');
    }
    if (files.length > maxEntries) {
      throw CatLocalPackageException(
        '猫源包条目过多（${files.length} 个，最多 $maxEntries 个），已拒绝导入',
      );
    }
    var total = 0;
    for (final entry in files) {
      if (entry.isSymlink) {
        throw CatLocalPackageException(
          '猫源包包含符号链接条目（${entry.name}），可能指向包外路径，已拒绝导入',
        );
      }
      _validateEntryName(entry.name);
      if (entry.uncompressedSize > maxEntryBytes) {
        throw CatLocalPackageException(
          '猫源包里的文件过大（${entry.name} 超过 128 MB），已拒绝导入',
        );
      }
      total += entry.uncompressedSize;
      if (total > maxTotalBytes) {
        throw const CatLocalPackageException('猫源包解压后超过 256 MB，已拒绝导入');
      }
    }
  }

  /// 拒绝 zip slip：绝对路径、盘符、`..` 越级、NTFS 非法字符、超长路径。
  static void _validateEntryName(String rawName) {
    final name = rawName.replaceAll('\\', '/');
    if (name.trim().isEmpty) {
      throw const CatLocalPackageException('猫源包包含空文件名，已拒绝导入');
    }
    if (name.contains('\u0000')) {
      throw const CatLocalPackageException('猫源包文件名包含非法字符，已拒绝导入');
    }
    if (name.startsWith('/') || RegExp(r'^[A-Za-z]:').hasMatch(name)) {
      throw CatLocalPackageException('猫源包内的路径是绝对路径（$rawName），已拒绝导入');
    }
    if (name.length > maxPathLength) {
      throw CatLocalPackageException('猫源包内的路径过长（${name.length} 个字符），已拒绝导入');
    }
    for (final segment in name.split('/')) {
      if (segment == '..') {
        throw CatLocalPackageException('猫源包内包含越级路径（$rawName），已拒绝导入');
      }
      if (segment.isEmpty) continue;
      if (segment.contains(':') ||
          segment.contains('*') ||
          segment.contains('?')) {
        throw CatLocalPackageException('猫源包内的文件名包含非法字符（$rawName），已拒绝导入');
      }
      if (segment.endsWith('.') || segment.endsWith(' ')) {
        throw CatLocalPackageException('猫源包内的文件名以空格或点结尾（$rawName），已拒绝导入');
      }
    }
  }

  // ---------------------------------------------------------------------
  // 解压
  // ---------------------------------------------------------------------

  /// 默认解压：Windows 10+ 自带 `tar.exe`（libarchive），不引入新依赖。
  ///
  /// tar 缺失或退出码非 0 都抛中文异常，绝不静默跳过。
  static Future<void> extractWithSystemTar(
    File archive,
    Directory destination,
  ) async {
    ProcessResult result;
    try {
      result = await Process.run('tar', [
        '-xf',
        archive.path,
        '-C',
        destination.path,
      ]);
    } on ProcessException {
      throw const CatLocalPackageException(
        '系统未提供 tar，无法解压猫源包（需要 Windows 10 及以上自带的 tar.exe）',
      );
    }
    if (result.exitCode != 0) {
      final stderr = (result.stderr ?? '').toString().trim();
      final detail = stderr.isEmpty ? '' : '：${_shorten(stderr)}';
      throw CatLocalPackageException(
        '解压猫源包失败（tar 退出码 ${result.exitCode}）$detail',
      );
    }
  }

  // ---------------------------------------------------------------------
  // 完整性校验（解压后）
  // ---------------------------------------------------------------------

  Future<_VerifiedPackage> _verify(
    Directory packageDir, {
    required List<_ZipEntry> entries,
  }) async {
    final files = <String, File>{};
    await for (final entity in packageDir.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) continue;
      files[_relativePosix(packageDir.path, entity.path)] = entity;
    }
    // 中央目录声明的大小不可全信：解压完再按实际体积兜一次，防 zip 炸弹撑爆磁盘。
    var totalBytes = 0;
    for (final file in files.values) {
      final bytes = await file.length();
      if (bytes > maxEntryBytes) {
        throw CatLocalPackageException(
          '猫源包里的文件过大（${_relativePosix(packageDir.path, file.path)}，超过 128 MB），已拒绝导入',
        );
      }
      totalBytes += bytes;
    }
    if (totalBytes > maxTotalBytes) {
      throw const CatLocalPackageException('猫源包解压后超过 256 MB，已拒绝导入');
    }
    // 解压结果要和压缩包对得上：缺文件说明 tar 没解全（或被杀软拦截）。
    final expected = entries
        .where((entry) => !entry.isDirectory)
        .map((entry) => _normalizeEntryName(entry.name))
        .toSet();
    final missing = expected.where((name) => !files.containsKey(name)).toList();
    if (missing.isNotEmpty) {
      throw CatLocalPackageException(
        '解压后缺少文件：${missing.take(3).join('、')}${missing.length > 3 ? ' 等' : ''}（可能被安全软件拦截，请重试）',
      );
    }

    final configKey = _selectFile(
      files.keys,
      '.json',
      preferredName: 'config.json',
    );
    if (configKey == null) {
      throw const CatLocalPackageException('猫源包不完整：缺少 JSON 配置文件（.json）');
    }
    final jarKey = _selectFile(files.keys, '.jar');
    if (jarKey == null) {
      throw const CatLocalPackageException('猫源包不完整：缺少爬虫 JAR 文件（.jar）');
    }

    var siteCount = 0;
    try {
      final decoded = ConfigDecoder.decode(
        await files[configKey]!.readAsString(),
      );
      if (decoded is Map && decoded['sites'] is List) {
        siteCount = (decoded['sites'] as List).length;
      }
    } on FormatException {
      // 这里只统计可识别的站点，配置解析错误留给后续加载流程。
    }

    return _VerifiedPackage(
      configRelative: configKey,
      jarRelative: jarKey,
      jarMd5: (await md5.bind(files[jarKey]!.openRead()).first).toString(),
      siteCount: siteCount,
    );
  }

  /// 优先配置惯用名，其余候选按目录深度及文件名排序，不依赖解压枚举顺序。
  static String? _selectFile(
    Iterable<String> keys,
    String extension, {
    String? preferredName,
  }) {
    final candidates = keys
        .where((key) => p.posix.extension(key).toLowerCase() == extension)
        .toList();
    candidates.sort((left, right) {
      if (preferredName != null) {
        final leftPreferred =
            p.posix.basename(left).toLowerCase() == preferredName;
        final rightPreferred =
            p.posix.basename(right).toLowerCase() == preferredName;
        if (leftPreferred != rightPreferred) return leftPreferred ? -1 : 1;
      }
      final depth = p.posix
          .split(left)
          .length
          .compareTo(p.posix.split(right).length);
      if (depth != 0) return depth;
      final name = left.toLowerCase().compareTo(right.toLowerCase());
      return name != 0 ? name : left.compareTo(right);
    });
    return candidates.isEmpty ? null : candidates.first;
  }

  /// 把 `archive/.staging-x/` 换成正式目录：先备份旧包，失败回滚。
  static Future<void> _publish(Directory staging, Directory target) async {
    final backup = Directory('${target.path}.old-${_stamp()}');
    final hadOld = await target.exists();
    if (hadOld) await _renamePackageDirectory(target, backup.path);
    try {
      await _renamePackageDirectory(staging, target.path);
    } catch (error) {
      if (hadOld && await backup.exists()) {
        await _renamePackageDirectory(backup, target.path);
      }
      throw CatLocalPackageException('写入猫源包目录失败（$error）');
    }
    if (await backup.exists()) {
      await backup.delete(recursive: true).catchError((_) => backup);
    }
  }

  /// Windows 上仍打开的解压文件或目录句柄可能暂时阻止同卷改名。
  static Future<void> _renamePackageDirectory(
    Directory directory,
    String to,
  ) async {
    for (var attempt = 0; ; attempt++) {
      try {
        await directory.rename(to);
        return;
      } on FileSystemException catch (error) {
        final code = error.osError?.errorCode;
        if (!Platform.isWindows ||
            attempt >= 4 ||
            (code != 5 && code != 32 && code != 33)) {
          rethrow;
        }
        await Future<void>.delayed(Duration(milliseconds: 50 << attempt));
      }
    }
  }

  static String _relativePosix(String root, String path) {
    final relative = p.relative(path, from: root);
    return relative.split(p.separator).join('/');
  }

  static String _normalizeEntryName(String name) {
    var value = name.replaceAll('\\', '/');
    while (value.startsWith('./')) {
      value = value.substring(2);
    }
    return value;
  }

  static String _shorten(String text) =>
      text.length <= 200 ? text : '${text.substring(0, 200)}…';
}

/// 注入用的解压函数签名：把 [archive] 解到 [destination]。
typedef CatPackageExtractor =
    Future<void> Function(File archive, Directory destination);

/// 导入成功的结果：路径都在数据目录下，可直接交给 `loadFromFile`。
class CatLocalPackageResult {
  const CatLocalPackageResult({
    required this.id,
    required this.directory,
    required this.configPath,
    required this.jarPath,
    required this.jarMd5,
    required this.siteCount,
  });

  final String id;
  final String directory;
  final String configPath;
  final String jarPath;
  final String jarMd5;
  final int siteCount;
}

/// 导入失败：message 直接展示给用户。
class CatLocalPackageException implements Exception {
  const CatLocalPackageException(this.message);

  final String message;

  @override
  String toString() => message;
}

class _VerifiedPackage {
  const _VerifiedPackage({
    required this.configRelative,
    required this.jarRelative,
    required this.jarMd5,
    required this.siteCount,
  });

  final String configRelative;
  final String jarRelative;
  final String jarMd5;
  final int siteCount;
}

/// 压缩包中央目录里的一个条目（只读，不参与解压）。
class _ZipEntry {
  const _ZipEntry({
    required this.name,
    required this.uncompressedSize,
    required this.isDirectory,
    required this.isSymlink,
  });

  final String name;
  final int uncompressedSize;
  final bool isDirectory;
  final bool isSymlink;
}

/// 极简 zip 中央目录读取：只为解压前的安全校验，不引入第三方依赖。
///
/// 不解压、不校验 CRC；能读出条目名与声明大小即可满足 zip slip 与容量上限检查。
class _ZipDirectory {
  const _ZipDirectory._();

  static const int _signatureCentral = 0x02014b50;
  static const int _signatureEnd = 0x06054b50;

  static List<_ZipEntry> read(Uint8List bytes) {
    try {
      return _readUnsafe(bytes);
    } on CatLocalPackageException {
      rethrow;
    } catch (_) {
      throw const CatLocalPackageException('压缩包已损坏或不是有效的 zip，无法导入');
    }
  }

  static List<_ZipEntry> _readUnsafe(Uint8List bytes) {
    if (bytes.length < 22) {
      throw const CatLocalPackageException('压缩包已损坏或不是有效的 zip（文件过短）');
    }
    final data = ByteData.sublistView(bytes);
    final end = _findEnd(data);
    if (end < 0) {
      throw const CatLocalPackageException('压缩包已损坏或不是有效的 zip（找不到压缩包目录）');
    }
    final entryCount = data.getUint16(end + 10, Endian.little);
    final directorySize = data.getUint32(end + 12, Endian.little);
    final directoryOffset = data.getUint32(end + 16, Endian.little);
    if (directoryOffset + directorySize > bytes.length) {
      throw const CatLocalPackageException('压缩包已损坏：目录区超出文件范围');
    }
    final entries = <_ZipEntry>[];
    var offset = directoryOffset;
    for (var index = 0; index < entryCount; index++) {
      if (offset + 46 > bytes.length ||
          data.getUint32(offset, Endian.little) != _signatureCentral) {
        throw const CatLocalPackageException('压缩包已损坏：文件目录项无法读取');
      }
      final madeBy = data.getUint16(offset + 4, Endian.little);
      final flags = data.getUint16(offset + 8, Endian.little);
      final uncompressed = data.getUint32(offset + 24, Endian.little);
      final nameLength = data.getUint16(offset + 28, Endian.little);
      final extraLength = data.getUint16(offset + 30, Endian.little);
      final commentLength = data.getUint16(offset + 32, Endian.little);
      final externalAttributes = data.getUint32(offset + 38, Endian.little);
      if (offset + 46 + nameLength > bytes.length) {
        throw const CatLocalPackageException('压缩包已损坏：文件名超出文件范围');
      }
      final nameBytes = bytes.sublist(offset + 46, offset + 46 + nameLength);
      final unicodeName = (flags & 0x800) != 0;
      final name = unicodeName
          ? utf8.decode(nameBytes, allowMalformed: true)
          : latin1.decode(nameBytes);
      final unix = (madeBy >> 8) == 3;
      final mode = (externalAttributes >> 16) & 0xFFFF;
      entries.add(
        _ZipEntry(
          name: name,
          uncompressedSize: uncompressed,
          isDirectory:
              name.endsWith('/') || (unix && (mode & 0xF000) == 0x4000),
          isSymlink: unix && (mode & 0xF000) == 0xA000,
        ),
      );
      offset += 46 + nameLength + extraLength + commentLength;
    }
    return entries;
  }

  /// 从文件尾向前找 EOCD（最多 64 KB 注释）。
  static int _findEnd(ByteData data) {
    final limit = data.lengthInBytes - 22;
    final start = limit - 65535 < 0 ? 0 : limit - 65535;
    for (var index = limit; index >= start; index--) {
      if (data.getUint32(index, Endian.little) == _signatureEnd) return index;
    }
    return -1;
  }
}
