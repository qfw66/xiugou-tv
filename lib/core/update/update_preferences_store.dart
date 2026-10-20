import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../config/windows_config_storage.dart';
import 'update_preferences.dart';

/// `update_preferences.json` 的读写。
///
/// 与 [FileSettingsStorage] 保持同一约定：原子写（`<name>.tmp-<pid>-<seq>` 后 rename），
/// 使既有的临时文件清理逻辑能识别残留；内容损坏时把原文件改名为
/// `.corrupt-<时间戳>` 留档，然后按默认值继续（更新偏好坏掉不该阻断启动）。
class UpdatePreferencesStore {
  static const String fileName = 'update_preferences.json';

  final Future<Directory> Function() _directory;
  static int _temporarySequence = 0;

  UpdatePreferencesStore({Future<Directory> Function()? directory})
      : _directory = directory ?? WindowsConfigStorage().getStorageDirectory;

  Future<File> _file() async =>
      File(p.join((await _directory()).path, fileName));

  Future<UpdatePreferences> read() async {
    final file = await _file();
    try {
      if (!await file.exists()) return UpdatePreferences.defaults;
      final content = await file.readAsString();
      if (content.trim().isEmpty) return UpdatePreferences.defaults;
      final decoded = jsonDecode(content);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('更新偏好格式无效');
      }
      return UpdatePreferences.fromJson(decoded);
    } on FormatException {
      await _quarantine(file);
      return UpdatePreferences.defaults;
    } catch (_) {
      // IO 失败（权限 / 占用）：按默认值继续，不覆盖用户文件
      return UpdatePreferences.defaults;
    }
  }

  Future<void> write(UpdatePreferences preferences) async {
    final target = await _file();
    await target.parent.create(recursive: true);
    final temp = File('${target.path}.tmp-$pid-${++_temporarySequence}');
    try {
      await temp.writeAsString(jsonEncode(preferences.toJson()), flush: true);
      await temp.rename(target.path);
    } catch (_) {
      // 写入失败不抛出：内存状态已更新，下一次启动按旧文件处理即可
      try {
        if (await temp.exists()) await temp.delete();
      } catch (_) {}
    }
  }

  Future<void> _quarantine(File file) async {
    try {
      if (!await file.exists()) return;
      final stamp = DateTime.now().millisecondsSinceEpoch;
      await file.rename('${file.path}.corrupt-$stamp');
    } catch (_) {
      // 改名失败就算了：不留档也不能阻断启动
    }
  }
}
