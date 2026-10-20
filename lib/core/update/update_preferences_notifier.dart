import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'update_preferences.dart';
import 'update_preferences_store.dart';

/// 更新偏好的内存状态 + 落盘。
///
/// 与 `SettingsRepository` 分开：更新偏好只有三个字段，独立文件与独立读取路径
/// 更小、更好回滚，也不必改 `SettingsSaveTarget` 与既有保存链路。
class UpdatePreferencesNotifier extends StateNotifier<UpdatePreferences> {
  final UpdatePreferencesStore _store;
  bool _loading = false;
  bool _dirty = false;

  UpdatePreferencesNotifier(this._store) : super(UpdatePreferences.defaults);

  /// 读取磁盘偏好；只会发生一次（首帧后由关于页或启动检查触发）。
  Future<void> load() async {
    if (_loading) return;
    _loading = true;
    final loaded = await _store.read();
    // 用户在读取完成前已经改过偏好：以内存为准，避免被旧文件覆盖
    if (!mounted || _dirty) return;
    state = loaded;
  }

  Future<void> setAutoCheck(bool value) =>
      _apply(state.copyWith(autoCheck: value));

  Future<void> setSource(String source) =>
      _apply(state.copyWith(source: source.trim()));

  Future<void> skipVersion(String tag) =>
      _apply(state.copyWith(skippedVersion: tag));

  Future<void> clearSkipped() => _apply(state.copyWith(clearSkipped: true));

  Future<void> _apply(UpdatePreferences next) async {
    _dirty = true;
    state = next;
    await _store.write(next);
  }
}
