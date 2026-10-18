import '../settings/settings_repository.dart';
import 'models/player_settings.dart';
import 'player_engine.dart';

/// 还原播放器相关数据。
///
/// 范围（与 SET-22/24/30 方案一致）：
/// - 当前影片的片头 / 片尾记录（[vodId] 为空时跳过，如直播 / 推送 / 续播）；
/// - `PlayerSettings` 全部字段回到默认值（含画面比例 `fit`）；
/// - 当前引擎即时恢复默认音量、1.0x 与默认 mpv 属性。
///
/// 不触碰播放历史、收藏、配置源、片头片尾总开关与其他设置分区。
Future<void> resetPlayerData({
  required SettingsRepository settings,
  required PlayerEngine engine,
  String? vodId,
}) async {
  Object? saveError;
  if (vodId != null && vodId.isNotEmpty) {
    final preferences = settings.playSkipPreferences;
    if (preferences.entryFor(vodId) != null) {
      try {
        await settings.updatePlaySkipPreferences(preferences.remove(vodId));
      } catch (error) {
        saveError = error;
      }
    }
  }
  try {
    await settings.resetPlayerSettings();
  } catch (error) {
    saveError = error;
  }

  // 即使落盘失败，也把当前引擎恢复到默认值，避免「内存/设置中心已复位、
  // 播放仍停在旧倍速/音量」的三方不一致；持久化失败由调用方提示并等待重试。
  await engine.setVolume(PlayerSettings.defaults.defaultVolume);
  await engine.setRate(PlayerSettings.defaults.defaultRate);
  await engine.applyPlaybackSettings(PlayerSettings.defaults);

  if (saveError != null) throw saveError;
}

/// 应用画面比例（SET-30）：失败时仅在内存仍是本次值时回滚到上一次。
///
/// 若失败返回前用户已发起更新的一次选择，不用旧值覆盖新值。
Future<void> applyPlayerScale(
    SettingsRepository settings, String scale) async {
  final previous = settings.playerSettings.scale;
  if (previous == scale) return;
  try {
    await settings.updatePlayerSettings(
        settings.playerSettings.copyWith(scale: scale));
  } catch (_) {
    if (settings.playerSettings.scale == scale) {
      try {
        await settings.updatePlayerSettings(
            settings.playerSettings.copyWith(scale: previous));
      } catch (_) {}
    }
    rethrow;
  }
}
