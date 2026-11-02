import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app.dart';
import 'core/app_info.dart';
import 'core/companion/companion_process_manager.dart';
import 'core/config/config_repository.dart';
import 'core/config/models/builtin_sites.dart';
import 'core/diagnostics/error_log.dart';
import 'core/net/http_client_factory.dart';
import 'core/danmaku/danmaku_api.dart';
import 'core/player/mpv_player_engine.dart';
import 'core/settings/models/appearance_preferences.dart';
import 'core/settings/settings_repository.dart';
import 'core/storage/app_data_reset.dart';
import 'core/storage/data_directory_manager.dart';
import 'ui/desktop/window/desktop_window_manager.dart';
import 'ui/theme/app_icon_assets.dart';
import 'ui/theme/app_palette.dart';

Future<void> main() async {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    // ⑥ 内存批：海报 / 台标等网络图解码缓存默认上限 100MB，收紧到 48MB；
    // 超出按 LRU 淘汰、重复浏览会再解码，换取常驻内存下降。
    PaintingBinding.instance.imageCache.maximumSizeBytes = 48 << 20;
    await loadAppVersionLabel();
    // §43：可选服务是否启用（只打印是否配置，不打印地址 / 令牌）
    debugPrint('[xiugou-tv] 弹幕服务：${danmakuServiceConfigured ? '已配置' : '未配置（config/app.env）'}');

    // 关于页「重置所有设置」：上次会话安排的全部清空，在创建任何存储之前执行
    try {
      if (await AppDataReset.applyPendingAtStartup()) {
        debugPrint('[xiugou-tv] 已按上次的「重置所有设置」清空数据目录');
      }
    } catch (error) {
      debugPrint('[xiugou-tv] reset failed: $error');
    }

    // N-2：先解析数据目录并执行待定迁移，再创建任何存储（避免运行中双目录写入）
    try {
      await DataDirectoryManager.initialize();
    } catch (error) {
      debugPrint('[xiugou-tv] data directory init failed: $error');
    }

    // 关于页「错误日志」：本次运行期间的未捕获异常、框架错误、播放器报错，只放内存（关闭即清空）
    final previousOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      ErrorLog.instance.record('界面', details.exception, details.stack);
      previousOnError?.call(details);
    };

    final configRepository = ConfigRepository(fallbackHomeSite: builtinDoubanSite);
    await configRepository.initialize();

    final settingsRepository = SettingsRepository();
    await settingsRepository.initialize(
      legacyHwdec: configRepository.currentWindowConfig.hardwareDecoding,
      legacyConfigUrl: configRepository.currentWindowConfig.lastConfigUrl,
    );
    // 应用生命周期内常驻：成功加载的 URL / 本地文件记入配置源历史
    settingsRepository.bindConfigRepository(configRepository);

    // SET-05：播放历史保留上限从设置同步一次（trim: false——启动不静默裁剪，见方案 §2.2）
    await configRepository.setHistoryLimit(
        settingsRepository.historyPreferences.limit,
        trim: false);
    // §14 无痕浏览：跟随历史偏好（流先给当前值，再推送设置页 / 重新读取后的变更）
    configRepository.setHistoryIncognito(settingsRepository.historyPreferences.incognito);
    settingsRepository.historyPreferencesStream.listen(
        (preferences) => configRepository.setHistoryIncognito(preferences.incognito));
    // §14 安全 DNS：未经工厂创建的 HttpClient（如普通海报 NetworkImage）也接管建连；
    // 选择跟随网络偏好实时切换（读取失败时偏好为默认「关闭」）。
    HttpClientFactory.installGlobalOverrides();
    HttpClientFactory.configureDoh(settingsRepository.networkPreferences.endpoint);
    settingsRepository.networkPreferencesStream.listen(
        (preferences) => HttpClientFactory.configureDoh(preferences.endpoint));

    final companionManager = CompanionProcessManager();
    // §59 站源直连被重置时改走 Windows 系统代理（只在系统代理开启时生效）
    companionManager.fallbackProxy = DanmakuApi.systemProxy;
    // 播放器先于窗口管理器创建：退出钩子要先停播放（窗口已隐藏，声音不能再继续）
    final playerEngine = MpvPlayerEngine();
    final windowManager = DesktopWindowManager(
      configRepository: configRepository,
      beforeClose: () async {
        try {
          await playerEngine.stop().timeout(const Duration(milliseconds: 500));
        } catch (_) {
          // 停播失败 / 超时不阻断关闭：进程退出时 mpv 随之结束
        }
        await companionManager.shutdown();
      },
    );
    // 首帧前按已保存主题给原生窗口底色，避免浅色主题启动时闪深色边
    final appearance = settingsRepository.appearancePreferences;
    final initialBrightness = switch (appearance.themeMode) {
      AppThemeMode.dark => Brightness.dark,
      AppThemeMode.light => Brightness.light,
      AppThemeMode.system =>
        WidgetsBinding.instance.platformDispatcher.platformBrightness,
    };
    await windowManager.initialize(
      backgroundColor: initialBrightness == Brightness.dark
          ? AppPalette.dark.background
          : AppPalette.light.background,
      iconPath: appIconFilePath(),
    );

    // 冷启动有效主入口：启动偏好 +「上次入口」解析（失败按点播首页）
    final startupEntry = settingsRepository.startupPreferences.effectiveEntry;

    // 初始化时捕获默认音量 / 倍速；之后只更新即时参数，不覆盖当前播放默认值
    unawaited(
        playerEngine.applyPlaybackSettings(settingsRepository.playerSettings));
    playerEngine.errorStream.listen((message) {
      if (message != null && message.trim().isNotEmpty) {
        ErrorLog.instance.record('播放器', message);
      }
    });
    settingsRepository.playerSettingsStream
        .skip(1)
        .listen(playerEngine.applyPlaybackSettings);

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
    ErrorLog.instance.record('未捕获异常', error, stack);
  });
}
