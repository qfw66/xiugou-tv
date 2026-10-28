import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'data_directory_manager.dart';
import 'data_restore_guard.dart';

/// 关于页「重置所有设置」= 全部清空（2026-10-27 用户口径）。
///
/// 为什么分两步：运行中的仓库持有内存快照，关闭链还会落盘（窗口几何、历史、配置快照…）；
/// 直接删目录会被这些写入重新填回。所以：
/// 1. 现在（[schedule]）：在默认目录写标记 `reset_pending.json`，并置
///    [dataRestorePendingRestart] 让本次会话后续写入全部跳过；随后重启；
/// 2. 下次启动、创建任何存储**之前**（[applyPendingAtStartup]）：把数据目录（默认目录，
///    以及当时在用的自定义目录）里的内容全部删掉——含自定义目录指针，回到全新安装状态。
///
/// 只删修狗TV 自己的数据目录内容；自定义目录本身保留（可能是用户建的文件夹），只清里面的东西。
abstract final class AppDataReset {
  static const String markerFileName = 'reset_pending.json';

  static File _marker(String defaultPath) => File(p.join(defaultPath, markerFileName));

  /// 第 1 步：安排清空（写标记 + 冻结本次会话的落盘）。
  static Future<void> schedule({String? defaultDirectory, String? activeDirectory}) async {
    final defaultPath = defaultDirectory ?? DataDirectoryManager.defaultDirectoryPath();
    final marker = _marker(defaultPath);
    await marker.parent.create(recursive: true);
    await marker.writeAsString(
      jsonEncode({
        'format': 'xiugou-tv-reset',
        'version': 1,
        'active': activeDirectory ?? DataDirectoryManager.currentPath,
      }),
      flush: true,
    );
    dataRestorePendingRestart = true;
  }

  /// 第 2 步：启动时执行（必须在 [DataDirectoryManager.initialize] 之前）。
  /// 返回是否执行了清空。任何失败都不阻断启动。
  static Future<bool> applyPendingAtStartup({String? defaultDirectory}) async {
    final defaultPath = p.normalize(p.absolute(defaultDirectory ?? DataDirectoryManager.defaultDirectoryPath()));
    final marker = _marker(defaultPath);
    if (!await marker.exists()) return false;
    String? active;
    try {
      final decoded = jsonDecode(await marker.readAsString());
      if (decoded is Map && decoded['active'] is String) active = decoded['active'] as String;
    } catch (_) {
      // 标记损坏：仍然清空默认目录（用户已确认过要清空）
    }

    final targets = <String>{defaultPath};
    if (active != null && active.trim().isNotEmpty) targets.add(p.normalize(p.absolute(active)));
    for (final dir in targets) {
      await _emptyDirectory(Directory(dir));
    }
    return true;
  }

  /// 清空目录内容（目录本身保留）。删不掉的文件（被占用）跳过，不抛。
  static Future<void> _emptyDirectory(Directory dir) async {
    if (!await dir.exists()) return;
    // 防呆：不允许清空盘符根目录或用户主目录
    final normalized = p.normalize(p.absolute(dir.path));
    final home = Platform.environment['USERPROFILE'];
    if (p.rootPrefix(normalized) == normalized ||
        (home != null && p.equals(normalized, p.normalize(home)))) {
      return;
    }
    await for (final entity in dir.list(followLinks: false)) {
      try {
        await entity.delete(recursive: true);
      } catch (_) {}
    }
  }
}
