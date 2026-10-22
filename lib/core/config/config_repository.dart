import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import '../api/models/vod_models.dart';
import '../history/history_match.dart';
import '../net/ascii_url.dart';
import '../net/relative_url.dart';
import 'config_decoder.dart';
import 'models/desktop_window_config.dart';
import 'models/builtin_sites.dart';
import 'models/config_snapshot.dart';
import 'models/history_record.dart';
import 'models/home_site_preference.dart';
import 'models/vod_config.dart';
import 'windows_config_storage.dart';
import '../storage/data_restore_guard.dart';

export 'models/config_snapshot.dart' show ConfigSourceKind;

/// 多仓（Depot）条目：一个命名订阅地址
class DepotEntry {
  final String name;
  final String url;

  const DepotEntry({required this.name, required this.url});
}

/// 多仓选择回调：请用户从清单中选择条目，返回下标；返回 null 表示取消
typedef DepotSelector = Future<int?> Function(List<DepotEntry> entries);

/// 用户取消多仓选择时抛出的信号
class DepotSelectionCancelled implements Exception {
  const DepotSelectionCancelled();

  @override
  String toString() => '已取消多仓选择';
}

/// 更晚的主动加载已经取代本次请求。
class ConfigLoadSuperseded implements Exception {
  const ConfigLoadSuperseded();

  @override
  String toString() => '配置加载已被更新的选择取代';
}

class _ResolvedConfig {
  final String rawContent;
  final List<String> depotPath;

  const _ResolvedConfig(this.rawContent, this.depotPath);
}

/// 一次成功加载配置的事件（供配置源历史记录使用）
class ConfigLoadEvent {
  final ConfigSourceKind kind;

  /// 远程地址（原始输入）或本地文件绝对路径
  final String location;
  final int siteCount;
  final int liveCount;

  const ConfigLoadEvent({
    required this.kind,
    required this.location,
    required this.siteCount,
    required this.liveCount,
  });
}

/// 配置源连通性测试结果类型
enum ConfigProbeKind { vodConfig, depot, cmsList, invalid, unreachable }

/// 配置源连通性测试结果（只读探测，不改变当前配置）
class ConfigProbeResult {
  final ConfigProbeKind kind;
  final Duration latency;

  /// 站点数 / 多仓条目数 / CMS 接口数
  final int count;
  final int liveCount;
  final String message;

  const ConfigProbeResult({
    required this.kind,
    required this.latency,
    this.count = 0,
    this.liveCount = 0,
    required this.message,
  });

  bool get ok => kind != ConfigProbeKind.invalid && kind != ConfigProbeKind.unreachable;
}

/// 全局配置仓库：负责远程与本地配置加载、持久化及状态发布
class ConfigRepository {
  final WindowsConfigStorage _storage;
  final Dio _dio;

  /// 多仓最大追踪层数（防御循环引用导致的无限递归）
  static const int _maxDepotDepth = 8;

  /// 播放历史默认保留条数（与 HistoryPreferences.defaultLimit 同值；
  /// 应用启动时由设置同步为偏好值，见 SET-05）
  static const int defaultHistoryLimit = 150;

  VodConfig _currentVodConfig = VodConfig.empty();
  DesktopWindowConfig _currentWindowConfig = const DesktopWindowConfig();
  Site? _selectedSite;
  ConfigSourceKind? _currentSourceKind;
  String? _currentSourceLocation;
  ConfigSnapshot? _currentSnapshot;
  String? _sourceRecoveryError;
  String? _configIdentity;
  Map<String, HomeSitePreference> _homeSitePreferences = {};
  String? _homeSiteReadError;
  String? _homeSiteSaveError;
  int _homeSiteRevision = 0;
  int _homeSitePendingSaves = 0;
  Future<void> _homeSiteSaveChain = Future<void>.value();
  final StreamController<void> _homeSiteController = StreamController<void>.broadcast();
  int _loadGeneration = 0;
  bool _disposed = false;
  Future<void> _snapshotSaveChain = Future<void>.value();
  Future<void> _windowSaveChain = Future<void>.value();
  List<HistoryRecord> _historyRecords = [];
  int _historyLimit = defaultHistoryLimit;
  List<VodItem> _favorites = [];

  final StreamController<VodConfig> _vodConfigController =
      StreamController<VodConfig>.broadcast();
  final StreamController<DesktopWindowConfig> _windowConfigController =
      StreamController<DesktopWindowConfig>.broadcast();
  final StreamController<Site?> _siteController =
      StreamController<Site?>.broadcast();
  final StreamController<List<HistoryRecord>> _historyController =
      StreamController<List<HistoryRecord>>.broadcast();
  final StreamController<List<VodItem>> _favoritesController =
      StreamController<List<VodItem>>.broadcast();
  final StreamController<ConfigLoadEvent> _configLoadedController =
      StreamController<ConfigLoadEvent>.broadcast();

  /// 每次通过 URL / 本地文件成功加载配置后发布（粘贴内容不发布）
  Stream<ConfigLoadEvent> get configLoadedStream => _configLoadedController.stream;

  /// 没有「首页默认站源」偏好时的兜底站源。
  ///
  /// 生产启动注入 `builtinDoubanSite`（§17/§18：默认打开即豆瓣热播）；测试与其它
  /// 场景不传，则沿用原来的「按可播性自动挑选」规则。
  final Site? fallbackHomeSite;

  ConfigRepository({WindowsConfigStorage? storage, Dio? dio, this.fallbackHomeSite})
      : _storage = storage ?? WindowsConfigStorage(),
        _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 15),
                receiveTimeout: const Duration(seconds: 20),
                headers: {
                  'User-Agent': 'okhttp/5.5.0',
                  'Accept': 'application/json, text/plain, */*',
                },
              ),
            );

  VodConfig get currentVodConfig => _currentVodConfig;
  DesktopWindowConfig get currentWindowConfig => _currentWindowConfig;
  Site? get selectedSite => _selectedSite;

  String? get currentConfigIdentity => _configIdentity;
  Stream<void> get homeSitePreferencesStream => _homeSiteController.stream;
  String? get homeSiteReadError => _homeSiteReadError;
  String? get homeSiteSaveError => _homeSiteSaveError;
  bool get isSavingHomeSite => _homeSitePendingSaves > 0;

  HomeSitePreference? get homeSitePreference => _homeSitePreferences[_configIdentity];

  /// 可选站源 = 内置虚拟站（豆瓣热播，§17） + 配置里的站源。
  ///
  /// 虚拟站不进 `VodConfig.sites`：它没有可执行端点，不该出现在聚合搜索或
  /// 站源体检里；只在「首页站源」这类导航选择中出现。
  List<Site> get _selectableSites =>
      <Site>[builtinDoubanSite, ..._currentVodConfig.sites];

  Site? _matchingSite(HomeSitePreference preference) {
    final candidates = _selectableSites.where((site) => site.key == preference.siteKey).toList();
    return candidates.length == 1 && preference.matches(candidates.single) &&
        HomeSitePreference.canSelect(candidates.single) ? candidates.single : null;
  }

  Site? get defaultHomeSite {
    final preference = homeSitePreference;
    return preference == null ? null : _matchingSite(preference);
  }

  List<Site> get availableHomeSites => List.unmodifiable(_currentVodConfig.sites.where(
    (site) => HomeSitePreference.canSelect(site) &&
        _currentVodConfig.sites.where((candidate) => candidate.key == site.key).length == 1,
  ));

  /// 首页站源下拉的候选项：内置虚拟站排首位（§17），其后是配置里的可用站源。
  ///
  /// [availableHomeSites] 保持「只含配置站源」的原语义——门禁用例与设置页的
  /// 失效提示都按它算，虚拟站单独拼在这里。
  List<Site> get homeSiteChoices =>
      List.unmodifiable(<Site>[builtinDoubanSite, ...availableHomeSites]);

  String? get homeSiteFallbackMessage => homeSitePreference != null && defaultHomeSite == null
      ? '默认站源「${homeSitePreference!.name}」已失效或不受支持，当前使用临时站源或自动选择；原偏好已保留。'
      : null;

  Future<void> setDefaultHomeSite(Site? site, {required String configIdentity}) async {
    if (_disposed) throw StateError('配置仓库已关闭');
    if (configIdentity != _configIdentity) throw StateError('配置已切换，请重新选择首页站源');
    if (_homeSiteReadError != null) throw StateError('首页站源偏好读取失败，请先修复文件并重新读取');
    if (site != null) {
      final preference = HomeSitePreference.fromSite(site);
      if (_matchingSite(preference) == null) throw StateError('该站源已失效、标识重复或不受支持');
      _homeSitePreferences[configIdentity] = preference;
    } else {
      _homeSitePreferences.remove(configIdentity);
    }
    await _persistHomeSites();
  }

  Future<void> retryHomeSiteSave() {
    if (_disposed) throw StateError('配置仓库已关闭');
    if (_homeSiteReadError != null) throw StateError('首页站源偏好尚未成功读取');
    return _persistHomeSites();
  }

  Future<void> reloadHomeSitePreferences() async {
    if (_disposed) throw StateError('配置仓库已关闭');
    if (isSavingHomeSite || _homeSiteSaveError != null) {
      throw StateError('请先完成首页站源偏好保存，避免丢失会话修改');
    }
    try {
      _homeSitePreferences = Map.of(await _storage.readHomeSitePreferences());
      _homeSiteReadError = null;
    } catch (_) {
      _homeSiteReadError = '首页站源偏好读取失败，原文件已保留；当前使用自动选择。请修复文件后重新读取。';
    }
    _publishHomeSites();
  }

  void _publishHomeSites() {
    if (!_disposed && !_homeSiteController.isClosed) _homeSiteController.add(null);
  }

  Future<void> _persistHomeSites() {
    final revision = ++_homeSiteRevision;
    final snapshot = Map<String, HomeSitePreference>.unmodifiable(_homeSitePreferences);
    _homeSitePendingSaves++;
    _publishHomeSites();
    final saving = _homeSiteSaveChain.then((_) async {
      try {
        await _storage.saveHomeSitePreferences(snapshot);
        if (revision == _homeSiteRevision) _homeSiteSaveError = null;
      } catch (error) {
        if (revision == _homeSiteRevision) {
          _homeSiteSaveError = error is DataRestorePendingRestartException
              ? '数据已恢复，请重启应用后再设置首页站源（本次修改未保存）。'
              : '首页站源偏好尚未保存到磁盘，请检查空间或权限后重试；退出可能丢失本次修改。';
        }
        rethrow;
      } finally {
        _homeSitePendingSaves--;
        _publishHomeSites();
      }
    });
    _homeSiteSaveChain = saving.then<void>((_) {}, onError: (Object error, StackTrace stack) {});
    return saving;
  }

  /// 当前生效配置的来源（远程订阅 / 本地文件）；粘贴内容或尚未加载时为 null
  ConfigSourceKind? get currentSourceKind => _currentSourceKind;
  String? get currentSourceLocation => _currentSourceLocation;
  String? get sourceRecoveryError => _sourceRecoveryError;
  List<HistoryRecord> get historyRecords => List.unmodifiable(_historyRecords);

  /// 当前播放历史保留上限（由设置同步；默认 [defaultHistoryLimit]）
  int get historyLimit => _historyLimit;
  List<VodItem> get favorites => List.unmodifiable(_favorites);

  Stream<VodConfig> get vodConfigStream async* {
    yield _currentVodConfig;
    yield* _vodConfigController.stream;
  }

  Stream<DesktopWindowConfig> get windowConfigStream async* {
    yield _currentWindowConfig;
    yield* _windowConfigController.stream;
  }

  Stream<Site?> get siteStream async* {
    yield _selectedSite;
    yield* _siteController.stream;
  }

  Stream<List<HistoryRecord>> get historyStream async* {
    yield List.unmodifiable(_historyRecords);
    yield* _historyController.stream;
  }

  Stream<List<VodItem>> get favoritesStream async* {
    yield _favorites;
    yield* _favoritesController.stream;
  }

  /// 初始化：从 Windows 本地持久化中恢复窗口配置与缓存的影视配置
  Future<void> initialize() async {
    await reloadHomeSitePreferences();
    _currentWindowConfig = await _storage.readWindowConfig();
    _windowConfigController.add(_currentWindowConfig);
    try {
      final snapshot = await _storage.readCurrentConfig();
      if (snapshot != null) {
        _applySnapshot(snapshot);
      } else {
        final savedUrl = _currentWindowConfig.lastConfigUrl;
        if (savedUrl != null && savedUrl.trim().isNotEmpty) {
          _currentSourceKind = ConfigSourceKind.url;
          _currentSourceLocation = savedUrl;
        }
        final cachedVod = await _storage.readCachedVodConfig();
        if (cachedVod != null) _applyVodConfig(cachedVod);
      }
    } catch (_) {
      _sourceRecoveryError = '当前配置快照读取失败，原文件已保留。请重新导入配置；不会自动恢复旧订阅。';
      _currentWindowConfig = _currentWindowConfig.copyWith(clearLastConfigUrl: true, depotPath: const []);
      _windowConfigController.add(_currentWindowConfig);
    }

    _historyRecords = List<HistoryRecord>.from(await _storage.readHistory());
    _publishHistory();

    _favorites = await _storage.readFavorites();
    _favoritesController.add(_favorites);

    // 如果此前保存了配置 URL，尝试后台异步更新最新配置
    final lastUrl = _currentWindowConfig.lastConfigUrl;
    if (lastUrl != null && lastUrl.isNotEmpty) {
      unawaited(loadFromUrl(lastUrl).catchError((_) => const VodConfig(sites: [])));
    }
  }

  /// 广播历史列表快照。
  ///
  /// 每次发布全新的不可变副本：订阅方（如 StateNotifier）依赖对象身份判断是否变更，
  /// 若复用同一可变列表，删除 / 进度更新后 UI 将不会刷新。
  void _publishHistory() {
    _historyController.add(List.unmodifiable(_historyRecords));
  }

  /// 历史按调用顺序保存，避免进度跟踪器与置顶 / 删除的快照乱序覆盖。
  Future<void> _historySaveChain = Future<void>.value();

  Future<void> _persistHistory() {
    final snapshot = List<HistoryRecord>.unmodifiable(_historyRecords);
    final next = _historySaveChain
        .catchError((_) {})
        .then((_) => _storage.saveHistory(snapshot));
    _historySaveChain = next;
    return next;
  }

  /// 设置播放历史保留上限。
  ///
  /// [trim] 为 true（默认）时，若当前记录数超出上限，立即裁剪到上限（保留最新）并落盘；
  /// 应用启动同步传 false：仅记录上限，读取什么显示什么，不做无提示的数据删除——
  /// 超限（外部编辑等异常）会在下一次新增或用户调整上限时收敛（见 SET-05 方案 §2.2）。
  /// 调用方保证 [limit] 为正数（设置归一化保证不小于 10）。
  Future<void> setHistoryLimit(int limit, {bool trim = true}) async {
    assert(limit > 0, '历史保留上限必须为正数');
    _historyLimit = limit;
    if (trim && _historyRecords.length > limit) {
      _historyRecords = _historyRecords.sublist(0, limit);
      _publishHistory();
      await _persistHistory();
    }
  }

  /// 添加或更新播放历史记录（置顶；同一影片只保留最近一条；超出上限剔除最旧）
  Future<void> addHistory(HistoryRecord record) async {
    // 去重按「站点 + 影片」：同一站点内保留最新一条（列表不堆集数），
    // 但不同站点的同名影片必须并存，否则跨站续播（SET-11）会失去进度来源。
    String siteOf(HistoryRecord r) {
      final key = (r.siteKey ?? '').trim();
      if (key.isNotEmpty) return key;
      return (r.siteName ?? '').trim();
    }
    final site = siteOf(record);
    // 旧记录可能没有站点字段：此时按「同站」处理，保持原有的去重置顶行为。
    bool sameSite(String other) =>
        other.isEmpty || site.isEmpty || other == site;
    _historyRecords.removeWhere((e) =>
        sameSite(siteOf(e)) &&
        (e.vodId == record.vodId ||
            (e.vodName == record.vodName &&
                e.episodeName == record.episodeName)));
    _historyRecords.insert(0, record);
    if (_historyRecords.length > _historyLimit) {
      _historyRecords = _historyRecords.sublist(0, _historyLimit);
    }
    _publishHistory();
    await _persistHistory();
  }

  /// 按记录 ID 查找历史（不存在时返回 null）
  HistoryRecord? findHistoryById(String id) {
    for (final record in _historyRecords) {
      if (record.id == id) return record;
    }
    return null;
  }

  /// 查找「同一影片 + 同一集」的最近一条记录（SET-11 跨站续播）。
  ///
  /// 只读：不合并、不迁移、不修改任何记录；选择规则见 [findLatestHistoryResumeMatch]。
  HistoryResumeMatch? findLatestResumeCandidate({
    required String vodId,
    required String vodName,
    required String episodeName,
    bool singleEpisode = false,
  }) {
    return findLatestHistoryResumeMatch(
      records: _historyRecords,
      vodId: vodId,
      vodName: vodName,
      episodeName: episodeName,
      singleEpisode: singleEpisode,
    );
  }

  /// 更新指定历史记录的播放进度（保持列表顺序不变，仅覆盖位置与时长）。
  ///
  /// 返回 false 表示记录不存在（例如已被用户删除），此时不做任何写入。
  Future<bool> updateHistoryProgress(
    String id, {
    required int positionMs,
    required int durationMs,
  }) async {
    final index = _historyRecords.indexWhere((e) => e.id == id);
    if (index < 0) return false;

    final current = _historyRecords[index];
    final safePosition = positionMs < 0 ? 0 : positionMs;
    // 时长偶发上报为 0（如切换流瞬间）时保留已知时长，避免进度条闪烁
    final safeDuration = durationMs > 0 ? durationMs : current.durationMs;
    if (current.positionMs == safePosition && current.durationMs == safeDuration) {
      return true;
    }

    _historyRecords[index] = current.copyWith(
      positionMs: safePosition,
      durationMs: safeDuration,
    );
    _publishHistory();
    await _persistHistory();
    return true;
  }

  /// 仅更新历史记录的线路来源字段（SET-12 自动换线）。
  ///
  /// 不改 `positionMs / durationMs / timestamp`，保持观看进度与排序不变；
  /// 记录不存在或落盘失败时不抛给播放链路，避免换线成功却因写历史失败而报错。
  Future<void> updateHistorySource(
    String id, {
    required String sourceName,
    required String playUrl,
    required String episodeUrl,
    String? siteKey,
    String? siteName,
  }) async {
    final index = _historyRecords.indexWhere((e) => e.id == id);
    if (index < 0) return;
    final current = _historyRecords[index];
    final next = current.copyWith(
      sourceName: sourceName,
      playUrl: playUrl,
      episodeUrl: episodeUrl,
      siteKey: siteKey ?? current.siteKey,
      siteName: siteName ?? current.siteName,
    );
    _historyRecords[index] = next;
    _publishHistory();
    try {
      await _persistHistory();
    } catch (_) {
      // 换线已生效；来源字段落盘失败不应中断播放，下一次写入会收敛。
    }
  }

  /// 删除指定单条历史记录
  Future<void> removeHistory(String id) async {
    // 跨站记录可能共享同一 id（vodId + 集名），只删第一条，避免误删其他站点。
    final index = _historyRecords.indexWhere((e) => e.id == id);
    if (index < 0) return;
    _historyRecords.removeAt(index);
    _publishHistory();
    await _persistHistory();
  }

  /// 清空全部历史记录
  Future<void> clearHistory() async {
    _historyRecords.clear();
    _publishHistory();
    await _persistHistory();
  }

  /// 检查某影片是否已收藏
  bool isFavorite(String vodId) => _favorites.any((e) => e.id == vodId);

  /// 切换收藏状态；落盘失败时撤回内存变更，避免 UI 显示「已保存」。
  Future<bool> toggleFavorite(VodItem item) async {
    final index = _favorites.indexWhere((e) => e.id == item.id);
    VodItem? removed;
    bool favorited;
    if (index >= 0) {
      removed = _favorites.removeAt(index);
      favorited = false;
    } else {
      _favorites.insert(0, item);
      favorited = true;
    }
    _favoritesController.add(_favorites);
    try {
      await _storage.saveFavorites(_favorites);
    } catch (_) {
      if (removed != null) {
        // 回退原对象而不是入参，避免把已收藏条目的字段（siteKey 等）降级。
        _favorites.insert(index, removed);
      } else {
        _favorites.removeWhere((e) => e.id == item.id);
      }
      _favoritesController.add(_favorites);
      rethrow;
    }
    return favorited;
  }

  /// 移除指定收藏；落盘失败时恢复原位置并抛错，避免静默丢失。
  Future<void> removeFavorite(String vodId) async {
    final index = _favorites.indexWhere((e) => e.id == vodId);
    if (index < 0) return;
    final removed = _favorites.removeAt(index);
    _favoritesController.add(_favorites);
    try {
      await _storage.saveFavorites(_favorites);
    } catch (_) {
      _favorites.insert(index, removed);
      _favoritesController.add(_favorites);
      rethrow;
    }
  }

  /// 从输入内容加载配置。输入可以是 URL，也可以是直接粘贴的 JSON/Base64。
  ///
  /// 当检测到「多仓（Depot）」清单（如 `{"urls":[...]}`）时：
  /// - 提供 [selectDepot] 则回调请用户选择（返回 null 视为取消并抛出 [DepotSelectionCancelled]）；
  /// - 未提供时仅对同一来源重放 [DesktopWindowConfig.depotPath]，否则选择第一项。
  Future<VodConfig> loadFromInput(String input, {DepotSelector? selectDepot}) async {
    final generation = _beginLoad();
    final value = input.trim();
    final resolved = await _readInput(value,
      selectDepot: selectDepot,
      savedPath: _savedDepotPath(ConfigSourceKind.url, value),
    );
    return _commitSnapshot(ConfigSnapshot(
      rawContent: resolved.rawContent,
      sourceKind: _isHttpUrl(value) ? ConfigSourceKind.url : null,
      sourceLocation: _isHttpUrl(value) ? value : null,
      depotPath: resolved.depotPath,
    ), generation);
  }

  Future<_ResolvedConfig> _readInput(String value, {DepotSelector? selectDepot, List<String> savedPath = const []}) async {
    if (value.isEmpty) {
      throw const FormatException('配置地址或配置内容不能为空');
    }
    if (_isHttpUrl(value)) {
      return _loadRemoteConfig(
        _normalizeConfigUrl(value),
        visitedUrls: <String>{},
        selectDepot: selectDepot,
        savedPath: savedPath,
      );
    }
    if (_looksLikeHtml(value) && !RegExp(r'<pre[^>]*>[\s\S]*?<\/pre>', caseSensitive: false).hasMatch(value)) {
      throw const FormatException('输入的内容为 HTML 网页，而非有效的 TVBox 影视配置 JSON 或 Base64 编码');
    }
    return _resolveContent(value, visitedUrls: <String>{}, selectDepot: selectDepot);
  }

  void _emitLoaded(ConfigSourceKind kind, String location, VodConfig config) {
    if (_configLoadedController.isClosed) return;
    _configLoadedController.add(ConfigLoadEvent(
      kind: kind,
      location: location,
      siteCount: config.sites.length,
      liveCount: config.lives.length,
    ));
  }

  /// 重新加载当前配置源：远程订阅（多仓按已保存的选择链重放）或本地文件；
  /// 当前配置来自粘贴内容或尚未加载时抛出 [StateError]
  Future<VodConfig> reloadCurrent() {
    final kind = _currentSourceKind;
    final location = _currentSourceLocation;
    if (kind == null || location == null || location.trim().isEmpty) {
      throw StateError('当前配置来自粘贴内容，无法重新加载');
    }
    return kind == ConfigSourceKind.file ? loadFromFile(location) : loadFromInput(location);
  }

  /// 导出当前生效配置到 [filePath]：优先写出缓存原文，缺失时写出规范化 JSON
  Future<void> exportCurrentConfig(String filePath) async {
    final raw = _currentSnapshot?.rawContent ?? await _storage.readCachedVodConfigRaw();
    final content = raw ?? const JsonEncoder.withIndent('  ').convert(_currentVodConfig.toJson());
    await File(filePath).writeAsString(content, flush: true);
  }

  /// 只读探测配置源（远程 URL 或本地文件）的可用性与格式，不改变当前配置
  Future<ConfigProbeResult> probeSource(String input) async {
    final value = input.trim();
    final stopwatch = Stopwatch()..start();
    String raw;
    try {
      if (_isHttpUrl(value)) {
        final response = await _dio.get<String>(
          _normalizeConfigUrl(value),
          options: Options(
            responseType: ResponseType.plain,
            followRedirects: true,
            maxRedirects: 5,
            receiveTimeout: const Duration(seconds: 15),
          ),
        );
        raw = response.data ?? '';
      } else {
        final file = File(value);
        if (value.isEmpty || !await file.exists()) {
          return ConfigProbeResult(
            kind: ConfigProbeKind.unreachable,
            latency: stopwatch.elapsed,
            message: '文件不存在',
          );
        }
        raw = await file.readAsString();
      }
    } on DioException catch (error) {
      return ConfigProbeResult(
        kind: ConfigProbeKind.unreachable,
        latency: stopwatch.elapsed,
        message: _describeDioError(error),
      );
    } catch (_) {
      return ConfigProbeResult(
        kind: ConfigProbeKind.unreachable,
        latency: stopwatch.elapsed,
        message: '读取失败',
      );
    }
    final latency = stopwatch.elapsed;
    return classifyConfigContent(raw, latency: latency);
  }

  /// 按内容识别配置格式（多仓 / CMS 清单 / 标准配置 / 无效）
  ConfigProbeResult classifyConfigContent(String raw, {Duration latency = Duration.zero}) {
    try {
      final depot = _parseDepotEntries(raw);
      if (depot != null) {
        return ConfigProbeResult(
          kind: ConfigProbeKind.depot,
          latency: latency,
          count: depot.length,
          message: '多仓清单 · ${depot.length} 个仓库',
        );
      }
      final cms = _parseCmsInterfaceSites(raw);
      if (cms != null) {
        return ConfigProbeResult(
          kind: ConfigProbeKind.cmsList,
          latency: latency,
          count: cms.length,
          message: 'CMS 资源站清单 · ${cms.length} 个接口',
        );
      }
      if (_looksLikeHtml(raw) && !RegExp(r'<pre[^>]*>', caseSensitive: false).hasMatch(raw)) {
        return ConfigProbeResult(kind: ConfigProbeKind.invalid, latency: latency, message: '返回的是网页而非配置');
      }
      final config = VodConfig.parseRawString(raw);
      if (config.sites.isEmpty && config.lives.isEmpty) {
        return ConfigProbeResult(kind: ConfigProbeKind.invalid, latency: latency, message: '未包含站点或直播');
      }
      return ConfigProbeResult(
        kind: ConfigProbeKind.vodConfig,
        latency: latency,
        count: config.sites.length,
        liveCount: config.lives.length,
        message: '${config.sites.length} 个站点 · ${config.lives.length} 个直播',
      );
    } catch (_) {
      return ConfigProbeResult(kind: ConfigProbeKind.invalid, latency: latency, message: '无法识别的配置格式');
    }
  }

  /// 连通性测试的错误摘要。
  ///
  /// 不对 [DioExceptionType] 做穷举 switch：dio 小版本会新增枚举值（如 transformTimeout），
  /// 穷举写法在依赖升级后会直接编译失败；各类超时统一按名称归类。
  String _describeDioError(DioException error) {
    final type = error.type;
    if (type == DioExceptionType.badResponse) {
      return 'HTTP ${error.response?.statusCode ?? '错误'}';
    }
    if (type == DioExceptionType.connectionError) return '无法连接';
    if (type == DioExceptionType.badCertificate) return '证书无效';
    if (type == DioExceptionType.cancel) return '已取消';
    if (type.name.toLowerCase().contains('timeout')) return '连接超时';
    return '网络错误';
  }

  /// 从远程 URL 加载配置。
  Future<VodConfig> loadFromUrl(String url) => loadFromInput(url);

  /// 从本地 JSON 文件加载配置
  Future<VodConfig> loadFromFile(String filePath, {DepotSelector? selectDepot}) async {
    final generation = _beginLoad();
    final file = File(filePath).absolute;
    if (!await file.exists()) {
      throw FileSystemException('指定的配置文件不存在', filePath);
    }
    final resolved = await _resolveContent(
      await file.readAsString(),
      visitedUrls: <String>{},
      selectDepot: selectDepot,
      savedPath: _savedDepotPath(ConfigSourceKind.file, file.path),
    );
    return _commitSnapshot(ConfigSnapshot(
      rawContent: resolved.rawContent,
      sourceKind: ConfigSourceKind.file,
      sourceLocation: file.path,
      depotPath: resolved.depotPath,
    ), generation);
  }

  Future<_ResolvedConfig> _loadRemoteConfig(
    String requestUrl, {
    required Set<String> visitedUrls,
    DepotSelector? selectDepot,
    List<String> savedPath = const [],
    int depth = 0,
    List<String> chain = const [],
  }) async {
    if (!visitedUrls.add(requestUrl)) {
      throw FormatException('配置仓库地址发生循环引用: $requestUrl');
    }

    final response = await _dio.get<String>(
      requestUrl,
      options: Options(
        responseType: ResponseType.plain,
        followRedirects: true,
        maxRedirects: 5,
      ),
    );

    final rawContent = response.data ?? '';
    try {
      return await _resolveContent(
        rawContent,
        baseUrl: requestUrl,
        visitedUrls: visitedUrls,
        selectDepot: selectDepot,
        savedPath: savedPath,
        depth: depth,
        chain: chain,
      );
    } on FormatException catch (error) {
      final contentType = response.headers['content-type']?.join(',').toLowerCase();
      if (_looksLikeHtml(rawContent) || contentType?.contains('text/html') == true) {
        throw FormatException('${error.message}\n请求地址: $requestUrl');
      }
      rethrow;
    }
  }

  Future<_ResolvedConfig> _resolveContent(
    String rawContent, {
    String? baseUrl,
    required Set<String> visitedUrls,
    DepotSelector? selectDepot,
    List<String> savedPath = const [],
    int depth = 0,
    List<String> chain = const [],
  }) async {
    final entries = _parseDepotEntries(rawContent);
    if (entries != null) {
      return _resolveDepot(
        entries: entries,
        baseUrl: baseUrl,
        visitedUrls: visitedUrls,
        selectDepot: selectDepot,
        savedPath: savedPath,
        depth: depth,
        chain: chain,
      );
    }
    final cmsSites = _parseCmsInterfaceSites(rawContent);
    if (cmsSites != null) {
      return _ResolvedConfig(jsonEncode(VodConfig(sites: cmsSites).toJson()), chain);
    }
    _parseConfig(rawContent, baseUrl: baseUrl);
    return _ResolvedConfig(rawContent, chain);
  }

  List<String> _savedDepotPath(ConfigSourceKind kind, String location) =>
      _currentSourceKind == kind && _currentSourceLocation == location
          ? List.of(_currentWindowConfig.depotPath)
          : const [];

  /// 解析配置原文为 [VodConfig]，并把站点相对地址按 [baseUrl] 还原。
  VodConfig _parseConfig(String rawContent, {String? baseUrl}) {
    final decoded = ConfigDecoder.decode(rawContent);
    if (decoded is! Map) {
      throw const FormatException('无法识别的配置格式，请提供 JSON 或 Base64 配置');
    }
    try {
      final config = VodConfig.fromJson(Map<String, dynamic>.from(decoded));
      return _absolutizeConfig(config, baseUrl);
    } catch (_) {
      throw const FormatException('配置字段格式无效');
    }
  }

  int _beginLoad() {
    if (_disposed) throw StateError('配置仓库已关闭');
    return ++_loadGeneration;
  }

  Future<VodConfig> _commitSnapshot(ConfigSnapshot snapshot, int generation) {
    final next = _snapshotSaveChain.then((_) async {
      if (_disposed || generation != _loadGeneration) {
        throw const ConfigLoadSuperseded();
      }
      final parsed = _parseConfig(snapshot.rawContent,
          baseUrl: _snapshotBaseUrl(snapshot));
      await _storage.saveCurrentConfig(snapshot);
      if (_disposed) throw const ConfigLoadSuperseded();
      _applySnapshot(snapshot, parsed: parsed);
      if (snapshot.sourceKind != null) {
        _emitLoaded(snapshot.sourceKind!, snapshot.sourceLocation!, parsed);
      }
      return parsed;
    });
    _snapshotSaveChain = next.then<void>((_) {}, onError: (Object error, StackTrace stack) {});
    return next;
  }

  DesktopWindowConfig _withCurrentSource(DesktopWindowConfig window) {
    final snapshot = _currentSnapshot;
    if (snapshot == null) return window;
    return window.copyWith(
      lastConfigUrl: snapshot.sourceKind == ConfigSourceKind.url ? snapshot.sourceLocation : null,
      clearLastConfigUrl: snapshot.sourceKind != ConfigSourceKind.url,
      depotPath: snapshot.depotPath,
    );
  }

  void _applySnapshot(ConfigSnapshot snapshot, {VodConfig? parsed}) {
    final config = parsed ??
        _parseConfig(snapshot.rawContent, baseUrl: _snapshotBaseUrl(snapshot));
    _currentSnapshot = snapshot;
    _sourceRecoveryError = null;
    _currentSourceKind = snapshot.sourceKind;
    _currentSourceLocation = snapshot.sourceLocation;
    _currentWindowConfig = _withCurrentSource(_currentWindowConfig);
    _windowConfigController.add(_currentWindowConfig);
    _applyVodConfig(config);
  }

  /// 检测内容是否为「多仓（Depot）」清单，返回条目列表；不是则返回 null。
  /// 兼容 `{"urls":[{"name":...,"url":...}, ...]}` 及其 Base64 / `<pre>` 变体。
  List<DepotEntry>? _parseDepotEntries(String rawContent) {
    final decoded = VodConfig.decodeRawString(rawContent);
    if (decoded is! Map) return null;

    // 同时声明了有效 sites 的内容优先按普通配置处理，避免误判
    final sites = decoded['sites'];
    if (sites is List && sites.isNotEmpty) return null;

    final urls = decoded['urls'];
    if (urls is! List) return null;

    final entries = <DepotEntry>[];
    for (final item in urls) {
      String name = '';
      String url = '';
      if (item is Map) {
        name = item['name']?.toString().trim() ?? '';
        url = item['url']?.toString().trim() ?? '';
      } else {
        url = item?.toString().trim() ?? '';
      }
      if (url.isEmpty) continue;
      entries.add(DepotEntry(name: name.isEmpty ? url : name, url: url));
    }

    return entries.isEmpty ? null : entries;
  }

  /// 检测「CMS 资源站清单」格式：顶层 JSON 数组，元素含 `api`（http/https）
  /// 且至少含 `apiType` 或 `name` 字段（典型样例：`test/ziyuanzu-cms-interfaces.json`）。
  /// 返回可用的站点列表；不是该格式时返回 null。
  List<Site>? _parseCmsInterfaceSites(String rawContent) {
    dynamic decoded;
    try {
      decoded = VodConfig.decodeRawString(rawContent);
    } catch (_) {
      return null;
    }
    if (decoded is! List || decoded.isEmpty) return null;

    final sites = <Site>[];
    final usedKeys = <String>{};
    for (final item in decoded) {
      if (item is! Map) continue;
      final api = item['api']?.toString().trim() ?? '';
      if (!_isHttpUrl(api)) continue;
      // 至少具备 apiType 或 name 之一，避免误吞任意含 api 字段的数组
      if (!item.containsKey('apiType') && !item.containsKey('name')) continue;

      final name = item['name']?.toString().trim() ?? '';
      final typeStr = item['apiType']?.toString().trim().toLowerCase() ?? '';
      final type = typeStr == 'xml' ? 0 : 1;

      sites.add(Site(
        key: _uniqueSiteKey(_siteKeyFromApi(api), usedKeys),
        name: name.isNotEmpty ? name : (Uri.tryParse(api)?.host ?? api),
        type: type,
        api: api,
      ));
    }

    return sites.isEmpty ? null : sites;
  }

  /// 以接口域名生成站点 Key（去掉 www. 前缀），作为选中与缓存标识
  String _siteKeyFromApi(String api) {
    final host = Uri.tryParse(api)?.host ?? '';
    if (host.isEmpty) return api;
    return host.startsWith('www.') ? host.substring(4) : host;
  }

  /// 保证 Key 唯一（同名域重复出现时追加序号后缀）
  String _uniqueSiteKey(String base, Set<String> used) {
    var key = base;
    var index = 2;
    while (!used.add(key)) {
      key = '$base-$index';
      index++;
    }
    return key;
  }

  /// 将条目解析为可用的绝对 http(s) 地址并去重（相对地址基于 [baseUrl] 解析）
  List<DepotEntry> _absoluteEntries(List<DepotEntry> entries, String? baseUrl) {
    final resolved = <DepotEntry>[];
    final seen = <String>{};
    for (final entry in entries) {
      var url = entry.url;
      if (!_isHttpUrl(url)) {
        if (baseUrl == null) continue;
        try {
          url = Uri.parse(baseUrl).resolve(url).toString();
        } catch (_) {
          continue;
        }
        if (!_isHttpUrl(url)) continue;
      }
      if (seen.add(url)) {
        resolved.add(DepotEntry(name: entry.name, url: url));
      }
    }
    return resolved;
  }

  /// 处理一层多仓：选择条目 -> 继续追踪（下一层多仓或最终配置）
  Future<_ResolvedConfig> _resolveDepot({
    required List<DepotEntry> entries,
    required String? baseUrl,
    required Set<String> visitedUrls,
    required DepotSelector? selectDepot,
    required List<String> savedPath,
    required int depth,
    required List<String> chain,
  }) async {
    if (depth >= _maxDepotDepth) {
      throw const FormatException('多仓层级过深，疑似地址循环引用');
    }

    final resolved = _absoluteEntries(entries, baseUrl);
    if (resolved.isEmpty) {
      throw const FormatException('多仓清单中没有可用的 http(s) 订阅地址');
    }

    final chosenIndex = await _chooseDepotIndex(resolved, selectDepot, depth, savedPath);
    if (chosenIndex == null) {
      throw const DepotSelectionCancelled();
    }

    final chosen = resolved[chosenIndex];
    return _loadRemoteConfig(
      _normalizeConfigUrl(chosen.url),
      visitedUrls: visitedUrls,
      selectDepot: selectDepot,
      savedPath: savedPath,
      depth: depth + 1,
      chain: [...chain, chosen.url],
    );
  }

  /// 决定本层选择：交互模式弹出选择器；非交互模式重放已保存链或回落第一项
  Future<int?> _chooseDepotIndex(List<DepotEntry> entries, DepotSelector? selectDepot, int depth, List<String> savedPath) async {
    if (selectDepot != null) {
      if (entries.length == 1) return 0;
      final choice = await selectDepot(entries);
      if (choice == null || choice < 0 || choice >= entries.length) return null;
      return choice;
    }

    if (depth < savedPath.length) {
      final index = entries.indexWhere((e) => e.url == savedPath[depth]);
      if (index >= 0) return index;
    }

    return 0;
  }

  bool _isHttpUrl(String value) {
    final uri = Uri.tryParse(value);
    return uri != null &&
        (uri.scheme.toLowerCase() == 'http' || uri.scheme.toLowerCase() == 'https') &&
        uri.host.isNotEmpty;
  }
  bool _looksLikeHtml(String content) {
    final prefix = content.trimLeft().toLowerCase();
    return prefix.startsWith('<!doctype html') ||
        prefix.startsWith('<html') ||
        prefix.startsWith('<head') ||
        prefix.contains('<html');
  }

  String _normalizeConfigUrl(String value) {
    final uri = Uri.parse(value);
    final host = uri.host.toLowerCase();
    final segments = uri.pathSegments;

    if (host == 'github.com' && segments.length >= 5 && segments[2] == 'blob') {
      return Uri(
        scheme: 'https',
        host: 'raw.githubusercontent.com',
        pathSegments: [segments[0], segments[1], ...segments.skip(3)],
        queryParameters: uri.queryParameters.isEmpty ? null : uri.queryParameters,
      ).toString();
    }

    if (host == 'github.com' && segments.length >= 5 && segments[2] == 'raw') {
      return Uri(
        scheme: 'https',
        host: 'raw.githubusercontent.com',
        pathSegments: [segments[0], segments[1], ...segments.skip(3)],
        queryParameters: uri.queryParameters.isEmpty ? null : uri.queryParameters,
      ).toString();
    }

    if (host == 'gitee.com' && segments.length >= 5 && segments[2] == 'blob') {
      return Uri(
        scheme: uri.scheme,
        host: uri.host,
        pathSegments: [segments[0], segments[1], 'raw', ...segments.skip(3)],
        queryParameters: uri.queryParameters.isEmpty ? null : uri.queryParameters,
      ).toString();
    }

    if (segments.length >= 6 && segments[2] == '-' && segments[3] == 'blob') {
      return Uri(
        scheme: uri.scheme,
        host: uri.host,
        pathSegments: [segments[0], segments[1], '-', 'raw', ...segments.skip(4)],
        queryParameters: uri.queryParameters.isEmpty ? null : uri.queryParameters,
      ).toString();
    }

    return _asciiUrl(value);
  }

  /// 把配置来源地址规范化为可请求的 ASCII 形式。
  ///
  /// 中文域名经 `Uri.host` 会变成百分号编码（`www.%E9%A5%AD...`），
  /// dio 与 HttpClient 都拒绝这种 host；手机端 okhttp 会自动转 punycode。
  String _asciiUrl(String value) => AsciiUrl.toAsciiHost(value);

  /// 把站点与全局 spider 的相对地址按配置来源还原为绝对地址。
  ///
  /// 手机端在 `Decoder.fix` 中对整份配置文本做等价替换；桌面端此前只还原
  /// 多仓条目，站点侧相对 api/ext/jar 无法下载。
  VodConfig _absolutizeConfig(VodConfig config, String? baseUrl) {
    final base = _configBaseUri(baseUrl);
    if (base == null) return config;
    return VodConfig(
      spider: RelativeUrl.resolve(base, config.spider, allowBareRelative: true),
      wallpaper: config.wallpaper,
      warning: config.warning,
      sites: config.sites
          .map((site) => site.copyWith(
                api: RelativeUrl.resolve(base, site.api, allowBareRelative: true) ?? site.api,
                ext: RelativeUrl.resolve(base, site.ext),
                jar: RelativeUrl.resolve(base, site.jar, allowBareRelative: true),
              ))
          .toList(),
      parses: config.parses,
      lives: config.lives,
      rules: config.rules,
      flags: config.flags,
      ads: config.ads,
    );
  }

  /// 快照对应的配置来源地址；粘贴内容没有基址。
  String? _snapshotBaseUrl(ConfigSnapshot snapshot) =>
      snapshot.sourceKind == null ? null : snapshot.sourceLocation;

  /// 配置来源的基址：远程用请求地址，本地文件用文件 URI。
  Uri? _configBaseUri(String? location) {    final value = location?.trim();
    if (value == null || value.isEmpty) return null;
    if (_isHttpUrl(value)) {
      final uri = Uri.tryParse(_asciiUrl(value));
      return uri == null || uri.host.isEmpty ? null : uri;
    }
    return Uri.tryParse(Uri.file(value).toString());
  }

  /// 切换当前使用的点播站点
  void selectSite(Site site) {
    _selectedSite = site;
    _siteController.add(_selectedSite);
  }

  /// 更新 Windows 窗口配置并自动持久化到本地
  Future<void> updateWindowConfig(DesktopWindowConfig newConfig) async {
    if (_disposed) throw StateError('配置仓库已关闭');
    _currentWindowConfig = _withCurrentSource(newConfig);
    _windowConfigController.add(_currentWindowConfig);
    final snapshot = _currentWindowConfig;
    final next = _windowSaveChain.then((_) => _storage.saveWindowConfig(snapshot));
    _windowSaveChain = next.then<void>((_) {}, onError: (Object error, StackTrace stack) {});
    await next;
  }

  void _applyVodConfig(VodConfig config) {
    final previousIdentity = _configIdentity;
    final previousSite = _selectedSite;
    _currentVodConfig = config;
    _configIdentity = HomeSitePreference.sourceIdentity(_currentSnapshot ?? ConfigSnapshot(
      rawContent: jsonEncode(config.toJson()),
      sourceKind: _currentSourceKind,
      sourceLocation: _currentSourceLocation,
      depotPath: _currentWindowConfig.depotPath,
    ));
    final preserved = previousIdentity == _configIdentity && previousSite != null
        ? _matchingSite(HomeSitePreference.fromSite(previousSite)) : null;
    final fallback = fallbackHomeSite;
    final preferred = preserved ??
        defaultHomeSite ??
        (fallback != null && HomeSitePreference.canSelect(fallback)
            ? fallback
            : null);
    if (preferred != null) {
      _selectedSite = preferred;
      _vodConfigController.add(_currentVodConfig);
      _siteController.add(_selectedSite);
      _publishHomeSites();
      return;
    }
    _vodConfigController.add(_currentVodConfig);

    // 智能选择首页站源，见 _pickDefaultSite 的优先级说明。
    if (config.sites.isNotEmpty) {
      _selectedSite = _pickDefaultSite(config.sites);
      _siteController.add(_selectedSite);
    } else {
      _selectedSite = null;
      _siteController.add(null);
    }
    _publishHomeSites();
  }

  /// 自动选择首页站源的优先级：
  /// 1. 标准 CMS（type 0/1）—— 直连最稳，不依赖 companion；
  /// 2. `csp_*` 加固载荷站点 —— companion 会先在载荷里做「去 Guard 后缀」的类发现
  ///    （DexSpiderLoader Level 0.5），命中真实爬虫后才有影片数据；
  /// 3. 带 HTTP 端点的站源（JS / 直连）；
  /// 4. 兜底第一个。
  ///
  /// 旧顺序把「api/ext 是 http」排在 `csp_*` 之前。而 drpy2 风格的 JS 源
  /// （api=引擎、ext=脚本）在桌面端没有运行时，首页会固定落在跑不了的站源上，
  /// 表现为分类和影片都为空。
  static Site _pickDefaultSite(List<Site> sites) {
    for (final site in sites) {
      if (site.type == 0 || site.type == 1) return site;
    }
    for (final site in sites) {
      if (site.api.trim().startsWith('csp_')) return site;
    }
    bool hasHttp(String? value) {
      final raw = value?.trim() ?? '';
      return raw.startsWith('http://') || raw.startsWith('https://');
    }

    for (final site in sites) {
      if (hasHttp(site.api) || hasHttp(site.ext)) return site;
    }
    return sites.first;
  }

  /// 等待当前排队的配置 / 历史 / 首页站源 / 窗口写入落定。
  ///
  /// 供数据备份（SET-10）在读取文件前做一致性快照；等待上限由调用方控制。
  Future<void> flushPendingWrites() async {
    await Future.wait([
      _snapshotSaveChain.catchError((_) {}),
      _windowSaveChain.catchError((_) {}),
      _homeSiteSaveChain.catchError((_) {}),
      _historySaveChain.catchError((_) {}),
    ]);
  }

  /// 释放资源
  Future<void> dispose() async {
    _disposed = true;
    _loadGeneration++;
    await _snapshotSaveChain;
    await _windowSaveChain;
    await _homeSiteSaveChain;
    await _homeSiteController.close();
    await _vodConfigController.close();
    await _windowConfigController.close();
    await _siteController.close();
    await _historyController.close();
    await _favoritesController.close();
    await _configLoadedController.close();
  }
}
