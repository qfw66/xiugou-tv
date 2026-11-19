import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../storage/data_restore_guard.dart';
import 'update_preferences.dart';
import 'update_preferences_store.dart';

/// 更新偏好的内存状态 + 按用户操作顺序落盘。
///
/// 每个修改在轮到它时基于上次接受的状态计算，严格保存成功后才发布。
/// 这样旧写入不会覆盖已确认的镜像配置，失败配置也不会混入后续开关写入。
class UpdatePreferencesNotifier extends StateNotifier<UpdatePreferences> {
  final UpdatePreferencesStore _store;
  bool _loading = false;
  bool _dirty = false;
  Future<void> _writes = Future<void>.value();

  UpdatePreferencesNotifier(this._store) : super(UpdatePreferences.defaults);

  /// 读取磁盘偏好；只会发生一次（首帧后由关于页或启动检查触发）。
  Future<void> load() async {
    if (_loading) return;
    _loading = true;
    final loaded = await _store.read();
    // 用户在读取完成前已经改过偏好：以内存为准，避免被旧文件覆盖。
    if (!mounted || _dirty) return;
    state = loaded;
  }

  Future<void> setAutoCheck(bool value) =>
      _apply((current) => current.copyWith(autoCheck: value));

  Future<void> setSource(String source) =>
      _apply((current) => current.copyWith(source: source.trim()));

  Future<void> setUseMirror(bool value) =>
      _apply((current) => current.copyWith(useMirror: value));

  Future<void> setMirrorsUrl(String value) {
    if (!UpdatePreferences.isValidMirrorsUrl(value)) {
      throw const FormatException('请输入有效的 HTTPS 镜像配置地址');
    }
    return _apply((current) => current.copyWith(mirrorsUrl: value.trim()));
  }

  Future<void> setMirrorSettings({required bool enabled, required String url}) {
    if (!UpdatePreferences.isValidMirrorsUrl(url)) {
      throw const FormatException('请输入有效的 HTTPS 镜像配置地址');
    }
    return _apply(
        (current) => current.copyWith(useMirror: enabled, mirrorsUrl: url.trim()),
        strict: true);
  }

  Future<void> skipVersion(String tag) =>
      _apply((current) => current.copyWith(skippedVersion: tag));

  Future<void> clearSkipped() =>
      _apply((current) => current.copyWith(clearSkipped: true));

  Future<void> _apply(UpdatePreferences Function(UpdatePreferences) update,
      {bool strict = false}) {
    if (dataRestorePendingRestart) {
      throw const DataRestorePendingRestartException();
    }
    _dirty = true;
    final pending = _writes.then((_) async {
      if (!mounted) return;
      if (dataRestorePendingRestart) {
        throw const DataRestorePendingRestartException();
      }
      final next = update(state);
      await _store.write(next, throwOnFailure: strict);
      if (dataRestorePendingRestart) {
        throw const DataRestorePendingRestartException();
      }
      if (mounted) state = next;
    });
    // A failed strict save is reported to its caller, but must not poison the
    // queue or supply its rejected snapshot to the next user operation.
    _writes = pending.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return pending;
  }
}
