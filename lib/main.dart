import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app.dart';
import 'core/app_info.dart';
import 'core/companion/companion_process_manager.dart';
import 'core/config/config_repository.dart';
import 'core/player/mpv_player_engine.dart';
import 'core/settings/settings_repository.dart';
import 'core/storage/data_directory_manager.dart';
import 'ui/desktop/window/desktop_window_manager.dart';

Future<void> main() async {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    await loadAppVersionLabel();

    // N-2：先解析数据目录并执行待定迁移，再创建任何存储（避免运行中双目录写入）
    try {
      await DataDirectoryManager.initialize();
    } catch (error) {
      debugPrint('[xiugou-tv] data directory init failed: $error');
    }

    final configRepository = ConfigRepository();
    await configRepository.initialize();

    final settingsRepository = SettingsRepository();
    await settingsRepository.initialize(
      legacyHwdec: configRepository.currentWindowConfig.hardwareDecoding,
      legacyConfigUrl: configRepository.currentWindowConfig.lastConfigUrl,
    );
    // 应用生命周期内常驻：成功加载的 URL / 本地文件记入配置源历史
    settingsRepository.bindConfigRepository(configRepository);

    // SET-05：播放历史保留上限从设置同步一次（trim: false——启动不静默裁剪，见方案 §2.2）
    await configRepository.setHistoryLimit(settingsRepository.historyPreferences.limit, trim: false);

    final companionManager = CompanionProcessManager();
    final windowManager = DesktopWindowManager(
      configRepository: configRepository,
      beforeClose: companionManager.shutdown,
    );
    await windowManager.initialize();

    // 冷启动有效主入口：启动偏好 +「上次入口」解析（失败按点播首页）
    final startupEntry = settingsRepository.startupPreferences.effectiveEntry;

    final playerEngine = MpvPlayerEngine();
    // 初始化时捕获默认音量 / 倍速；之后只更新即时参数，不覆盖当前播放默认值
    unawaited(playerEngine.applyPlaybackSettings(settingsRepository.playerSettings));
    settingsRepository.playerSettingsStream.skip(1).listen(playerEngine.applyPlaybackSettings);

    runApp(
      ProviderScope(
        overrides: [
          configRepositoryProvider.overrideWithValue(configRepository),
          windowManagerProvider.overrideWithValue(windowManager),
          playerEngineProvider.overrideWithValue(playerEngine),
          settingsRepositoryProvider.overrideWithValue(settingsRepository),
          startupEntryProvider.overrideWithValue(startupEntry),
        ],
        child: const XiugouTvApp(),
      ),
    );

    unawaited(playerEngine.initialize());
  }, (error, stack) {
    debugPrint('[xiugou-tv] startup error: $error\n$stack');
  });
}
