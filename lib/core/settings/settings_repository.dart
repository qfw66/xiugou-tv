import 'dart:async';
import '../config/config_repository.dart';
import '../player/models/player_settings.dart';
import 'models/config_source_entry.dart';
import 'models/appearance_preferences.dart';
import 'models/history_preferences.dart';
import 'models/play_skip_preferences.dart';
import 'models/search_preferences.dart';
import 'models/self_check_preferences.dart';
import 'models/startup_preferences.dart';
import 'settings_storage.dart';

enum SettingsSaveTarget { player, sources, startup, search, history, selfCheck, playSkip, appearance }

/// 磁盘保存状态，与内存值及播放器参数应用结果相互独立。
class SettingsSaveState {
  final bool isSaving;
  final Set<SettingsSaveTarget> failedTargets;
  const SettingsSaveState({this.isSaving = false, this.failedTargets = const {}});
  bool get hasFailure => failedTargets.isNotEmpty;
}

/// 设置中心仓库：播放器首选项与配置源历史的内存状态、广播与串行落盘
class SettingsRepository {
  /// 配置源历史最多保留条数
  static const int maxConfigSources = 30;

  final SettingsStorage _storage;
  final int Function() _now;

  PlayerSettings _playerSettings = PlayerSettings.defaults;
  List<ConfigSourceEntry> _configSources = const [];
  StartupPreferences _startupPreferences = const StartupPreferences();
  bool _startupReadFailed = false;
  SearchPreferences _searchPreferences = const SearchPreferences();
  bool _searchReadFailed = false;
  HistoryPreferences _historyPreferences = const HistoryPreferences();
  bool _historyReadFailed = false;
  SelfCheckPreferences _selfCheckPreferences = const SelfCheckPreferences();
  bool _selfCheckReadFailed = false;
  PlaySkipPreferences _playSkipPreferences = const PlaySkipPreferences();
  bool _playSkipReadFailed = false;
  Future<void> _playSkipSaveChain = Future.value();
  AppearancePreferences _appearancePreferences = AppearancePreferences.none;
  bool _appearanceReadFailed = false;
  Future<void> _appearanceSaveChain = Future.value();

  final _playerSettingsController = StreamController<PlayerSettings>.broadcast();
  final _configSourcesController = StreamController<List<ConfigSourceEntry>>.broadcast();
  final _startupPreferencesController = StreamController<StartupPreferences>.broadcast();
  final _searchPreferencesController = StreamController<SearchPreferences>.broadcast();
  final _historyPreferencesController = StreamController<HistoryPreferences>.broadcast();
  final _selfCheckPreferencesController = StreamController<SelfCheckPreferences>.broadcast();
  final _playSkipPreferencesController = StreamController<PlaySkipPreferences>.broadcast();
  final _appearancePreferencesController = StreamController<AppearancePreferences>.broadcast();

  final _saveStateController = StreamController<SettingsSaveState>.broadcast();
  final _failedSaves = <SettingsSaveTarget>{};
  int _pendingSaves = 0;
  bool _disposed = false;

  SettingsSaveState get saveState => SettingsSaveState(
    isSaving: _pendingSaves > 0,
    failedTargets: Set.unmodifiable(_failedSaves),
  );

  Stream<SettingsSaveState> get saveStateStream async* {
    yield saveState;
    yield* _saveStateController.stream;
  }

  void _notifySaveState() {
    if (!_disposed) _saveStateController.add(saveState);
  }

  Future<void> _enqueueSave(SettingsSaveTarget target, Future<void> previous,
      Future<void> Function() save) {
    _pendingSaves++;
    _notifySaveState();
    return previous.catchError((_) {}).then((_) async {
      try {
        await save();
        _failedSaves.remove(target);
      } catch (_) {
        _failedSaves.add(target);
        rethrow;
      } finally {
        _pendingSaves--;
        _notifySaveState();
      }
    });
  }

  /// 重试当前失败文件的最新内存快照，不重放旧的失败参数。
  Future<void> retryFailedSaves() async {
    if (_pendingSaves > 0) return;
    final failed = Set.of(_failedSaves);
    await Future.wait([
      if (failed.contains(SettingsSaveTarget.player)) _persistPlayer(),
      if (failed.contains(SettingsSaveTarget.sources)) _persistSources(),
      if (failed.contains(SettingsSaveTarget.startup)) _persistStartupPreferences(),
      if (failed.contains(SettingsSaveTarget.search)) _persistSearchPreferences(),
      if (failed.contains(SettingsSaveTarget.history)) _persistHistoryPreferences(),
      if (failed.contains(SettingsSaveTarget.selfCheck)) _persistSelfCheckPreferences(),
      if (failed.contains(SettingsSaveTarget.playSkip)) _persistPlaySkipPreferences(),
      if (failed.contains(SettingsSaveTarget.appearance)) _persistAppearancePreferences(),
    ]);
  }

  Future<void> _playerSaveChain = Future<void>.value();
  Future<void> _sourcesSaveChain = Future<void>.value();
  Future<void> _startupPreferencesSaveChain = Future<void>.value();
  Future<void> _searchPreferencesSaveChain = Future<void>.value();
  Future<void> _historyPreferencesSaveChain = Future<void>.value();
  Future<void> _selfCheckPreferencesSaveChain = Future<void>.value();

  SettingsRepository({SettingsStorage? storage, int Function()? clock})
      : _storage = storage ?? SettingsStorage.windows(),
        _now = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  PlayerSettings get playerSettings => _playerSettings;
  List<ConfigSourceEntry> get configSources => _configSources;

  Stream<PlayerSettings> get playerSettingsStream async* {
    yield _playerSettings;
    yield* _playerSettingsController.stream;
  }

  Stream<List<ConfigSourceEntry>> get configSourcesStream async* {
    yield _configSources;
    yield* _configSourcesController.stream;
  }

  StartupPreferences get startupPreferences => _startupPreferences;

  /// 启动偏好文件读取失败（结构损坏等）；修复文件前禁止覆盖写入
  bool get startupReadFailed => _startupReadFailed;

  /// 本次启动解析出的有效主入口
  StartupEntry get effectiveStartupEntry => _startupPreferences.effectiveEntry;

  Stream<StartupPreferences> get startupPreferencesStream async* {
    yield _startupPreferences;
    yield* _startupPreferencesController.stream;
  }

  SearchPreferences get searchPreferences => _searchPreferences;

  /// 搜索偏好文件读取失败（结构损坏等）；修复文件前禁止覆盖写入
  bool get searchReadFailed => _searchReadFailed;

  Stream<SearchPreferences> get searchPreferencesStream async* {
    yield _searchPreferences;
    yield* _searchPreferencesController.stream;
  }

  HistoryPreferences get historyPreferences => _historyPreferences;

  /// 历史偏好文件读取失败（结构损坏等）；修复文件前禁止覆盖写入
  bool get historyReadFailed => _historyReadFailed;

  Stream<HistoryPreferences> get historyPreferencesStream async* {
    yield _historyPreferences;
    yield* _historyPreferencesController.stream;
  }

  SelfCheckPreferences get selfCheckPreferences => _selfCheckPreferences;

  /// 自检偏好文件读取失败（结构损坏等）；修复文件前禁止覆盖写入
  bool get selfCheckReadFailed => _selfCheckReadFailed;

  Stream<SelfCheckPreferences> get selfCheckPreferencesStream async* {
    yield _selfCheckPreferences;
    yield* _selfCheckPreferencesController.stream;
  }

  PlaySkipPreferences get playSkipPreferences => _playSkipPreferences;

  /// 片头片尾偏好文件读取失败（结构损坏等）；修复文件前禁止覆盖写入
  bool get playSkipReadFailed => _playSkipReadFailed;

  Stream<PlaySkipPreferences> get playSkipPreferencesStream async* {
    yield _playSkipPreferences;
    yield* _playSkipPreferencesController.stream;
  }

  AppearancePreferences get appearancePreferences => _appearancePreferences;

  /// 外观偏好文件读取失败（结构损坏等）；修复文件前禁止覆盖写入
  bool get appearanceReadFailed => _appearanceReadFailed;

  Stream<AppearancePreferences> get appearancePreferencesStream async* {
    yield _appearancePreferences;
    yield* _appearancePreferencesController.stream;
  }

  /// 从磁盘恢复设置。
  ///
  /// 首次运行（设置文件尚不存在）时：
  /// - 播放器解码方式从旧版窗口配置 [legacyHwdec] 迁移；
  /// - 配置源历史以当前订阅地址 [legacyConfigUrl] 作为首条。
  Future<void> initialize({String? legacyHwdec, String? legacyConfigUrl}) async {
    final storedPlayer = await _storage.readPlayerSettings();
    _playerSettings = storedPlayer ??
        PlayerSettings.defaults.copyWith(hwdec: PlayerSettings.normalizeHwdec(legacyHwdec));
    _playerSettingsController.add(_playerSettings);

    final storedSources = await _storage.readConfigSources();
    if (storedSources != null) {
      _configSources = List.unmodifiable(_dedupe(storedSources).take(maxConfigSources));
    } else if (legacyConfigUrl != null && legacyConfigUrl.trim().isNotEmpty) {
      _configSources = List.unmodifiable([
        ConfigSourceEntry(kind: ConfigSourceKind.url, location: legacyConfigUrl.trim(), lastUsedAt: _now()),
      ]);
      unawaited(_persistSources().catchError((_) {}));
    }
    _configSourcesController.add(_configSources);

    try {
      _startupPreferences = await _storage.readStartupPreferences() ?? const StartupPreferences();
      _startupReadFailed = false;
    } catch (_) {
      // 结构损坏：保留原文件，按默认运行，等待修复后重新读取
      _startupPreferences = const StartupPreferences();
      _startupReadFailed = true;
    }
    _startupPreferencesController.add(_startupPreferences);

    try {
      _searchPreferences = await _storage.readSearchPreferences() ?? const SearchPreferences();
      _searchReadFailed = false;
    } catch (_) {
      // 结构损坏：保留原文件，按默认运行，等待修复后重新读取
      _searchPreferences = const SearchPreferences();
      _searchReadFailed = true;
    }
    _searchPreferencesController.add(_searchPreferences);

    try {
      _historyPreferences = await _storage.readHistoryPreferences() ?? const HistoryPreferences();
      _historyReadFailed = false;
    } catch (_) {
      // 结构损坏：保留原文件，按默认运行，等待修复后重新读取
      _historyPreferences = const HistoryPreferences();
      _historyReadFailed = true;
    }
    _historyPreferencesController.add(_historyPreferences);

    try {
      _selfCheckPreferences = await _storage.readSelfCheckPreferences() ?? const SelfCheckPreferences();
      _selfCheckReadFailed = false;
    } catch (_) {
      // 结构损坏：保留原文件，按默认（关闭）运行，等待修复后重新读取
      _selfCheckPreferences = const SelfCheckPreferences();
      _selfCheckReadFailed = true;
    }
    _selfCheckPreferencesController.add(_selfCheckPreferences);

    try {
      _playSkipPreferences = await _storage.readPlaySkipPreferences() ?? const PlaySkipPreferences();
      _playSkipReadFailed = false;
    } catch (_) {
      // 结构损坏：保留原文件，按默认（开启、无记录）运行，等待修复后重新读取
      _playSkipPreferences = const PlaySkipPreferences();
      _playSkipReadFailed = true;
    }
    _playSkipPreferencesController.add(_playSkipPreferences);

    try {
      _appearancePreferences = await _storage.readAppearancePreferences() ??
          AppearancePreferences.none;
      _appearanceReadFailed = false;
    } catch (_) {
      // 结构损坏：保留原文件，按默认外观运行，等待修复后重新读取
      _appearancePreferences = AppearancePreferences.none;
      _appearanceReadFailed = true;
    }
    _appearancePreferencesController.add(_appearancePreferences);
  }

  List<ConfigSourceEntry> _dedupe(List<ConfigSourceEntry> entries) {
    final seen = <String>{};
    return [for (final e in entries) if (seen.add(e.location)) e];
  }

  // ---------------- 播放器设置 ----------------

  /// 更新播放器设置（先规范化再广播，随后串行落盘）
  Future<void> updatePlayerSettings(PlayerSettings settings) async {
    final normalized = settings.normalized();
    if (normalized == _playerSettings) return;
    _playerSettings = normalized;
    _playerSettingsController.add(normalized);
    await _persistPlayer();
  }

  Future<void> resetPlayerSettings() => updatePlayerSettings(PlayerSettings.defaults);

  Future<void> _persistPlayer() {
    final snapshot = _playerSettings;
    final next = _enqueueSave(SettingsSaveTarget.player, _playerSaveChain,
        () => _storage.savePlayerSettings(snapshot));
    _playerSaveChain = next;
    return next;
  }

  // ---------------- 配置源历史 ----------------

  /// 记录一次成功加载：同地址条目更新并置顶（保留自定义名称），超出上限淘汰最旧条目
  Future<void> recordConfigLoad(ConfigLoadEvent event) async {
    final location = event.location.trim();
    if (location.isEmpty) return;

    ConfigSourceEntry? existing;
    for (final e in _configSources) {
      if (e.location == location) existing = e;
    }
    final updated = (existing ?? ConfigSourceEntry(kind: event.kind, location: location)).copyWith(
      lastUsedAt: _now(),
      siteCount: event.siteCount,
      liveCount: event.liveCount,
    );
    _publishSources([
      updated,
      ..._configSources.where((e) => e.location != location),
    ].take(maxConfigSources).toList());
    await _persistSources();
  }

  Future<void> renameConfigSource(String location, String name) async {
    final index = _configSources.indexWhere((e) => e.location == location);
    if (index < 0) return;
    final list = List<ConfigSourceEntry>.from(_configSources);
    list[index] = list[index].copyWith(name: name.trim());
    _publishSources(list);
    await _persistSources();
  }

  /// 从历史中移除（不影响当前已加载的配置，也不删除本地文件）
  Future<void> removeConfigSource(String location) async {
    if (!_configSources.any((e) => e.location == location)) return;
    _publishSources(_configSources.where((e) => e.location != location).toList());
    await _persistSources();
  }

  void _publishSources(List<ConfigSourceEntry> list) {
    _configSources = List.unmodifiable(list);
    _configSourcesController.add(_configSources);
  }

  Future<void> _persistSources() {
    final snapshot = _configSources;
    final next = _enqueueSave(SettingsSaveTarget.sources, _sourcesSaveChain,
        () => _storage.saveConfigSources(snapshot));
    _sourcesSaveChain = next;
    return next;
  }

  // ---------------- 启动偏好（下次进入页面 / 上次入口） ----------------

  /// 更新「下次进入页面」偏好（先归一化再广播，随后串行落盘）。
  ///
  /// 以传入快照整体替换当前偏好；调用方应基于 [startupPreferences] 构造，避免丢弃「上次入口」记录。
  Future<void> updateStartupPreferences(StartupPreferences preferences) async {
    if (_startupReadFailed) {
      throw StateError('启动偏好读取失败，请先修复文件并重新读取');
    }
    final normalized = preferences.normalized();
    if (normalized == _startupPreferences) return;
    _startupPreferences = normalized;
    _startupPreferencesController.add(normalized);
    await _persistStartupPreferences();
  }

  /// 记录「上次入口」；仅接受点播 / 直播。
  ///
  /// 与偏好保存共用串行写链，但写入失败保持静默（不进入失败横幅、不抛出）；
  /// 成功写入后磁盘已含最新快照，会清除该目标此前残留的失败标记；
  /// 后续任意成功写入都会落盘包含最新记录的快照。
  Future<void> recordLastEntry(StartupEntry entry) async {
    if (_startupReadFailed) return;
    if (entry != StartupEntry.vod && entry != StartupEntry.live) return;
    if (_startupPreferences.lastEntry == entry) return;
    _startupPreferences = _startupPreferences.copyWith(lastEntry: entry);
    _startupPreferencesController.add(_startupPreferences);
    final snapshot = _startupPreferences;
    _startupPreferencesSaveChain = _startupPreferencesSaveChain
        .catchError((_) {})
        .then((_) async {
          await _storage.saveStartupPreferences(snapshot);
          // 该快照包含此前全部内存修改：写入成功即磁盘与内存一致，清除残留失败标记
          if (_failedSaves.remove(SettingsSaveTarget.startup)) {
            _notifySaveState();
          }
        })
        .catchError((_) {});
    await _startupPreferencesSaveChain;
  }

  /// 重新读取启动偏好（读取失败修复后的恢复入口）。
  ///
  /// 成功时以磁盘内容整体替换内存；失败保持原文件与失败状态。
  Future<void> reloadStartupPreferences() async {
    if (_failedSaves.contains(SettingsSaveTarget.startup)) {
      throw StateError('请先重试保存启动偏好，避免丢失本次修改');
    }
    try {
      _startupPreferences = await _storage.readStartupPreferences() ?? const StartupPreferences();
      _startupReadFailed = false;
    } catch (_) {
      _startupReadFailed = true;
    }
    _startupPreferencesController.add(_startupPreferences);
  }

  Future<void> _persistStartupPreferences() {
    final snapshot = _startupPreferences;
    final next = _enqueueSave(SettingsSaveTarget.startup, _startupPreferencesSaveChain,
        () => _storage.saveStartupPreferences(snapshot));
    _startupPreferencesSaveChain = next;
    return next;
  }

  // ---------------- 搜索偏好（显示方式 / 聚合开关） ----------------

  /// 更新搜索偏好（整体快照替换，随后串行落盘）。
  ///
  /// 调用方应基于 [searchPreferences] 构造，避免丢弃另一字段。
  Future<void> updateSearchPreferences(SearchPreferences preferences) async {
    if (_searchReadFailed) {
      throw StateError('搜索偏好读取失败，请先修复文件并重新读取');
    }
    if (preferences == _searchPreferences) return;
    _searchPreferences = preferences;
    _searchPreferencesController.add(preferences);
    await _persistSearchPreferences();
  }

  /// 重新读取搜索偏好（读取失败修复后的恢复入口）。
  ///
  /// 成功时以磁盘内容整体替换内存；失败保持原文件与失败状态。
  Future<void> reloadSearchPreferences() async {
    if (_failedSaves.contains(SettingsSaveTarget.search)) {
      throw StateError('请先重试保存搜索偏好，避免丢失本次修改');
    }
    try {
      _searchPreferences = await _storage.readSearchPreferences() ?? const SearchPreferences();
      _searchReadFailed = false;
    } catch (_) {
      _searchReadFailed = true;
    }
    _searchPreferencesController.add(_searchPreferences);
  }

  Future<void> _persistSearchPreferences() {
    final snapshot = _searchPreferences;
    final next = _enqueueSave(SettingsSaveTarget.search, _searchPreferencesSaveChain,
        () => _storage.saveSearchPreferences(snapshot));
    _searchPreferencesSaveChain = next;
    return next;
  }

  // ---------------- 历史记录数量偏好（播放历史上限） ----------------

  /// 更新历史记录数量偏好（整体快照替换，随后串行落盘）。
  ///
  /// 调用方在保存成功后应将新上限同步到 `ConfigRepository`（设置页负责触发立即裁剪）。
  Future<void> updateHistoryPreferences(HistoryPreferences preferences) async {
    if (_historyReadFailed) {
      throw StateError('历史偏好读取失败，请先修复文件并重新读取');
    }
    if (preferences == _historyPreferences) return;
    _historyPreferences = preferences;
    _historyPreferencesController.add(preferences);
    await _persistHistoryPreferences();
  }

  /// 重新读取历史偏好（读取失败修复后的恢复入口）。
  ///
  /// 成功时以磁盘内容整体替换内存；失败保持原文件与失败状态。
  Future<void> reloadHistoryPreferences() async {
    if (_failedSaves.contains(SettingsSaveTarget.history)) {
      throw StateError('请先重试保存历史偏好，避免丢失本次修改');
    }
    try {
      _historyPreferences = await _storage.readHistoryPreferences() ?? const HistoryPreferences();
      _historyReadFailed = false;
    } catch (_) {
      _historyReadFailed = true;
    }
    _historyPreferencesController.add(_historyPreferences);
  }

  Future<void> _persistHistoryPreferences() {
    final snapshot = _historyPreferences;
    final next = _enqueueSave(SettingsSaveTarget.history, _historyPreferencesSaveChain,
        () => _storage.saveHistoryPreferences(snapshot));
    _historyPreferencesSaveChain = next;
    return next;
  }

  // ---------------- 站点自检偏好（体检总开关） ----------------

  /// 更新站点自检偏好（整体快照替换，随后串行落盘）。
  ///
  /// 落盘成功后由调用方把新状态同步给伴随服务（见设置页的开关处理），
  /// 本方法只负责内存状态与磁盘一致性。
  Future<void> updateSelfCheckPreferences(SelfCheckPreferences preferences) async {
    if (_selfCheckReadFailed) {
      throw StateError('自检偏好读取失败，请先修复文件并重新读取');
    }
    if (preferences == _selfCheckPreferences) return;
    _selfCheckPreferences = preferences;
    _selfCheckPreferencesController.add(preferences);
    await _persistSelfCheckPreferences();
  }

  /// 重新读取自检偏好（读取失败修复后的恢复入口）。
  ///
  /// 成功时以磁盘内容整体替换内存；失败保持原文件与失败状态。
  Future<void> reloadSelfCheckPreferences() async {
    if (_failedSaves.contains(SettingsSaveTarget.selfCheck)) {
      throw StateError('请先重试保存自检偏好，避免丢失本次修改');
    }
    try {
      _selfCheckPreferences = await _storage.readSelfCheckPreferences() ?? const SelfCheckPreferences();
      _selfCheckReadFailed = false;
    } catch (_) {
      _selfCheckReadFailed = true;
    }
    _selfCheckPreferencesController.add(_selfCheckPreferences);
  }

  Future<void> _persistSelfCheckPreferences() {
    final snapshot = _selfCheckPreferences;
    final next = _enqueueSave(SettingsSaveTarget.selfCheck, _selfCheckPreferencesSaveChain,
        () => _storage.saveSelfCheckPreferences(snapshot));
    _selfCheckPreferencesSaveChain = next;
    return next;
  }

  // ---------------- 片头 / 片尾偏好 ----------------

  /// 更新片头片尾偏好（整体快照替换，随后串行落盘）。
  ///
  /// 保存失败会抛给调用方（播放器内面板负责提示与重试），内存值保持最新。
  Future<void> updatePlaySkipPreferences(PlaySkipPreferences preferences) async {
    if (_playSkipReadFailed) {
      throw StateError('片头片尾偏好读取失败，请先修复文件并重新读取');
    }
    _playSkipPreferences = preferences;
    _playSkipPreferencesController.add(preferences);
    await _persistPlaySkipPreferences();
  }

  /// 重新读取片头片尾偏好（读取失败修复后的恢复入口）。
  Future<void> reloadPlaySkipPreferences() async {
    if (_failedSaves.contains(SettingsSaveTarget.playSkip)) {
      throw StateError('请先重试保存片头片尾偏好，避免丢失本次修改');
    }
    try {
      _playSkipPreferences =
          await _storage.readPlaySkipPreferences() ?? const PlaySkipPreferences();
      _playSkipReadFailed = false;
    } catch (_) {
      _playSkipReadFailed = true;
    }
    _playSkipPreferencesController.add(_playSkipPreferences);
  }

  Future<void> _persistPlaySkipPreferences() {
    final snapshot = _playSkipPreferences;
    final next = _enqueueSave(SettingsSaveTarget.playSkip, _playSkipSaveChain,
        () => _storage.savePlaySkipPreferences(snapshot));
    _playSkipSaveChain = next;
    return next;
  }

  // ---------------- 外观偏好（SET-08：壁纸） ----------------

  /// 更新外观偏好（整体快照替换，随后串行落盘）。
  ///
  /// 保存失败会抛给调用方（设置页「外观」分区负责提示 / 横幅重试），内存值保持最新。
  Future<void> updateAppearancePreferences(
      AppearancePreferences preferences) async {
    if (_appearanceReadFailed) {
      throw StateError('外观偏好读取失败，请先修复文件并重新读取');
    }
    _appearancePreferences = preferences;
    _appearancePreferencesController.add(preferences);
    await _persistAppearancePreferences();
  }

  /// 重新读取外观偏好（读取失败修复后的恢复入口）。
  Future<void> reloadAppearancePreferences() async {
    if (_failedSaves.contains(SettingsSaveTarget.appearance)) {
      throw StateError('请先重试保存外观偏好，避免丢失本次修改');
    }
    try {
      _appearancePreferences = await _storage.readAppearancePreferences() ??
          AppearancePreferences.none;
      _appearanceReadFailed = false;
    } catch (_) {
      _appearanceReadFailed = true;
    }
    _appearancePreferencesController.add(_appearancePreferences);
  }

  Future<void> _persistAppearancePreferences() {
    final snapshot = _appearancePreferences;
    final next = _enqueueSave(SettingsSaveTarget.appearance,
        _appearanceSaveChain, () => _storage.saveAppearancePreferences(snapshot));
    _appearanceSaveChain = next;
    return next;
  }

  /// 订阅配置仓库的成功加载事件并记入历史；返回的订阅由调用方负责取消
  StreamSubscription<ConfigLoadEvent> bindConfigRepository(ConfigRepository repository) {
    return repository.configLoadedStream.listen((event) {
      unawaited(recordConfigLoad(event).catchError((_) {}));
    });
  }

  /// 等待当前排队的设置写入落定（SET-10 备份前一致性快照）。
  Future<void> flushPendingWrites() async {
    await Future.wait([
      _playerSaveChain.catchError((_) {}),
      _sourcesSaveChain.catchError((_) {}),
      _startupPreferencesSaveChain.catchError((_) {}),
      _searchPreferencesSaveChain.catchError((_) {}),
      _historyPreferencesSaveChain.catchError((_) {}),
      _selfCheckPreferencesSaveChain.catchError((_) {}),
      _playSkipSaveChain.catchError((_) {}),
      _appearanceSaveChain.catchError((_) {}),
    ]);
  }

  Future<void> dispose() async {
    _disposed = true;
    await Future.wait([
      _playerSaveChain.catchError((_) {}),
      _sourcesSaveChain.catchError((_) {}),
      _startupPreferencesSaveChain.catchError((_) {}),
      _searchPreferencesSaveChain.catchError((_) {}),
      _historyPreferencesSaveChain.catchError((_) {}),
      _selfCheckPreferencesSaveChain.catchError((_) {}),
      _playSkipSaveChain.catchError((_) {}),
      _appearanceSaveChain.catchError((_) {}),
    ]);
    await _playSkipPreferencesController.close();
    await _appearancePreferencesController.close();
    await _saveStateController.close();
    await _playerSettingsController.close();
    await _configSourcesController.close();
    // 关闭启动 / 搜索偏好广播为尽力而为，不等待完成：其完成时机依赖事件循环，
    // 不承载额外的资源释放语义，等待会拖住仓库释放。
    unawaited(_startupPreferencesController.close());
    unawaited(_searchPreferencesController.close());
    unawaited(_historyPreferencesController.close());
    unawaited(_selfCheckPreferencesController.close());
  }
}
