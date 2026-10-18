import 'dart:io';

import 'package:path/path.dart' as p;

import '../config/windows_config_storage.dart';
import 'models/appearance_preferences.dart';

/// 图片像素探针：返回 null 表示无法识别（格式损坏 / 不受支持）。
///
/// 由 UI 层注入（依赖 `dart:ui`），让本文件保持纯 IO、可在无引擎的单元测试里运行。
typedef WallpaperSizeProbe = Future<({int width, int height})?> Function(
    File file);

/// 壁纸导入失败：`message` 直接展示给用户（中文、可行动）。
class WallpaperImportException implements Exception {
  final String message;

  const WallpaperImportException(this.message);

  @override
  String toString() => message;
}

/// 壁纸副本管理（SET-08）。
///
/// 选图后把图片**复制**到 `<数据目录>/wallpaper/current.<ext>`，偏好里只存文件名：
/// - 用户移动 / 删除原图不会影响壁纸；
/// - 「恢复默认」只删副本，不触碰用户原图；
/// - 只保留一份当前壁纸（换图成功后清掉旧扩展名的副本）。
class WallpaperStore {
  static const String directoryName = 'wallpaper';

  /// 选择时体积上限（20 MB）。
  static const int maxBytes = 20 * 1024 * 1024;

  /// 选择时单边像素上限（防解码 OOM）。
  static const int maxDimension = 8000;

  static const Set<String> allowedExtensions = {
    'jpg',
    'jpeg',
    'png',
    'webp',
    'bmp',
  };

  final Future<Directory> Function() _dataDirectory;
  final WallpaperSizeProbe? _probeSize;

  WallpaperStore({
    Future<Directory> Function()? directory,
    WallpaperSizeProbe? probeSize,
  })  : _dataDirectory =
            directory ?? WindowsConfigStorage().getStorageDirectory,
        _probeSize = probeSize;

  Future<Directory> _wallpaperDirectory() async =>
      Directory(p.join((await _dataDirectory()).path, directoryName));

  /// 解析偏好里的文件名到可直接显示的绝对路径；文件缺失 / 名称非法时返回 null。
  Future<String?> resolvePath(String? fileName) async {
    final name = fileName?.trim();
    if (name == null || name.isEmpty) return null;
    if (name.contains('/') ||
        name.contains(r'\') ||
        name.contains('..') ||
        !AppearancePreferences.fileNamePattern.hasMatch(name)) {
      return null;
    }
    final file = File(p.join((await _wallpaperDirectory()).path, name));
    return await file.exists() ? file.path : null;
  }

  /// 导入 `sourcePath` 指向的图片，返回**新的偏好**（尚未落盘，由调用方保存）。
  ///
  /// 校验顺序：存在性 → 扩展名 → 体积 → 像素；任何一步失败都抛
  /// [WallpaperImportException]，不会删除既有副本、不会产生半截文件。
  Future<AppearancePreferences> importFrom(
      String sourcePath, AppearancePreferences current) async {
    final source = File(sourcePath);
    if (!await source.exists()) {
      throw const WallpaperImportException('找不到所选图片，请重新选择');
    }
    final ext = p.extension(sourcePath).replaceFirst('.', '').toLowerCase();
    if (!allowedExtensions.contains(ext)) {
      throw const WallpaperImportException(
          '只支持 jpg / jpeg / png / webp / bmp 格式');
    }
    if (await source.length() > maxBytes) {
      throw const WallpaperImportException('图片超过 20 MB，请换一张');
    }
    final probe = _probeSize;
    if (probe != null) {
      final size = await probe(source);
      if (size == null) {
        throw const WallpaperImportException('无法识别该图片，请换一张');
      }
      if (size.width > maxDimension || size.height > maxDimension) {
        throw const WallpaperImportException(
            '图片尺寸过大（上限 8000×8000），请换一张');
      }
    }

    final directory = await _wallpaperDirectory();
    await directory.create(recursive: true);
    // 文件名带时间戳：换同格式图片时路径也会变，避免 Flutter 图片缓存命中旧图。
    final name = 'current-${DateTime.now().millisecondsSinceEpoch}.$ext';
    final target = File(p.join(directory.path, name));
    final temp = File('${target.path}.tmp-$pid');
    try {
      await source.copy(temp.path);
      await temp.rename(target.path);
    } finally {
      try {
        if (await temp.exists()) await temp.delete();
      } on FileSystemException {
        // 清理失败不影响已完成的替换。
      }
    }
    // 替换成功后再清旧扩展名的副本：失败时用户原有壁纸仍然可用。
    await _deleteAllExcept(directory, keep: name);
    return current.withWallpaper(name);
  }

  /// 恢复默认：删除副本（不触碰用户原图），返回未设置壁纸的偏好。
  Future<AppearancePreferences> clear() async {
    final directory = await _wallpaperDirectory();
    if (await directory.exists()) {
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is! File) continue;
        try {
          await entity.delete();
        } on FileSystemException {
          // 单个文件删除失败时继续清理其余副本。
        }
      }
    }
    return AppearancePreferences.none;
  }

  Future<void> _deleteAllExcept(Directory directory, {required String keep}) async {
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File || p.basename(entity.path) == keep) continue;
      final name = p.basename(entity.path);
      if (!p.basenameWithoutExtension(name).startsWith('current')) continue;
      try {
        await entity.delete();
      } on FileSystemException {
        // 旧副本删除失败不影响新壁纸生效。
      }
    }
  }
}
