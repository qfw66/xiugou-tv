import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:path/path.dart' as p;
import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/api/cms_json_api.dart';
import 'core/api/douban_repository.dart';
import 'core/api/models/vod_models.dart';
import 'core/api/parse_engine.dart';
import 'core/api/play_failure_text.dart';
import 'core/api/search_cancel_token.dart';
import 'core/api/search_engine.dart';
import 'core/app_info.dart';
import 'core/companion/companion_ui_channel.dart';
import 'core/companion/companion_spider_api.dart';
import 'core/api/site_api.dart';
import 'core/config/config_repository.dart';
import 'core/config/models/builtin_sites.dart';
import 'core/config/models/config_source_summary.dart';
import 'core/config/models/history_record.dart';
import 'core/config/models/home_site_preference.dart';
import 'core/config/models/vod_config.dart';
import 'core/live/live_playback_mode.dart';
import 'core/live/live_repository.dart';
import 'core/live/live_source.dart';
import 'core/live/live_source_history.dart';
import 'core/live/live_switch_reconcile.dart';
import 'core/live/live_text_loader.dart';
import 'core/live/epg_repository.dart';
import 'core/history/history_match.dart';
import 'core/danmaku/danmaku_api.dart';
import 'core/danmaku/danmaku_cache.dart';
import 'core/danmaku/danmaku_controller.dart';
import 'core/danmaku/danmaku_settings.dart';
import 'core/danmaku/live_danmaku_client.dart';
import 'core/segments/segments_api.dart';
import 'core/segments/segments_controller.dart';
import 'core/player/models/player_settings.dart';
import 'core/player/models/player_state.dart';
import 'core/player/hls_playlist_probe.dart';
import 'core/player/mpv_player_engine.dart';
import 'core/player/muted_playback_hint.dart';
import 'core/player/playback_http_headers.dart';
import 'core/player/playback_history_tracker.dart';
import 'core/player/playback_intent.dart';
import 'core/player/auto_line_switch_controller.dart';
import 'core/player/line_switch_planner.dart';
import 'core/player/player_data_reset.dart';
import 'core/settings/models/appearance_preferences.dart';
import 'core/settings/models/config_source_entry.dart';
import 'core/settings/models/play_skip_preferences.dart';
import 'core/settings/models/player_shortcut_bindings.dart';
import 'core/settings/models/search_preferences.dart';
import 'core/settings/models/startup_preferences.dart';
import 'core/settings/settings_repository.dart';
import 'core/settings/wallpaper_store.dart';
import 'core/storage/cache_maintenance.dart';
import 'core/storage/app_data_reset.dart';
import 'core/storage/data_directory_manager.dart';
import 'core/storage/data_backup_service.dart';
import 'core/storage/data_restore_guard.dart';
import 'core/update/installer_launcher.dart';
import 'core/update/update_controller.dart';
import 'core/update/update_downloader.dart';
import 'core/update/update_preferences.dart';
import 'core/update/update_preferences_notifier.dart';
import 'core/update/update_preferences_store.dart';
import 'core/update/update_service.dart';
import 'ui/desktop/catalog/category_filter_bar.dart';
import 'ui/desktop/catalog/douban_poster_image.dart';
import 'ui/desktop/catalog/poster_image.dart';
import 'ui/desktop/catalog/vod_detail_dialog.dart';
import 'ui/desktop/catalog/vod_grid_view.dart';
import 'ui/desktop/catalog/vod_grid_skeleton.dart';
import 'ui/desktop/catalog/vod_list_view.dart';
import 'ui/desktop/home/netflix_home_view.dart';
import 'ui/desktop/catalog/search_site_groups.dart';
import 'ui/desktop/catalog/search_site_bar.dart';
import 'ui/desktop/dialogs/depot_selection_dialog.dart';
import 'ui/desktop/dialogs/favorites_dialog.dart';
import 'ui/desktop/dialogs/history_dialog.dart';
import 'ui/desktop/wallpaper/wallpaper_size_probe.dart';
import 'ui/desktop/dialogs/live_channels_dialog.dart';
import 'ui/desktop/dialogs/push_stream_dialog.dart';
import 'ui/desktop/dialogs/site_selector_dialog.dart';
import 'ui/desktop/dialogs/spider_dialog_host.dart';
import 'ui/desktop/dialogs/update_dialog.dart';
import 'ui/desktop/player/desktop_video_player.dart';
import 'ui/desktop/player/segment_panel.dart';
import 'ui/desktop/player/episode_drawer.dart';
import 'ui/desktop/player/live_source_picker.dart';
import 'ui/desktop/player/live_danmaku_binding.dart';
import 'ui/desktop/player/playback_mode_badge.dart';
import 'ui/desktop/settings/about_update_section.dart';
import 'ui/desktop/settings/settings_page.dart';
import 'ui/desktop/shell/desktop_sidebar.dart';
import 'ui/desktop/widgets/app_message.dart';
import 'ui/desktop/widgets/desktop_window_frame.dart';
import 'ui/desktop/widgets/dialog_drag_strip.dart';
import 'ui/desktop/widgets/filter_pill.dart';
import 'ui/desktop/widgets/home_search_bar_host.dart';
import 'ui/desktop/widgets/horizontal_scroll_area.dart';
import 'ui/desktop/window/desktop_window_manager.dart';
import 'ui/theme/app_palette.dart';
import 'ui/theme/app_tokens.dart';
import 'ui/theme/app_theme.dart';
import 'core/player/cross_site_failover_planner.dart';
import 'core/player/cross_site_search_service.dart';
import 'core/player/playback_source_loader.dart';
import 'core/player/external_player_launcher.dart';

part 'playback_source_actions.dart';
part 'playback_external_actions.dart';

// --- 全局依赖 Provider ---

final configRepositoryProvider = Provider<ConfigRepository>((ref) {
  throw UnimplementedError(
      'ConfigRepository 必须在启动时通过 ProviderScope overrides 注入');
});

final windowManagerProvider = Provider<DesktopWindowManager>((ref) {
  throw UnimplementedError(
      'DesktopWindowManager 必须在启动时通过 ProviderScope overrides 注入');
});

final playerEngineProvider = Provider<MpvPlayerEngine>((ref) {
  throw UnimplementedError(
      'MpvPlayerEngine 必须在启动时通过 ProviderScope overrides 注入');
});

final settingsRepositoryProvider = Provider<SettingsRepository>((ref) {
  throw UnimplementedError(
      'SettingsRepository 必须在启动时通过 ProviderScope overrides 注入');
});

/// 搜索显示与聚合开关偏好（随设置保存 / 读取实时更新）
final searchPreferencesProvider = StreamProvider<SearchPreferences>((ref) {
  return ref.watch(settingsRepositoryProvider).searchPreferencesStream;
});

/// 外观偏好（SET-08：壁纸；主题）；随设置保存 / 读取实时更新
final appearancePreferencesProvider =
    StreamProvider<AppearancePreferences>((ref) {
  return ref.watch(settingsRepositoryProvider).appearancePreferencesStream;
});

/// 当前主题模式：默认深色；「跟随系统」由 MaterialApp 依平台亮度解析。
final themeModeProvider = Provider<AppThemeMode>((ref) {
  final preferences = ref.watch(appearancePreferencesProvider).valueOrNull ??
      ref.read(settingsRepositoryProvider).appearancePreferences;
  return preferences.themeMode;
});

/// 壁纸副本管理。像素探针依赖 `dart:ui`，因此在这里（UI 层）装配。
final wallpaperStoreProvider = Provider<WallpaperStore>(
    (ref) => WallpaperStore(probeSize: probeWallpaperImageSize));

/// 本次启动解析出的有效主入口。
///
/// 默认点播首页（与既有行为一致）；应用启动时由 main() 依据启动偏好注入。
final startupEntryProvider = Provider<StartupEntry>((ref) => StartupEntry.vod);

/// 设置中心是否打开（独立全屏页，覆盖主视图与播放器）
final settingsPageOpenProvider = StateProvider<bool>((ref) => false);

// --- 配置源徽标与切换（方案 B · Phase 1）---

/// 成功加载过的配置源历史（远程订阅 / 本地文件，最近使用在前）。
final configSourcesProvider = StreamProvider<List<ConfigSourceEntry>>((ref) {
  return ref.watch(settingsRepositoryProvider).configSourcesStream;
});

/// 顶栏「当前配置源」徽标的展示信息（方案 §4.1）。
final configSourceSummaryProvider = Provider<ConfigSourceSummary>((ref) {
  final config = ref.watch(vodConfigProvider);
  final repository = ref.watch(configRepositoryProvider);
  final entries = ref.watch(configSourcesProvider).valueOrNull ??
      ref.watch(settingsRepositoryProvider).configSources;
  return buildConfigSourceSummary(
    kind: repository.currentSourceKind,
    location: repository.currentSourceLocation,
    entries: entries,
    hasConfig: config.sites.isNotEmpty || config.lives.isNotEmpty,
  );
});

// --- 检测更新（BACKLOG §8）---

final updatePreferencesStoreProvider =
    Provider<UpdatePreferencesStore>((ref) => UpdatePreferencesStore());

final updatePreferencesProvider =
    StateNotifierProvider<UpdatePreferencesNotifier, UpdatePreferences>((ref) {
  final notifier =
      UpdatePreferencesNotifier(ref.watch(updatePreferencesStoreProvider));
  unawaited(notifier.load());
  return notifier;
});

final updateServiceProvider = Provider<UpdateService>((ref) {
  final service = UpdateService();
  ref.onDispose(service.dispose);
  return service;
});

final updateDownloaderProvider = Provider<UpdateDownloader>((ref) {
  final downloader = UpdateDownloader();
  unawaited(downloader.pruneStaleOnStartup());
  ref.onDispose(downloader.close);
  return downloader;
});

final installerLauncherProvider =
    Provider<InstallerLauncher>((ref) => InstallerLauncher());

final updateControllerProvider =
    StateNotifierProvider<UpdateController, UpdateUiState>((ref) {
  return UpdateController(
    service: ref.watch(updateServiceProvider),
    downloader: ref.watch(updateDownloaderProvider),
    launcher: ref.watch(installerLauncherProvider),
    preferences: ref.read(updatePreferencesProvider.notifier),
    closeApp: () => ref.read(windowManagerProvider).close(),
  );
});

/// 打开更新对话框（检查结果、下载进度、安装确认都在同一框内切换）。
Future<void> showUpdateDialog(BuildContext context) => showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _UpdateDialogHost(),
    );

final cmsApiProvider = Provider<CmsJsonApi>((ref) => CmsJsonApi());
final Provider<SiteApi> siteApiProvider = Provider<SiteApi>((ref) {
  final api = SiteApi(
    cmsApi: ref.watch(cmsApiProvider),
    // 伴随服务懒启动后由 SiteApi 把当前开关推给 Java 侧
    selfCheckEnabled: () =>
        ref.read(settingsRepositoryProvider).selfCheckPreferences.enabled,
  );
  // 每次加载配置都让伴随服务释放旧配置的资源：否则类加载器、python 子进程、
  // 代理端口只增不减，换几次配置后加固源会因端口池耗尽而无法播放。
  final sub = ref.read(configRepositoryProvider).configLoadedStream.listen((_) {
    // 配置一加载就把 jar 在后台准备好（下载壳 → 解密载荷 → dex2jar，首次要十几秒）。
    // 否则第一次点详情/播放会踩超时，表现成「必须先做一次全局搜索才能激活」。
    unawaited(() async {
      await api.resetCompanionSpiders();
      ref.read(liveRepositoryProvider).notifyScriptReset();
      await api.prewarmCompanionJars(
          ref.read(configRepositoryProvider).currentVodConfig.sites);
    }());
  });
  final readyPort = api.companionManager.readyPort;
  var previousPort = readyPort.value;
  void onCompanionReady() {
    final port = readyPort.value;
    if (port != null && port != previousPort) {
      ref.read(liveRepositoryProvider).notifyScriptReset();
    }
    previousPort = port;
  }
  readyPort.addListener(onCompanionReady);
  ref.onDispose(() {
    unawaited(sub.cancel());
    readyPort.removeListener(onCompanionReady);
  });
  // 启动阶段：配置在 runApp 之前就加载完了，configLoadedStream 那一次事件没有监听者，
  // 所以这里再主动预热一次（否则首次使用仍要「先全局搜索一次」才激活）。
  unawaited(api.prewarmCompanionJars(
      ref.read(configRepositoryProvider).currentVodConfig.sites));
  return api;
});
final parseEngineProvider = Provider<ParseEngine>((ref) => ParseEngine());

/// 载荷界面通道：跟随 companion 进程长轮询弹窗 / Toast 事件（配置中心的扫码登录、填写 cookie）。
final companionUiChannelProvider = Provider<CompanionUiChannel>((ref) {
  final manager = ref.watch(siteApiProvider).companionManager;
  final channel = CompanionUiChannel(
    readyPort: manager.readyPort,
    onActivity: manager.notifyActivity,
  )..start();
  ref.onDispose(channel.dispose);
  return channel;
});
final searchEngineProvider = Provider<SearchEngine>(
    (ref) => SearchEngine(siteApi: ref.watch(siteApiProvider)));

/// 豆瓣「热播」数据源（§17）：内存缓存 8 分钟，失败不缓存。
final doubanRepositoryProvider =
    Provider<DoubanRepository>((ref) => DoubanRepository());

final liveRepositoryProvider = Provider<LiveRepository>((ref) {
  final repository = LiveRepository(
    loadScript: (source) => ref.read(siteApiProvider).fetchLiveSource(source),
  );
  ref.onDispose(repository.dispose);
  return repository;
});

/// ⑤-2/⑤-3 直播运行态：当前频道列表与高亮索引（播放器抽屉 / ←→ 切台共用）。
/// 仅本次运行内有效；跨启动的「上次频道」走 live_last.json。
class LivePlaybackRuntime {
  final List<Live> channels;
  final int index;

  /// 静态频道对账可更新目录地址而不重开；原播放地址仍归属 [index]。
  final String? retainedPlaybackUrl;

  /// 只有已提交的参数对象拥有该频道身份；失败选台可保留另一个 [index]。
  final ({MediaPlaySpec spec, Live channel})? committedPlayback;

  const LivePlaybackRuntime({
    required this.channels,
    required this.index,
    this.retainedPlaybackUrl,
    this.committedPlayback,
  });
}

final liveRuntimeProvider = StateProvider<LivePlaybackRuntime?>((ref) => null);

/// 直播页「播放方式」菜单的选择：本次运行内按频道地址生效，不落盘。
final livePlaybackChoicesProvider =
    StateProvider<Map<String, LivePlaybackChoice>>((ref) => const {});

/// 起播前正在只读清单识别播放方式（左上角胶囊转圈、顶栏常显）。
final livePlaybackProbingProvider = StateProvider<bool>((ref) => false);

/// 自动识别没有结论（超时 / 网络失败）的地址：本次运行内不再自动探测，
/// 再进同一频道直接按直播起播、不再多等；菜单里选「自动识别」仍会重新探测。
final Set<String> _liveProbeFailedUrls = <String>{};

/// 每次起播直播频道 +1：探测期间又换了台，旧的探测结果直接作废。
int _liveLaunchSerial = 0;

/// ⑤ 修复：直播入口「先进入播放页再加载」的加载态。
/// true 时播放页可见（即使尚无播放规格）并显示居中加载指示；加载完成或
/// 用户中途返回即复位（迟到的起播结果按此作废，不产生幽灵播放）。
final liveEntryLoadingProvider = StateProvider<bool>((ref) => false);
final epgRepositoryProvider = Provider<EpgRepository>((ref) {
  final repository = EpgRepository();
  ref.onDispose(repository.dispose);
  return repository;
});

/// 存储与缓存盘点 / 清理（SET-09）。默认使用真实 %APPDATA%/XiugouTV。
final cacheMaintenanceProvider =
    Provider<CacheMaintenance>((ref) => CacheMaintenance());

/// 数据备份与恢复（SET-10）。读取前等待配置 / 设置保存链落定。
final dataBackupServiceProvider = Provider<DataBackupService>((ref) {
  return DataBackupService(
    appVersion: () => appVersionLabel ?? '未知版本',
    flushPendingWrites: () async {
      await Future.wait([
        ref.read(configRepositoryProvider).flushPendingWrites(),
        ref.read(settingsRepositoryProvider).flushPendingWrites(),
        ref.read(liveRepositoryProvider).flushPendingWrites(),
      ]);
    },
  );
});

/// 播放进度跟踪器：把播放位置持续写回历史记录（断点续播数据源）
final playbackHistoryTrackerProvider = Provider<PlaybackHistoryTracker>((ref) {
  final tracker = PlaybackHistoryTracker(
    engine: ref.watch(playerEngineProvider),
    repository: ref.watch(configRepositoryProvider),
  );
  ref.onDispose(tracker.dispose);
  return tracker;
});

/// 自动换线提示（SET-12）：由播放器外层监听并显示顶部浮层消息。
final lineSwitchNoticeProvider = StateProvider<String?>((ref) => null);

/// 播放器内手动换线（SET-12 重做）：与自动换线共用同一条执行链路。
final manualLineSwitchProvider =
    Provider<Future<void> Function(PlaybackSession, int)>((ref) {
  return (session, sourceIndex) =>
      _manualSwitchToLine(ref, session, sourceIndex);
});

/// 早期错误自动换线控制器（SET-12）。
final autoLineSwitchProvider = Provider<AutoLineSwitchController>((ref) {
  final controller = AutoLineSwitchController(
    engine: ref.watch(playerEngineProvider),
    canSwitch: (epoch) {
      if (epoch != _playbackSessionEpoch) return false;
      if (ref.read(settingsPageOpenProvider)) return false;
      if (ref.read(playerRefreshBusyProvider) ||
          ref.read(playbackSourceChangeProvider) != null) {
        return false;
      }
      final session = ref.read(activePlaybackSessionProvider);
      final spec = ref.read(activePlaySpecProvider);
      return session != null &&
          !session.switching &&
          spec != null &&
          !spec.isLive;
    },
    onCandidate: (candidate, position, epoch) =>
        _autoSwitchToLine(ref, candidate, position, epoch),
    onNotice: (message) =>
        ref.read(lineSwitchNoticeProvider.notifier).state = message,
    onBusyChanged: (busy) =>
        ref.read(playerAutoSwitchBusyProvider.notifier).state = busy,
    isEnabled: () =>
        ref.read(settingsRepositoryProvider).playerSettings.autoLineSwitch,
  );
  ref.onDispose(controller.dispose);
  return controller;
});

/// 同步响应式 VodConfig 状态 Notifier
class VodConfigNotifier extends StateNotifier<VodConfig> {
  final ConfigRepository _repo;
  StreamSubscription? _sub;

  VodConfigNotifier(this._repo) : super(_repo.currentVodConfig) {
    _sub = _repo.vodConfigStream.listen((cfg) {
      state = cfg;
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

final vodConfigProvider =
    StateNotifierProvider<VodConfigNotifier, VodConfig>((ref) {
  final repo = ref.watch(configRepositoryProvider);
  return VodConfigNotifier(repo);
});

/// 同步响应式 Site 状态 Notifier
class CurrentSiteNotifier extends StateNotifier<Site?> {
  final ConfigRepository _repo;
  StreamSubscription? _sub;

  CurrentSiteNotifier(this._repo) : super(_repo.selectedSite) {
    _sub = _repo.siteStream.listen((site) {
      state = site;
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

final currentSiteProvider =
    StateNotifierProvider<CurrentSiteNotifier, Site?>((ref) {
  final repo = ref.watch(configRepositoryProvider);
  return CurrentSiteNotifier(repo);
});

/// 同步响应式 History 状态 Notifier
class HistoryNotifier extends StateNotifier<List<HistoryRecord>> {
  final ConfigRepository _repo;
  StreamSubscription? _sub;

  HistoryNotifier(this._repo) : super(_repo.historyRecords) {
    _sub = _repo.historyStream.listen((list) {
      state = list;
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

final historyProvider =
    StateNotifierProvider<HistoryNotifier, List<HistoryRecord>>((ref) {
  final repo = ref.watch(configRepositoryProvider);
  return HistoryNotifier(repo);
});

/// 同步响应式 Favorites 状态 Notifier
class FavoritesNotifier extends StateNotifier<List<VodItem>> {
  final ConfigRepository _repo;
  StreamSubscription? _sub;

  FavoritesNotifier(this._repo) : super(_repo.favorites) {
    _sub = _repo.favoritesStream.listen((list) {
      state = list;
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

final favoritesProvider =
    StateNotifierProvider<FavoritesNotifier, List<VodItem>>((ref) {
  final repo = ref.watch(configRepositoryProvider);
  return FavoritesNotifier(repo);
});

/// 同步响应式直播收藏状态（§33）。直播频道与点播影片是两份独立数据，
/// 因此各自一个 Notifier；抽屉「收藏频道」置顶分类（§34）从这里取键。
class LiveFavoritesNotifier extends StateNotifier<List<Live>> {
  final ConfigRepository _repo;
  StreamSubscription? _sub;

  LiveFavoritesNotifier(this._repo) : super(_repo.liveFavorites) {
    _sub = _repo.liveFavoritesStream.listen((list) {
      state = list;
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

final liveFavoritesProvider =
    StateNotifierProvider<LiveFavoritesNotifier, List<Live>>((ref) {
  final repo = ref.watch(configRepositoryProvider);
  return LiveFavoritesNotifier(repo);
});

/// 弹窗探测（§40）：有模态弹窗时窗口仍要能拖动。
final DialogRouteObserver _dialogRouteObserver = DialogRouteObserver();

final activePlaySpecProvider = StateProvider<MediaPlaySpec?>((ref) => null);

/// §16 起播准备态：非空时立刻把播放页亮出来（解析仍在原链路里跑）。
///
/// 只用它决定「播放页是否出现」与「页内骨架/失败面板显示什么」，
/// 不参与会话、换线与历史——那些仍由 `activePlaySpec` / `PlaybackSession` 负责。
final playbackIntentProvider = StateProvider<PlaybackIntent?>((ref) => null);

/// §43 弹幕加载器（全应用一份；换集 / 退出由 [_DanmakuSessionSync] 驱动）。
final danmakuControllerProvider = Provider<DanmakuController>((ref) {
  final controller = DanmakuController(
    api: DanmakuApi(),
    cache: DanmakuCache(p.join(DataDirectoryManager.currentPath, 'danmaku')),
  );
  ref.onDispose(controller.dispose);
  return controller;
});

/// §43 本次播放的弹幕开关覆盖：null = 跟随设置默认值；退出播放页时复位。
final danmakuSessionOverrideProvider = StateProvider<bool?>((ref) => null);

final liveDanmakuClientProvider = Provider<LiveDanmakuClient>((ref) {
  final manager = ref.watch(siteApiProvider).companionManager;
  final client = LiveDanmakuClient(onActivity: manager.notifyActivity);
  ref.onDispose(client.dispose);
  return client;
});

/// §44 共享片段加载 / 提交（全应用一份；换集由 [_SegmentsSessionSync] 驱动）。
final segmentsControllerProvider = Provider<SegmentsController>((ref) {
  final controller = SegmentsController(
    api: SegmentsApi(),
    dataDir: DataDirectoryManager.currentPath,
  );
  ref.onDispose(controller.dispose);
  return controller;
});

/// 最近一次「点选集」的入参，供准备态「重试」复用（只存数据，不存闭包）。
final pendingPlayProvider =
    StateProvider<({VodItem item, EpisodeSelection selection, Site? site})?>(
        (ref) => null);

/// 准备态的作废计数：每次发起/取消都自增，迟到的解析结果直接丢弃。
int _playPreparationEpoch = 0;

/// §16 带准备态的起播：立意图 → 播放页先出现 → 解析 → 成功接管 / 失败留在页内。
///
/// 顶层函数（而非某个 State 的方法）是因为「播放页」与「详情/选集弹窗」分属两个类，
/// 两边都要能触发同一套逻辑。
Future<void> startEpisodePlaybackWithIntent(
  WidgetRef ref,
  VodItem item,
  EpisodeSelection selection, {
  Site? targetSite,
}) async {
  final epoch = ++_playPreparationEpoch;
  _playbackSessionEpoch++;
  ref.read(playbackSourceChangeProvider)?.cancelToken.cancel();
  final episode = selection.episodes[selection.index];
  final intent = PlaybackIntent(
    title: item.name,
    subtitle: '${episode.name} · ${selection.sourceName}',
    cover: item.pic,
  );
  ref.read(pendingPlayProvider.notifier).state =
      (item: item, selection: selection, site: targetSite);
  ref.read(playbackIntentProvider.notifier).state = intent;

  final result = await () async {
    try {
      return await _startEpisodePlayback(
        ref,
        item: item,
        sourceName: selection.sourceName,
        episodes: selection.episodes,
        index: selection.index,
        targetSite: targetSite,
        sources: selection.sources,
        sourceIndex: selection.sourceIndex,
      );
    } catch (error) {
      // 骨架不能永远转：异常也收敛成失败态（可重试）。
      return (error: '播放解析异常：$error', resumeMatch: null);
    }
  }();
  // 期间用户点了「返回」或又发起新一次播放：本次结果作废。
  if (!ref.context.mounted || epoch != _playPreparationEpoch) return;
  if (result.error != null) {
    // 留在播放页：失败态可重试，不再弹回列表。
    ref.read(playbackIntentProvider.notifier).state = intent.copyWith(
      status: PlaybackPrepareStatus.failed,
      error: result.error,
    );
    return;
  }
  // 成功：真实播放规格已就位，撤掉准备态。
  ref.read(playbackIntentProvider.notifier).state = null;
  ref.read(pendingPlayProvider.notifier).state = null;
  _showResumeHint(ref, result.resumeMatch);
}

/// 准备态「重试」：用同一份待播数据再跑一次。
Future<void> retryPlayPreparation(WidgetRef ref) async {
  final pending = ref.read(pendingPlayProvider);
  if (pending == null) return;
  await startEpisodePlaybackWithIntent(ref, pending.item, pending.selection,
      targetSite: pending.site);
}

/// 准备态「返回」：作废在途结果并回到列表。
void cancelPlayPreparation(WidgetRef ref) {
  _playPreparationEpoch++;
  final sourceChange = ref.read(playbackSourceChangeProvider);
  if (sourceChange != null) {
    sourceChange.cancelToken.cancel();
  } else {
    _playbackSessionEpoch++;
  }
  ref.read(pendingPlayProvider.notifier).state = null;
  ref.read(playbackIntentProvider.notifier).state = null;
}

/// 音量落盘防抖（§36）：拖动音量条会连续上报，500ms 内的多次只写最后一次。
Timer? _volumeCommitTimer;
double? _pendingVolumeCommit;

/// 记住用户调好的音量（§36）：写进 player_settings.defaultVolume，全局一个值。
///
/// 静音（0）**不写入** —— 否则「静音一次」会让下次起播的默认音量也变成 0，
/// 用户会以为播放器坏了。静音状态本身不跨会话记忆，符合已批准口径。
void _commitPlaybackVolume(WidgetRef ref, double value) {
  if (value <= 0) return;
  _pendingVolumeCommit = value;
  _volumeCommitTimer?.cancel();
  _volumeCommitTimer = Timer(const Duration(milliseconds: 500), () {
    final target = _pendingVolumeCommit;
    _pendingVolumeCommit = null;
    if (target == null) return;
    final repo = ref.read(settingsRepositoryProvider);
    final current = repo.playerSettings.defaultVolume;
    if ((current - target).abs() < 0.5) return;
    unawaited(repo.updatePlayerSettings(
      repo.playerSettings.copyWith(
        defaultVolume: target.clamp(0.0, 100.0).roundToDouble(),
      ),
    ));
  });
}

/// 静音起播提醒的去重表（§36 / §36-R）：按「影片身份」去重，换片重新提示。
final MutedPlaybackHintRegistry _mutedHintRegistry =
    MutedPlaybackHintRegistry();

/// 静音起播提醒：**每部影片最多一次**（同一部片内切集/暂停继续不重复打扰）。
void _showMutedHintForSpec(WidgetRef ref) {
  final spec = ref.read(playerEngineProvider).currentSpec;
  if (spec == null) return;
  final key = MutedPlaybackHintRegistry.keyFor(
    title: spec.title,
    url: spec.url,
  );
  if (!_mutedHintRegistry.shouldHint(key)) return;
  WidgetsBinding.instance.addPostFrameCallback((_) {
    showAppMessage('当前是静音，点音量按钮即可恢复', type: AppMessageType.info);
  });
}

/// 播放会话（点播剧集上下文，仅内存）：供播放器内「上一集 / 下一集」使用。
///
/// 详情页选集、播放内切集、历史续播都会建立；直播 / 推送直链不建立会话。
class PlaybackSession {
  final VodItem item;
  final String sourceName;
  final List<VodEpisode> episodes;
  final int index;
  final Site? site;

  /// 同一详情页的全部播放线路（SET-12 自动换线候选）。
  final List<PlayFrom> sources;

  /// 当前线路在 [sources] 中的下标。
  final int sourceIndex;

  /// 已尝试过的线路键（`lineSwitchKey`）；每个会话只增不减。
  ///
  /// 语义是「用过」（含当前线路、含手动切换成功的线路），**不是「失败」**；
  /// 只服务自动换线候选过滤，不能拿来判断 UI 是否可点。
  final Set<String> triedLines;

  /// 本会话里**确认失败**的线路键（解析为空 / 启动抛错）；切集时清空。
  ///
  /// 抽屉与线路面板的「不可点」只认这个集合：否则从 A 切到 B 后，
  /// A 因为「已试过」被永久禁用，用户再也换不回来。
  final Set<String> failedLines;

  /// 切换进行中：两个切集按钮一并禁用，防止重复触发。
  final bool switching;

  const PlaybackSession({
    required this.item,
    required this.sourceName,
    required this.episodes,
    required this.index,
    required this.site,
    this.sources = const [],
    this.sourceIndex = 0,
    this.triedLines = const {},
    this.failedLines = const {},
    this.switching = false,
  });

  bool get hasPrev => index > 0;

  bool get hasNext => index < episodes.length - 1;

  PlaybackSession copyWith({
    int? index,
    bool? switching,
    String? sourceName,
    List<VodEpisode>? episodes,
    List<PlayFrom>? sources,
    int? sourceIndex,
    Set<String>? triedLines,
    Set<String>? failedLines,
  }) =>
      PlaybackSession(
        item: item,
        sourceName: sourceName ?? this.sourceName,
        episodes: episodes ?? this.episodes,
        index: index ?? this.index,
        site: site,
        sources: sources ?? this.sources,
        sourceIndex: sourceIndex ?? this.sourceIndex,
        triedLines: triedLines ?? this.triedLines,
        failedLines: failedLines ?? this.failedLines,
        switching: switching ?? this.switching,
      );
}

final activePlaybackSessionProvider =
    StateProvider<PlaybackSession?>((ref) => null);

/// 选集抽屉正在浏览的线路。null 表示跟随实际播放线路；只切目录时不改播放真相。
final episodeBrowseSourceIndexProvider = StateProvider<int?>((ref) => null);

/// §15 详情弹窗「当前集」：仅同站同片且有播放会话时返回快照，否则 `null`。
///
/// 只看会话、不看 `activePlaySpec`：关闭播放器会先清空规格，随后才恢复详情弹窗，
/// 用规格会把「播放中返回选集」这条主路径判成没有当前集。
CurrentEpisode? currentEpisodeForDetail({
  required PlaybackSession? session,
  required String vodId,
  required String? siteKey,
}) {
  if (session == null) return null;
  if (session.item.id != vodId) return null;
  if (session.site?.key != siteKey) return null;
  final index = session.index;
  if (index < 0 || index >= session.episodes.length) return null;
  return CurrentEpisode(
    sourceName: session.sourceName,
    index: index,
    episodeName: session.episodes[index].name,
  );
}

/// 片头 / 片尾偏好（响应式）：播放器按钮回显与设置页共用同一来源。
final playSkipPreferencesProvider = StreamProvider<PlaySkipPreferences>((ref) {
  final repository = ref.watch(settingsRepositoryProvider);
  return repository.playSkipPreferencesStream;
});

/// 播放刷新忙碌态（仅内存）。
///
/// 刷新进行中：刷新按钮与切集按钮一并禁用，避免两条启动链路竞争。
final playerRefreshBusyProvider = StateProvider<bool>((ref) => false);

/// 自动换线忙碌态（仅内存）：换线解析 / 启动期间禁用刷新与切集。
final playerAutoSwitchBusyProvider = StateProvider<bool>((ref) => false);

/// 播放会话变更代际（全局递增）。
///
/// 建立 / 关闭会话与每次发起切集都会递增；切换流程在解析与启动前后校验，
/// 迟到的异步结果在代际不一致时必须作废（不播放、不写历史、不更新 UI）。
int _playbackSessionEpoch = 0;

/// 当前「刷新」的持有者代际：只有持有者可以复位忙碌态（避免旧刷新清掉新刷新的忙碌态）。
int? _refreshOwnerEpoch;

// --- 点播剧集播放管线（详情页选集与播放内切集共用同一链路） ---

/// 配置或站点可独立于播放代际变化；异步结果提交前必须同时核验三者。
bool Function() _playbackRequestStaleGuard(WidgetRef ref) {
  final epoch = _playbackSessionEpoch;
  final repository = ref.read(configRepositoryProvider);
  final config = repository.currentVodConfig;
  final siteKey = repository.selectedSite?.key;
  return () => !ref.context.mounted ||
      epoch != _playbackSessionEpoch ||
      !identical(config, repository.currentVodConfig) ||
      siteKey != repository.selectedSite?.key;
}

/// 统一的播放启动入口（保持既有语义）：
/// - [historyRecordId] 非空时开启进度跟踪（点播）；为空时停止跟踪（直播 / 推送直链不进历史）；
/// - 跟踪必须在 `play()` 之前挂上，以免漏掉起播后的首批位置事件；
/// - [restoreRecordId] 启动失败时把跟踪对象改回仍在其位的那条记录（不写错记录）；
/// - [isStale] 引擎启动窗口内的作废判定：为 true 时不提交播放规格，避免迟到结果
///   把已关闭的播放器重新唤醒（幽灵播放）。
Future<void> _launchPlayback(WidgetRef ref, MediaPlaySpec spec,
    {String? historyRecordId,
    String? restoreRecordId,
    bool Function()? isStale,
    _LiveCatalogPlaybackSnapshot? liveCatalog,
    bool keepSettingsOpen = false}) async {
  bool stale() => !ref.context.mounted || (isStale?.call() ?? false);
  if (stale()) return;
  // invariant: 只有显式选台或同频道事务传入目录归属，独立来源不继承旧频道。
  final catalogSnapshot = liveCatalog ??
      _LiveCatalogPlaybackSnapshot.forChannel(spec, null);
  final tracker = ref.read(playbackHistoryTrackerProvider);
  final engine = ref.read(playerEngineProvider);
  Future<void> discardStaleOpen() async {
    // invariant: 只能清理本次仍持有的打开结果，不能停止后续请求的引擎或历史跟踪。
    if (!identical(engine.currentSpec, spec)) return;
    tracker.track(null, flushPrevious: false);
    await engine.stop();
  }

  if (historyRecordId == null) {
    ref.read(autoLineSwitchProvider).disarm();
  }
  if (historyRecordId != null) {
    tracker.track(historyRecordId);
  } else {
    unawaited(tracker.stop());
  }
  try {
    await engine.play(spec);
  } catch (_) {
    if (stale()) {
      await discardStaleOpen();
      rethrow;
    }
    // 启动失败：跟踪对象改回原记录（flushPrevious: false 避免把原集位置写进目标集记录）
    tracker.track(restoreRecordId, flushPrevious: false);
    rethrow;
  }
  if (stale()) {
    await discardStaleOpen();
    return;
  }
  final committed = catalogSnapshot.rebase(spec, ref.read(liveRuntimeProvider));
  ref.read(liveRuntimeProvider.notifier).state = committed.runtime;
  ref.read(activePlaySpecProvider.notifier).state = committed.spec;
  // 起播时收起设置中心，避免视频在隐藏状态下播放
  if (!keepSettingsOpen) {
    ref.read(settingsPageOpenProvider.notifier).state = false;
  }
}

// --- ⑤ 直播播放（入口直连 / 切台 / 抽屉与管理弹窗共用） ---

/// 直播频道收藏的两处入口（播放器抽屉 / 主视图频道弹窗）共用同一套回调，
/// 避免各写一份失败处理。落盘失败会提示并 rethrow，弹窗据此回退星标。
class LiveFavoriteActions {
  final Set<String> keys;
  final Future<void> Function(Live) toggle;

  const LiveFavoriteActions({required this.keys, required this.toggle});
}

LiveFavoriteActions _liveFavoriteActions(WidgetRef ref) {
  final repo = ref.read(configRepositoryProvider);
  return LiveFavoriteActions(
    keys: repo.liveFavorites.map((e) => e.key).toSet(),
    toggle: (channel) async {
      try {
        await repo.toggleLiveFavorite(channel);
      } on DataRestorePendingRestartException catch (error) {
        showAppMessage(error.message, type: AppMessageType.error);
        rethrow;
      } catch (_) {
        showAppMessage('收藏保存失败，请稍后重试', type: AppMessageType.error);
        rethrow;
      }
    },
  );
}

/// 起播指定直播频道：更新运行态（抽屉 / 切台的单一数据源）、记录启动入口与
/// 「上次频道」（以用户选择为准——失败也保留，便于下次原样重试）。
/// 返回是否成功起播；失败给统一提示而不抛出（直播失败可直接换台重试）。
Future<bool> _startLiveChannel(WidgetRef ref, List<Live> channels, int index,
    {bool Function()? isStale, bool keepSettingsOpen = false,
    int lineIndex = 0}) async {
  if (index < 0 || index >= channels.length ||
      !ref.context.mounted || (isStale?.call() ?? false)) {
    return false;
  }
  final sessionEpoch = ++_playbackSessionEpoch;
  _playPreparationEpoch++;
  ref.read(playbackSourceChangeProvider)?.cancelToken.cancel();
  ref.read(pendingPlayProvider.notifier).state = null;
  ref.read(playbackIntentProvider.notifier).state = null;
  final live = channels[index];
  final serial = ++_liveLaunchSerial;
  bool stale() => !ref.context.mounted ||
      sessionEpoch != _playbackSessionEpoch ||
      serial != _liveLaunchSerial || (isStale?.call() ?? false);
  ref.read(livePlaybackProbingProvider.notifier).state = false;
  final committed = ref.read(liveRuntimeProvider)?.committedPlayback;
  ref.read(liveRuntimeProvider.notifier).state = LivePlaybackRuntime(
    channels: List.unmodifiable(channels),
    index: index,
    committedPlayback: committed != null &&
            identical(committed.spec, ref.read(activePlaySpecProvider))
        ? committed
        : null,
  );
  unawaited(
      ref.read(settingsRepositoryProvider).recordLastEntry(StartupEntry.live));
  unawaited(ref.read(liveRepositoryProvider).saveLastChannelKey(liveChannelBookmark(live)));
  try {
    final spec = await _resolveLivePlaySpec(ref, live, serial, lineIndex);
    if (spec == null || stale()) return false;
    await _launchPlayback(ref, spec,
        isStale: stale,
        liveCatalog: _LiveCatalogPlaybackSnapshot.forChannel(spec, live),
        keepSettingsOpen: keepSettingsOpen);
    return !stale();
  } catch (_) {
    if (stale()) return false;
    showAppMessage('直播播放失败，请检查地址或尝试其他频道', type: AppMessageType.error);
    return false;
  }
}

/// ⑤-3 切台：相对位移循环选择（← / → 与抽屉共用），成功后给轻提示。
Future<void> _switchLiveChannel(WidgetRef ref, int delta) async {
  if (!ref.context.mounted) return;
  final runtime = ref.read(liveRuntimeProvider);
  final playingIndex =
      _livePlayingIndex(ref.read(activePlaySpecProvider), runtime);
  if (runtime == null || playingIndex < 0 || delta == 0) return;
  final next = (playingIndex + delta) % runtime.channels.length;
  final name = runtime.channels[next].name;
  final started = await _startLiveChannel(ref, runtime.channels, next);
  if (started) {
    showAppMessage('已切换至 $name', type: AppMessageType.info);
  }
}

/// 频道 → 播放参数：按需先只读清单识别播放方式（见 [shouldProbeLiveChannel]）。
/// 识别期间又换了台时返回 null（旧结果作废）。
Future<MediaPlaySpec?> _resolveLivePlaySpec(
  WidgetRef ref,
  Live live,
  int serial,
  int lineIndex,
) async {
  final url = livePlaySpec(live, lineIndex: lineIndex).url;
  final choice = ref.read(livePlaybackChoicesProvider)[url];
  final settings = ref.read(settingsRepositoryProvider).playerSettings;
  final probe = shouldProbeLiveChannel(
        live: live.copyWith(url: url),
        choice: choice,
        isManualChannel: live.groupName == LiveRepository.manualSourceName,
        autoDetect: settings.autoDetectLiveDirectMode,
      ) &&
      (choice == LivePlaybackChoice.auto ||
          !_liveProbeFailedUrls.contains(url));
  if (!probe) return livePlaySpec(live, choice: choice, lineIndex: lineIndex);
  final probing = ref.read(livePlaybackProbingProvider.notifier);
  probing.state = true;
  try {
    final result = await sharedHlsPlaylistProbe.probe(
      url,
      headers: withBrowserHeaderFallbacks(
        live.headers.isEmpty ? null : live.headers,
        url,
        enabled: settings.browserHeaders,
      ),
    );
    if (serial != _liveLaunchSerial) return null;
    if (result.failed) {
      _liveProbeFailedUrls.add(url);
    } else {
      _liveProbeFailedUrls.remove(url);
    }
    return livePlaySpec(live, choice: choice, probe: result, lineIndex: lineIndex);
  } finally {
    if (serial == _liveLaunchSerial) probing.state = false;
  }
}

/// 管理弹窗选台回调：优先在当前列表定位；新频道（刚导入）并入列表后播放。
/// 直链弹窗刚给出的播放方式覆盖列表里的旧条目和菜单里的本次选择。
Future<void> _playLiveFromDialog(WidgetRef ref, Live live) async {
  final runtime = ref.read(liveRuntimeProvider);
  final channels = [...?runtime?.channels];
  if (live.playbackMode != null) {
    final choices = ref.read(livePlaybackChoicesProvider.notifier);
    if (choices.state.containsKey(live.url)) {
      choices.state = {...choices.state}..remove(live.url);
    }
  }
  final index = channels.indexWhere((channel) => channel.key == live.key);
  if (index >= 0) {
    channels[index] = live;
    await _startLiveChannel(ref, channels, index);
    return;
  }
  channels.add(live);
  await _startLiveChannel(ref, channels, channels.length - 1);
}

/// ⑤-3 抽屉「管理频道」入口：在播放器上直接打开管理弹窗（不打断播放）。
Future<void> _showLiveManagerDialog(BuildContext context, WidgetRef ref) async {
  final repo = ref.read(configRepositoryProvider);
  final sourceUrl = repo.currentWindowConfig.lastConfigUrl;
  await showDialog<void>(
    context: context,
    builder: (_) => Consumer(
      builder: (_, dialogRef, __) {
        final fav = _liveFavoriteActions(dialogRef);
        return LiveChannelsDialog(
          lives: dialogRef.watch(vodConfigProvider).lives,
          repository: dialogRef.watch(liveRepositoryProvider),
          epgRepository: dialogRef.watch(epgRepositoryProvider),
          baseUri: sourceUrl == null ? null : Uri.tryParse(sourceUrl),
          favoritedKeys: fav.keys,
          onToggleFavorite: fav.toggle,
          // 「播放直链」的自动识别开关 / 浏览器头回退跟随设置（D2）
          autoDetectDirectMode: dialogRef
              .read(settingsRepositoryProvider)
              .playerSettings
              .autoDetectLiveDirectMode,
          browserHeaderFallbacks: dialogRef
              .read(settingsRepositoryProvider)
              .playerSettings
              .browserHeaders,
          onPlayLive: (live) => unawaited(_playLiveFromDialog(ref, live)),
        );
      },
    ),
  );
}

/// 解析指定集数的播放地址（失败或地址为空返回 null，报错口径与既有选集一致）。
Future<MediaPlaySpec?> _resolveEpisodeSpec(
  WidgetRef ref, {
  required Site? site,
  required String sourceName,
  required String episodeUrl,
  Duration? timeout,
}) async {
  _lastPlayError = null;
  try {
    final future = ref.read(siteApiProvider).resolvePlayback(
          site,
          id: episodeUrl,
          flag: sourceName,
          preferredQualityName:
              ref.read(playbackQualityPreferencesProvider)[site?.key],
          parses: ref.read(configRepositoryProvider).currentVodConfig.parses,
          parseEngine: ref.read(parseEngineProvider),
        );
    final resolved =
        timeout == null ? await future : await future.timeout(timeout);
    if (resolved.url.isEmpty) return null;
    return resolved;
  } catch (e) {
    // 记住原因：源方「没下发内容」和「解析配置错」是两回事，别让用户去改解析。
    // 给用户看的文案统一由 playResolveFailureText 生成，不直接显示异常原文。
    _lastPlayError = e;
    return null;
  }
}

/// 最近一次解析播放失败的异常（由 [_resolveEpisodeSpec] 写入），交给 [playResolveFailureText] 出文案。
Object? _lastPlayError;

/// 构建目标集播放参数并写入历史记录（切集与详情页选集共用同一字段与记录 ID 规则）。
({MediaPlaySpec spec, String? recordId, HistoryResumeMatch? resumeMatch})
    _prepareEpisodePlayback(
  WidgetRef ref, {
  required VodItem item,
  required String sourceName,
  required List<VodEpisode> episodes,
  required int index,
  required Site? site,
  required MediaPlaySpec resolved,
}) {
  final episode = episodes[index];
  if (resolved.isLive) {
    return (
      spec: resolved.copyWith(
        headers: resolved.headers ?? site?.header,
        title: '${item.name} - ${episode.name} ($sourceName)',
        startPosition: Duration.zero,
      ),
      recordId: null,
      resumeMatch: null,
    );
  }
  final repo = ref.read(configRepositoryProvider);
  final recordId = HistoryRecord.buildId(item.id, episode.name);
  final resumeMatch = repo.findLatestResumeCandidate(
    vodId: item.id,
    vodName: item.name,
    episodeName: episode.name,
    // 单集影片（电影）跨站集名差异大：按最外层片名续播，不再死扣集名。
    singleEpisode: episodes.length == 1 ||
        (episodes.isNotEmpty &&
            episodes.every((e) => isMovieEpisodeName(e.name))),
  );
  final existing = resumeMatch?.record;

  // 片头跳过：起播位置取「续播位置」与「片头」的较大者（片头只提前、不回退）
  final opening = _openingStart(ref, item.id);
  final resume = existing?.resumePosition;
  final startPosition =
      (opening != null && (resume == null || resume < opening))
          ? opening
          : resume;

  final spec = resolved.copyWith(
    headers: resolved.headers ?? site?.header,
    title: '${item.name} - ${episode.name} ($sourceName)',
    startPosition: startPosition ?? Duration.zero,
  );

  // 记录播放历史（沿用已有进度，避免置顶时把断点清零）
  unawaited(
    repo.addHistory(
      HistoryRecord(
        id: recordId,
        vodId: item.id,
        vodName: item.name,
        vodPic: item.pic,
        episodeName: episode.name,
        sourceName: sourceName,
        playUrl: resolved.url,
        episodeUrl: episode.url,
        siteKey: item.siteKey ?? site?.key,
        siteName: item.siteName ?? site?.name,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        positionMs: existing?.positionMs ?? 0,
        durationMs: existing?.durationMs ?? 0,
      ),
    ),
  );
  return (spec: spec, recordId: recordId, resumeMatch: resumeMatch);
}

/// 详情页选集播放：解析 → 记录 → 启动 → 建立播放会话。
///
/// 首轮自动换线（SET-12）：当前线路解析 / 启动失败时，按详情页顺序尝试
/// 同站同片同集的最多 2 条备用线路；全部失败才返回错误。
Future<({String? error, HistoryResumeMatch? resumeMatch})>
    _startEpisodePlayback(
  WidgetRef ref, {
  required VodItem item,
  required String sourceName,
  required List<VodEpisode> episodes,
  required int index,
  Site? targetSite,
  List<PlayFrom>? sources,
  int sourceIndex = 0,
}) async {
  if (index < 0 || index >= episodes.length) {
    return (error: playResolveFailureText(null), resumeMatch: null);
  }
  final site = targetSite ?? ref.read(configRepositoryProvider).selectedSite;
  final allSources = (sources == null || sources.isEmpty)
      ? <PlayFrom>[PlayFrom(name: sourceName, episodes: episodes)]
      : sources;
  final selectedIndex =
      sourceIndex >= 0 && sourceIndex < allSources.length ? sourceIndex : 0;
  final currentSource = allSources[selectedIndex];
  final currentEpisode = episodes[index];
  final tried = <String>{lineSwitchKey(selectedIndex, currentSource.name)};

  final attempts = <LineCandidate>[
    LineCandidate(
      source: currentSource,
      episode: currentEpisode,
      sourceIndex: selectedIndex,
      episodeIndex: index,
    ),
    ...planLineCandidates(
      sources: allSources,
      currentSourceIndex: selectedIndex,
      episodeName: currentEpisode.name,
      currentEpisodeUrl: currentEpisode.url,
      tried: tried,
    ),
  ];

  final isStale = _playbackRequestStaleGuard(ref);
  final failed = <String>{};
  for (final candidate in attempts) {
    if (isStale()) {
      return (error: null, resumeMatch: null);
    }
    tried.add(candidate.key);
    final resolved = await _resolveEpisodeSpec(
      ref,
      site: site,
      sourceName: candidate.source.name,
      episodeUrl: candidate.episode.url,
      timeout: attempts.length > 1 ? const Duration(seconds: 20) : null,
    );
    if (isStale()) return (error: null, resumeMatch: null);
    if (resolved == null) {
      failed.add(candidate.key);
      continue;
    }

    final prepared = _prepareEpisodePlayback(
      ref,
      item: item,
      sourceName: candidate.source.name,
      episodes: candidate.source.episodes,
      index: candidate.episodeIndex,
      site: site,
      resolved: resolved,
    );
    try {
      await _launchPlayback(
        ref,
        prepared.spec,
        historyRecordId: prepared.recordId,
        isStale: isStale,
      );
    } catch (_) {
      if (isStale()) return (error: null, resumeMatch: null);
      failed.add(candidate.key);
      continue;
    }
    if (isStale()) {
      return (error: null, resumeMatch: null);
    }

    // 建立播放会话（供播放器内切集 / 自动换线）；同时作废在途的旧切换结果
    _playbackSessionEpoch++;
    final session = PlaybackSession(
      item: item,
      sourceName: candidate.source.name,
      episodes: candidate.source.episodes,
      index: candidate.episodeIndex,
      site: site,
      sources: allSources,
      sourceIndex: candidate.sourceIndex,
      triedLines: Set.unmodifiable(tried),
      failedLines: Set.unmodifiable(failed),
    );
    ref.read(activePlaybackSessionProvider.notifier).state = session;
    ref.read(episodeBrowseSourceIndexProvider.notifier).state = null;
    if (!prepared.spec.isLive) {
      ref.read(autoLineSwitchProvider).arm(
            sources: allSources,
            currentSourceIndex: candidate.sourceIndex,
            currentSourceName: candidate.source.name,
            episodeName: candidate.episode.name,
            currentEpisodeUrl: candidate.episode.url,
            tried: tried,
            epoch: _playbackSessionEpoch,
            startPosition: prepared.spec.startPosition ?? Duration.zero,
          );
    }
    if (tried.length > 1) {
      final start = prepared.spec.startPosition ?? Duration.zero;
      ref.read(lineSwitchNoticeProvider.notifier).state =
          '已切换到线路「${candidate.source.name}」'
          '${start > Duration.zero ? '，从 ${_formatPlaybackPosition(start)} 继续播放' : ''}';
    }
    return (error: null, resumeMatch: prepared.resumeMatch);
  }

  return (
    error:
        playResolveFailureText(_lastPlayError, allLines: attempts.length > 1),
    resumeMatch: null,
  );
}

String _formatPlaybackPosition(Duration position) {
  final totalSeconds = position.inSeconds;
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  String two(int value) => value.toString().padLeft(2, '0');
  return hours > 0
      ? '$hours:${two(minutes)}:${two(seconds)}'
      : '$minutes:${two(seconds)}';
}

/// 跨站续播提示（SET-11）：只在非精确 ID 命中时出现，并提供「从头播放」逃生口。
void _showResumeHint(WidgetRef ref, HistoryResumeMatch? match) {
  if (match == null || match.level == HistoryMatchLevel.exact) return;
  final resume = match.record.resumePosition;
  if (resume == null) return;
  final source = match.record.siteName?.trim().isNotEmpty == true
      ? match.record.siteName!.trim()
      : (match.record.sourceName.trim().isNotEmpty
          ? match.record.sourceName.trim()
          : '其他站点');
  showAppMessage(
    '已从「$source」的观看进度续播（${_formatPlaybackPosition(resume)}）',
    type: AppMessageType.info,
    action: AppMessageAction(
      label: '从头播放',
      onPressed: () => unawaited(_restartCurrentFromStart(ref)),
    ),
  );
}

/// 把当前记录进度清零并从 0 继续播放（只影响当前记录，不删除其他站点记录）。
Future<void> _restartCurrentFromStart(WidgetRef ref) async {
  final tracker = ref.read(playbackHistoryTrackerProvider);
  final engine = ref.read(playerEngineProvider);
  final recordId = tracker.activeRecordId;
  try {
    await engine.seek(Duration.zero);
    await engine.resume();
    if (recordId == null) return;
    tracker.track(recordId, flushPrevious: false);
    unawaited(ref.read(configRepositoryProvider).updateHistoryProgress(
          recordId,
          positionMs: 0,
          durationMs: engine.duration.inMilliseconds,
        ));
  } catch (_) {
    // 重播失败不影响当前播放；用户可再次点击。
  }
}

/// 记录 / 清除「线路确认失败」标记：只影响抽屉与线路面板的可点态，
/// 不参与自动换线的候选过滤（那套仍用 `triedLines`）。
void _markLineFailed(Ref ref, String key, {bool failed = true}) {
  final session = ref.read(activePlaybackSessionProvider);
  if (session == null) return;
  final next = {...session.failedLines};
  final changed = failed ? next.add(key) : next.remove(key);
  if (!changed) return;
  ref.read(activePlaybackSessionProvider.notifier).state =
      session.copyWith(failedLines: Set.unmodifiable(next));
}

/// 选集解析/启动失败时旧媒体仍在播放：只恢复会话闸门。
/// 原自动换线控制器没有被拆除，起播窗口与已尝试线路均保持原值。
void _restoreEpisodeSwitchSession(WidgetRef ref, PlaybackSession session) {
  ref.read(activePlaybackSessionProvider.notifier).state =
      session.copyWith(switching: false);
  ref.read(autoLineSwitchProvider).resumePendingAttempt();
}

/// 自动换线实际执行：解析候选线路 → 启动 → 保留位置与历史记录 → 更新会话。
///
/// 返回 true 表示已成功切换；false 表示该候选不可用 / 已作废。
Future<bool> _autoSwitchToLine(
  Ref ref,
  LineCandidate candidate,
  Duration position,
  int epoch,
) async {
  if (epoch != _playbackSessionEpoch) return false;
  final session = ref.read(activePlaybackSessionProvider);
  if (session == null ||
      session.switching ||
      ref.read(playerRefreshBusyProvider)) {
    return false;
  }
  final tracker = ref.read(playbackHistoryTrackerProvider);
  final engine = ref.read(playerEngineProvider);
  final recordId = tracker.activeRecordId;

  try {
    final resolved = await ref
        .read(siteApiProvider)
        .resolvePlayback(
          session.site,
          id: candidate.episode.url,
          flag: candidate.source.name,
          preferredQualityName:
              ref.read(playbackQualityPreferencesProvider)[session.site?.key],
          parses: ref.read(configRepositoryProvider).currentVodConfig.parses,
          parseEngine: ref.read(parseEngineProvider),
        )
        .timeout(const Duration(seconds: 20));
    if (resolved.url.isEmpty) {
      _markLineFailed(ref, candidate.key);
      return false;
    }
    if (epoch != _playbackSessionEpoch) return false;

    final spec = resolved.copyWith(
      headers: resolved.headers ?? session.site?.header,
      title:
          '${session.item.name} - ${candidate.episode.name} (${candidate.source.name})',
      startPosition: position > Duration.zero ? position : null,
    );

    if (recordId != null) {
      tracker.track(recordId);
    } else {
      unawaited(tracker.stop());
    }
    try {
      await engine.play(spec);
    } catch (_) {
      tracker.track(recordId, flushPrevious: false);
      _markLineFailed(ref, candidate.key);
      return false;
    }
    if (epoch != _playbackSessionEpoch) {
      if (ref.read(activePlaySpecProvider) == null) {
        await engine.stop();
        tracker.track(null, flushPrevious: false);
      }
      return false;
    }
    ref.read(activePlaySpecProvider.notifier).state = spec;
    if (!ref.read(settingsPageOpenProvider)) {
      ref.read(settingsPageOpenProvider.notifier).state = false;
    }

    // 恢复跟踪：以切换前位置为基线 / 下限，避免 seek 过渡期把断点改小。
    if (recordId != null) {
      tracker.track(
        recordId,
        flushPrevious: false,
        baseline: position,
        floor: position > Duration.zero ? position : null,
      );
      unawaited(ref.read(configRepositoryProvider).updateHistorySource(
            recordId,
            sourceName: candidate.source.name,
            playUrl: resolved.url,
            episodeUrl: candidate.episode.url,
            siteKey: session.item.siteKey ?? session.site?.key,
            siteName: session.item.siteName ?? session.site?.name,
          ));
    }

    final current = ref.read(activePlaybackSessionProvider);
    if (current != null && epoch == _playbackSessionEpoch) {
      ref.read(activePlaybackSessionProvider.notifier).state = current.copyWith(
        sourceName: candidate.source.name,
        sourceIndex: candidate.sourceIndex,
        episodes: candidate.source.episodes,
        index: candidate.episodeIndex,
        triedLines: {...current.triedLines, candidate.key},
        // 切换成功：该线路不再算失败（失败可能只是暂时性）。
        failedLines: {
          for (final key in current.failedLines)
            if (key != candidate.key) key,
        },
      );
    }
    ref.read(episodeBrowseSourceIndexProvider.notifier).state = null;
    ref.read(lineSwitchNoticeProvider.notifier).state =
        '已切换到线路「${candidate.source.name}」'
        '${position > Duration.zero ? '，从 ${_formatPlaybackPosition(position)} 继续播放' : ''}';
    return true;
  } catch (_) {
    return false;
  }
}

/// 播放内切集（上一集 / 下一集）：与详情页选集共用解析与记录链路。
///
/// 守卫：无会话 / 切换中 / 越界 / 原地切换 → 无任何副作用直接返回。
/// 迟到结果在会话已关闭或被替换时作废（不播放、不写历史、不更新 UI）。
/// 返回 null 表示成功或无事发生；否则为用户可展示的错误文案。
Future<({String? error, HistoryResumeMatch? resumeMatch})> _switchEpisode(
    WidgetRef ref, int targetIndex,
    {int? sourceIndex}) async {
  if (ref.read(playbackSourceChangeProvider) != null ||
      ref.read(playerRefreshBusyProvider) ||
      ref.read(playerAutoSwitchBusyProvider)) {
    return (error: null, resumeMatch: null); // 刷新 / 换线进行中：互斥
  }
  final session = ref.read(activePlaybackSessionProvider);
  if (session == null || session.switching) {
    return (error: null, resumeMatch: null);
  }
  final allSources = session.sources.isEmpty
      ? <PlayFrom>[
          PlayFrom(name: session.sourceName, episodes: session.episodes),
        ]
      : session.sources;
  final targetSourceIndex = sourceIndex ?? session.sourceIndex;
  if (targetSourceIndex < 0 || targetSourceIndex >= allSources.length) {
    return (error: null, resumeMatch: null);
  }
  final targetSource = allSources[targetSourceIndex];
  if (targetIndex < 0 || targetIndex >= targetSource.episodes.length) {
    return (error: null, resumeMatch: null);
  }
  if (targetSourceIndex == session.sourceIndex &&
      targetIndex == session.index) {
    return (error: null, resumeMatch: null);
  }

  // 不 disarm 原自动换线：switching 已阻止并发；失败时保留原早期窗口，
  // 成功后下方会以目标集的新状态覆盖 arm。
  final epoch = ++_playbackSessionEpoch;
  ref.read(autoLineSwitchProvider).rebindEpoch(epoch);
  ref.read(activePlaybackSessionProvider.notifier).state =
      session.copyWith(switching: true);

  final resolved = await _resolveEpisodeSpec(
    ref,
    site: session.site,
    sourceName: targetSource.name,
    episodeUrl: targetSource.episodes[targetIndex].url,
  );

  // 会话已关闭 / 被替换 / 有更新操作：迟到结果作废
  if (epoch != _playbackSessionEpoch) {
    return (error: null, resumeMatch: null);
  }
  final current = ref.read(activePlaybackSessionProvider);
  if (current == null) return (error: null, resumeMatch: null);
  if (resolved == null) {
    _restoreEpisodeSwitchSession(ref, current);
    return (
      error: playResolveFailureText(_lastPlayError),
      resumeMatch: null,
    );
  }

  // 切换前快照：启动失败时用于把历史与跟踪对象恢复到「切换前」状态。
  final repo = ref.read(configRepositoryProvider);
  final previousRecordId =
      ref.read(playbackHistoryTrackerProvider).activeRecordId ??
      ref.read(_sourceRecoverySnapshotProvider)?.recordId;
  final previousRecord = previousRecordId == null
      ? null
      : repo.findHistoryById(previousRecordId);

  final prepared = _prepareEpisodePlayback(
    ref,
    item: current.item,
    sourceName: targetSource.name,
    episodes: targetSource.episodes,
    index: targetIndex,
    site: current.site,
    resolved: resolved,
  );

  // 历史回滚：恢复切换前快照（同源去重会顺带移除目标集记录）。
  Future<void> restoreHistory() async {
    if (previousRecord == null) return;
    try {
      await repo.addHistory(previousRecord);
    } catch (_) {
      // 历史回滚失败不应掩盖失败提示 / 影响返回主视图
    }
  }

  try {
    await _launchPlayback(
      ref,
      prepared.spec,
      historyRecordId: prepared.recordId,
      restoreRecordId: previousRecordId,
      isStale: () => epoch != _playbackSessionEpoch,
    );
  } catch (_) {
    // 启动失败：保持当前播放与索引，恢复闸门 / 历史 / 跟踪对象（与解析失败同口径）。
    if (epoch != _playbackSessionEpoch) {
      // 已作废的启动不放马后炮：不弹提示；仅当没有新播放接管时才回滚历史。
      if (ref.read(activePlaySpecProvider) == null) await restoreHistory();
      return (error: null, resumeMatch: null);
    }
    await restoreHistory();
    final failed = ref.read(activePlaybackSessionProvider);
    if (failed != null) {
      _restoreEpisodeSwitchSession(ref, failed);
    }
    return (error: '播放启动失败，请重试', resumeMatch: null);
  }

  if (epoch != _playbackSessionEpoch) {
    // 引擎启动窗口内返回主视图：目标集记录已在起播前写入（同源去重已删掉原集记录），
    // 需回滚到切换前状态，避免历史出现用户未观看的集数、当前集断点丢失。
    if (ref.read(activePlaySpecProvider) == null) await restoreHistory();
    return (error: null, resumeMatch: null);
  }

  final latest = ref.read(activePlaybackSessionProvider);
  if (latest != null) {
    final resetTried = <String>{
      lineSwitchKey(targetSourceIndex, targetSource.name),
    };
    ref.read(activePlaybackSessionProvider.notifier).state = latest.copyWith(
      sourceName: targetSource.name,
      sourceIndex: targetSourceIndex,
      episodes: targetSource.episodes,
      index: targetIndex,
      switching: false,
      triedLines: resetTried,
      failedLines: const {},
    );
    ref.read(episodeBrowseSourceIndexProvider.notifier).state = null;
    if (!prepared.spec.isLive) {
      ref.read(autoLineSwitchProvider).arm(
            sources: allSources,
            currentSourceIndex: targetSourceIndex,
            currentSourceName: targetSource.name,
            episodeName: targetSource.episodes[targetIndex].name,
            currentEpisodeUrl: targetSource.episodes[targetIndex].url,
            tried: resetTried,
            epoch: _playbackSessionEpoch,
            startPosition: prepared.spec.startPosition ?? Duration.zero,
          );
    }
  }
  return (error: null, resumeMatch: prepared.resumeMatch);
}

// --- 片头 / 片尾跳过 ---

/// 允许设置片头 / 片尾的窗口：min(时长 / 2, 10 分钟)。
Duration _skipSetLimit(Duration duration) {
  final half = Duration(milliseconds: duration.inMilliseconds ~/ 2);
  const tenMinutes = Duration(minutes: 10);
  return half < tenMinutes ? half : tenMinutes;
}

/// 片头 / 片尾校验提示用的时间格式（h:mm:ss / mm:ss）。
String _formatSkipMs(int ms) {
  final d = Duration(milliseconds: ms);
  final hours = d.inHours;
  final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
}

/// 当前影片生效的片头起点（未设置或总开关关闭时为 null）。
Duration? _openingStart(WidgetRef ref, String vodId) {
  final preferences = ref.read(settingsRepositoryProvider).playSkipPreferences;
  if (!preferences.enabled) return null;
  final entry = preferences.entryFor(vodId);
  if (entry == null || entry.openingMs <= 0) return null;
  return Duration(milliseconds: entry.openingMs);
}

/// 由播放会话装配片头 / 片尾视图模型；无会话返回 null（直播 / 推送 / 续播不显示）。
PlayerSkipNav? _buildSkipNav(WidgetRef ref, PlaybackSession? session,
    BuildContext playerContext, PlaySkipPreferences preferences) {
  if (session == null) return null;
  final entry = preferences.entryFor(session.item.id);
  return PlayerSkipNav(
    openingMs: entry?.openingMs ?? 0,
    endingMs: entry?.endingMs ?? 0,
    // 总开关关闭时，「跳过片头」胶囊不应出现（自动跳过已被 _openingStart 关闭）。
    enabled: preferences.enabled,
    onSetOpeningAt: (ms) =>
        unawaited(_editSkipMarker(playerContext, ref, ending: false, atMs: ms)),
    onSetEndingAt: (ms) =>
        unawaited(_editSkipMarker(playerContext, ref, ending: true, atMs: ms)),
    onClearOpening: () => unawaited(
        _editSkipMarker(playerContext, ref, ending: false, clear: true)),
    onClearEnding: () => unawaited(
        _editSkipMarker(playerContext, ref, ending: true, clear: true)),
  );
}

/// 写入片头 / 片尾标记（点击即记，不再弹窗）。
///
/// - [atMs] 为**绝对时间点**毫秒；缺省用当前播放位置；
/// - 片尾由宿主换算为「距片尾偏移」后落盘（沿用 `play_skip_preferences` 口径）；
/// - [clear] 清除该侧标记（保留另一侧，空条目自动移除）；
/// - 范围（min(时长/2, 10 分钟)）与重叠校验保留，反馈走顶部浮层消息。
Future<void> _editSkipMarker(BuildContext context, WidgetRef ref,
    {required bool ending, int? atMs, bool clear = false}) async {
  final session = ref.read(activePlaybackSessionProvider);
  if (session == null || ref.read(activePlaySpecProvider) == null) return;
  // 切换 / 刷新过渡期时长与位置可能仍属上一集：避免据此写入错误时间点
  if (session.switching || ref.read(playerRefreshBusyProvider) ||
      ref.read(playbackSourceChangeProvider) != null) {
    return;
  }
  final label = ending ? '片尾' : '片头';
  final repository = ref.read(settingsRepositoryProvider);
  final preferences = repository.playSkipPreferences;
  final entry = preferences.entryFor(session.item.id);

  // updatedAt 单调递增：系统时钟回拨时不至于让自己刚写的条目成为「最旧」而被淘汰
  final now = DateTime.now().millisecondsSinceEpoch;
  final newest = preferences.items.values
      .fold<int>(0, (acc, item) => item.updatedAt > acc ? item.updatedAt : acc);
  final stamp = now > newest ? now : newest + 1;

  Future<bool> persist(PlaySkipEntry next) async {
    final updated = preferences.upsert(session.item.id, next);
    try {
      await repository.updatePlaySkipPreferences(updated);
      return true;
    } catch (_) {
      if (!context.mounted) return false;
      showAppMessage(
        '$label保存失败，请重试',
        type: AppMessageType.error,
        action: AppMessageAction(
          label: '重试',
          // 用仓库的失败重试（取当前内存快照），避免回放本次的旧快照覆盖后续修改
          onPressed: () => unawaited(repository.retryFailedSaves()),
        ),
      );
      return false;
    }
  }

  if (clear) {
    final currentMs = ending ? (entry?.endingMs ?? 0) : (entry?.openingMs ?? 0);
    if (entry == null || currentMs <= 0) return;
    final next = entry.copyWith(
        openingMs: ending ? null : 0,
        endingMs: ending ? 0 : null,
        updatedAt: stamp);
    if (await persist(next) && context.mounted) {
      showAppMessage('$label已清除', type: AppMessageType.success);
    }
    return;
  }

  final engine = ref.read(playerEngineProvider);
  final duration = engine.duration;
  if (duration <= Duration.zero) {
    showAppMessage('时长未知，暂时无法设置片头 / 片尾', type: AppMessageType.warning);
    return;
  }

  final pointMs = atMs ?? engine.position.inMilliseconds;
  // 片尾存「距片尾偏移」（时长 − 标记点）。
  final valueMs = ending ? duration.inMilliseconds - pointMs : pointMs;
  final limitMs = _skipSetLimit(duration).inMilliseconds;
  if (valueMs <= 0 || valueMs > limitMs) {
    showAppMessage('仅允许在$label附近的 ${_formatSkipMs(limitMs)} 内设置，请先调整播放位置',
        type: AppMessageType.warning);
    return;
  }

  // 重叠校验：片头起点 + 片尾偏移必须小于总时长（留 1s 余量）
  final otherMs =
      entry == null ? 0 : (ending ? entry.openingMs : entry.endingMs);
  if (otherMs > 0 && valueMs + otherMs >= duration.inMilliseconds - 1000) {
    showAppMessage('片头与片尾重叠，请调整后再设置', type: AppMessageType.warning);
    return;
  }

  final next = (entry ?? const PlaySkipEntry()).copyWith(
      openingMs: ending ? null : valueMs,
      endingMs: ending ? valueMs : null,
      updatedAt: stamp);
  if (await persist(next) && context.mounted) {
    showAppMessage('$label已更新', type: AppMessageType.success);
  }
}

/// 播放器切集入口：失败时以顶部浮层消息提示（与详情页选集失败口径一致）。
Future<void> _handleEpisodeSwitch(
    BuildContext context, WidgetRef ref, int targetIndex) async {
  final result = await _switchEpisode(ref, targetIndex);
  if (!context.mounted) return;
  if (result.error != null) {
    showAppMessage(result.error!, type: AppMessageType.error);
    return;
  }
  _showResumeHint(ref, result.resumeMatch);
}

Future<void> _handleEpisodeSwitchOnSource(BuildContext context, WidgetRef ref,
    int sourceIndex, int targetIndex) async {
  final result =
      await _switchEpisode(ref, targetIndex, sourceIndex: sourceIndex);
  if (!context.mounted) return;
  if (result.error != null) {
    showAppMessage(result.error!, type: AppMessageType.error);
    return;
  }
  _showResumeHint(ref, result.resumeMatch);
}

/// 刷新当前播放：可解析场景（点播剧集）重新解析，其余原样重载。
///
/// 保留刷新前位置、不新增历史记录、失败不打断当前播放；
/// 返回 `refreshed` 表示是否真的重载过，`error` 为用户可展示的错误文案。
Future<({String? error, bool refreshed})> _refreshPlayback(
    WidgetRef ref) async {
  final spec = ref.read(activePlaySpecProvider);
  if (spec == null) return (error: null, refreshed: false);
  if (ref.read(playbackSourceChangeProvider) != null ||
      ref.read(playerRefreshBusyProvider) ||
      ref.read(playerAutoSwitchBusyProvider)) {
    return (error: null, refreshed: false);
  }
  // 切集进行中互斥：否则会作废切集代际，使会话卡在 switching=true
  if (ref.read(activePlaybackSessionProvider)?.switching ?? false) {
    return (error: null, refreshed: false);
  }

  final epoch = ++_playbackSessionEpoch; // 作废在途的切集 / 刷新
  final isStale = _playbackRequestStaleGuard(ref);
  final liveCatalog = _LiveCatalogPlaybackSnapshot(
      spec, ref.read(liveRuntimeProvider));
  _refreshOwnerEpoch = epoch;
  ref.read(playerRefreshBusyProvider.notifier).state = true;
  ref.read(autoLineSwitchProvider).disarm();

  var refreshed = false;
  String? error;
  try {
    final tracker = ref.read(playbackHistoryTrackerProvider);
    final engine = ref.read(playerEngineProvider);
    final recovery = ref.read(_sourceRecoverySnapshotProvider);
    final recordId = spec.isLive
        ? null
        : tracker.activeRecordId ?? recovery?.recordId;
    final position = recovery?.position ?? engine.position;

    // 刷新期间不落盘：避免解析 / seek 过渡期的位置事件把断点改小
    tracker.track(null, flushPrevious: false);

    var target = spec;

    final session = ref.read(activePlaybackSessionProvider);
    final resetTried = session == null
        ? const <String>{}
        : <String>{lineSwitchKey(session.sourceIndex, session.sourceName)};
    if (session != null) {
      ref.read(activePlaybackSessionProvider.notifier).state =
          session.copyWith(triedLines: resetTried);
    }
    if (session != null) {
      // 点播剧集：重新解析当前集（与详情页选集 / 切集同一调用）
      final episode = session.episodes[session.index];
      var timedOut = false;
      Object? refreshError;
      MediaPlaySpec? resolved;
      try {
        resolved = await ref
            .read(siteApiProvider)
            .resolvePlayback(
              session.site,
              id: episode.url,
              flag: session.sourceName,
              preferredQualityName: spec.isLive &&
                      spec.qualityIndex >= 0 &&
                      spec.qualityIndex < spec.qualities.length
                  ? spec.qualities[spec.qualityIndex].name
                  : ref.read(playbackQualityPreferencesProvider)[session.site?.key],
              parses:
                  ref.read(configRepositoryProvider).currentVodConfig.parses,
              parseEngine: ref.read(parseEngineProvider),
            )
            .timeout(const Duration(seconds: 20));
        if (resolved.url.isEmpty) resolved = null;
      } on TimeoutException {
        timedOut = true;
      } catch (e) {
        refreshError = e;
        resolved = null;
      }
      if (isStale()) return (error: null, refreshed: false);
      if (resolved == null) {
        error = timedOut
            ? '刷新失败：解析超时，请稍后重试'
            : '刷新失败：${playResolveFailureText(refreshError)}';
      } else {
        target = resolved.copyWith(
          headers: resolved.headers ?? session.site?.header,
          title: spec.title,
          startPosition: resolved.isLive ? Duration.zero : position,
        );
      }
    } else {
      // 直播 / 推送直链 / 历史续播等无剧集上下文：原样重载当前播放参数。
      // 必须带上 mode / modeSource / modeDetail：只复制 isLive 会把直链点播打回直播
      // （刷新后既丢进度条，又回到直播重连语义）。
      target = spec.copyWith(startPosition: position);
    }

    if (error == null && !isStale()) {
      try {
        await _launchPlayback(ref, target,
            isStale: isStale, liveCatalog: liveCatalog);
        refreshed = !isStale();
      } catch (_) {
        if (!isStale()) error = '刷新失败：播放启动失败，请重试';
      }
    }

    // 换源回滚失败时继续隔离位置事件，只有刷新成功才重接保存的历史。
    // 普通刷新仍保留原有失败回退语义，断点使用刷新前位置为下限和基线。
    if (!isStale() &&
        (recovery == null || refreshed) &&
        recordId != null &&
        ref.read(activePlaySpecProvider)?.isLive == false) {
      tracker.track(recordId,
          flushPrevious: false,
          baseline: position,
          floor: position > Duration.zero ? position : null);
      if (error == null && position > Duration.zero) {
        unawaited(ref.read(configRepositoryProvider).updateHistoryProgress(
              recordId,
              positionMs: position.inMilliseconds,
              durationMs: engine.duration.inMilliseconds,
            ));
      }
      if (session != null && ref.read(activePlaySpecProvider) != null) {
        ref.read(autoLineSwitchProvider).arm(
              sources: session.sources,
              currentSourceIndex: session.sourceIndex,
              currentSourceName: session.sourceName,
              episodeName: session.episodes[session.index].name,
              currentEpisodeUrl: session.episodes[session.index].url,
              tried: resetTried,
              epoch: _playbackSessionEpoch,
              startPosition: position,
            );
      }
    }
  } finally {
    // 无论成功 / 失败 / 抛错 / 已被新播放接管，都由本次刷新的持有者复位忙碌态，
    // 避免永久灰显（新刷新会改写持有者，旧的一律不复位）。
    if (_refreshOwnerEpoch == epoch) {
      _refreshOwnerEpoch = null;
      if (ref.context.mounted) {
        ref.read(playerRefreshBusyProvider.notifier).state = false;
      }
    }
  }

  return (error: error, refreshed: refreshed);
}

/// 从头重播当前播放：只移动播放位置并继续播放，不重新解析、不重建播放器。
///
/// 位置归零后由既有 tracker 继续跟踪同一历史记录（不新增记录、不改记录 ID），
/// 并把断点显式清零——同时清掉刷新遗留的位置下限，避免回退事件被拦掉。
/// 返回 null 表示成功或无事发生；否则为用户可展示的错误文案。
Future<String?> _replayFromStart(WidgetRef ref, MpvPlayerEngine engine) async {
  // provider 级复核：组件按钮的 busy 只是构建期快照，切换 / 刷新可能刚刚开始
  if (ref.read(playbackSourceChangeProvider) != null ||
      ref.read(playerRefreshBusyProvider) ||
      (ref.read(activePlaybackSessionProvider)?.switching ?? false)) {
    return null;
  }
  final epoch = _playbackSessionEpoch;
  final tracker = ref.read(playbackHistoryTrackerProvider);
  final recordId = tracker.activeRecordId;
  try {
    await engine.seek(Duration.zero);
    if (epoch != _playbackSessionEpoch) return null; // 期间已切集 / 开始新播放
    if (recordId != null) {
      // 在 resume 之前清零：清 floor / 基线并显式写 0，
      // 这样即使随后立刻返回主视图，也不会残留旧断点。
      tracker.track(recordId, flushPrevious: false);
      unawaited(ref.read(configRepositoryProvider).updateHistoryProgress(
            recordId,
            positionMs: 0,
            durationMs: engine.duration.inMilliseconds,
          ));
    }
    if (epoch != _playbackSessionEpoch) return null;
    await engine.resume();
  } catch (_) {
    return '重播失败，请稍后再试';
  }
  return null;
}

/// 重播入口：失败时以顶部浮层消息提示（与刷新失败同口径）。
Future<void> _handleReplayRequested(
    BuildContext context, WidgetRef ref, MpvPlayerEngine engine) async {
  final error = await _replayFromStart(ref, engine);
  if (error != null && context.mounted) {
    showAppMessage(error, type: AppMessageType.error);
  }
}

/// 播放器刷新入口：失败或成功均给出明确反馈。
Future<void> _handleRefreshPlayback(BuildContext context, WidgetRef ref) async {
  final result = await _refreshPlayback(ref);
  if (!context.mounted) return;
  final message = result.error ?? (result.refreshed ? '已刷新' : null);
  if (message != null) {
    showAppMessage(
      message,
      type:
          result.error != null ? AppMessageType.error : AppMessageType.success,
    );
  }
}

/// 由播放会话装配切集视图模型；无会话或单集（≤1 集）返回 null（按钮整对隐藏）。
/// [refreshBusy] 为真（刷新进行中）时两个切集按钮一并禁用，避免两条启动链路竞争。
PlayerEpisodeNav? _buildEpisodeNav(
    WidgetRef ref, PlaybackSession? session, BuildContext playerContext,
    {bool refreshBusy = false}) {
  if (session == null || session.episodes.length <= 1) return null;
  return PlayerEpisodeNav(
    canPrev: session.hasPrev && !session.switching && !refreshBusy,
    canNext: session.hasNext && !session.switching && !refreshBusy,
    switching: session.switching,
    onPrevEpisode: () =>
        _handleEpisodeSwitch(playerContext, ref, session.index - 1),
    onNextEpisode: () =>
        _handleEpisodeSwitch(playerContext, ref, session.index + 1),
  );
}

/// §20 播放页右侧选集抽屉：由播放会话装配（集列表 + 线路胶囊）。
///
/// 只在多集会话里出现；线路切换沿用 SET-12 的手动换线（保留当前集与位置），
/// 抽屉不关闭、列表随会话更新。
PlayerEpisodeListNav? _buildEpisodeListNav(
    WidgetRef ref, PlaybackSession? session, BuildContext playerContext,
    {bool busy = false}) {
  if (session == null) return null;
  final sources = session.sources.isEmpty
      ? <PlayFrom>[
          PlayFrom(name: session.sourceName, episodes: session.episodes),
        ]
      : session.sources;
  final hasChoices = session.episodes.length > 1 || sources.length > 1;
  if (!hasChoices) return null;
  final requestedBrowse = ref.watch(episodeBrowseSourceIndexProvider);
  final browseSourceIndex = requestedBrowse != null &&
          requestedBrowse >= 0 &&
          requestedBrowse < sources.length
      ? requestedBrowse
      : session.sourceIndex.clamp(0, sources.length - 1);
  final browseSource = sources[browseSourceIndex];
  final browsingPlayingLine = browseSourceIndex == session.sourceIndex;
  final episodes = <PlayerEpisodeOption>[
    for (var i = 0; i < browseSource.episodes.length; i++)
      PlayerEpisodeOption(
        index: i,
        name: browseSource.episodes[i].name,
        current: browsingPlayingLine && i == session.index,
      ),
  ];
  final lines = <PlayerLineChoice>[
    if (sources.length > 1)
      for (var i = 0; i < sources.length; i++)
        PlayerLineChoice(
          index: i,
          name: sources[i].name,
          current: i == session.sourceIndex,
          browsing: i == browseSourceIndex,
          unavailable:
              session.failedLines.contains(lineSwitchKey(i, sources[i].name)),
        ),
  ];
  return PlayerEpisodeListNav(
    episodes: episodes,
    lines: lines,
    lineName: browseSource.name,
    browsingPlayingLine: browsingPlayingLine,
    switching: session.switching || busy,
    onSelectEpisode: (index) => unawaited(
      browsingPlayingLine
          ? _handleEpisodeSwitch(playerContext, ref, index)
          : _handleEpisodeSwitchOnSource(
              playerContext, ref, browseSourceIndex, index),
    ),
    onSelectLine: (index) =>
        unawaited(ref.read(manualLineSwitchProvider)(session, index)),
  );
}

/// 播放器内线路视图模型（SET-12 重做）：只列「本片这一集确实存在」的线路。
///
/// 当前线路打勾、已失败灰显、缺集线路不出现；只剩当前线路时不显示整个分组。
PlayerLineNav? _buildLineNav(WidgetRef ref, PlaybackSession? session,
    {bool busy = false}) {
  if (session == null || session.sources.length <= 1) return null;
  final episodeName = session.episodes[session.index].name;
  final options = <PlayerLineOption>[];
  for (var i = 0; i < session.sources.length; i++) {
    final source = session.sources[i];
    if (matchEpisodeOnLine(source, episodeName) == null) continue;
    options.add(PlayerLineOption(
      index: i,
      name: source.name,
      current: i == session.sourceIndex,
      unavailable: session.failedLines.contains(lineSwitchKey(i, source.name)),
    ));
  }
  if (options.length <= 1) return null;
  return PlayerLineNav(
    options: options,
    busy: busy || session.switching,
    onSelect: (index) =>
        unawaited(ref.read(manualLineSwitchProvider)(session, index)),
  );
}

/// 播放器内手动换线（SET-12 重做）：与自动换线共用 `_autoSwitchToLine`，
/// 保证位置保持、历史回写、提示口径完全一致。
Future<void> _manualSwitchToLine(
    Ref ref, PlaybackSession session, int sourceIndex) async {
  final current = ref.read(activePlaybackSessionProvider);
  if (current == null) return;
  if (sourceIndex < 0 || sourceIndex >= current.sources.length) return;
  if (sourceIndex == current.sourceIndex) {
    ref.read(episodeBrowseSourceIndexProvider.notifier).state = null;
    return;
  }
  if (ref.read(playbackSourceChangeProvider) != null ||
      ref.read(playerRefreshBusyProvider) ||
      ref.read(playerAutoSwitchBusyProvider) ||
      current.switching) {
    ref.read(lineSwitchNoticeProvider.notifier).state = '正在切换，请稍候…';
    return;
  }
  final target = current.sources[sourceIndex];
  final episodeName = current.episodes[current.index].name;
  final match = matchEpisodeOnLine(target, episodeName);
  if (match == null) {
    // 只切选集目录，不改变实际播放会话、历史或播放代际。
    ref.read(episodeBrowseSourceIndexProvider.notifier).state = sourceIndex;
    ref.read(lineSwitchNoticeProvider.notifier).state =
        '线路「${target.name}」没有「$episodeName」，已显示该线路选集；当前播放未中断';
    return;
  }
  ref.read(episodeBrowseSourceIndexProvider.notifier).state = null;

  // 作废在途的自动换线 / 切集结果，并关闭自动换线（新线路由用户选定）。
  final epoch = ++_playbackSessionEpoch;
  ref.read(autoLineSwitchProvider).disarm();
  final position = ref.read(playerEngineProvider).position;
  final candidate = LineCandidate(
    source: target,
    episode: target.episodes[match.episodeIndex],
    sourceIndex: sourceIndex,
    episodeIndex: match.episodeIndex,
    matchedBy: match.matchedBy,
  );

  ref.read(playerAutoSwitchBusyProvider.notifier).state = true;
  try {
    final switched = await _autoSwitchToLine(ref, candidate, position, epoch);
    if (!switched && epoch == _playbackSessionEpoch) {
      ref.read(lineSwitchNoticeProvider.notifier).state =
          '切换到线路「${target.name}」失败，请稍后重试';
    }
  } finally {
    ref.read(playerAutoSwitchBusyProvider.notifier).state = false;
  }
}

/// 显示配置输入弹窗
void showConfigDialog(BuildContext context, WidgetRef ref) {
  final repo = ref.read(configRepositoryProvider);
  showDialog<void>(
    context: context,
    builder: (_) => ConfigDialog(repository: repo),
  );
}

/// 打开设置中心
void openSettingsPage(WidgetRef ref) {
  ref.read(settingsPageOpenProvider.notifier).state = true;
}

/// 频道抽屉头部「直播源」下拉：只换直播（独立直播源），点播 / 主配置不动。
/// 选项：跟随主配置源 + 带直播的其它配置源 + 直播源历史（按地址去重）。
LiveSourceNav _buildLiveSourceNav(WidgetRef ref, BuildContext context) {
  final history = ref.read(liveRepositoryProvider).sourceHistory;
  final summary = ref.watch(configSourceSummaryProvider);
  final entries = ref.watch(configSourcesProvider).valueOrNull ??
      ref.read(settingsRepositoryProvider).configSources;
  final active = history.active;
  final options = <LiveSourceOption>[
    LiveSourceOption(
      name: '跟随主配置源',
      subtitle: '主配置：${summary.displayName}',
      current: active == null,
    ),
  ];
  final listed = <String>{};
  for (final entry in entries) {
    if (entry.location == summary.location || entry.liveCount <= 0) continue;
    final location = _configSourceLiveLocation(entry);
    if (location == null || !listed.add(location)) continue;
    options.add(LiveSourceOption(
      location: location,
      name: entry.displayName,
      subtitle: _configSourceSubtitle(entry),
      current: active == location,
    ));
  }
  for (final entry in history.entries) {
    if (!listed.add(entry.location)) continue;
    options.add(LiveSourceOption(
      location: entry.location,
      name: entry.displayName,
      subtitle: _liveSourceEntrySubtitle(entry),
      current: active == entry.location,
    ));
  }
  return LiveSourceNav(
    label: history.activeEntry?.displayName ?? '跟随主配置源',
    options: options,
    onSelect: (option) => _selectLiveSource(ref, option),
    onManage: () => unawaited(_showLiveManagerDialog(context, ref)),
  );
}

/// 配置源历史 → 独立直播源地址：本地文件转 file:// URI，远程只收 http(s)。
String? _configSourceLiveLocation(ConfigSourceEntry entry) {
  final location = entry.location.trim();
  if (entry.kind == ConfigSourceKind.file) {
    try {
      return Uri.file(location).toString();
    } catch (_) {
      return null;
    }
  }
  final uri = Uri.tryParse(location);
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
    return null;
  }
  return location;
}

/// 抽屉里切直播源：成功后 sourceChanges → [_LiveSourceWatcher] 重载频道列表；
/// 失败时直播源保持不变。
Future<void> _selectLiveSource(WidgetRef ref, LiveSourceOption option) async {
  final repository = ref.read(liveRepositoryProvider);
  final location = option.location;
  try {
    if (location == null) {
      await repository.clearActiveSource();
      showAppMessage('直播已改用主配置源', type: AppMessageType.success);
      return;
    }
    final used = await repository.useSourceEntry(location);
    showAppMessage('已切换直播源：${used.displayName}（${used.channelCount} 个频道）',
        type: AppMessageType.success);
  } catch (error) {
    final text = error is FormatException
        ? error.message
        : error.toString().replaceFirst('Exception: ', '');
    showAppMessage('切换失败：$text（当前直播源未改变）', type: AppMessageType.error);
  }
}

String _liveSourceEntrySubtitle(LiveSourceEntry entry) {
  final parts = <String>[
    entry.kind == LiveSourceKind.config ? '配置里的直播' : '频道清单',
    if (entry.channelCount > 0) '${entry.channelCount} 个频道',
  ];
  final relative = _relativeConfigSourceTime(entry.lastUsedAt);
  if (relative != null) parts.add(relative);
  return parts.join(' · ');
}

/// 直播页左上角「播放方式」：本次运行内按频道地址记住选择，选完按新方式重播当前频道。
/// 推送的直播流等不在频道列表里的播放不显示。
PlaybackModeNav? _buildPlaybackModeNav(WidgetRef ref) {
  final spec = ref.watch(activePlaySpecProvider);
  final runtime = ref.watch(liveRuntimeProvider);
  if (spec == null || _livePlayingIndex(spec, runtime) < 0) return null;
  final override = ref.watch(livePlaybackChoicesProvider)[spec.url];
  return PlaybackModeNav(
    mode: spec.mode,
    source: spec.modeSource,
    detail: spec.modeDetail,
    checked: checkedLivePlaybackChoice(spec, override: override),
    busy: ref.watch(livePlaybackProbingProvider),
    onSelect: (choice) => unawaited(_applyLivePlaybackChoice(ref, choice)),
  );
}

Future<void> _applyLivePlaybackChoice(
  WidgetRef ref,
  LivePlaybackChoice choice,
) async {
  final spec = ref.read(activePlaySpecProvider);
  final runtime = ref.read(liveRuntimeProvider);
  final index = _livePlayingIndex(spec, runtime);
  if (spec == null || runtime == null || index < 0) return;
  final restartUrl = livePlaySpec(runtime.channels[index],
      lineIndex: spec.qualityIndex).url;
  final choices = ref.read(livePlaybackChoicesProvider.notifier);
  choices.state = {...choices.state, spec.url: choice, restartUrl: choice};
  // 选的方式和正在用的一致时不重播，免得画面中断；「自动识别」总是重新识别。
  final unchanged = (choice == LivePlaybackChoice.live && spec.isLive) ||
      (choice == LivePlaybackChoice.vod && !spec.isLive);
  if (unchanged) return;
  final started = await _startLiveChannel(ref, runtime.channels, index,
      lineIndex: spec.qualityIndex);
  final now = ref.read(activePlaySpecProvider);
  if (!started || now == null) return;
  showAppMessage(now.isLive ? '已按直播播放' : '已按点播播放，可以拖动进度',
      type: AppMessageType.info);
}

/// 正在播的频道在运行态列表里的位置；不在列表里（推送的直播流等）返回 -1。
int _livePlayingIndex(MediaPlaySpec? spec, LivePlaybackRuntime? runtime) {
  if (spec == null || runtime == null) return -1;
  final committed = runtime.committedPlayback;
  if (committed != null) {
    if (!identical(committed.spec, spec)) return -1;
    final reconciled = reconcileLiveAfterConfigSwitch(
        catalog: LiveCatalog(channels: runtime.channels),
        current: committed.channel,
        previousScopeId: null);
    return reconciled.found ? reconciled.index : -1;
  }
  final channels = runtime.channels;
  final index = runtime.index;
  bool matches(Live live) => live.url == spec.url ||
      live.lines.any((line) => line.url == spec.url);
  if (index >= 0 && index < channels.length &&
      (runtime.retainedPlaybackUrl == spec.url || matches(channels[index]))) {
    return index;
  }
  return channels.indexWhere(matches);
}

bool _liveChannelLinesChanged(Live? previous, Live current) =>
    previous == null ||
    previous.url != current.url ||
    !mapEquals(previous.headers, current.headers) ||
    previous.lines.length != current.lines.length ||
    previous.lines.asMap().entries.any((entry) =>
        entry.value.name != current.lines[entry.key].name ||
        entry.value.url != current.lines[entry.key].url);

MediaPlaySpec _withLiveCatalogLines(MediaPlaySpec playing, Live channel) {
  final lines = channel.lines.isEmpty
      ? [LiveLine(name: '线路1', url: channel.url)]
      : channel.lines;
  final qualities = [
    for (final line in lines)
      PlaybackQuality(name: line.name, url: line.url, headers: channel.headers),
  ];
  var selected = qualities.indexWhere((line) => line.url == playing.url);
  if (selected < 0) {
    // invariant: 保留旧流的真实选中项，新目录线路的索引保持不变。
    selected = qualities.length;
    qualities.add(PlaybackQuality(
      name: '当前线路（旧地址）',
      url: playing.url,
      headers: playing.headers ?? const {},
    ));
  }
  final normalized = qualities.length < 2
      ? const <PlaybackQuality>[]
      : qualities;
  if (playing.qualityIndex == selected &&
      playing.qualities.length == normalized.length &&
      normalized.asMap().entries.every((entry) {
        final current = playing.qualities[entry.key];
        final next = entry.value;
        return current.name == next.name &&
            current.url == next.url &&
            mapEquals(current.headers, next.headers) &&
            current.needsParse == next.needsParse;
      })) {
    return playing;
  }
  return playing.copyWith(
    qualities: List<PlaybackQuality>.unmodifiable(normalized),
    qualityIndex: selected,
  );
}

/// 在途播放只可合入其捕获频道的目录变化，不能把独立来源接入电视目录。
class _LiveCatalogPlaybackSnapshot {
  factory _LiveCatalogPlaybackSnapshot(
      MediaPlaySpec? playing, LivePlaybackRuntime? runtime) {
    final index = _livePlayingIndex(playing, runtime);
    return _LiveCatalogPlaybackSnapshot.forChannel(
        playing, index < 0 ? null : runtime!.channels[index]);
  }

  const _LiveCatalogPlaybackSnapshot.forChannel(this.playing, this.anchor);

  final MediaPlaySpec? playing;
  final Live? anchor;

  ({MediaPlaySpec spec, LivePlaybackRuntime? runtime}) rebase(
      MediaPlaySpec target, LivePlaybackRuntime? latest) {
    final previous = playing;
    final originalChannel = anchor;
    if (previous == null || originalChannel == null || latest == null) {
      return (spec: target, runtime: latest);
    }
    if (target.url != previous.url && target.url != originalChannel.url &&
        !originalChannel.lines.any((line) => line.url == target.url)) {
      return (spec: target, runtime: latest);
    }
    final reconciled = reconcileLiveAfterConfigSwitch(
        catalog: LiveCatalog(channels: latest.channels),
        current: originalChannel,
        previousScopeId: null);
    if (!reconciled.found) return (spec: target, runtime: latest);
    final currentIndex = reconciled.index;
    final channel = latest.channels[currentIndex];
    final retainedUrl = channel.url == target.url ||
            channel.lines.any((line) => line.url == target.url)
        ? null
        : target.url;
    final committedSpec = _withLiveCatalogLines(target, channel);
    return (
      spec: committedSpec,
      runtime: latest.index == currentIndex &&
              latest.retainedPlaybackUrl == retainedUrl &&
              identical(latest.committedPlayback?.spec, committedSpec) &&
              identical(latest.committedPlayback?.channel, channel)
          ? latest
          : LivePlaybackRuntime(
              channels: latest.channels,
              index: currentIndex,
              retainedPlaybackUrl: retainedUrl,
              committedPlayback: (spec: committedSpec, channel: channel),
            ),
    );
  }
}

/// 直播页：按直播起播的，或按点播起播的直播频道（地址仍在当前频道列表里）。
bool _isLivePage(MediaPlaySpec? spec, LivePlaybackRuntime? runtime) =>
    spec != null && (spec.isLive || _livePlayingIndex(spec, runtime) >= 0);

String _configSourceKindLabel(ConfigSourceKind? kind) =>
    kind == ConfigSourceKind.file ? '本地文件' : '远程订阅';

String _configSourceSubtitle(ConfigSourceEntry entry) {
  final parts = <String>[
    _configSourceKindLabel(entry.kind),
    '${entry.liveCount} 个直播源',
  ];
  final relative = _relativeConfigSourceTime(entry.lastUsedAt);
  if (relative != null) parts.add(relative);
  return parts.join(' · ');
}

String? _relativeConfigSourceTime(int milliseconds) {
  if (milliseconds <= 0) return null;
  final usedAt = DateTime.fromMillisecondsSinceEpoch(milliseconds);
  final diff = DateTime.now().difference(usedAt);
  if (diff.isNegative || diff.inMinutes < 1) return '刚刚';
  if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
  if (diff.inDays < 1) return '${diff.inHours} 小时前';
  if (diff.inDays < 30) return '${diff.inDays} 天前';
  return '${(diff.inDays / 30).floor()} 个月前';
}

/// 目录操作只归属于当前目录中的频道，游戏直播等独立来源保留直播样式。
bool _isLiveCatalogPlaybackActive(WidgetRef ref) {
  try {
    return _livePlayingIndex(
        ref.read(activePlaySpecProvider), ref.read(liveRuntimeProvider)) >= 0;
  } catch (_) {
    // 播放器页面可能已被销毁，WidgetRef 不再可用。
    return false;
  }
}

/// 独立直播源切换 / 删除后，对账正在播放的直播：当前频道仍在则继续播放并刷新列表，
/// 否则起播新列表第一个频道，新列表为空则停止。不在直播时不做事（下次进入直播会重新加载）。
/// 点播不受影响。
class _LiveSourceWatcher extends ConsumerStatefulWidget {
  const _LiveSourceWatcher();

  @override
  ConsumerState<_LiveSourceWatcher> createState() => _LiveSourceWatcherState();
}

class _LiveSourceWatcherState extends ConsumerState<_LiveSourceWatcher> {
  StreamSubscription<void>? _subscription;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _subscription = ref
        .read(liveRepositoryProvider)
        .sourceChanges
        .listen((_) => unawaited(_reconcile()));
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  bool _stale(int generation, int sessionEpoch) =>
      !mounted || generation != _generation ||
      sessionEpoch != _playbackSessionEpoch || !_isLiveCatalogPlaybackActive(ref);

  Future<void> _reconcile() async {
    final generation = ++_generation;
    if (!_isLiveCatalogPlaybackActive(ref)) return;
    final sessionEpoch = _playbackSessionEpoch;
    final LiveCatalog catalog;
    try {
      final sourceUrl =
          ref.read(configRepositoryProvider).currentWindowConfig.lastConfigUrl;
      catalog = await ref.read(liveRepositoryProvider).load(
            ref.read(vodConfigProvider).lives,
            baseUri: sourceUrl == null ? null : Uri.tryParse(sourceUrl),
          );
    } catch (error) {
      if (!_stale(generation, sessionEpoch)) {
        showAppMessage('直播频道加载失败：${liveErrorMessage(error)}',
            type: AppMessageType.error);
      }
      return;
    }
    if (_stale(generation, sessionEpoch)) return;
    // invariant: 同代际切线可能已提交，目录结果只能合入当前播放的地址。
    final runtime = ref.read(liveRuntimeProvider);
    final playing = ref.read(activePlaySpecProvider);
    final selectedLineName = playing != null && playing.qualityIndex >= 0 &&
            playing.qualityIndex < playing.qualities.length
        ? playing.qualities[playing.qualityIndex].name
        : null;
    final playingIndex = _livePlayingIndex(playing, runtime);
    final current = playingIndex < 0 ? null : runtime!.channels[playingIndex];
    final reconciled = reconcileLiveAfterConfigSwitch(
        catalog: catalog, current: current, previousScopeId: null);
    if (reconciled.found && !reconciled.requiresRestart) {
      final channel = reconciled.channels[reconciled.index];
      // invariant: 重复目录通知不替换播放参数；新菜单参数必须同时更新频道绑定。
      final committedSpec = playing != null &&
              _liveChannelLinesChanged(current, channel)
          ? _withLiveCatalogLines(playing, channel)
          : playing;
      ref.read(liveRuntimeProvider.notifier).state = LivePlaybackRuntime(
        channels: reconciled.channels,
        index: reconciled.index,
        retainedPlaybackUrl: committedSpec?.url,
        committedPlayback: committedSpec == null
            ? null
            : (spec: committedSpec, channel: channel),
      );
      if (!identical(committedSpec, playing)) {
        ref.read(activePlaySpecProvider.notifier).state = committedSpec;
      }
      return;
    }
    if (reconciled.channels.isNotEmpty) {
      final lines = reconciled.channels[reconciled.index].lines;
      final selectedLine = reconciled.found && selectedLineName != null
          ? lines.indexWhere((line) => line.name == selectedLineName)
          : -1;
      final started = await _startLiveChannel(
          ref, reconciled.channels, reconciled.index,
          isStale: () => !mounted || generation != _generation,
          keepSettingsOpen: true,
          lineIndex: selectedLine < 0 ? 0 : selectedLine);
      if (started && !reconciled.found) {
        showAppMessage('直播源已更换，正在播放「${reconciled.channels[reconciled.index].name}」');
      }
      return;
    }
    try {
      await ref.read(playerEngineProvider).stop();
    } catch (_) {
      // 停止失败不影响清空直播态。
    }
    if (_stale(generation, sessionEpoch)) return;
    ref.read(playbackHistoryTrackerProvider).stop();
    ref.read(activePlaySpecProvider.notifier).state = null;
    ref.read(liveRuntimeProvider.notifier).state = null;
    showAppMessage('新的直播源没有可播放的频道，已停止播放', type: AppMessageType.warning);
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// 显示站点切换弹窗
void showSiteSelectorDialog(BuildContext context, WidgetRef ref) {
  final repo = ref.read(configRepositoryProvider);
  final config = repo.currentVodConfig;
  final currentSite = repo.selectedSite;

  if (config.sites.isEmpty) {
    showConfigDialog(context, ref);
    return;
  }

  showDialog<void>(
    context: context,
    builder: (_) => SiteSelectorDialog(
      // 内置虚拟站排首位：选中即首页切到豆瓣热播（§17）
      sites: <Site>[builtinDoubanSite, ...config.sites],
      currentSite: currentSite,
      onSiteSelected: (site) {
        repo.selectSite(site);
      },
    ),
  );
}

/// 配置源设置弹窗：支持 URL 加载、粘贴 JSON/Base64 与导入本地配置文件
class ConfigDialog extends StatefulWidget {
  final ConfigRepository repository;

  /// 本地配置文件选择器（可注入以便测试；缺省弹出系统文件对话框）
  final Future<String?> Function()? pickConfigFile;

  const ConfigDialog(
      {super.key, required this.repository, this.pickConfigFile});

  @override
  State<ConfigDialog> createState() => _ConfigDialogState();
}

class _ConfigDialogState extends State<ConfigDialog> {
  late final TextEditingController _controller;
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: widget.repository.currentWindowConfig.lastConfigUrl ?? '',
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 多仓选择回调（URL / 粘贴 / 本地文件三条路径共用同一选择弹窗）
  Future<int?> _selectDepot(List<DepotEntry> entries) => showDialog<int>(
        context: context,
        barrierDismissible: false,
        builder: (_) => DepotSelectionDialog(entries: entries),
      );

  Future<void> _load() async {
    final input = _controller.text.trim();
    if (input.isEmpty) {
      setState(() => _errorMessage = '请输入配置 URL，或直接粘贴 JSON/Base64 配置内容');
      return;
    }

    await _runLoad(() =>
        widget.repository.loadFromInput(input, selectDepot: _selectDepot));
  }

  /// 导入本地配置文件（TVBox 标准 JSON / Base64、多仓清单、CMS 资源站清单）
  Future<void> _importFromFile() async {
    if (_isLoading) return;
    final picker = widget.pickConfigFile ?? _pickConfigFile;

    String? path;
    try {
      path = await picker();
    } catch (error) {
      if (mounted) setState(() => _errorMessage = _formatError(error));
      return;
    }
    if (path == null || path.isEmpty) return; // 用户取消了文件选择

    final selectedPath = path;
    await _runLoad(() => widget.repository
        .loadFromFile(selectedPath, selectDepot: _selectDepot));
  }

  /// 系统文件选择对话框（配置 / 订阅文件）
  Future<String?> _pickConfigFile() async {
    const typeGroup = XTypeGroup(
      label: '配置文件',
      extensions: ['json', 'txt', 'm3u', 'conf'],
    );
    final file = await openFile(acceptedTypeGroups: [typeGroup]);
    return file?.path;
  }

  /// 统一的加载执行与错误处理：成功后关闭弹窗；取消多仓选择时静默复位
  Future<void> _runLoad(Future<void> Function() task) async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      await task();
      if (mounted) Navigator.of(context).pop();
    } on DepotSelectionCancelled {
      if (!mounted) return;
      setState(() => _isLoading = false);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = _formatError(error);
      });
    }
  }

  String _formatError(Object error) {
    if (error is FormatException) return error.message.toString();
    if (error is FileSystemException) {
      return error.path != null
          ? '${error.message}：${error.path}'
          : error.message;
    }
    return error.toString().replaceFirst('Exception: ', '');
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: context.palette.raised,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.lg)),
      title: Row(
        children: [
          Icon(Icons.settings_outlined,
              color: context.palette.accentInk, size: 20),
          const SizedBox(width: 8),
          Text('配置源设置',
              style: TextStyle(
                  fontSize: AppType.heading,
                  color: context.palette.textTitle,
                  fontWeight: FontWeight.bold)),
        ],
      ),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '输入配置文件地址，粘贴 JSON / Base64 内容，或导入本地文件：',
              style: TextStyle(
                  fontSize: AppType.label, color: context.palette.textBody),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _controller,
              enabled: !_isLoading,
              minLines: 1,
              maxLines: 6,
              style: TextStyle(
                  fontSize: AppType.label, color: context.palette.textMain),
              decoration: InputDecoration(
                hintText: 'https://example.com/tv.json 或粘贴配置内容',
                hintStyle: TextStyle(color: context.palette.textDim),
                filled: true,
                fillColor: context.palette.raised,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadii.sm),
                  borderSide: BorderSide(color: context.palette.borderStrong),
                ),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _isLoading ? null : _importFromFile,
                  icon: const Icon(Icons.folder_open_rounded, size: 16),
                  label: const Text('导入本地文件…',
                      style: TextStyle(fontSize: AppType.label)),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: context.palette.textBody,
                    side: BorderSide(color: context.palette.borderStrong),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppRadii.sm)),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '支持 TVBox 配置 / 多仓清单 / CMS 资源站清单',
                    style: TextStyle(
                        fontSize: AppType.body, color: context.palette.textDim),
                  ),
                ),
              ],
            ),
            if (_errorMessage != null) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: context.palette.accentWash,
                  borderRadius: BorderRadius.circular(AppRadii.sm),
                  border: Border.all(color: context.palette.danger),
                ),
                child: Text(
                  _errorMessage!,
                  style: TextStyle(
                      fontSize: AppType.body,
                      height: 1.4,
                      color: context.palette.danger),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isLoading ? null : () => Navigator.of(context).pop(),
          child: Text('取消', style: TextStyle(color: context.palette.textSub)),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: context.palette.accent,
            // 品牌底上必须显式前景 onPrimary：M3 默认前景是 primary=品牌色，会同色不可见
            foregroundColor: Theme.of(context).colorScheme.onPrimary,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadii.sm)),
          ),
          onPressed: _isLoading ? null : _load,
          child: _isLoading
              ? SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Theme.of(context).colorScheme.onPrimary),
                )
              : const Text('加载配置',
                  style: TextStyle(fontWeight: FontWeight.bold)),
        ),
      ],
    );
  }
}

/// 片尾跳过监听：只在播放器子树内挂载（此时引擎一定已注入）。
///
/// 到达「时长 − 片尾」时调用 SET-17 的切集入口；本集只触发一次，
/// 且要求本集先上报过片尾点之前的位置（视为真正起播）。
class _PlaySkipWatcher extends ConsumerStatefulWidget {
  final MpvPlayerEngine engine;
  final Widget child;

  const _PlaySkipWatcher({required this.engine, required this.child});

  @override
  ConsumerState<_PlaySkipWatcher> createState() => _PlaySkipWatcherState();
}

class _PlaySkipWatcherState extends ConsumerState<_PlaySkipWatcher> {
  StreamSubscription<Duration>? _subscription;

  /// 单订阅流（部分测试替身）已被播放器内部消费时的回退时钟。
  Timer? _timer;
  String? _triggeredFor;
  String? _armedKey;

  @override
  void initState() {
    super.initState();
    try {
      _subscription = widget.engine.positionStream.listen(_onPosition);
    } on StateError {
      // 该引擎的位置流是单订阅且已被播放器消费：退回 500ms 轮询（真机引擎为广播流，走上面分支）。
      _timer = Timer.periodic(const Duration(milliseconds: 500),
          (_) => _onPosition(widget.engine.position));
    }
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    _timer?.cancel();
    super.dispose();
  }

  void _onPosition(Duration position) {
    if (!mounted || ref.read(activePlaySpecProvider)?.isLive == true) return;
    // 设置中心打开时不自动切集：否则会把用户的设置面板强行关掉并丢失未提交输入
    if (ref.read(settingsPageOpenProvider)) return;
    final session = ref.read(activePlaybackSessionProvider);
    if (session == null) return;
    if (session.switching || ref.read(playerRefreshBusyProvider) ||
        ref.read(playbackSourceChangeProvider) != null) {
      return;
    }
    final preferences =
        ref.read(settingsRepositoryProvider).playSkipPreferences;
    if (!preferences.enabled) return;
    final entry = preferences.entryFor(session.item.id);
    if (entry == null || entry.endingMs <= 0) return;
    if (!session.hasNext) return;
    final duration = widget.engine.duration;
    if (duration <= Duration.zero) return;
    final endAt = duration - Duration(milliseconds: entry.endingMs);
    if (endAt <= Duration.zero) return;

    final key = '${session.item.id}#${session.index}';
    if (_triggeredFor != null && _triggeredFor != key) {
      // 新的一集：解除上一次的触发标记
      _triggeredFor = null;
    }
    if (position < endAt) {
      _armedKey = key;
      return;
    }
    if (_armedKey != key) return;
    if (_triggeredFor == key) return;
    _triggeredFor = key;
    unawaited(_handleEpisodeSwitch(context, ref, session.index + 1));
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// 画面比例选择：复用 SET-04 的 `PlayerSettings.scale`（持久化 + 实时重排）。
Future<void> _handleScaleChanged(WidgetRef ref, String scale) async {
  await applyPlayerScale(ref.read(settingsRepositoryProvider), scale);
}

/// 重置播放器数据：当前影片片头 / 片尾 + 播放器设置（含画面比例）+ 即时应用。
Future<void> _handleResetPlayerData(
    WidgetRef ref, MpvPlayerEngine engine) async {
  final session = ref.read(activePlaybackSessionProvider);
  await resetPlayerData(
    settings: ref.read(settingsRepositoryProvider),
    engine: engine,
    vodId: session?.item.id,
  );
}

/// §44 把播放会话同步给共享片段加载器：片名 + 当前集变化 → load；无会话 / 直播 → clear。
class _SegmentsSessionSync extends StatefulWidget {
  const _SegmentsSessionSync({
    required this.session,
    required this.controller,
    required this.child,
  });

  final PlaybackSession? session;
  final SegmentsController controller;
  final Widget child;

  @override
  State<_SegmentsSessionSync> createState() => _SegmentsSessionSyncState();
}

class _SegmentsSessionSyncState extends State<_SegmentsSessionSync> {
  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(_SegmentsSessionSync old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    final session = widget.session;
    if (session == null || session.episodes.isEmpty) {
      widget.controller.clear();
      return;
    }
    final index = session.index.clamp(0, session.episodes.length - 1);
    unawaited(widget.controller.load(
      title: session.item.name,
      episodeName: session.episodes[index].name,
      episodeCount: session.episodes.length,
      // 集名认不出集号时按选集位置兜底（「正片」「彩蛋」这类）
      episodeIndex: index,
    ));
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// §43 把播放会话同步给弹幕加载器：
/// 站点 + 影片 + 当前集变化 → load（同片同集不重复拉；换线不变）；
/// 无会话 / 直播 / 关闭弹幕 → clear（取消在途请求）。
class _DanmakuSessionSync extends StatefulWidget {
  const _DanmakuSessionSync({
    required this.session,
    required this.enabled,
    required this.controller,
    required this.child,
  });

  final PlaybackSession? session;
  final bool enabled;
  final DanmakuController controller;
  final Widget child;

  @override
  State<_DanmakuSessionSync> createState() => _DanmakuSessionSyncState();
}

class _DanmakuSessionSyncState extends State<_DanmakuSessionSync> {
  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(_DanmakuSessionSync old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    final session = widget.session;
    if (!widget.enabled || session == null || session.episodes.isEmpty) {
      if (widget.controller.value.phase != DanmakuLoadPhase.idle) {
        widget.controller.clear();
      }
      return;
    }
    final index = session.index.clamp(0, session.episodes.length - 1);
    // 集号 / 总集数参与本地校验（多集认不出集号不匹配、单集按电影匹配），
    // 站点 + 影片 id 区分播放会话：同名不同片不复用上一部的弹幕
    unawaited(widget.controller.load(
      name: session.item.name,
      episode: session.episodes[index].name,
      episodeIndex: index,
      episodeCount: session.episodes.length,
      yearHint: session.item.year,
      scope: '${session.site?.key ?? ''}|${session.item.id}',
    ));
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// 订阅播放器设置流（流对象仅建立一次），把「画面缩放」模式与
/// 「播放时隐藏标题栏」（§38）实时传给播放器。
class _PlayerPrefsBinding extends StatefulWidget {
  final SettingsRepository repository;
  final Widget Function(
      BuildContext context,
      String scale,
      bool hideWindowTitleBar,
      bool danmakuEnabled,
      DanmakuSettings danmakuSettings,
      bool showMiniProgress,
      double holdRate,
      bool autoHideCursor,
      PlayerShortcutBindings shortcuts) builder;

  const _PlayerPrefsBinding({required this.repository, required this.builder});

  @override
  State<_PlayerPrefsBinding> createState() => _PlayerPrefsBindingState();
}

class _PlayerPrefsBindingState extends State<_PlayerPrefsBinding> {
  late final Stream<PlayerSettings> _stream =
      widget.repository.playerSettingsStream;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<PlayerSettings>(
      stream: _stream,
      initialData: widget.repository.playerSettings,
      builder: (context, snapshot) {
        final settings = snapshot.data ?? PlayerSettings.defaults;
        return widget.builder(
            context,
            settings.scale,
            settings.hideWindowTitleBar,
            settings.danmakuEnabled,
            settings.danmaku,
            settings.showMiniProgress,
            settings.holdRate,
            settings.autoHideCursor,
            settings.shortcuts);
      },
    );
  }
}

/// 更新对话框的宿主：把 Riverpod 状态接到纯展示的 [UpdateDialog] 上。
class _UpdateDialogHost extends ConsumerWidget {
  const _UpdateDialogHost();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(updateControllerProvider);
    final prefs = ref.watch(updatePreferencesProvider);
    final controller = ref.read(updateControllerProvider.notifier);
    final tag = state.result?.manifest?.tag;
    return UpdateDialog(
      state: state,
      currentVersion: appVersionLabel ?? '未知版本',
      isPortable: controller.isPortable,
      skipped: tag != null && prefs.isSkipped(tag),
      onDownload: () => unawaited(controller.downloadAndInstall()),
      onCancelDownload: controller.cancelDownload,
      onInstall: () => unawaited(controller.install()),
      onSkip: () => unawaited(controller.skipCurrentVersion()),
      onClearSkip: () => unawaited(controller.clearSkipped()),
      onRetry: () => unawaited(controller.check()),
      onClose: () => Navigator.of(context).pop(),
      onOpenReleasePage: () => unawaited(controller.openReleasePage()),
      onOpenFolder: () => unawaited(controller.openDownloadFolder()),
    );
  }
}

/// 关于页的更新行：把状态与动作接到纯展示的 [AboutUpdateSection]。
class AboutUpdateSectionHost extends ConsumerWidget {
  const AboutUpdateSectionHost({super.key, this.between});

  /// 插在「当前版本」与「自动检查」之间（关于页的构建信息）
  final Widget? between;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(updatePreferencesProvider);
    final state = ref.watch(updateControllerProvider);
    final controller = ref.read(updateControllerProvider.notifier);
    return AboutUpdateSection(
      preferences: prefs,
      state: state,
      currentVersion: appVersionLabel ?? '未知版本',
      onCheck: () {
        unawaited(controller.check());
        unawaited(showUpdateDialog(context));
      },
      onAutoCheckChanged: (value) => unawaited(
          ref.read(updatePreferencesProvider.notifier).setAutoCheck(value)),
      onOpenResult: () => unawaited(showUpdateDialog(context)),
      between: between,
    );
  }
}

/// 关于页「重置所有设置」= **全部清空**（2026-10-27 用户口径）：设置、历史、收藏、配置源、
/// 直播源、片头片尾、弹幕 / 片段缓存、壁纸、备份……数据目录里的一切，回到刚安装的状态。
///
/// 安排清空（写标记、冻结本次会话落盘）→ 拉起新进程 → 走正常关闭链；
/// 新进程启动时、创建任何存储之前真正删除（见 [AppDataReset]）。
Future<void> _resetAllSettingsAndRestart(WidgetRef ref) async {
  await AppDataReset.schedule();
  try {
    await Process.start(Platform.resolvedExecutable, const [],
        mode: ProcessStartMode.detached);
  } catch (_) {
    showAppMessage('已重置，请手动重新打开应用', type: AppMessageType.success);
    return;
  }
  await ref.read(windowManagerProvider).close();
}

/// 启动后检查一次更新。
///
/// 用户口径（2026-10-19）：只在打开软件后执行一次，默认开启，可在关于页关闭。
/// 播放中或已有弹窗时不打断，改为底部提示条。
class UpdateCheckHost extends ConsumerStatefulWidget {
  final Widget child;
  final Duration delay;

  const UpdateCheckHost({
    super.key,
    required this.child,
    this.delay = const Duration(seconds: 8),
  });

  @override
  ConsumerState<UpdateCheckHost> createState() => _UpdateCheckHostState();
}

class _UpdateCheckHostState extends ConsumerState<UpdateCheckHost> {
  Timer? _timer;
  bool _ran = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer(widget.delay, _run);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _run() async {
    if (_ran || !mounted) return;
    _ran = true;
    if (!ref.read(updatePreferencesProvider).autoCheck) return;

    final controller = ref.read(updateControllerProvider.notifier);
    final result = await controller.check();
    if (!mounted || result == null) return;
    if (result.status != UpdateCheckStatus.available || result.skipped) return;

    final playing = ref.read(activePlaySpecProvider) != null;
    final settingsOpen = ref.read(settingsPageOpenProvider);
    final unobstructed = ModalRoute.of(context)?.isCurrent ?? false;
    if (playing || settingsOpen || !unobstructed) {
      showAppMessage(
        '发现新版本 ${result.manifest?.tag ?? ''}',
        type: AppMessageType.warning,
        action: AppMessageAction(
          label: '查看',
          onPressed: () {
            if (mounted) unawaited(showUpdateDialog(context));
          },
        ),
      );
      return;
    }
    unawaited(showUpdateDialog(context));
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Windows 桌面应用程序顶层组件
/// 顶部「站点资源准备」提示条：准备中转圈，失败给「重试」，成功自动隐藏。
///
/// 延迟 1.5 秒再出现：热启动（缓存已就绪）往往 1~2 秒就完成，
/// 立刻弹会让人误以为「每次打开都要等」。失败则立即出现。
class PrewarmBanner extends ConsumerWidget {
  const PrewarmBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.watch(siteApiProvider);
    return ValueListenableBuilder<PrewarmStatus>(
      valueListenable: api.prewarm,
      builder: (context, status, _) => _PrewarmBannerBody(
        status: status,
        onRetry: () => unawaited(api.prewarmCompanionJars(
            ref.read(configRepositoryProvider).currentVodConfig.sites,
            force: true)),
      ),
    );
  }
}

class _PrewarmBannerBody extends StatefulWidget {
  const _PrewarmBannerBody({required this.status, required this.onRetry});

  final PrewarmStatus status;
  final VoidCallback onRetry;

  @override
  State<_PrewarmBannerBody> createState() => _PrewarmBannerBodyState();
}

class _PrewarmBannerBodyState extends State<_PrewarmBannerBody> {
  static const Duration _delayBeforeShow = Duration(milliseconds: 1500);
  Timer? _delay;
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(covariant _PrewarmBannerBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.status != widget.status) _sync();
  }

  @override
  void dispose() {
    _delay?.cancel();
    super.dispose();
  }

  void _sync() {
    final status = widget.status;
    if (status.failed) {
      _delay?.cancel();
      _delay = null;
      if (!_visible) setState(() => _visible = true);
      return;
    }
    if (!status.running) {
      _delay?.cancel();
      _delay = null;
      if (_visible) setState(() => _visible = false);
      return;
    }
    if (_visible || _delay != null) return;
    _delay = Timer(_delayBeforeShow, () {
      _delay = null;
      if (mounted && widget.status.running) setState(() => _visible = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final status = widget.status;
    if (!_visible) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Material(
      elevation: 8,
      borderRadius: BorderRadius.circular(AppRadii.pill),
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (status.running)
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Icon(Icons.wifi_off_rounded,
                  size: 16, color: theme.colorScheme.error),
            const SizedBox(width: 10),
            Text(status.message, style: theme.textTheme.bodyMedium),
            if (status.failed) ...[
              const SizedBox(width: 4),
              TextButton(
                onPressed: widget.onRetry,
                child: const Text('重试'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class XiugouTvApp extends ConsumerWidget {
  const XiugouTvApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final windowMgr = ref.watch(windowManagerProvider);
    final currentSite = ref.watch(currentSiteProvider);
    final activeSiteName = currentSite?.name;
    final playbackConfig = ref.watch(vodConfigProvider);
    final activePlaySpec = ref.watch(activePlaySpecProvider);
    final liveEntryLoading = ref.watch(liveEntryLoadingProvider);
    final prepareIntent = ref.watch(playbackIntentProvider);
    final activeSession = ref.watch(activePlaybackSessionProvider);
    ref.watch(episodeBrowseSourceIndexProvider);
    // §43 弹幕：加载器 + 本次播放的开关覆盖
    final danmakuController = ref.watch(danmakuControllerProvider);
    final danmakuOverride = ref.watch(danmakuSessionOverrideProvider);
    // §44 共享片段（未配置服务时整套不挂）
    final segmentsController = ref.watch(segmentsControllerProvider);
    // ⑤-2/⑤-3 直播运行态：仅直播播放时下发给抽屉层与切台快捷键
    final liveRuntime = ref.watch(liveRuntimeProvider);
    // 按点播播放的直播频道也算直播页：抽屉、切台、播放方式照常可用；
    // 弹幕、片段两个入口只属于点播剧集，直播页（含按点播播放）一律不挂。
    final livePage = _isLivePage(activePlaySpec, liveRuntime);
    final livePlayingIndex = _livePlayingIndex(activePlaySpec, liveRuntime);
    final liveChannels = livePlayingIndex >= 0
        ? liveRuntime!.channels
        : const <Live>[];
    // §34：抽屉「收藏频道」置顶分类用的收藏键（与频道弹窗同一份数据）。
    final liveFavoriteKeys =
        ref.watch(liveFavoritesProvider).map((e) => e.key).toSet();
    final playerEngine = ref.watch(playerEngineProvider);
    final showSettings = ref.watch(settingsPageOpenProvider);
    final sourceChange = ref.watch(playbackSourceChangeProvider);
    final refreshBusy = ref.watch(playerRefreshBusyProvider) || sourceChange != null;
    final autoSwitchBusy = ref.watch(playerAutoSwitchBusyProvider);
    final sourceSearchReady = (activeSession?.site != null ||
        (prepareIntent?.isFailed == true && ref.watch(pendingPlayProvider) != null)) &&
        !livePage;
    final playSkipPreferences =
        ref.watch(playSkipPreferencesProvider).valueOrNull ??
            ref.read(settingsRepositoryProvider).playSkipPreferences;
    final isRealMpvEngine = playerEngine.runtimeType == MpvPlayerEngine;
    final trackNavs =
        isRealMpvEngine ? buildPlayerTrackNavs(playerEngine) : null;

    return MaterialApp(
      title: '修狗TV',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(
          brightness: Brightness.light, palette: AppPalette.light),
      darkTheme:
          buildAppTheme(brightness: Brightness.dark, palette: AppPalette.dark),
      themeMode: switch (ref.watch(themeModeProvider)) {
        AppThemeMode.dark => ThemeMode.dark,
        AppThemeMode.light => ThemeMode.light,
        AppThemeMode.system => ThemeMode.system,
      },
      // 弹窗探测：dialogObserver 用于「有弹窗时仍能拖动窗口」。
      navigatorObservers: [_dialogRouteObserver],
      // 全局消息浮层：挂在 Navigator 之上（盖过对话框），空白区域不拦截事件。
      //
      // §40 窗口拖动带也挂在**这一层**：弹窗的模态遮罩在 Navigator 内部，
      // 放在 home/Scaffold 里的任何拖拽区都会被遮罩挡住（实测无效）。
      builder: (context, child) => Stack(
        children: [
          child ?? const SizedBox.shrink(),
          const _LiveSourceWatcher(),
          AppMessageHost(key: appMessageKey),
          // 首次启动的站点资源准备提示：只在「准备中 / 失败」时出现，成功自动消失。
          const Positioned(
            top: 14,
            left: 0,
            right: 0,
            child: Center(child: PrewarmBanner()),
          ),
          DialogDragStrip(
            windowManager: windowMgr,
            observer: _dialogRouteObserver,
          ),
        ],
      ),
      home: Builder(
        builder: (innerContext) => UpdateCheckHost(
          child: SpiderDialogHost(
            channel: ref.read(companionUiChannelProvider),
            openUrl: ref.read(installerLauncherProvider).openUrl,
            child: Builder(
              builder: (ctx) {
                final searchBridge = ref.watch(homeSearchBridgeProvider);
                return DesktopWindowFrame(
                  windowManager: windowMgr,
                  activeSiteName: activeSiteName,
                  onSettingsPressed: () => openSettingsPage(ref),
                  onSiteSelectorPressed: () =>
                      showSiteSelectorDialog(innerContext, ref),
                  searchBar: const HomeSearchBarHost(),
                  onRefresh:
                      searchBridge.visible ? searchBridge.onRefresh : null,
                  refreshBusy: searchBridge.refreshBusy,
                  child: DesktopShell(
                    showPlayer: activePlaySpec != null ||
                        liveEntryLoading ||
                        prepareIntent != null,
                    showSettings: showSettings,
                    settingsView: showSettings
                        ? SettingsPage(
                            companionSpiderApi:
                                ref.read(siteApiProvider).companionSpiderApi,
                            liveRepository: ref.read(liveRepositoryProvider),
                            playerSettingsApplication:
                                playerEngine.settingsApplication,
                            playerEngine: playerEngine,
                            configRepository:
                                ref.read(configRepositoryProvider),
                            settingsRepository:
                                ref.read(settingsRepositoryProvider),
                            cacheMaintenance:
                                ref.read(cacheMaintenanceProvider),
                            epgRepository: ref.read(epgRepositoryProvider),
                            dataBackupService:
                                ref.read(dataBackupServiceProvider),
                            wallpaperStore: ref.read(wallpaperStoreProvider),
                            isPlaybackActive: () =>
                                ref.read(activePlaySpecProvider) != null,
                            updateSection: (buildInfo) =>
                                AboutUpdateSectionHost(between: buildInfo),
                            onResetAll: () => _resetAllSettingsAndRestart(ref),
                            onClose: () {
                              ref
                                  .read(settingsPageOpenProvider.notifier)
                                  .state = false;
                              ref
                                  .read(autoLineSwitchProvider)
                                  .resumePendingAttempt();
                            },
                            onAddConfig: (pageContext) => showDialog<void>(
                              context: pageContext,
                              builder: (_) => ConfigDialog(
                                  repository:
                                      ref.read(configRepositoryProvider)),
                            ),
                          )
                        : null,
                    mainView: WallpaperBackdrop(
                      store: ref.read(wallpaperStoreProvider),
                      child: const DesktopMainView(),
                    ),
                    playerView: activePlaySpec == null &&
                            !liveEntryLoading &&
                            prepareIntent == null
                        ? null
                        : Stack(
                            fit: StackFit.expand,
                            children: [
                              _LineSwitchNoticeHost(
                                child: _PlaySkipWatcher(
                                  engine: playerEngine,
                                  child: _PlayerPrefsBinding(
                                    repository:
                                        ref.read(settingsRepositoryProvider),
                                    builder: (playerContext,
                                            scale,
                                            hideWindowTitleBar,
                                            danmakuDefault,
                                            danmakuSettings,
                                            showMiniProgress,
                                            holdRate,
                                            autoHideCursor,
                                            shortcuts) =>
                                        _SegmentsSessionSync(
                                      session: !segmentsServiceConfigured ||
                                              livePage
                                          ? null
                                          : activeSession,
                                      controller: segmentsController,
                                      child: _DanmakuSessionSync(
                                        session: livePage
                                            ? null
                                            : activeSession,
                                        // §43 弹幕可选：本次构建未配置弹幕服务时不加载、不挂入口
                                        enabled: danmakuServiceConfigured &&
                                            !livePage &&
                                            (danmakuOverride ?? danmakuDefault),
                                        controller: danmakuController,
                                        child: LiveDanmakuBinding(
                                          client: ref.watch(liveDanmakuClientProvider),
                                          sourceUrl: activePlaySpec != null &&
                                                  activePlaySpec.liveDanmakuSources.isNotEmpty
                                              ? activePlaySpec.liveDanmakuSources.first.url
                                              : null,
                                          contextKey: (playbackConfig, currentSite?.key),
                                          enabled: danmakuOverride ?? danmakuDefault,
                                          settings: danmakuSettings,
                                          preparing: prepareIntent != null || liveEntryLoading,
                                          onToggle: () => ref
                                              .read(danmakuSessionOverrideProvider.notifier)
                                              .state = !(danmakuOverride ?? danmakuDefault),
                                          onSettingsChanged: (next) {
                                            final repo = ref.read(settingsRepositoryProvider);
                                            unawaited(repo.updatePlayerSettings(
                                                repo.playerSettings.copyWith(danmaku: next)));
                                          },
                                          builder: (_, liveDanmakuNav) => DesktopVideoPlayer(
                                          liveDanmakuNav: liveDanmakuNav,
                                          shortcuts: shortcuts,
                                          seekRecovery: isRealMpvEngine ? playerEngine : null,
                                          qualityNav: activePlaySpec == null ||
                                                  (!livePage && activeSession == null) || activePlaySpec.qualities.length < 2
                                              ? null
                                              : PlayerQualityNav(
                                                  names: activePlaySpec.qualities.map((q) => q.name).toList(),
                                                  selectedIndex: activePlaySpec.qualityIndex,
                                                  label: livePage ? '线路' : '清晰度',
                                                  busy: refreshBusy || autoSwitchBusy || (activeSession?.switching ?? false),
                                                  onSelect: (index) => unawaited(livePage
                                                      ? ref.read(switchLiveLineProvider)(index)
                                                      : ref.read(switchPlaybackQualityProvider)(index)),
                                                ),
                                          externalNav: activePlaySpec == null || prepareIntent != null
                                              ? null
                                              : PlayerExternalNav(
                                                  busy: sourceChange?.kind == PlaybackSourceChangeKind.external,
                                                  enabled: !refreshBusy && !autoSwitchBusy && !(activeSession?.switching ?? false),
                                                  statusText: sourceChange?.kind == PlaybackSourceChangeKind.external
                                                      ? sourceChange?.statusText : null,
                                                  onLaunch: () => unawaited(ref.read(launchExternalPlaybackProvider)(
                                                      (warnings) => _confirmExternalPlayback(playerContext, ref, warnings))),
                                                ),
                                          sourceSwitchNav: sourceSearchReady
                                              ? PlayerSourceSwitchNav(
                                                  busy: sourceChange?.kind == PlaybackSourceChangeKind.source,
                                                  enabled: !refreshBusy && !autoSwitchBusy && !(activeSession?.switching ?? false),
                                                  statusText: sourceChange?.statusText,
                                                  onSearch: () => unawaited(ref.read(switchPlaybackSourceProvider)(
                                                      (candidates) => _choosePlaybackSource(playerContext, ref, candidates))),
                                                  onCancel: sourceChange?.cancelToken.cancel,
                                                )
                                              : null,
                                          danmakuNav:
                                              !danmakuServiceConfigured ||
                                                      activeSession == null ||
                                                      livePage
                                                  ? null
                                                  : PlayerDanmakuNav(
                                                      state: danmakuController,
                                                      settings: danmakuSettings,
                                                      // §43 播放页「弹幕设置」抽屉：与设置中心同一份设置，改动落盘
                                                      onSettingsChanged:
                                                          (next) {
                                                        final repo = ref.read(
                                                            settingsRepositoryProvider);
                                                        unawaited(repo
                                                            .updatePlayerSettings(repo
                                                                .playerSettings
                                                                .copyWith(
                                                                    danmaku:
                                                                        next)));
                                                      },
                                                      enabled:
                                                          danmakuOverride ??
                                                              danmakuDefault,
                                                      onToggle: () => ref
                                                              .read(
                                                                  danmakuSessionOverrideProvider
                                                                      .notifier)
                                                              .state =
                                                          !(danmakuOverride ??
                                                              danmakuDefault),
                                                    ),
                                          playerEngine: playerEngine,
                                          windowManager: windowMgr,
                                          scale: scale,
                                          hideWindowTitleBar:
                                              hideWindowTitleBar,
                                          showMiniProgress: showMiniProgress,
                                          holdRate: holdRate,
                                          autoHideCursor: autoHideCursor,
                                          playerInfoLabel: 'MPV 播放器',
                                          episodeNav: _buildEpisodeNav(
                                              ref, livePage ? null : activeSession, playerContext,
                                              refreshBusy: refreshBusy ||
                                                  autoSwitchBusy),
                                          episodeListNav: _buildEpisodeListNav(
                                              ref, livePage ? null : activeSession, playerContext,
                                              busy: refreshBusy ||
                                                  autoSwitchBusy),
                                          lineNav: _buildLineNav(
                                              ref, livePage ? null : activeSession,
                                              busy: refreshBusy ||
                                                  autoSwitchBusy),
                                          playbackModeNav:
                                              _buildPlaybackModeNav(ref),
                                          liveSourceNav: liveChannels.isEmpty
                                              ? null
                                              : _buildLiveSourceNav(
                                                  ref, innerContext),
                                          onLivePrev: liveChannels.isEmpty
                                              ? null
                                              : () => unawaited(
                                                  _switchLiveChannel(ref, -1)),
                                          onLiveNext: liveChannels.isEmpty
                                              ? null
                                              : () => unawaited(
                                                  _switchLiveChannel(ref, 1)),
                                          liveChannels: liveChannels,
                                          liveCurrentIndex: livePlayingIndex < 0
                                              ? 0
                                              : livePlayingIndex,
                                          liveFavoriteKeys: liveFavoriteKeys,
                                          onLiveSelect: liveChannels.isEmpty
                                              ? null
                                              : (index) {
                                                  if (!_isLiveCatalogPlaybackActive(ref) ||
                                                      !identical(liveRuntime,
                                                          ref.read(liveRuntimeProvider))) {
                                                    return;
                                                  }
                                                  unawaited(_startLiveChannel(
                                                      ref, liveChannels, index));
                                                },
                                          onLiveManage: () => unawaited(
                                              _showLiveManagerDialog(
                                                  innerContext, ref)),
                                          refreshNav: PlayerRefreshNav(
                                            busy: refreshBusy ||
                                                autoSwitchBusy ||
                                                (activeSession?.switching ??
                                                    false),
                                            onRefresh: () =>
                                                _handleRefreshPlayback(
                                                    playerContext, ref),
                                          ),
                                          skipNav: _buildSkipNav(
                                              ref,
                                              livePage ? null : activeSession,
                                              playerContext,
                                              playSkipPreferences),
                                          // §44 共享片段：与本地片头片尾是两个独立功能
                                          segmentsNav:
                                              !segmentsServiceConfigured ||
                                                      activeSession == null ||
                                                      livePage
                                                  ? null
                                                  : PlayerSegmentsNav(
                                                      state: segmentsController,
                                                      onSubmit:
                                                          segmentsController
                                                              .submit,
                                                      onFeedback:
                                                          segmentsController
                                                              .feedback,
                                                      autoApply: ref
                                                          .read(
                                                              settingsRepositoryProvider)
                                                          .playerSettings
                                                          .segmentsAutoApply,
                                                      onAutoApplyChanged: (v) {
                                                        final repo = ref.read(
                                                            settingsRepositoryProvider);
                                                        unawaited(repo
                                                            .updatePlayerSettings(repo
                                                                .playerSettings
                                                                .copyWith(
                                                                    segmentsAutoApply:
                                                                        v)));
                                                      },
                                                      localOpeningMs: playSkipPreferences
                                                              .enabled
                                                          ? (playSkipPreferences
                                                                  .entryFor(
                                                                      activeSession
                                                                          .item
                                                                          .id)
                                                                  ?.openingMs ??
                                                              0)
                                                          : 0,
                                                    ),
                                          // §16 起播准备态：解析期间页内骨架 / 失败可重试
                                          preparing: prepareIntent,
                                          onRetryPrepare:
                                              prepareIntent?.isFailed == true
                                                  ? () => unawaited(
                                                      retryPlayPreparation(ref))
                                                  : null,
                                          onCancelPrepare: prepareIntent == null
                                              ? null
                                              : () =>
                                                  cancelPlayPreparation(ref),
                                          onVolumeCommitted: (value) =>
                                              _commitPlaybackVolume(ref, value),
                                          onMutedPlaybackDetected: () =>
                                              _showMutedHintForSpec(ref),
                                          replayNav: PlayerReplayNav(
                                            busy: refreshBusy ||
                                                autoSwitchBusy ||
                                                (activeSession?.switching ??
                                                    false),
                                            onReplay: () => unawaited(
                                                _handleReplayRequested(
                                                    playerContext,
                                                    ref,
                                                    playerEngine)),
                                          ),
                                          videoTracksNav: trackNavs?.video,
                                          audioTracksNav: trackNavs?.audio,
                                          subtitleTracksNav:
                                              trackNavs?.subtitle,
                                          onScaleChanged: (value) =>
                                              _handleScaleChanged(ref, value),
                                          resetNav: PlayerResetNav(
                                            enabled: !refreshBusy &&
                                                !autoSwitchBusy &&
                                                !(activeSession?.switching ??
                                                    false),
                                            onReset: () =>
                                                _handleResetPlayerData(
                                                    ref, playerEngine),
                                          ),
                                          onBack: () {
                                            cancelPlayPreparation(ref);
                                            ref
                                                .read(autoLineSwitchProvider)
                                                .disarm();
                                            // 先同步捕获最终播放位置写入历史，再停止引擎（stop 会重置位置）
                                            unawaited(ref
                                                .read(
                                                    playbackHistoryTrackerProvider)
                                                .stop());
                                            playerEngine.stop();
                                            ref
                                                .read(activePlaySpecProvider
                                                    .notifier)
                                                .state = null;

                                            // ⑤ 修复：加载态中返回同样撤销（迟到起播作废，见 _enterLive）
                                            ref
                                                .read(liveEntryLoadingProvider
                                                    .notifier)
                                                .state = false;
                                            // §43 退出播放：取消在途弹幕请求，开关回到设置默认
                                            danmakuController.clear();
                                            segmentsController.clear();
                                            ref
                                                .read(
                                                    danmakuSessionOverrideProvider
                                                        .notifier)
                                                .state = null;
                                            // 关闭播放会话并作废在途切换结果
                                            ref
                                                .read(
                                                    episodeBrowseSourceIndexProvider
                                                        .notifier)
                                                .state = null;
                                            _playbackSessionEpoch++;
                                            ref
                                                .read(
                                                    activePlaybackSessionProvider
                                                        .notifier)
                                                .state = null;
                                          },
                                        ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              if (liveEntryLoading)
                                const _LiveEntryLoadingOverlay(),
                            ],
                          ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// ⑤ 修复：直播入口「先进入播放页再加载」的过渡态。
///
/// 居中的加载指示 + 文案（skill `Loading States`：异步等待必须有可见反馈，
/// 不能冻结 UI）；`IgnorePointer` 保证底层控制条（返回 / 播放）仍可点，
/// Esc 也可直接退出。
class _LiveEntryLoadingOverlay extends StatelessWidget {
  const _LiveEntryLoadingOverlay();

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return IgnorePointer(
      child: Center(
        child: Semantics(
          liveRegion: true,
          container: true,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 34,
                height: 34,
                child: CircularProgressIndicator(
                    strokeWidth: 3.5, color: palette.accentInk),
              ),
              const SizedBox(height: AppSpacing.md),
              Text('正在加载直播频道…',
                  style: TextStyle(
                      color: palette.playerText, fontSize: AppType.body)),
            ],
          ),
        ),
      ),
    );
  }
}

/// SET-12 换线「进行中」提示的展示时长（压短，避免把结果提示压在换台之后）。
const Duration _lineSwitchProgressDuration = Duration(milliseconds: 1200);

/// 换线提示类型：进度 = info、失败 = error、缺集 = warning、其余（已切换）= success。
AppMessageType _lineSwitchNoticeType(String message) {
  if (message.contains('正在尝试') || message.contains('正在切换')) {
    return AppMessageType.info;
  }
  if (message.contains('失败')) return AppMessageType.error;
  if (message.contains('请换一条') || message.contains('当前播放未中断')) {
    return AppMessageType.warning;
  }
  return AppMessageType.success;
}

/// 监听自动换线提示并显示顶部浮层消息（SET-12）。
class _LineSwitchNoticeHost extends ConsumerStatefulWidget {
  final Widget child;

  const _LineSwitchNoticeHost({required this.child});

  @override
  ConsumerState<_LineSwitchNoticeHost> createState() =>
      _LineSwitchNoticeHostState();
}

class _LineSwitchNoticeHostState extends ConsumerState<_LineSwitchNoticeHost> {
  String? _last;

  void _schedule(String message) {
    if (message == _last) return;
    _last = message;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 消息改为堆叠展示后，「换线提示会吞掉续播提示」的旧坑（评审 N7）已
      // 消失；「进行中」提示仍压到 1.2 秒，避免把结果提示压到用户已经换台
      // 之后才出现。
      final isProgress = message.contains('正在尝试') || message.contains('正在切换');
      showAppMessage(
        message,
        type: _lineSwitchNoticeType(message),
        duration: isProgress ? _lineSwitchProgressDuration : null,
      );
      ref.read(lineSwitchNoticeProvider.notifier).state = null;
      // 复位去重键：同一文案在后续会话/再次换线时仍需提示，只抑制同一帧内的重复。
      _last = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final current = ref.watch(lineSwitchNoticeProvider);
    if (current != null) _schedule(current);
    ref.listen<String?>(lineSwitchNoticeProvider, (previous, next) {
      if (next != null) _schedule(next);
    });
    return widget.child;
  }
}

/// 桌面主区域外壳：在「主视图 ⇄ 播放器 ⇄ 设置中心」之间切换。
///
/// 契约：播放或打开设置期间主视图必须保持挂载（仅隐藏，不销毁），
/// 返回时恢复此前的分类选择 / 搜索结果 / 列表数据，而不是重新加载回首页默认状态；
/// 设置中心覆盖在播放器之上时，播放器同样保持挂载。
/// 主视图壁纸背景（SET-08）。
///
/// 只包住主视图：播放器 / 设置页在 [DesktopShell] 的更高层，不受影响。未设置壁纸时
/// 与旧版视觉一致（只铺一层深色底，不额外压暗）；设置后固定叠一层 55% 黑遮罩，
/// 保证任何图片下左侧导航 / 分类栏 / 标题文字都有对比度。
class WallpaperBackdrop extends ConsumerStatefulWidget {
  final WallpaperStore store;
  final Widget child;

  const WallpaperBackdrop(
      {super.key, required this.store, required this.child});

  @override
  ConsumerState<WallpaperBackdrop> createState() => _WallpaperBackdropState();
}

class _WallpaperBackdropState extends ConsumerState<WallpaperBackdrop> {
  String? _fileName;
  Future<String?>? _resolved;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final preferences = ref.watch(appearancePreferencesProvider).valueOrNull ??
        AppearancePreferences.none;
    if (preferences.wallpaperFileName != _fileName) {
      _fileName = preferences.wallpaperFileName;
      _resolved = widget.store.resolvePath(_fileName);
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: palette.background),
        FutureBuilder<String?>(
          future: _resolved,
          builder: (context, snapshot) {
            final path = snapshot.data;
            if (path == null) return const SizedBox.shrink();
            final windowWidth = MediaQuery.sizeOf(context).width;
            final cacheWidth =
                windowWidth <= 0 ? null : windowWidth.clamp(1, 2560).round();
            return Stack(
              fit: StackFit.expand,
              children: [
                Image.file(
                  File(path),
                  fit: BoxFit.cover,
                  filterQuality: FilterQuality.medium,
                  cacheWidth: cacheWidth,
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                ),
                // 遮罩随主题：深色 55% 黑，浅色 55% 白（固定值，不提供滑杆）
                ColoredBox(color: palette.scrim),
              ],
            );
          },
        ),
        widget.child,
      ],
    );
  }
}

class DesktopShell extends StatelessWidget {
  final bool showPlayer;
  final Widget mainView;
  final Widget? playerView;
  final bool showSettings;
  final Widget? settingsView;

  const DesktopShell({
    super.key,
    required this.showPlayer,
    required this.mainView,
    this.playerView,
    this.showSettings = false,
    this.settingsView,
  });

  @override
  Widget build(BuildContext context) {
    final settingsVisible = showSettings && settingsView != null;
    return Stack(
      fit: StackFit.expand,
      children: [
        // 隐藏层与其浮层必须共享语义生命周期，同时禁止隐藏层持有键盘焦点。
        Offstage(
          offstage: showPlayer || settingsVisible,
          child: ExcludeFocus(
            excluding: showPlayer || settingsVisible,
            child: Overlay.wrap(child: mainView),
          ),
        ),
        if (showPlayer && playerView != null)
          Offstage(
            offstage: settingsVisible,
            child: ExcludeFocus(
              excluding: settingsVisible,
              child: Overlay.wrap(child: playerView!),
            ),
          ),
        if (settingsVisible) settingsView!,
      ],
    );
  }
}

/// 桌面主体视图（左侧垂直导航面板 + 顶部搜索栏 + 站源动态分类滚动条 + 影视海报瀑布流）
class DesktopMainView extends ConsumerStatefulWidget {
  const DesktopMainView({super.key});

  @override
  ConsumerState<DesktopMainView> createState() => _DesktopMainViewState();
}

class _DesktopMainViewState extends ConsumerState<DesktopMainView> {
  final TextEditingController _searchController = TextEditingController();

  /// 搜索框焦点（聚焦时外框高亮；B3）
  final FocusNode _searchFocusNode = FocusNode();
  final ScrollController _categoryScrollController = ScrollController();

  /// 海报网格的滚动控制器：豆瓣首页据此判断「内容有没有撑满一屏」（§19）
  final ScrollController _gridScrollController = ScrollController();

  List<VodItem> _items = [];
  List<VodCategory> _categories = [];
  VodCategory? _selectedCategory;
  bool _isLoading = false;
  String? _errorMessage;
  bool _isSearching = false;

  /// 搜索态下按站点筛选的分组键；null 表示「全部」
  String? _searchSiteGroupKey;

  /// 搜索相关提示（如当前站源不支持搜索）；为空时按加载 / 搜索状态显示默认文案
  String? _searchNotice;

  /// 聚合搜索进行中：结果边到边显示，结束前不显示「未找到」
  bool _searchPending = false;
  StreamSubscription<SearchBatch>? _searchSub;

  /// 本次聚合搜索的取消令牌：点叉 / 换站 / 发起新搜索 / 销毁时取消，
  /// 把「取消」一直传到站源请求，真正停掉在途 HTTP（§18）。
  SearchCancelToken? _searchCancelToken;
  final Set<String> _searchSeenKeys = <String>{};
  int _searchCompleted = 0;
  int _searchTotal = 0;
  int _searchFailed = 0;
  String? _firstSearchFailure;

  String? _loadedSiteIdentity;
  int _contentGeneration = 0;
  Timer? _prewarmTimer;

  /// 豆瓣首页每页条数（24 ≈ 宽窗口 3 行，滚动时再续）
  static const int _doubanPageSize = 24;

  /// 豆瓣首页分页游标（§19 无限滚动）
  int _doubanNextStart = 0;
  bool _doubanHasMore = false;
  bool _doubanLoadingMore = false;

  /// 当前正在翻页的豆瓣集合 id：换分类后旧页结果按它丢弃
  String? _doubanCollection;

  /// 普通站源分类页的翻页状态（§30）。豆瓣首页那条无限滚动线不覆盖普通站源，
  /// 分类标签永远停在 `pg=1` 一页（上游 CMS 默认 20 条），这就是「每标签只显示 20 部」的根因。
  /// 这里独立一套游标，不与豆瓣链路共用状态。
  static const int _maxCategoryPages = 50;
  int _categoryPage = 1;
  bool _categoryHasMore = false;
  bool _categoryLoadingMore = false;

  /// 当前翻页绑定的「站源 + 分类」；换分类 / 换站源后在途的旧页结果按它丢弃。
  String? _categoryPageKey;

  /// 已展示条目的去重键。站源常见「忽略 pg、每页返回同一批」的假分页，
  /// 靠它识别「这一页零新增 = 到底」，否则会无限空转。
  final Set<String> _categorySeenKeys = <String>{};

  /// 当前站源首页声明的分类筛选（分类 id → 筛选组，待办第 20 条）。
  /// 只在拉首页时更新；切分类直接按分类 id 查表，换站 / 豆瓣 / 无站时清空。
  Map<String, List<VodFilter>> _siteFilters = const {};

  /// 用户的筛选选择，键 = 站源身份 + 分类 id。只记在内存：切分类再切回保留，
  /// 换配置或重启清空（不落盘：站源改了选项后旧值会变成看不见的隐性过滤）。
  final Map<String, Map<String, String>> _filterSelections = {};

  /// [_filterSelections] 所属的配置身份；配置一换就整表清空。
  String? _filterSelectionConfig;

  /// 页面上手动展开 / 收起筛选条的结果，本次运行内全局记住；null 表示没动过，
  /// 跟随设置「分类页筛选条默认展开」（默认收起）。设置一改就清掉，让新默认立即生效。
  bool? _filterBarExpandedOverride;

  /// 分类请求（首屏 / 翻页）的取消令牌：改筛选、切分类、换站、搜索、销毁时取消，
  /// 真正中止在途请求。结果是否采纳仍由 generation + 翻页键判定，令牌只负责释放资源。
  SearchCancelToken? _categoryCancelToken;

  /// 豆瓣全分类数据池（用于仿 Netflix 首页各分类横滑画报流）
  final Map<String, List<VodItem>> _doubanCategoryItems = {};

  /// 是否在豆瓣虚拟站中处于单一分类网格查看态（点击横滑流中“查看全部”后）
  bool _doubanViewingSingleCategory = false;

  /// 冷启动直播入口：在直播弹窗关闭前推迟主视图初始加载
  bool _startupLiveEntryPending = false;

  /// 本次直播弹窗内是否已启动频道播放（用于区分「关闭后回到点播」）
  bool _livePlaybackStartedInDialog = false;

  /// 直播入口防重入（频道列表可能来自网络，缓慢时避免双击叠加加载）。
  bool _liveEntryBusy = false;
  int _liveFavoriteGeneration = 0;

  /// 从「详情/选集弹窗」起播时记住来源：退出播放器后要回到这个弹窗，而不是首页。
  VodDetail? _playbackOriginDetail;
  Site? _playbackOriginSite;

  /// §15：最近一次播放会话的只读副本。
  ///
  /// 播放会话在 `onBack` 里会被清空（作废在途切换），而恢复详情弹窗要等下一帧、
  /// 用户也可能从首页重新打开同一部片——两条路径都要知道「上次播到第几集」。
  /// 副本只供详情弹窗判定当前集，不参与播放器逻辑。
  PlaybackSession? _lastPlayedSession;
  bool _restoringDetailDialog = false;

  String? _currentSiteIdentity() {
    final repository = ref.read(configRepositoryProvider);
    final site = repository.selectedSite;
    return site == null
        ? null
        : '${repository.currentConfigIdentity}:${HomeSitePreference.requestIdentity(site)}';
  }

  bool _acceptContent(int generation, String? identity) =>
      mounted &&
      generation == _contentGeneration &&
      identity == _currentSiteIdentity();

  /// 取消在途的增量搜索：停止接收后续批次，并**取消站源请求**（否则用户点叉
  /// 之后几十个站源仍会在后台跑完，纯属浪费——§18）。
  void _cancelSearchStream() {
    _searchSub?.cancel();
    _searchSub = null;
    _searchCancelToken?.cancel();
    _searchCancelToken = null;
    _searchPending = false;
  }

  /// 清空搜索词并回到常规首页 / 分类加载（搜索框清除、换源同步与
  /// 空态行动按钮共用——B2）。
  void _clearSearchToHome() {
    _searchController.clear();
    loadSiteData();
  }

  void _synchronizeSite() {
    if (!mounted || _loadedSiteIdentity == _currentSiteIdentity()) return;
    _clearSearchToHome();
  }

  /// 搜索进行中（聚合增量或非聚合整块等待）——搜索按钮据此禁用并显示转圈（B3）。
  bool get _searchBusy => _isSearching && (_searchPending || _isLoading);

  /// 搜索框聚焦变化：刷新外框高亮（B3）。
  void _onSearchFocusChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    // 冷启动直播入口：推迟主视图初始加载，首帧后打开直播入口；其余入口保持原有加载行为
    _startupLiveEntryPending =
        ref.read(startupEntryProvider) == StartupEntry.live;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_startupLiveEntryPending) {
        unawaited(_showLiveDialog());
      } else {
        loadSiteData();
      }
    });
    // 搜索框聚焦时高亮外框（B3）
    _searchFocusNode.addListener(_onSearchFocusChanged);
    _syncSearchBridge();
  }

  void _syncSearchBridge() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final searchPrefs = ref.read(searchPreferencesProvider).valueOrNull ??
          const SearchPreferences();
      ref.read(homeSearchBridgeProvider.notifier).state = HomeSearchBridge(
        searchController: _searchController,
        searchFocusNode: _searchFocusNode,
        isSearching: _isSearching,
        searchBusy: _searchBusy,
        isAggregate: searchPrefs.aggregate,
        onSearch: _handleSearch,
        onClear: _clearSearchToHome,
        onRefresh: () => loadSiteData(
          category: _selectedCategory,
          preserveCategories: true,
          forceRefresh: true,
        ),
        refreshBusy: _isLoading,
        visible: true,
      );
    });
  }

  @override
  void dispose() {
    // 刻意不在 dispose 里复位 homeSearchBridgeProvider：主视图在整个应用
    // 生命周期内只会随 ProviderScope 一起销毁（播放页 / 设置页都是 Offstage，
    // 不卸载它），那一刻标题栏也不在了；而在 dispose 之后再碰 ref 会抛
    // `Cannot use "ref" after the widget was disposed`（旧实现用 post-frame
    // 复位正好踩中）。新实例挂载时 initState → _syncSearchBridge 会覆盖旧值。
    _prewarmTimer?.cancel();
    _cancelSearchStream();
    _cancelCategoryRequest();
    _searchController.dispose();
    _searchFocusNode.removeListener(_onSearchFocusChanged);
    _searchFocusNode.dispose();
    _categoryScrollController.dispose();
    _gridScrollController.dispose();
    super.dispose();
  }

  /// 当前首页是否为内置「豆瓣热播」虚拟站（§17）。
  bool get _isDoubanHome {
    final site = ref.read(configRepositoryProvider).selectedSite;
    return site != null && isBuiltinSite(site);
  }

  /// 豆瓣首页加载（第一页）：分类固定 5 类，内容来自 [DoubanRepository]。
  ///
  /// 刻意复用普通站源那套界面状态（`_categories` / `_items` / `_errorMessage`），
  /// 于是骨架、空态、错误重试、分类胶囊都不需要另写一份。
  Future<void> _loadDouban({
    required int generation,
    required String? identity,
    VodCategory? category,
    bool forceRefresh = false,
  }) async {
    final repository = ref.read(doubanRepositoryProvider);
    final categories = <VodCategory>[
      for (final entry in doubanCategories)
        VodCategory(id: entry.id, name: entry.name),
    ];
    final target = category ?? categories.first;
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _isSearching = false;
      _searchSiteGroupKey = null;
      _searchNotice = null;
      _categories = categories;
      _selectedCategory = target;
      // 换分类 = 重新从第 0 条开始（§19 无限滚动的游标）
      _doubanCollection = target.id;
      _doubanNextStart = 0;
      _doubanHasMore = false;
      _doubanLoadingMore = false;
    });

    try {
      final page = await repository.fetchPage(target.id,
          start: 0, count: _doubanPageSize, forceRefresh: forceRefresh);
      if (!_acceptContent(generation, identity) || !mounted) return;
      if (_doubanCollection != target.id) return;
      setState(() {
        _items = [for (final item in page.items) item.toVodItem()];
        _doubanCategoryItems[target.id] = _items;
        _doubanNextStart = page.nextStart;
        _doubanHasMore = page.hasMore;
        _isLoading = false;
      });
      _maybeFillDoubanPage();

      // 并发预加载其余豆瓣分类（构建仿 Netflix 首页完整横滑画报轨道）
      for (final cat in categories) {
        if (cat.id == target.id) continue;
        repository
            .fetchPage(cat.id, start: 0, count: _doubanPageSize)
            .then((p) {
          if (!mounted || !_isDoubanHome) return;
          setState(() {
            _doubanCategoryItems[cat.id] = [
              for (final it in p.items) it.toVodItem()
            ];
          });
        }).catchError((_) {});
      }
    } on DoubanException catch (error) {
      if (!_acceptContent(generation, identity) || !mounted) return;
      setState(() {
        _items = [];
        _errorMessage = '豆瓣数据加载失败：${error.message}';
        _isLoading = false;
      });
    } catch (error) {
      if (!_acceptContent(generation, identity) || !mounted) return;
      setState(() {
        _items = [];
        _errorMessage = '豆瓣数据加载失败：$error';
        _isLoading = false;
      });
    }
  }

  /// 豆瓣首页触底续页（§19 无限滚动）。
  ///
  /// 只在「豆瓣首页 + 非搜索态 + 没有正在加载」时追加；按 `nextStart` 继续，
  /// 已加载条目按 id 去重（翻页期间豆瓣榜单可能轻微换位），到底后不再请求。
  Future<void> _loadMoreDouban() async {
    if (!_isDoubanHome || _isSearching || _isLoading) return;
    if (_doubanLoadingMore || !_doubanHasMore) return;
    final collection = _doubanCollection;
    if (collection == null) return;

    final generation = _contentGeneration;
    final identity = _currentSiteIdentity();
    setState(() => _doubanLoadingMore = true);

    try {
      final page = await ref.read(doubanRepositoryProvider).fetchPage(
          collection,
          start: _doubanNextStart,
          count: _doubanPageSize);
      if (!_acceptContent(generation, identity) || !mounted) return;
      if (_doubanCollection != collection) return; // 期间换了分类：丢弃
      final known = <String>{for (final item in _items) item.id};
      final fresh = <VodItem>[
        for (final item in page.items)
          if (known.add(item.id)) item.toVodItem(),
      ];
      setState(() {
        _items = [..._items, ...fresh];
        _doubanNextStart = page.nextStart;
        _doubanHasMore = page.hasMore;
        _doubanLoadingMore = false;
      });
      _maybeFillDoubanPage();
    } on DoubanException catch (error) {
      if (!_acceptContent(generation, identity) || !mounted) return;
      setState(() => _doubanLoadingMore = false);
      showAppMessage('加载更多失败：${error.message}', type: AppMessageType.error);
    } catch (error) {
      if (!_acceptContent(generation, identity) || !mounted) return;
      setState(() => _doubanLoadingMore = false);
      showAppMessage('加载更多失败：$error', type: AppMessageType.error);
    }
  }

  /// 内容没撑满一屏（宽窗口 + 每页 24 条很常见）时自动续一页，
  /// 否则用户连"滚到底"的机会都没有，无限滚动形同不存在。
  void _maybeFillDoubanPage() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_isDoubanHome || !_doubanHasMore || _doubanLoadingMore) {
        return;
      }
      if (!_gridScrollController.hasClients) return;
      final position = _gridScrollController.position;
      if (position.maxScrollExtent <= position.viewportDimension * 0.15) {
        unawaited(_loadMoreDouban());
      }
    });
  }

  /// 网格滚动到接近底部时续页；`ScrollNotification` 从内部 GridView 冒泡上来。
  ///
  /// 豆瓣首页和普通站源分类页共用这条触发器，但各走各的游标与数据源。
  bool _onGridScroll(ScrollNotification notification) {
    if (notification.metrics.axis != Axis.vertical) return false;
    if (_isSearching) return false;
    // 剩余可滚高度不足两屏时提前取，滚动不会「顿一下」
    if (notification.metrics.extentAfter >= 600) return false;
    if (_isDoubanHome) {
      unawaited(_loadMoreDouban());
    } else {
      unawaited(_loadMoreCategory());
    }
    return false;
  }

  /// 分类页翻页键：站源身份 + 分类。换站源、换分类都会让它变化，
  /// 在途的旧页结果据此丢弃（§30 记的「防串台」依赖项）。
  ///
  /// 末尾追加筛选条件指纹：改了条件，在途的旧条件翻页同样按键丢弃。
  String? _categoryPageKeyFor(VodCategory? category) {
    final identity = _currentSiteIdentity();
    if (identity == null) return null;
    final fingerprint = filterSelectionFingerprint(_filterExtendFor(category));
    return '$identity|${category?.id ?? ''}|${category?.name ?? ''}|$fingerprint';
  }

  /// 分类当前的筛选组；无 id 的分类、未声明筛选的分类返回空表。
  List<VodFilter> _filtersFor(VodCategory? category) {
    final id = category?.id ?? '';
    if (id.isEmpty) return const [];
    return _siteFilters[id] ?? const [];
  }

  String? _filterSelectionKey(VodCategory? category) {
    final identity = _currentSiteIdentity();
    final id = category?.id ?? '';
    if (identity == null || id.isEmpty) return null;
    return '$identity|$id';
  }

  /// 分类请求要下发的 extend：只含当前筛选组里仍存在的 key，未选为空表。
  Map<String, String> _filterExtendFor(VodCategory? category) {
    final key = _filterSelectionKey(category);
    final selection = key == null ? null : _filterSelections[key];
    if (selection == null || selection.isEmpty) return const {};
    return sanitizeFilterSelection(selection, _filtersFor(category));
  }

  /// 配置换了就清空筛选记忆（拍板项②：只按站源 + 分类记在内存）。
  void _syncFilterSelectionScope() {
    final config = ref.read(configRepositoryProvider).currentConfigIdentity;
    if (config == _filterSelectionConfig) return;
    _filterSelectionConfig = config;
    _filterSelections.clear();
  }

  /// 取消在途分类请求并发一张新令牌（首屏与翻页共用）。
  SearchCancelToken _renewCategoryCancelToken() {
    _categoryCancelToken?.cancel();
    return _categoryCancelToken = SearchCancelToken();
  }

  void _cancelCategoryRequest() {
    _categoryCancelToken?.cancel();
    _categoryCancelToken = null;
  }

  /// 用户改了筛选：记下选择，回到顶部并以新条件从第 1 页重拉。
  ///
  /// 走 `loadSiteData` 这条已有路径：它负责递增 generation、取消旧请求、
  /// 重置分页游标与去重集合，不另写一套。
  void _onFilterChanged(Map<String, String> selection) {
    final category = _selectedCategory;
    final key = _filterSelectionKey(category);
    if (key == null) return;
    setState(() {
      if (selection.isEmpty) {
        _filterSelections.remove(key);
      } else {
        _filterSelections[key] = Map.unmodifiable(selection);
      }
    });
    if (_gridScrollController.hasClients) _gridScrollController.jumpTo(0);
    loadSiteData(category: category, preserveCategories: true);
  }

  /// 站源是否声明了下一页。
  ///
  /// 只认站源自己给出的信号：`pagecount > 当前页`，或声明了 `total`
  /// 且已展示条数还没到 `total`。两者都没声明就判到底 —— 宁可不翻，
  /// 也不要对着不支持 `pg` 的站源无限空转。
  static bool _declaresMorePages(VodPageResult page, int shown) {
    if (page.pageCount > page.page) return true;
    return page.pageCount <= 1 && page.total > shown;
  }

  /// 首屏落地后重置分类页翻页状态。
  ///
  /// 首页推荐（`fetchHome` 没有 `page` 入参）与没有 id 的分类都不可翻页，
  /// 这里一并把状态收干净，避免残留上一个分类的游标。
  void _resetCategoryPagination({
    VodPageResult? page,
    VodCategory? category,
    required List<VodItem> items,
  }) {
    _categoryPageKey = _categoryPageKeyFor(category);
    _categoryLoadingMore = false;
    _categorySeenKeys
      ..clear()
      ..addAll(items.map(searchItemKey));
    if (page == null || category == null || category.id.isEmpty) {
      _categoryPage = 1;
      _categoryHasMore = false;
      return;
    }
    _categoryPage = page.page < 1 ? 1 : page.page;
    _categoryHasMore = _declaresMorePages(page, items.length);
  }

  /// 分类页取下一页并增量追加。
  Future<void> _loadMoreCategory() async {
    if (_isSearching || _isLoading || _categoryLoadingMore) return;
    if (!_categoryHasMore) return;
    final site = ref.read(configRepositoryProvider).selectedSite;
    if (site == null || isBuiltinSite(site)) return;
    final category = _selectedCategory;
    if (category == null || category.id.isEmpty) return;
    final pageKey = _categoryPageKey;
    if (pageKey == null || pageKey != _categoryPageKeyFor(category)) return;
    if (_categoryPage >= _maxCategoryPages) {
      setState(() => _categoryHasMore = false);
      return;
    }

    final generation = _contentGeneration;
    final identity = _currentSiteIdentity();
    final requested = _categoryPage + 1;
    final cancelToken = _renewCategoryCancelToken();
    setState(() => _categoryLoadingMore = true);
    try {
      final result = await ref.read(siteApiProvider).fetchCategory(site,
          categoryId: category.id,
          page: requested,
          extend: _filterExtendFor(category),
          cancelToken: cancelToken);
      if (!_acceptContent(generation, identity) || !mounted) return;
      // 等的时候用户可能已经切了分类：键不匹配就整批丢弃。
      if (pageKey != _categoryPageKeyFor(_selectedCategory)) return;

      final appended = <VodItem>[];
      appendUniqueSearchItems(appended, _categorySeenKeys, result.list);
      if (appended.isEmpty) {
        // 站源忽略了 pg（每页返回同一批）或确实没有下一页：就此收口，
        // 不再重试，否则每次触底都会白发一次请求。
        setState(() {
          _categoryPage = requested;
          _categoryLoadingMore = false;
          _categoryHasMore = false;
        });
        return;
      }
      final shown = _items.length + appended.length;
      setState(() {
        _items = [..._items, ...appended];
        _categoryPage = requested;
        _categoryLoadingMore = false;
        _categoryHasMore =
            requested < _maxCategoryPages && _declaresMorePages(result, shown);
      });
      // 一次翻页可能还是撑不满一屏，继续补。
      _maybeFillCategoryPage();
    } catch (_) {
      if (!_acceptContent(generation, identity) || !mounted) return;
      // 翻页失败不打断已看到的内容，只停掉这条翻页线。
      setState(() {
        _categoryLoadingMore = false;
        _categoryHasMore = false;
      });
    }
  }

  /// 分类页首屏没撑满一屏时自动续一页，否则用户连「滚到底」的机会都没有。
  void _maybeFillCategoryPage() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _isDoubanHome || _isSearching) return;
      if (!_categoryHasMore || _categoryLoadingMore) return;
      if (!_gridScrollController.hasClients) return;
      final position = _gridScrollController.position;
      if (position.maxScrollExtent <= position.viewportDimension * 0.15) {
        unawaited(_loadMoreCategory());
      }
    });
  }

  /// 加载当前站源数据：
  /// - 当 category 为 null 时：拉取该站源的首页信息动态填充分类滚动条，并默认选中第一个分类，展示该分类下的视频数据；
  /// - 当指定 category 时：拉取对应分类的视频数据并刷新瀑布流。
  Future<void> loadSiteData(
      {VodCategory? category,
      bool preserveCategories = false,
      bool forceRefresh = false}) async {
    // 冷启动直播入口期间推迟主视图加载，避免因页面偏好发起站源请求
    if (_startupLiveEntryPending) return;
    if (!mounted) return;
    _searchNotice = null;
    // 首次进入主视图时预热：这里能确保配置里的站点已经加载好
    //（provider 创建时配置可能还没进来，那时站点列表为空，预热会被整条跳过）。
    // 延后 3 秒再开始：低配机上 JVM 启动要 10~20 秒，别让它和首屏抢磁盘/CPU。
    _prewarmTimer?.cancel();
    _prewarmTimer = Timer(const Duration(seconds: 3), () {
      _prewarmTimer = null;
      if (!mounted) return;
      unawaited(ref.read(siteApiProvider).prewarmCompanionJars(
          ref.read(configRepositoryProvider).currentVodConfig.sites));
    });
    final site = ref.read(configRepositoryProvider).selectedSite;
    debugPrint('${site?.toJson()}'); // Map 直接打印
    final identity = _currentSiteIdentity();
    final changed = identity != _loadedSiteIdentity;
    _loadedSiteIdentity = identity;
    final generation = ++_contentGeneration;
    _cancelSearchStream();
    _syncFilterSelectionScope();
    final cancelToken = _renewCategoryCancelToken();
    if (site == null) {
      setState(() {
        _items = [];
        _categories = [];
        _siteFilters = const {};
        _selectedCategory = null;
        _isLoading = false;
        _isSearching = false;
        _searchSiteGroupKey = null;
        _errorMessage = null;
      });
      return;
    }
    if (changed) {
      _items = [];
      _siteFilters = const {};
    }

    // 内置「豆瓣热播」：走独立数据源，不碰 SiteApi（§17）
    if (isBuiltinSite(site)) {
      _siteFilters = const {};
      await _loadDouban(
          generation: generation,
          identity: identity,
          category: category,
          forceRefresh: forceRefresh);
      return;
    }

    // 格式化输出切换/加载站源的清晰调试信息
    // ignore: avoid_print
    print('\n================ [xiugou-tv 站源调试] ================');
    // ignore: avoid_print
    print(
        '[站源信息]: ${site.name} (Key: ${site.key}, Type: ${site.type}, Api: ${site.api})');
    // ignore: avoid_print
    print(
        '[当前操作]: ${category == null ? "获取站源首页推荐与动态分类" : "切换到分类: ${category.name} (ID: ${category.id})"}');
    // ignore: avoid_print
    print('===========================================================');

    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _isSearching = false;
      _searchSiteGroupKey = null;
      if (!preserveCategories && category == null) {
        _categories = [];
        _selectedCategory = null;
        _siteFilters = const {};
      }
    });

    try {
      final siteApi = ref.read(siteApiProvider);

      if (category == null) {
        // 请求站源首页，动态拉取该站源专属的分类列表
        final homeRes = await siteApi.fetchHome(site);
        if (!_acceptContent(generation, identity)) return;
        final fetchedCats = homeRes.categories;

        // ignore: avoid_print
        print(
            '--> [站源返回分类数]: ${fetchedCats.length} 个 -> [ ${fetchedCats.map((c) => "${c.name}(${c.id})").join(", ")} ]');

        if (fetchedCats.isNotEmpty) {
          final firstCat = fetchedCats.first;
          if (mounted) {
            setState(() {
              _categories = fetchedCats;
              _selectedCategory = firstCat;
              _siteFilters = homeRes.filters;
            });
          }

          // 默认加载站源第 1 个分类的数据
          if (firstCat.id.isNotEmpty) {
            // ignore: avoid_print
            print('--> 默认拉取第 1 个分类: ${firstCat.name} (ID: ${firstCat.id})');
            final extend = _filterExtendFor(firstCat);
            VodPageResult catRes;
            try {
              catRes = await siteApi.fetchCategory(site,
                  categoryId: firstCat.id,
                  extend: extend,
                  cancelToken: cancelToken);
            } catch (error) {
              // Home already succeeded: a failing first category must not wipe its recommendations.
              if (homeRes.list.isEmpty) rethrow;
              if (!_acceptContent(generation, identity)) return;
              showAppMessage('「${firstCat.name}」加载失败：$error',
                  type: AppMessageType.warning);
              catRes = const VodPageResult.empty();
            }
            if (!_acceptContent(generation, identity)) return;
            // ignore: avoid_print
            print('--> [第 1 分类视频数]: ${catRes.list.length} 部');
            // 空结果回退首页推荐只在无筛选时生效：带筛选的空结果是真空，要如实显示。
            final showCategory = catRes.list.isNotEmpty || extend.isNotEmpty;
            final itemsToShow = showCategory ? catRes.list : homeRes.list;
            if (mounted) {
              setState(() {
                _items = itemsToShow;
                _isLoading = false;
              });
            }
            // catRes 为空时 itemsToShow 实际是首页推荐，不是这个分类的数据；
            // 此时不能挂上分类游标，否则第 2 页会把分类结果接到首页推荐后面。
            _resetCategoryPagination(
                page: showCategory ? catRes : null,
                category: firstCat,
                items: itemsToShow);
            _maybeFillCategoryPage();
          } else {
            // ignore: avoid_print
            print('--> [首页推荐视频数]: ${homeRes.list.length} 部');
            if (mounted) {
              setState(() {
                _items = homeRes.list;
                _isLoading = false;
              });
            }
            _resetCategoryPagination(
                page: homeRes, category: firstCat, items: homeRes.list);
          }
        } else {
          // 站源未返回分类结构，展示首页推荐数据
          // ignore: avoid_print
          print('--> [首页推荐视频数]: ${homeRes.list.length} 部 (站源未声明独立分类)');
          if (mounted) {
            setState(() {
              _categories = [];
              _selectedCategory = null;
              _siteFilters = homeRes.filters;
              _items = homeRes.list;
              _isLoading = false;
            });
            _resetCategoryPagination(page: homeRes, items: homeRes.list);
          }
        }
      } else {
        // 用户手动切换点击某一分类
        setState(() {
          _selectedCategory = category;
        });

        VodPageResult catRes;
        if (category.id.isNotEmpty) {
          catRes = await siteApi.fetchCategory(site,
              categoryId: category.id,
              extend: _filterExtendFor(category),
              cancelToken: cancelToken);
        } else {
          catRes = await siteApi.fetchHome(site);
        }
        if (!_acceptContent(generation, identity)) return;
        // ignore: avoid_print
        print(
            '--> [分类切换成功]: ${category.name} (ID: ${category.id})，返回视频数: ${catRes.list.length} 部');

        if (mounted) {
          setState(() {
            _items = catRes.list;
            _isLoading = false;
          });
        }
        _resetCategoryPagination(
            page: catRes, category: category, items: catRes.list);
        _maybeFillCategoryPage();
      }
    } catch (e) {
      if (!_acceptContent(generation, identity)) return;
      final errorMsg = e is UnsupportedError
          ? (e.message?.toString() ?? e.toString())
          : '加载站点内容失败: $e';
      // ignore: avoid_print
      print('--> [站源数据加载失败]: '
          '${e is SpiderCallException ? '加载站点内容失败: ${e.diagnostic}' : errorMsg}');
      _categoryHasMore = false;
      _categoryLoadingMore = false;
      if (mounted) {
        setState(() {
          _errorMessage = errorMsg;
          _isLoading = false;
        });
      }
    }
  }

  /// 搜索：聚合开时逐站增量渲染（先完成先显示）；聚合关时仅检索当前站源（不受支持时明确提示且不发起请求）
  Future<void> _handleSearch(String keyword) async {
    final query = keyword.trim();
    if (query.isEmpty) {
      loadSiteData();
      return;
    }

    final settings = ref.read(settingsRepositoryProvider);
    final config = ref.read(configRepositoryProvider);
    final generation = ++_contentGeneration;
    final identity = _currentSiteIdentity();
    // 豆瓣首页本身不可检索：点片拿到的片名必须在已启用站源里聚合一圈（§17）
    final isAggregate = _isDoubanHome || settings.searchPreferences.aggregate;
    _cancelSearchStream();
    _cancelCategoryRequest();
    _searchSeenKeys.clear();
    _searchCompleted = 0;
    _searchTotal = 0;
    _searchFailed = 0;
    _firstSearchFailure = null;
    setState(() {
      // 聚合搜索不再整块转圈：结果区边到边显示，进度由站点栏尾部胶囊承担
      _isLoading = !isAggregate;
      _errorMessage = null;
      _searchNotice = null;
      _selectedCategory = null;
      _searchSiteGroupKey = null;
      _isSearching = true;
      _searchPending = isAggregate;
      _items = [];
    });

    try {
      final searchEngine = ref.read(searchEngineProvider);
      if (isAggregate) {
        final cancelToken = SearchCancelToken();
        _searchCancelToken = cancelToken;
        _listenToSearch(
          searchEngine.searchAllIncremental(
              config.currentVodConfig.sites, query,
              cancelToken: cancelToken),
          generation: generation,
          identity: identity,
        );
        return;
      }

      final site = config.selectedSite;
      if (site == null) {
        if (_acceptContent(generation, identity)) {
          setState(() {
            _items = [];
            _isLoading = false;
          });
        }
        return;
      }
      if (!searchEngine.supportsSearch(site)) {
        if (_acceptContent(generation, identity)) {
          setState(() {
            _items = [];
            _isLoading = false;
            _searchNotice = '当前站源不支持搜索，未发起检索';
          });
        }
        return;
      }
      final cancelToken = SearchCancelToken();
      _searchCancelToken = cancelToken;
      _listenToSearch(
        searchEngine
            .searchAllIncremental([site], query, cancelToken: cancelToken),
        generation: generation,
        identity: identity,
      );
    } catch (e) {
      if (_acceptContent(generation, identity)) {
        setState(() {
          _errorMessage = '聚合搜索失败: $e';
          _isLoading = false;
          _searchPending = false;
        });
      }
    }
  }

  /// 订阅增量搜索：每批去重后追加；迟到批次按代际 / 身份丢弃。
  void _listenToSearch(
    Stream<SearchBatch> stream, {
    required int generation,
    required String? identity,
  }) {
    _searchSub = stream.listen(
      (batch) {
        if (!_acceptContent(generation, identity)) return;
        final added = <VodItem>[];
        appendUniqueSearchItems(added, _searchSeenKeys, batch.items);
        setState(() {
          if (added.isNotEmpty) _items = [..._items, ...added];
          _searchCompleted = batch.completed;
          _searchTotal = batch.total;
          if (batch.error != null) {
            _searchFailed++;
            _firstSearchFailure ??= '${batch.site.name}：${batch.error}';
            _searchNotice = '$_searchFailed 个站点搜索失败；$_firstSearchFailure';
          }
        });
      },
      onError: (Object error) {
        if (!_acceptContent(generation, identity)) return;
        setState(() {
          if (_items.isEmpty) {
            _errorMessage = '聚合搜索失败: $error';
          } else {
            _searchNotice = '部分搜索失败: $error';
          }
          _searchPending = false;
          _isLoading = false;
        });
      },
      onDone: () {
        if (!_acceptContent(generation, identity)) return;
        setState(() {
          _searchPending = false;
          _isLoading = false;
          if (_searchCompleted > 0 && _searchFailed == _searchCompleted) {
            _errorMessage = '搜索失败：$_firstSearchFailure';
          } else if (_searchFailed > 0 && _items.isEmpty) {
            _searchNotice =
                '其余站点无匹配，$_searchFailed 个站点搜索失败；$_firstSearchFailure';
          }
        });
        _searchSub = null;
      },
    );
  }

  Future<void> _onItemClicked(VodItem item) async {
    // 豆瓣首页是导航层：点片不进详情，直接拿片名去已启用站源全局搜索（§17）
    if (_isDoubanHome && !_isSearching) {
      final keyword = DoubanRepository.searchKeyword(item.name);
      _searchController.text = keyword;
      FocusScope.of(context).unfocus();
      await _handleSearch(keyword);
      return;
    }
    final repo = ref.read(configRepositoryProvider);
    // 优先使用条目自带的 siteKey (跨站聚合搜索条目)，其次回退为当前选定站源
    Site? targetSite;
    if (item.siteKey != null && item.siteKey!.isNotEmpty) {
      final matches =
          repo.currentVodConfig.sites.where((s) => s.key == item.siteKey);
      if (matches.isNotEmpty) {
        targetSite = matches.first;
      }
    }
    targetSite ??= repo.selectedSite;
    if (targetSite == null) return;

    // FongMi 语义：带 action 的条目（配置中心的扫码 / 填 cookie 设置项）不进详情，
    // 由站源自己弹窗处理，窗口经 SpiderDialogHost 呈现。
    final action = item.action;
    if (action != null) {
      await _runSiteAction(targetSite, action);
      return;
    }

    final clickedAt = DateTime.now();
    final navigator = Navigator.of(context, rootNavigator: true);
    final loadingRoute = DialogRoute<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => Center(
        child: CircularProgressIndicator(color: context.palette.accentInk),
      ),
    );
    unawaited(navigator.push(loadingRoute));

    void closeLoading() {
      // 站源可能已在加载窗口之上弹出扫码窗，只移除本次请求自己的路由。
      if (loadingRoute.isActive) navigator.removeRoute(loadingRoute);
    }

    try {
      final siteApi = ref.read(siteApiProvider);
      final detail = await siteApi.fetchDetail(targetSite, vodId: item.id);
      closeLoading();
      if (!mounted) return;
      // 无播放线路的返回值也可能带标题；源弹窗接管时不再用占位详情遮挡它。
      if (targetSite.usesCompanion &&
          (detail == null || detail.sources.isEmpty) &&
          await _awaitSiteDialogSince(clickedAt)) {
        return;
      }
      if (!mounted) return;
      if (detail == null ||
          (detail.item.name.isEmpty && detail.sources.isEmpty)) {
        showAppMessage('获取详情失败: 详情为空', type: AppMessageType.error);
        return;
      }
      _showDetailDialog(detail, targetSite);
    } catch (e) {
      closeLoading();
      if (!mounted) return;
      if (e is SpiderCallException &&
          (e.stage == 'empty' || e.stage == 'interaction') &&
          await _awaitSiteDialogSince(clickedAt)) {
        return;
      }
      if (!mounted) return;
      showAppMessage('获取详情失败: $e', type: AppMessageType.error);
    } finally {
      closeLoading();
    }
  }

  /// 触发站源动作；载荷返回带 msg 的结果时直接提示（弹窗类结果由 SpiderDialogHost 呈现）。
  Future<void> _runSiteAction(Site site, String action) async {
    try {
      final raw = await ref.read(siteApiProvider).performAction(site, action);
      final msg = _actionMessage(raw);
      if (mounted && msg != null) showAppMessage(msg);
    } catch (e) {
      if (mounted) showAppMessage('站源操作失败: $e', type: AppMessageType.error);
    }
  }

  static String? _actionMessage(String raw) {
    if (raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final msg = '${decoded['msg'] ?? decoded['toast'] ?? ''}'.trim();
        return msg.isEmpty ? null : msg;
      }
    } on FormatException {
      // 非 JSON 的纯文本结果按原样提示
      return raw.trim();
    }
    return null;
  }

  /// [since] 之后是否有载荷弹窗出现。弹窗事件经合并与长轮询才到达，可能晚于 RPC 响应，
  /// 所以最多再等 [wait]。
  Future<bool> _awaitSiteDialogSince(DateTime since,
      {Duration wait = const Duration(milliseconds: 800)}) async {
    final channel = ref.read(companionUiChannelProvider);
    final deadline = DateTime.now().add(wait);
    while (true) {
      final shownAt = channel.lastDialogShownAt;
      if (shownAt != null && !shownAt.isBefore(since)) return true;
      if (DateTime.now().isAfter(deadline)) return false;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  /// 统一打开「详情 / 选集」弹窗。
  ///
  /// 同时记住起播来源：用户从选集里点某一集后，弹窗会先关闭、进入播放器；
  /// 退出播放器时应回到这个弹窗继续选集，而不是掉回首页。
  void _showDetailDialog(VodDetail detail, Site? site) {
    _showDetailDialogWithCurrentEpisode(
      detail,
      site,
      currentEpisodeForDetail(
        // 关播后会话已清空：优先用保留副本，同站同片才命中。
        session: _lastPlayedSession ?? ref.read(activePlaybackSessionProvider),
        vodId: detail.item.id,
        siteKey: site?.key,
      ),
    );
  }

  /// 打开弹窗并**显式**指定当前集：`null` 即零高亮，不再回落推断。
  void _showDetailDialogWithCurrentEpisode(
      VodDetail detail, Site? site, CurrentEpisode? currentEpisode) {
    final repo = ref.read(configRepositoryProvider);
    showDialog<void>(
      context: context,
      builder: (_) => VodDetailDialog(
        detail: detail,
        isFavorite: repo.isFavorite(detail.item.id),
        currentEpisode: currentEpisode,
        onOpenUrl: ref.read(installerLauncherProvider).openUrl,
        onToggleFavorite: () async {
          try {
            await repo.toggleFavorite(detail.item);
            return null;
          } on DataRestorePendingRestartException catch (error) {
            return error.message;
          } catch (_) {
            return '收藏保存失败，请稍后重试';
          }
        },
        onPlayEpisode: (selection) {
          _playbackOriginDetail = detail;
          _playbackOriginSite = site;
          unawaited(
              _startPlayEpisode(detail.item, selection, targetSite: site));
        },
      ),
    );
  }

  /// 播放器退出后恢复「选集弹窗」。只对「从详情弹窗起播」的会话生效；
  /// 从历史/直播等入口起播时来源为空，行为与以前一致（回主视图）。
  Future<void> _restorePlaybackOriginDetail() async {
    final detail = _playbackOriginDetail;
    if (detail == null || _restoringDetailDialog) return;
    final site = _playbackOriginSite;
    _playbackOriginDetail = null;
    _playbackOriginSite = null;
    _restoringDetailDialog = true;
    try {
      // 等播放器层先完成一次重建，避免与「隐藏播放器」抢同一帧
      await Future<void>.delayed(Duration.zero);
      if (!mounted) return;
      _showDetailDialog(detail, site);
    } finally {
      _restoringDetailDialog = false;
    }
  }

  /// 详情页选集播放（薄封装）：立意图 → 解析 → 启动，见 [startEpisodePlaybackWithIntent]。
  /// 管线与播放内切集共用（顶层 `_startEpisodePlayback` / `_switchEpisode`）。
  Future<void> _startPlayEpisode(VodItem item, EpisodeSelection selection,
          {Site? targetSite}) =>
      startEpisodePlaybackWithIntent(ref, item, selection,
          targetSite: targetSite);

  /// 续播时重新解析选集；Spider 失败明确报错，CMS 保留历史直链兜底。
  /// 历史续播用：拉取影片详情（失败 / 超时返回 null，不打断旧兜底路径）。
  Future<VodDetail?> _loadDetailForHistory(
      HistoryRecord record, Site site) async {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => Center(
        child: CircularProgressIndicator(color: context.palette.accentInk),
      ),
    );
    try {
      return await ref
          .read(siteApiProvider)
          .fetchDetail(site, vodId: record.vodId)
          .timeout(const Duration(seconds: 20));
    } catch (_) {
      return null;
    } finally {
      if (mounted) Navigator.of(context).pop();
    }
  }

  /// 历史续播用：在详情里定位「记录里的那一条线路 + 那一集」。
  ///
  /// 优先按线路名匹配；线路改名了就找包含该集（直链优先、集名兜底）的线路；
  /// 都没有返回 null（调用方退回单集直链续播）。
  EpisodeSelection? _locateHistorySelection(
      VodDetail detail, HistoryRecord record) {
    if (detail.sources.isEmpty) return null;
    var sourceIndex =
        detail.sources.indexWhere((s) => s.name == record.sourceName);
    if (sourceIndex < 0) {
      bool hasEpisode(PlayFrom source) => source.episodes.any((e) =>
          (record.episodeUrl.isNotEmpty && e.url == record.episodeUrl) ||
          e.name == record.episodeName);
      sourceIndex = detail.sources.indexWhere(hasEpisode);
    }
    if (sourceIndex < 0) return null;
    final source = detail.sources[sourceIndex];
    var episodeIndex = record.episodeUrl.isEmpty
        ? -1
        : source.episodes.indexWhere((e) => e.url == record.episodeUrl);
    if (episodeIndex < 0) {
      episodeIndex =
          source.episodes.indexWhere((e) => e.name == record.episodeName);
    }
    if (episodeIndex < 0) return null;
    return EpisodeSelection(
      episode: source.episodes[episodeIndex],
      sourceName: source.name,
      episodes: source.episodes,
      index: episodeIndex,
      sources: detail.sources,
      sourceIndex: sourceIndex,
    );
  }

  Future<void> _resumeHistoryRecord(HistoryRecord record) async {
    final repo = ref.read(configRepositoryProvider);
    Site? site;
    if (record.siteKey != null && record.siteKey!.isNotEmpty) {
      final matches =
          repo.currentVodConfig.sites.where((s) => s.key == record.siteKey);
      if (matches.isNotEmpty) site = matches.first;
    }

    if (site == null &&
        record.episodeUrl.isNotEmpty &&
        !(Uri.tryParse(record.episodeUrl)?.hasScheme ?? false)) {
      showAppMessage('原站源已不可用，请重新导入配置后续播', type: AppMessageType.error);
      return;
    }

    // 先按「详情 + 选集」续播：历史记录只存了单集信息，走直链会没有播放会话——
    // 播放页没有上一集 / 下一集 / 选集抽屉，退出后也回不到详情页（2026-10-22 反馈）。
    // 详情拿不到（站源已删 / 只剩直链）时再退回下面的单集直链续播。
    if (site != null && record.vodId.isNotEmpty) {
      final detail = await _loadDetailForHistory(record, site);
      if (!mounted) return;
      if (detail != null) {
        final selection = _locateHistorySelection(detail, record);
        if (selection != null) {
          // 退出播放器后回到「选集详情」而不是首页。
          _playbackOriginDetail = detail;
          _playbackOriginSite = site;
          await startEpisodePlaybackWithIntent(
            ref,
            detail.item,
            selection,
            targetSite: site,
          );
          return;
        }
      }
    }
    _playbackOriginDetail = null;
    _playbackOriginSite = null;

    var playUrl = record.playUrl;
    Map<String, String>? headers;
    if (record.episodeUrl.isNotEmpty) {
      try {
        final resolved = await ref.read(siteApiProvider).resolvePlayback(
              site,
              id: record.episodeUrl,
              flag: record.sourceName,
              parses: repo.currentVodConfig.parses,
              parseEngine: ref.read(parseEngineProvider),
            );
        if (resolved.url.isNotEmpty) {
          playUrl = resolved.url;
          headers = resolved.headers;
        }
      } catch (e) {
        if (site?.usesCompanion ?? false) {
          if (mounted) {
            showAppMessage(playResolveFailureText(e),
                type: AppMessageType.error);
          }
          return;
        }
      }
    }
    if (!mounted) return;
    if (playUrl.isEmpty) {
      if (mounted) {
        showAppMessage('该记录缺少可用播放地址，无法续播', type: AppMessageType.error);
      }
      return;
    }

    final playSpec = MediaPlaySpec(
      url: playUrl,
      headers: headers ?? site?.header,
      title: '${record.vodName} - ${record.episodeName} (${record.sourceName})',
      startPosition: record.resumePosition,
    );

    // 置顶并刷新最近观看时间与最新直链，进度原样保留
    unawaited(
      repo.addHistory(
        record.copyWith(
          playUrl: playUrl,
          timestamp: DateTime.now().millisecondsSinceEpoch,
        ),
      ),
    );

    // 历史续播不建立剧集会话；作废旧会话与自动换线状态，避免旧候选抢播放。
    _playbackSessionEpoch++;
    ref.read(activePlaybackSessionProvider.notifier).state = null;
    ref.read(autoLineSwitchProvider).disarm();
    await _launchPlayback(ref, playSpec, historyRecordId: record.id);
  }

  // --- 左侧 4 大核心功能弹窗 ---

  void _showHistoryDialog() {
    final repo = ref.read(configRepositoryProvider);

    showDialog(
      context: context,
      // 经 Consumer 监听 historyProvider：删除 / 清空 / 进度更新后弹窗内容实时刷新
      builder: (_) => Consumer(
        builder: (_, dialogRef, __) => HistoryDialog(
          records: dialogRef.watch(historyProvider),
          onPlayRecord: _resumeHistoryRecord,
          onDeleteRecord: (id) => repo.removeHistory(id),
          onClearAll: () => repo.clearHistory(),
          incognito: repo.historyIncognito,
        ),
      ),
    );
  }

  void _recordStartupEntry(StartupEntry entry) {
    unawaited(ref.read(settingsRepositoryProvider).recordLastEntry(entry));
  }

  Future<void> _showLiveDialog() async {
    final repo = ref.read(configRepositoryProvider);
    final sourceUrl = repo.currentWindowConfig.lastConfigUrl;

    _livePlaybackStartedInDialog = false;
    _recordStartupEntry(StartupEntry.live);
    await showDialog<void>(
      context: context,
      builder: (_) => Consumer(
        builder: (_, dialogRef, __) {
          final fav = _liveFavoriteActions(dialogRef);
          return LiveChannelsDialog(
            lives: dialogRef.watch(vodConfigProvider).lives,
            repository: dialogRef.watch(liveRepositoryProvider),
            epgRepository: dialogRef.watch(epgRepositoryProvider),
            baseUri: sourceUrl == null ? null : Uri.tryParse(sourceUrl),
            favoritedKeys: fav.keys,
            onToggleFavorite: fav.toggle,
            // 「播放直链」的自动识别开关 / 浏览器头回退跟随设置（D2）
            autoDetectDirectMode: dialogRef
                .read(settingsRepositoryProvider)
                .playerSettings
                .autoDetectLiveDirectMode,
            browserHeaderFallbacks: dialogRef
                .read(settingsRepositoryProvider)
                .playerSettings
                .browserHeaders,
            onPlayLive: (live) {
              _livePlaybackStartedInDialog = true;
              unawaited(_playLiveFromDialog(ref, live));
            },
          );
        },
      ),
    );
    if (!mounted) return;
    // 未启动频道播放的关闭视为回到点播主入口
    if (!_livePlaybackStartedInDialog) _recordStartupEntry(StartupEntry.vod);
    // 冷启动直播入口结束后，恢复被推迟的主视图加载
    if (_startupLiveEntryPending) {
      _startupLiveEntryPending = false;
      loadSiteData();
    }
  }

  /// ⑤-2 直播入口：加载频道 → 按「上次频道」解析起播位 → 直接起播。
  /// 没有任何可用频道时回退到频道管理弹窗（内含导入与空态行动）。
  /// 冷启动直播入口与本页点按共用同一路径。
  Future<void> _enterLive() async {
    if (_liveEntryBusy) return;
    _liveFavoriteGeneration++;
    _liveEntryBusy = true;
    final loading = ref.read(liveEntryLoadingProvider.notifier);
    bool cancelled() => ref.read(liveEntryLoadingProvider) != true;
    // ⑤ 修复「先卡后跳」：点击立即进入播放页（加载态），频道加载与起播都在
    // 页面内进行；Esc / 返回可中途退出，迟到的起播结果作废（cancelled）。
    loading.state = true;
    try {
      _recordStartupEntry(StartupEntry.live);
      final configRepo = ref.read(configRepositoryProvider);
      final sourceUrl = configRepo.currentWindowConfig.lastConfigUrl;
      final lives = ref.read(vodConfigProvider).lives;
      final liveRepository = ref.read(liveRepositoryProvider);
      List<Live> channels;
      try {
        channels = (await liveRepository.load(lives,
                baseUri: sourceUrl == null ? null : Uri.tryParse(sourceUrl)))
            .channels;
      } catch (_) {
        channels = const [];
      }
      if (!mounted || cancelled()) return;
      if (channels.isEmpty) {
        // 没有任何可用频道：撤下加载页，回到既有的管理弹窗。
        loading.state = false;
        await _showLiveDialog();
        return;
      }
      final lastKey = await liveRepository.loadLastChannelKey();
      if (!mounted || cancelled()) return;
      await _startLiveChannel(
          ref, channels, resolveLiveBookmark(channels, lastKey),
          isStale: cancelled);
    } finally {
      if (!cancelled()) loading.state = false;
      _liveEntryBusy = false;
    }
  }

  void _showPushDialog() {
    showDialog(
      context: context,
      builder: (_) => PushStreamDialog(
        onPlayPush: (spec) {
          _playbackSessionEpoch++;
          _playPreparationEpoch++;
          ref.read(playbackSourceChangeProvider)?.cancelToken.cancel();
          ref.read(pendingPlayProvider.notifier).state = null;
          ref.read(playbackIntentProvider.notifier).state = null;
          return _launchPlayback(ref, spec);
        },
      ),
    );
  }

  Future<void> _playLiveFavorite(Live favorite) async {
    if (!mounted) return;
    final generation = ++_liveFavoriteGeneration;
    final epoch = _playbackSessionEpoch;
    final repo = ref.read(configRepositoryProvider);
    final config = repo.currentVodConfig;
    final siteKey = repo.selectedSite?.key;
    bool staleContext() => !mounted ||
        generation != _liveFavoriteGeneration ||
        !identical(config, repo.currentVodConfig) ||
        siteKey != repo.selectedSite?.key;

    final favorites = repo.liveFavorites;
    var channels = favorites;
    var index = favorites.indexWhere((channel) => channel.key == favorite.key);
    var lineIndex = 0;
    if (index < 0) {
      channels = [favorite];
      index = 0;
    }
    if (!favorite.isScripted && (favorite.scriptKey?.isEmpty ?? true)) {
      try {
        final sourceUrl = repo.currentWindowConfig.lastConfigUrl;
        final catalog = await ref.read(liveRepositoryProvider).load(
          config.lives,
          baseUri: sourceUrl == null ? null : Uri.tryParse(sourceUrl),
        );
        final match = catalog.channels.indexWhere((channel) =>
            !channel.isScripted && (channel.scriptKey?.isEmpty ?? true) &&
            channel.matchesKey(favorite.key));
        if (match >= 0) {
          channels = catalog.channels;
          index = match;
          final line = channels[index].lines.indexWhere(
              (line) => line.url == favorite.url);
          lineIndex = line < 0 ? 0 : line;
        }
      } catch (_) {
        // invariant: 当前目录不可用时，收藏快照仍可独立播放。
      }
    }
    if (staleContext() || epoch != _playbackSessionEpoch) return;
    await _startLiveChannel(ref, channels, index,
        lineIndex: lineIndex, isStale: staleContext);
  }

  void _showFavoritesDialog() {
    final repo = ref.read(configRepositoryProvider);
    final favoritesList = ref.read(favoritesProvider);

    showDialog(
      context: context,
      builder: (_) => FavoritesDialog(
        items: favoritesList,
        onItemTap: (item) => _onItemClicked(item),
        onRemoveItem: (id) async {
          try {
            await repo.removeFavorite(id);
            return null;
          } on DataRestorePendingRestartException catch (error) {
            return error.message;
          } catch (_) {
            return '收藏保存失败，请稍后重试';
          }
        },
        // §33：直播收藏是另一份数据（List<Live>），单独传入；
        // 为空时弹窗仍然显示分栏，让用户知道这里是「有但还没收藏」。
        liveItems: repo.liveFavorites,
        onLiveTap: (channel) => unawaited(_playLiveFavorite(channel)),
        onRemoveLiveItem: (key) async {
          try {
            await repo.removeLiveFavorite(key);
            return null;
          } on DataRestorePendingRestartException catch (error) {
            return error.message;
          } catch (_) {
            return '收藏保存失败，请稍后重试';
          }
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    ref.listen<Site?>(currentSiteProvider, (_, __) => _synchronizeSite());
    ref.listen<VodConfig>(vodConfigProvider, (_, __) => _synchronizeSite());
    // §15：保留最近一次播放会话，供关播后 / 重新打开详情时判定当前集。
    ref.listen<PlaybackSession?>(activePlaybackSessionProvider, (_, next) {
      if (next != null) _lastPlayedSession = next;
    });
    // 设置「分类页筛选条默认展开」一改，丢掉页面上的临时展开 / 收起，按新默认显示。
    ref.listen<AsyncValue<SearchPreferences>>(searchPreferencesProvider,
        (previous, next) {
      final before = previous?.valueOrNull?.filterBarExpanded;
      final after = next.valueOrNull?.filterBarExpanded;
      if (before != null && after != null && before != after) {
        setState(() => _filterBarExpandedOverride = null);
      }
    });
    ref.listen<MediaPlaySpec?>(activePlaySpecProvider, (previous, next) {
      // 播放器关闭（返回主视图）：「上次入口」回到点播
      if (previous != null && next == null) {
        _recordStartupEntry(StartupEntry.vod);
        _restorePlaybackOriginDetail();
        // ⑤-2 冷启动直播直连：离开播放器后恢复被推迟的主视图加载
        if (_startupLiveEntryPending) {
          _startupLiveEntryPending = false;
          loadSiteData();
        }
      }
    });

    final config = ref.watch(vodConfigProvider);
    final searchPrefs = ref.watch(searchPreferencesProvider).valueOrNull ??
        const SearchPreferences();
    _syncSearchBridge();

    // 搜索态：由结果本地派生站点分组与筛选；非搜索态保持原分类内容。
    final searchSiteGroups = _isSearching
        ? groupSearchResultsBySite(_items)
        : const <SearchSiteGroup>[];
    final activeSearchSiteKey = _isSearching &&
            _searchSiteGroupKey != null &&
            searchSiteGroups.any((group) => group.key == _searchSiteGroupKey)
        ? _searchSiteGroupKey
        : null;
    final visibleItems = _isSearching
        ? filterSearchResultsBySite(_items, activeSearchSiteKey)
        : _items;
    // 分类筛选（待办第 20 条）：搜索态与豆瓣首页不显示。
    final currentFilters = _isSearching || _isDoubanHome
        ? const <VodFilter>[]
        : _filtersFor(_selectedCategory);
    final currentFilterSelection = currentFilters.isEmpty
        ? const <String, String>{}
        : _filterExtendFor(_selectedCategory);
    final hasActiveFilterOnEmpty =
        !_isSearching && currentFilterSelection.isNotEmpty;
    // 筛选条默认收起（设置可改）；页面上点过开关后，本次运行内按点过的结果。
    final filterBarExpanded =
        _filterBarExpandedOverride ?? searchPrefs.filterBarExpanded;

    if (config.sites.isEmpty && config.lives.isEmpty) {
      return Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 460),
          padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 32),
          decoration: BoxDecoration(
            color: context.palette.panel,
            borderRadius: BorderRadius.circular(AppRadii.lg),
            border: Border.all(color: context.glassBorder, width: 1.0),
            boxShadow: AppShadows.subtleDepth(),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 84,
                height: 84,
                decoration: BoxDecoration(
                  color: context.palette.accentWash,
                  borderRadius: BorderRadius.circular(AppRadii.pill),
                  border: Border.all(
                    color: context.palette.accentInk.withValues(alpha: 0.35),
                    width: 1.2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: context.palette.accentInk.withValues(alpha: 0.15),
                      blurRadius: 16,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Icon(Icons.tv_rounded,
                    size: 42, color: context.palette.accentInk),
              ),
              const SizedBox(height: 18),
              Text(
                '修狗TV',
                style: TextStyle(
                  fontSize: AppType.h1,
                  fontWeight: FontWeight.bold,
                  color: context.palette.textTitle,
                  letterSpacing: 0.8,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '尚未加载影视配置，请添加 TVBox 影视配置订阅源',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: AppType.body,
                  color: context.palette.textSub,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: context.palette.accent,
                  // 品牌底上必须显式前景 onPrimary：M3 默认前景是 primary=品牌色，会同色不可见
                  foregroundColor: Theme.of(context).colorScheme.onPrimary,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 26, vertical: 13),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadii.pill)),
                  elevation: 2,
                  shadowColor: context.palette.accentInk.withValues(alpha: 0.3),
                ),
                icon: const Icon(Icons.settings_outlined, size: 18),
                label: const Text('立即配置影视源',
                    style: TextStyle(
                        fontSize: AppType.title, fontWeight: FontWeight.bold)),
                onPressed: () {
                  showConfigDialog(context, ref);
                },
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: context.glassBorder, width: 1.0),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(AppRadii.pill)),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 10),
                    ),
                    onPressed: _enterLive,
                    icon: const Icon(Icons.live_tv_outlined, size: 16),
                    label: const Text('打开电视直播',
                        style: TextStyle(fontSize: AppType.caption)),
                  ),
                  const SizedBox(width: 10),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: context.glassBorder, width: 1.0),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(AppRadii.pill)),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 10),
                    ),
                    onPressed: _showPushDialog,
                    icon: const Icon(Icons.send_outlined, size: 16),
                    label: const Text('打开直链推送',
                        style: TextStyle(fontSize: AppType.caption)),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ==================== 左侧导航面板 (历史 / 直播 / 推送 / 收藏 / 设置) ====================
          DesktopSidebar(
            onHistoryTap: _showHistoryDialog,
            onLiveTap: _enterLive,
            onPushTap: _showPushDialog,
            onFavoritesTap: _showFavoritesDialog,
            onSettingsTap: () => openSettingsPage(ref),
          ),

          const SizedBox(width: 14),

          // ==================== 右侧主内容区域 ====================
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 原全宽大搜索栏已全面迁移至顶部标题栏 (Netflix 风格紧凑栏)，主内容区直接呈现内容

                // 2. 搜索态：命中站点胶囊（站点名 + 数量）；否则：站源动态分类滚动条
                if (_isSearching) ...[
                  if (!_isLoading &&
                      _errorMessage == null &&
                      (searchSiteGroups.isNotEmpty || _searchPending)) ...[
                    SearchSiteBar(
                      key: ValueKey('search-sites-$_contentGeneration'),
                      groups: searchSiteGroups,
                      totalCount: _items.length,
                      selectedKey: activeSearchSiteKey,
                      onSelected: (key) =>
                          setState(() => _searchSiteGroupKey = key),
                      progress: _searchPending
                          ? _SearchProgressPill(
                              completed: _searchCompleted, total: _searchTotal)
                          : null,
                    ),
                    const SizedBox(height: 10),
                  ],
                ] else if (_categories.isNotEmpty) ...[
                  if (!_isDoubanHome ||
                      _isSearching ||
                      _doubanViewingSingleCategory) ...[
                    Row(
                      children: [
                        Expanded(
                          child: Container(
                            height: 38,
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            // 分类多时鼠标滚轮 / 按住拖动都能横向滚动（§41）。
                            child: HorizontalScrollArea(
                              controller: _categoryScrollController,
                              child: ListView.separated(
                                key: const ValueKey('category-bar'),
                                controller: _categoryScrollController,
                                scrollDirection: Axis.horizontal,
                                itemCount: _categories.length +
                                    (_isDoubanHome &&
                                            _doubanViewingSingleCategory
                                        ? 1
                                        : 0),
                                separatorBuilder: (_, __) =>
                                    const SizedBox(width: 8),
                                itemBuilder: (context, index) {
                                  if (_isDoubanHome &&
                                      _doubanViewingSingleCategory) {
                                    if (index == 0) {
                                      return FilterPill(
                                        label: '◀ 返回推荐大厅',
                                        isSelected: false,
                                        onTap: () {
                                          setState(() {
                                            _doubanViewingSingleCategory =
                                                false;
                                          });
                                        },
                                      );
                                    }
                                    index -= 1;
                                  }
                                  final cat = _categories[index];
                                  final isSelected =
                                      _selectedCategory?.id == cat.id;

                                  return FilterPill(
                                    label: cat.name,
                                    isSelected: isSelected,
                                    onTap: () {
                                      _searchController.clear();
                                      loadSiteData(
                                          category: cat,
                                          preserveCategories: true);
                                    },
                                  );
                                },
                              ),
                            ),
                          ),
                        ),
                        // 当前分类声明了筛选时，分类条右侧给折叠开关（待办第 20 条）。
                        if (currentFilters.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          CategoryFilterToggle(
                            filters: currentFilters,
                            selection: currentFilterSelection,
                            expanded: filterBarExpanded,
                            onToggle: () => setState(() =>
                                _filterBarExpandedOverride = !filterBarExpanded),
                          ),
                        ],
                      ],
                    ),
                    // 筛选行固定在网格上方、不随网格滚动；无筛选或收起时整块不渲染。
                    if (currentFilters.isNotEmpty && filterBarExpanded) ...[
                      const SizedBox(height: 6),
                      CategoryFilterBar(
                        filters: currentFilters,
                        selection: currentFilterSelection,
                        onChanged: _onFilterChanged,
                      ),
                    ],
                    const SizedBox(height: 10),
                  ],
                ],

                if (_isSearching && _items.isNotEmpty && _searchNotice != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(children: [
                      Expanded(
                          child: Text(_searchNotice!,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: AppType.caption,
                                  color: palette.danger))),
                      TextButton(
                          onPressed: _searchBusy
                              ? null
                              : () => _handleSearch(_searchController.text),
                          child: const Text('重试')),
                    ]),
                  ),

                // 豆瓣单一分类网格提示：明确「点片=搜索」，避免被当成进豆瓣详情（§17）
                if (_isDoubanHome &&
                    !_isSearching &&
                    _doubanViewingSingleCategory) ...[
                  Padding(
                    padding: const EdgeInsets.only(left: 2, bottom: 8),
                    child: Text(
                      '点海报即在已启用站源里搜索该片，不进豆瓣详情',
                      style: TextStyle(
                          fontSize: AppType.caption,
                          color: context.palette.textSub),
                    ),
                  ),
                ],

                // 3. 影视海报瀑布流网格容器 (已按要求彻底删除 '豆瓣电影排行' 副标题，直接显示分类内容)
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: context.palette.panel,
                      borderRadius: BorderRadius.circular(AppRadii.lg),
                      border:
                          Border.all(color: context.glassBorder, width: 1.0),
                      boxShadow: AppShadows.subtleDepth(),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: _isLoading
                        // B2 首屏加载：首页 / 分类用海报骨架（与真网格同布局，
                        // 加载完成不跳变）；搜索加载为整块等待（B3：带文案解释）。
                        ? (_isSearching
                            ? Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    CircularProgressIndicator(
                                        color: context.palette.accentInk),
                                    const SizedBox(height: 12),
                                    // 等待要有解释（skill: Loading Indicators；B3）
                                    Text('正在搜索…',
                                        style: TextStyle(
                                            fontSize: AppType.body,
                                            color: context.palette.textSub)),
                                  ],
                                ),
                              )
                            : const VodGridSkeleton())
                        : _errorMessage != null
                            ? Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Container(
                                      width: 64,
                                      height: 64,
                                      decoration: BoxDecoration(
                                        color: palette.danger
                                            .withValues(alpha: 0.12),
                                        borderRadius: BorderRadius.circular(
                                            AppRadii.pill),
                                        border: Border.all(
                                          color: palette.danger
                                              .withValues(alpha: 0.35),
                                          width: 1.0,
                                        ),
                                      ),
                                      child: Icon(Icons.error_outline_rounded,
                                          size: 32, color: palette.danger),
                                    ),
                                    const SizedBox(height: 14),
                                    Text(_errorMessage!,
                                        style: TextStyle(
                                            color: palette.danger,
                                            fontSize: AppType.label,
                                            fontWeight: FontWeight.w500)),
                                    const SizedBox(height: 18),
                                    ElevatedButton.icon(
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: palette.accent,
                                        foregroundColor: Theme.of(context)
                                            .colorScheme
                                            .onPrimary,
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 22, vertical: 10),
                                        shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(
                                                AppRadii.pill)),
                                      ),
                                      icon: const Icon(Icons.refresh_rounded,
                                          size: 16),
                                      label: const Text('重试',
                                          style: TextStyle(
                                              fontSize: AppType.body,
                                              fontWeight: FontWeight.bold)),
                                      onPressed: () => _isSearching
                                          ? _handleSearch(
                                              _searchController.text)
                                          : loadSiteData(
                                              category: _selectedCategory,
                                              preserveCategories: true),
                                    ),
                                  ],
                                ),
                              )
                            : visibleItems.isEmpty
                                ? Center(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Container(
                                          width: 72,
                                          height: 72,
                                          decoration: BoxDecoration(
                                            color: palette.raised,
                                            borderRadius: BorderRadius.circular(
                                                AppRadii.pill),
                                            border: Border.all(
                                                color: context.glassBorder,
                                                width: 1.0),
                                            boxShadow: AppShadows.subtleDepth(),
                                          ),
                                          child: Icon(
                                            _isSearching
                                                ? Icons.search_off_rounded
                                                : Icons.inbox_rounded,
                                            size: 36,
                                            color: palette.accentInk,
                                          ),
                                        ),
                                        const SizedBox(height: 16),
                                        Text(
                                          _searchNotice ??
                                              (_isSearching
                                                  ? (_searchPending
                                                      ? (activeSearchSiteKey !=
                                                              null
                                                          ? '正在搜索…（该站点暂无结果）'
                                                          : '正在搜索…（已返回 0 条）')
                                                      : (searchPrefs.aggregate
                                                          ? '未找到相关聚合搜索结果'
                                                          : '未找到相关搜索结果'))
                                                  : (currentFilterSelection
                                                          .isNotEmpty
                                                      ? '当前筛选条件下暂无内容'
                                                      : '当前分类下暂无内容')),
                                          style: TextStyle(
                                              color: palette.textTitle,
                                              fontSize: AppType.label,
                                              fontWeight: FontWeight.w600),
                                        ),
                                        // 搜索 0 结果时给弱建议（skill: No Results；B3）
                                        if (_isSearching &&
                                            !_searchPending &&
                                            _searchNotice == null) ...[
                                          const SizedBox(height: 6),
                                          Text('可尝试更换关键词，或切换站源',
                                              style: TextStyle(
                                                  fontSize: AppType.caption,
                                                  color: palette.textSub)),
                                        ],
                                        const SizedBox(height: 18),
                                        // B2 空态行动化（skill: Empty States：说明 + 行动）
                                        ElevatedButton.icon(
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: palette.accent,
                                            foregroundColor: Theme.of(context)
                                                .colorScheme
                                                .onPrimary,
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 20, vertical: 10),
                                            shape: RoundedRectangleBorder(
                                                borderRadius:
                                                    BorderRadius.circular(
                                                        AppRadii.pill)),
                                          ),
                                          icon: Icon(
                                            _isSearching ||
                                                    hasActiveFilterOnEmpty
                                                ? Icons.clear_rounded
                                                : Icons.refresh_rounded,
                                            size: 16,
                                          ),
                                          label: Text(
                                            _isSearching
                                                ? '清空搜索'
                                                : hasActiveFilterOnEmpty
                                                    ? '清除筛选'
                                                    : '刷新',
                                            style: const TextStyle(
                                                fontSize: AppType.body,
                                                fontWeight: FontWeight.bold),
                                          ),
                                          onPressed: _isSearching
                                              ? _clearSearchToHome
                                              : hasActiveFilterOnEmpty
                                                  ? () => _onFilterChanged(
                                                      const {})
                                                  : () => loadSiteData(
                                                      category:
                                                          _selectedCategory,
                                                      preserveCategories: true),
                                        ),
                                      ],
                                    ),
                                  )
                                : (_isSearching &&
                                        searchPrefs.display ==
                                            SearchDisplay.list)
                                    ? VodListView(
                                        items: visibleItems,
                                        onItemTap: _onItemClicked,
                                      )
                                    : (_isDoubanHome &&
                                            !_isSearching &&
                                            !_doubanViewingSingleCategory)
                                        ? NetflixHomeView(
                                            scrollController:
                                                _gridScrollController,
                                            onScrollNotification: _onGridScroll,
                                            categoryItemsMap:
                                                _doubanCategoryItems,
                                            categories: _categories,
                                            isLoading: _isLoading,
                                            onItemTap: _onItemClicked,
                                            onCategoryTap: (category) {
                                              setState(() {
                                                _doubanViewingSingleCategory =
                                                    true;
                                                _selectedCategory = category;
                                                _items = _doubanCategoryItems[
                                                        category.id] ??
                                                    [];
                                              });
                                              loadSiteData(
                                                  category: category,
                                                  preserveCategories: true);
                                            },
                                            stillUrlFor: (item) => ref
                                                .read(doubanRepositoryProvider)
                                                .stillUrlFor(item.id),
                                            imageProviderFor: (item, spec) {
                                              // 站源海报可能带 `@Referer=…` 尾巴：
                                              // 先拆出真实地址再判豆瓣图床
                                              final pic =
                                                  PosterSource.parse(item.pic)
                                                      .url;
                                              if (!DoubanRepository
                                                  .isDoubanPoster(pic)) {
                                                return null;
                                              }
                                              // 巨幅位优先横版剧照（16:9）；
                                              // 拉不到时 urlOverride 为空，
                                              // 回落竖版原图（现状口径）。
                                              final url = spec.urlOverride ??
                                                  (spec.highRes
                                                      ? DoubanRepository
                                                          .highResPosterUrl(pic)
                                                      : pic);
                                              return DoubanPosterImage(
                                                url,
                                                fallbackUrl:
                                                    spec.highRes ? pic : null,
                                                targetWidth: spec.targetWidth,
                                              );
                                            },
                                          )
                                        : Stack(
                                            children: [
                                              // §19 无限滚动：滚动通知从内部 GridView
                                              // 冒泡上来，接近底部时续页
                                              NotificationListener<
                                                  ScrollNotification>(
                                                onNotification: _onGridScroll,
                                                child: VodGridView(
                                                  items: visibleItems,
                                                  onItemTap: _onItemClicked,
                                                  controller:
                                                      _gridScrollController,
                                                  // 统一海报入口：豆瓣图床自己发请求
                                                  // （NetworkImage 的 headers.add 会叠两条
                                                  // UA → 403，§17）；站源 `@头` 尾巴拆开带上
                                                  imageProviderFor: (item) =>
                                                      posterImageProvider(
                                                          item.pic,
                                                          targetWidth: 512),
                                                ),
                                              ),
                                              if (_doubanLoadingMore &&
                                                  _isDoubanHome &&
                                                  !_isSearching)
                                                Positioned(
                                                  left: 0,
                                                  right: 0,
                                                  bottom: 14,
                                                  child: Center(
                                                    child: Container(
                                                      padding: const EdgeInsets
                                                          .symmetric(
                                                          horizontal: 14,
                                                          vertical: 8),
                                                      decoration: BoxDecoration(
                                                        color: context
                                                            .palette.raised
                                                            .withValues(
                                                                alpha: 0.92),
                                                        borderRadius:
                                                            BorderRadius
                                                                .circular(
                                                                    AppRadii
                                                                        .pill),
                                                        border: Border.all(
                                                            color: context
                                                                .palette
                                                                .border),
                                                      ),
                                                      child: Row(
                                                        mainAxisSize:
                                                            MainAxisSize.min,
                                                        children: [
                                                          SizedBox(
                                                            width: 12,
                                                            height: 12,
                                                            child:
                                                                CircularProgressIndicator(
                                                              strokeWidth: 2,
                                                              color: context
                                                                  .palette
                                                                  .accentInk,
                                                            ),
                                                          ),
                                                          const SizedBox(
                                                              width: 8),
                                                          Text(
                                                            '正在加载更多…',
                                                            style: TextStyle(
                                                              fontSize: AppType
                                                                  .caption,
                                                              color: context
                                                                  .palette
                                                                  .textSub,
                                                            ),
                                                          ),
                                                        ],
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                            ],
                                          ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 筛选胶囊按钮 [ xxx ] / [ xxx 3 ]（Infuse × Netflix 风格流媒体药丸）
///
/// 站源分类栏与搜索结果站点栏共用；[count] 非空时在名称右侧显示数量徽标。
/// 搜索进行中的尾部进度胶囊（不可点，完成后自动消失）
class _SearchProgressPill extends StatelessWidget {
  const _SearchProgressPill({required this.completed, required this.total});

  final int completed;
  final int total;

  @override
  Widget build(BuildContext context) {
    final label = total > 0 ? '搜索中 $completed/$total' : '搜索中…';
    final palette = context.palette;

    return Container(
      key: const ValueKey('search-progress-pill'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
      decoration: BoxDecoration(
        color: palette.card,
        borderRadius: BorderRadius.circular(AppRadii.pill),
        border: Border.all(
          color: palette.accentInk.withValues(alpha: 0.35),
          width: 1,
        ),
      ),
      alignment: Alignment.center,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: palette.accentInk,
              // 有总数时给确定性进度（skill: Progress Indicators）；无总数保持动画
              value: total > 0 ? (completed / total).clamp(0.0, 1.0) : null,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(
              fontSize: AppType.caption,
              fontWeight: FontWeight.w600,
              color: palette.accentInk,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
