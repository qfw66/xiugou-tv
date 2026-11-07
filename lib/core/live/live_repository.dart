import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import '../bounded_map.dart';
import '../config/models/vod_config.dart';
import '../config/windows_config_storage.dart';
import '../net/http_client_factory.dart';
import '../player/models/player_state.dart';
import '../storage/data_restore_guard.dart';
import 'live_channel_merge.dart';
import 'live_direct_mode_memory.dart';
import 'live_playlist_parser.dart';
import 'live_script_catalog.dart';
import 'live_source.dart';
import 'live_source_history.dart';
import 'live_text_loader.dart';

/// 接收已还原相对地址的脚本描述，返回原始 liveContent 结果。
typedef LiveScriptLoader = Future<Object?> Function(Live source);

/// 直播源独立落盘；配置内的源与用户导入源不会修改点播配置。
class LiveRepository {
  static const String sourceHistoryFileName = 'live_source_history.json';

  /// 在「直播源」里填单个播放地址时，频道追加到这个自定义源（不替换当前直播源）。
  static const String manualSourceId = 'manual-channels';
  static const String manualSourceName = '手动添加';

  final WindowsConfigStorage _storage;
  final Dio _dio;
  final bool _ownsDio;
  final LiveScriptLoader? _loadScript;
  final _scriptCatalog = const LiveScriptCatalog();
  final _parser = const LivePlaylistParser();
  /// 拉取失败时回退用的频道缓存（每源可达数千频道）；按 [_maxConfiguredSources] 淘汰最早的源。
  final _configuredCache = <String, List<Live>>{};
  static const int _maxConfiguredSources = 16;
  List<LiveSource> _sources = const [];
  Future<void>? _initializing;
  Future<void> _writeQueue = Future.value();
  String? _storageWarning;
  String? _lastChannelKey;
  /// 直链「按主机记忆播放方式」（D3：仅直链 + host，≤32 条）。
  LiveDirectModeMemory _directModes = LiveDirectModeMemory();
  /// 独立直播源（当前项 + 历史）；当前项为空时直播跟随主配置源。
  LiveSourceHistory _sourceHistory = LiveSourceHistory.empty;
  String? _sourceHistoryWarning;
  final _sourceChanges = StreamController<void>.broadcast();
  var _sequence = 0;
  var _disposed = false;

  LiveRepository({
    WindowsConfigStorage? storage,
    Dio? dio,
    LiveScriptLoader? loadScript,
  })  : _storage = storage ?? WindowsConfigStorage(),
        _loadScript = loadScript,
        _ownsDio = dio == null,
        _dio = dio ??
            HttpClientFactory.createDio(BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 20),
            ));

  List<LiveSource> get sources => List.unmodifiable(_sources);

  /// 「手动添加」分组里的频道（单个播放地址），按添加顺序；需已初始化。
  List<Live> get manualChannels {
    for (final source in _sources) {
      if (source.id == manualSourceId) return source.channels;
    }
    return const [];
  }

  /// 独立直播源设置（需先走 [loadSourceHistory] 或任一初始化路径）。
  LiveSourceHistory get sourceHistory => _sourceHistory;

  /// 直播实际使用的频道来源变化时触发：切换 / 删除 / 清空独立直播源，或新增手动频道。
  /// 只用于通知「需要重新加载频道」，点播配置不受影响。
  Stream<void> get sourceChanges => _sourceChanges.stream;

  /// 脚本代理重置后，通知宿主重新加载频道以取得新的代理地址。
  void notifyScriptReset() {
    if (!_disposed) _sourceChanges.add(null);
  }

  Future<LiveSourceHistory> loadSourceHistory() async {
    await _initialize();
    return _sourceHistory;
  }

  /// 「上次直播频道」的 key（需先走 [loadLastChannelKey] 或任一初始化路径）。
  String? get lastChannelKey => _lastChannelKey;

  /// 读取上次直播频道 key（确保初始化完成；无记录时为 null）。
  Future<String?> loadLastChannelKey() async {
    await _initialize();
    return _lastChannelKey;
  }

  /// 直链弹窗的「按主机记忆播放方式」：命中返回记录的 [PlaybackMode]，否则 null。
  ///
  /// 只用于「播放直链」；导入频道 / 收藏 / 上次频道不读写这里（D7）。
  Future<PlaybackMode?> loadDirectPlaybackMode(String host) async {
    await _initialize();
    return _directModes.modeFor(host);
  }

  /// 写入 / 删除（[mode] 为 null）某主机的直链播放方式。
  ///
  /// 与直播源共用写队列（串行 + 原子替换）；无变化不落盘。
  /// 纯体验信息：数据恢复锁定期间静默跳过，读写失败由调用方吞掉（不影响起播）。
  Future<void> rememberDirectPlaybackMode(String host, PlaybackMode? mode) {
    final key = LiveDirectModeMemory.normalizeHost(host);
    final future = _writeQueue.catchError((_) {}).then((_) async {
      if (_disposed) throw StateError('直播源仓库已关闭');
      await _initialize();
      if (key.isEmpty || dataRestorePendingRestart) return;
      final next = LiveDirectModeMemory(_directModes.entries);
      if (mode == null) {
        next.forget(key);
      } else {
        next.remember(key, mode);
      }
      final encoded = jsonEncode(next.toJson());
      if (encoded == jsonEncode(_directModes.toJson())) return;
      final directory = await _storage.getStorageDirectory();
      final file =
          File(p.join(directory.path, LiveDirectModeMemory.fileName));
      final temp = File('${file.path}.tmp-${++_sequence}');
      try {
        await temp.writeAsString(encoded, flush: true);
        await temp.rename(file.path);
      } finally {
        if (await temp.exists()) await temp.delete();
      }
      _directModes = next;
    });
    _writeQueue = future;
    return future;
  }

  /// 记录上次直播频道 key（null / 空串 = 清除）；写入与直播源共用同一队列，
  /// 原子替换、失败不破坏旧文件。数据恢复后的锁定期间静默跳过（纯体验信息）。
  Future<void> saveLastChannelKey(String? key) {
    final value = _nonEmpty(key);
    final future = _writeQueue.catchError((_) {}).then((_) async {
      if (_disposed) throw StateError('直播源仓库已关闭');
      await _initialize();
      if (dataRestorePendingRestart) return;
      final directory = await _storage.getStorageDirectory();
      final file = File(p.join(directory.path, 'live_last.json'));
      final temp = File('${file.path}.tmp-${++_sequence}');
      try {
        await temp.writeAsString(jsonEncode({'lastChannelKey': value}),
            flush: true);
        await temp.rename(file.path);
      } finally {
        if (await temp.exists()) await temp.delete();
      }
      _lastChannelKey = value;
    });
    _writeQueue = future;
    return future;
  }

  Future<void> _initialize() => _initializing ??= _readStorage();

  /// 读取落盘状态：直播源 + 上次频道 + 直链主机记忆 + 独立直播源（互相独立，互不因对方损坏而失败）。
  Future<void> _readStorage() async {
    await _readSources();
    await _readLastChannelKey();
    await _readDirectModes();
    await _readSourceHistory();
  }

  /// 读取独立直播源（live_source_history.json）；没有文件 = 跟随主配置源（老版本数据不变）。
  Future<void> _readSourceHistory() async {
    try {
      final directory = await _storage.getStorageDirectory();
      final file = File(p.join(directory.path, sourceHistoryFileName));
      if (!await file.exists()) return;
      _sourceHistory =
          LiveSourceHistory.fromJson(jsonDecode(await file.readAsString()));
    } catch (_) {
      _sourceHistoryWarning = '直播源设置无法读取，已暂时使用主配置源的直播';
    }
  }

  Future<void> _readSources() async {
    try {
      final directory = await _storage.getStorageDirectory();
      final file = File(p.join(directory.path, 'live_sources.json'));
      if (!await file.exists()) return;
      final raw = jsonDecode(await file.readAsString());
      if (raw is! List) throw const FormatException('直播源缓存格式无效');
      _sources = List.unmodifiable(raw
          .whereType<Map<String, dynamic>>()
          .map(LiveSource.fromJson)
          .where((source) => source.id.isNotEmpty));
    } catch (_) {
      _storageWarning = '自定义直播源缓存无法读取，可重新导入；点播数据未受影响';
    }
  }

  /// 读取「上次直播频道」（live_last.json）；纯体验信息，损坏时静默回退。
  Future<void> _readLastChannelKey() async {
    try {
      final directory = await _storage.getStorageDirectory();
      final file = File(p.join(directory.path, 'live_last.json'));
      if (!await file.exists()) return;
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map) return;
      _lastChannelKey = _nonEmpty(raw['lastChannelKey']?.toString());
    } catch (_) {
      // 读失败按「没有上次频道」处理，不影响其他直播功能。
    }
  }

  /// 读取直链主机记忆（live_direct_modes.json）；损坏时静默回退空表。
  Future<void> _readDirectModes() async {
    try {
      final directory = await _storage.getStorageDirectory();
      final file =
          File(p.join(directory.path, LiveDirectModeMemory.fileName));
      if (!await file.exists()) return;
      _directModes =
          LiveDirectModeMemory.fromJson(jsonDecode(await file.readAsString()));
    } catch (_) {
      // 读失败按空表处理：只影响「少探测一次」，不影响播放。
    }
  }

  /// 加载直播频道。[configured] / [baseUri] 是主配置源的 lives；设置了独立直播源时
  /// 改用它的频道（主配置只供点播），用户导入与「手动添加」的频道始终合并在后。
  Future<LiveCatalog> load(
    List<Live> configured, {
    Uri? baseUri,
    bool refresh = false,
  }) async {
    await _initialize();
    final warnings = <String>[
      if (_storageWarning != null) _storageWarning!,
      if (_sourceHistoryWarning != null) _sourceHistoryWarning!,
    ];
    var active = _sourceHistory.activeEntry;
    List<LiveChannelEntry>? refreshedChannels;
    if (active != null && refresh && active.kind == LiveSourceKind.config) {
      final refreshed = await _refreshConfigSource(active, warnings);
      active = refreshed.entry;
      refreshedChannels = refreshed.channels;
    }
    final lives = active == null ? configured : _livesOf(active);
    final livesBase = active == null ? baseUri : Uri.tryParse(active.location);
    // 成功刷新直接使用已验证的频道，避免脚本再次执行并生成第二批代理地址。
    // 空列表不进 async 辅助方法：多一次 await 会让起播晚一个微任务（与改动前时序一致）。
    final configuredResults = refreshedChannels ?? (lives.isEmpty
        ? const <LiveChannelEntry>[]
        : await _resolveConfigured(lives, livesBase, refresh, warnings));
    if (refresh) {
      final updates = <LiveSource, LiveSource>{};
      for (final source in List<LiveSource>.of(_sources)) {
        if (source.location == null) continue;
        try {
          final document = await loadLiveText(
            Uri.parse(source.location!),
            dio: _dio,
            allowFile: true,
            maxBytes: 5 * 1024 * 1024,
          );
          updates[source] = LiveSource(
            id: source.id,
            name: source.name,
            location: source.location,
            epg: source.epg,
            channels: _parser.parse(document.content,
                baseUri: document.uri, epg: source.epg),
          );
        } catch (error) {
          warnings.add('${source.name}：更新失败，保留缓存。${liveErrorMessage(error)}');
        }
      }
      if (updates.isNotEmpty) {
        try {
          // 按对象身份应用刷新，避免慢请求复活已删除或覆盖已重新导入的源。
          await _commit((current) =>
              current.map((source) => updates[source] ?? source).toList());
        } catch (error) {
          warnings.add('直播源更新未保存：${liveErrorMessage(error)}');
        }
      }
    }
    final entries = <LiveChannelEntry>[
      ...configuredResults,
      for (final source in _sources)
        for (final channel in source.channels)
          (
            channel: channel,
            source: source.id == manualSourceId ? null : source,
          ),
    ];
    return LiveCatalog(
      channels: mergeLiveChannels(
          entries.where((entry) => _isPlayable(entry.channel))),
      warnings: List.unmodifiable(warnings),
    );
  }

  /// 逐条解析配置里的 lives（清单类拉取并展开）。
  Future<List<LiveChannelEntry>> _resolveConfigured(
    List<Live> configured,
    Uri? baseUri,
    bool refresh,
    List<String> warnings,
  ) async {
    final results = List<List<Live>>.generate(configured.length, (_) => []);
    // 限制订阅并发，不因一条慢源阻断已知直链，也不同时请求所有站点。
    for (var offset = 0; offset < configured.length; offset += 4) {
      final end = (offset + 4).clamp(0, configured.length);
      await Future.wait([
        for (var index = offset; index < end; index++)
          _loadConfigured(configured[index], baseUri, refresh, warnings)
              .then((value) => results[index] = value),
      ]);
    }
    final inlineSource = Object();
    final sources = [
      for (final source in configured)
        source.isScripted || source.isPlaylist ? Object() : inlineSource,
    ];
    return [
      for (var index = 0; index < results.length; index++)
        for (final channel in results[index])
          (channel: channel, source: sources[index]),
    ];
  }

  static bool _isPlayable(Live channel) =>
      !channel.isScripted &&
      !channel.isPlaylist &&
      LivePlaylistParser.isStreamUrl(channel.url);

  static int _playableCount(Iterable<Live> channels) =>
      channels.where(_isPlayable).map((channel) => channel.key).toSet().length;

  /// 独立直播源对应的 lives：配置类型用快照，清单类型就是清单地址本身。
  List<Live> _livesOf(LiveSourceEntry entry) => entry.kind ==
          LiveSourceKind.config
      ? entry.lives
      : [Live(name: entry.displayName, url: entry.location, isPlaylist: true)];

  /// 先验证新配置可加载，再提交描述快照；失败后由 load 重新加载旧描述。
  Future<({LiveSourceEntry entry, List<LiveChannelEntry>? channels})>
      _refreshConfigSource(
    LiveSourceEntry entry,
    List<String> warnings,
  ) async {
    try {
      final sourceUri = Uri.parse(entry.location);
      final document = await _fetchSourceText(sourceUri);
      final detected = _classifySourceText(document.content);
      if (detected.kind != LiveSourceKind.config) {
        throw const FormatException('地址返回的已不是配置 JSON');
      }
      final refreshWarnings = <String>[];
      final channels = await _resolveConfigured(
          detected.lives, sourceUri, true, refreshWarnings);
      if (_playableCount(channels.map((entry) => entry.channel)) == 0) {
        throw FormatException(refreshWarnings.isEmpty
            ? '配置里的直播没有可播放的频道'
            : '配置里的直播都无法加载：${refreshWarnings.first}');
      }
      final next = entry.copyWith(lives: List.unmodifiable(detected.lives));
      if (jsonEncode(next.toJson()) != jsonEncode(entry.toJson())) {
        await _commitSourceHistory(
            (history) => history.replace(next), notify: false);
      }
      warnings.addAll(refreshWarnings);
      return (entry: next, channels: channels);
    } catch (error) {
      warnings.add(
          '${entry.displayName}：更新失败，保留上次的直播源配置。${liveErrorMessage(error)}');
      return (entry: entry, channels: null);
    }
  }

  Future<List<Live>> _loadConfigured(
    Live source,
    Uri? baseUri,
    bool refresh,
    List<String> warnings,
  ) async {
    if (source.isScripted) {
      try {
        final loader = _loadScript;
        if (loader == null) {
          throw const FormatException('当前未提供脚本直播加载器');
        }
        final resolved = _scriptCatalog.resolveSource(source, baseUri);
        final content = await loader(resolved);
        // 代理地址包含进程注册令牌，脚本结果不能进入静态清单缓存。
        return _scriptCatalog.parse(content, source: resolved, baseUri: baseUri);
      } catch (error) {
        warnings.add('${source.name}：脚本直播加载失败。${liveErrorMessage(error)}');
        return const [];
      }
    }
    final url = LivePlaylistParser.resolveAddress(source.url, baseUri);
    if (!source.isPlaylist) {
      if (!LivePlaylistParser.isStreamUrl(url)) {
        warnings.add('${source.name}：频道地址无效');
        return const [];
      }
      final lines = <LiveLine>[];
      final seenUrls = <String>{};
      for (final line in source.lines) {
        final address = LivePlaylistParser.resolveAddress(line.url, baseUri);
        if (LivePlaylistParser.isStreamUrl(address) && seenUrls.add(address)) {
          lines.add(LiveLine(name: line.name, url: address));
        }
      }
      return [
        source.copyWith(
          url: url,
          lines: List.unmodifiable(lines),
          logo: LivePlaylistParser.resolveAddress(source.logo ?? '', baseUri),
          epg: LivePlaylistParser.resolveAddress(source.epg ?? '', baseUri),
        )
      ];
    }
    final key = _playlistCacheKey(url, source);
    if (!refresh && _configuredCache.containsKey(key)) {
      return _configuredCache[key]!;
    }
    try {
      final document = await loadLiveText(
        Uri.parse(url),
        dio: _dio,
        headers: source.headers,
        allowFile: baseUri?.scheme == 'file',
        maxBytes: 5 * 1024 * 1024,
      );
      final channels = _parser.parse(
        document.content,
        baseUri: document.uri,
        group: source.group,
        epg: source.epg,
        logo: source.logo,
        headers: source.headers,
      );
      _configuredCache.putBounded(key, channels, _maxConfiguredSources);
      return channels;
    } catch (error) {
      final cached = _configuredCache[key];
      warnings.add(
          '${source.name}：${liveErrorMessage(error)}${cached == null ? '' : '，已保留缓存频道'}');
      return cached ?? const [];
    }
  }

  /// 设置页「直播源」输入：自动识别并生效。
  ///
  /// - 频道清单（txt / m3u / m3u8，多个频道）或配置 JSON（只取 lives）：设为当前独立直播源并记入历史；
  /// - 单个播放地址（含只解析出一个频道的清单、HLS 播放流）：追加到「手动添加」，
  ///   同地址只更新名称，当前直播源和历史都不变。
  ///
  /// 识别或拉取失败抛 [FormatException]，当前直播源保持不变。
  Future<LiveSourceApplyResult> applySourceInput(String input) async {
    await _initialize();
    final parsed = _parseSourceInput(input);
    final uri = parsed.uri;
    if (!const {'http', 'https', 'file'}.contains(uri.scheme) ||
        _isMediaPath(uri)) {
      return _saveManualChannel(
          _manualChannel(parsed.name ?? _streamName(uri), uri.toString()));
    }
    final detected = await _detectSource(uri, allowSingle: true);
    if (detected is Live) {
      return _saveManualChannel(Live(
        name: parsed.name ?? detected.name,
        url: detected.url,
        group: manualSourceName,
        logo: detected.logo,
        epg: detected.epg,
        headers: detected.headers,
      ));
    }
    return LiveSourceApplyResult.source(
        await _activateSource(detected as LiveSourceEntry));
  }

  /// 从历史切换：重新拉取并识别；失败抛出，当前直播源不变。
  Future<LiveSourceEntry> useSourceEntry(String location) async {
    await _initialize();
    final uri = Uri.tryParse(location);
    if (uri == null || !const {'http', 'https', 'file'}.contains(uri.scheme)) {
      throw const FormatException('直播源地址无效');
    }
    final detected = await _detectSource(uri, allowSingle: false);
    return _activateSource(detected as LiveSourceEntry);
  }

  /// 删除一条历史；删的是当前直播源时直播回退到主配置源。
  Future<void> removeSourceEntry(String location) =>
      _commitSourceHistory((history) => history.remove(location));

  /// 不再使用独立直播源（历史保留），直播回退到主配置源。
  Future<void> clearActiveSource() =>
      _commitSourceHistory((history) => history.deactivate());

  /// 拉取并识别独立直播源地址。返回 [LiveSourceEntry]（可设为直播源）或
  /// [Live]（[allowSingle] 时只有一个频道 / 是播放流本身）。
  Future<Object> _detectSource(Uri uri, {required bool allowSingle}) async {
    final document = await _fetchSourceText(uri);
    final location = uri.toString();
    final detected =
        _classifySourceText(document.content, baseUri: document.uri);
    final now = DateTime.now().millisecondsSinceEpoch;
    if (detected.kind == LiveSourceKind.config) {
      final warnings = <String>[];
      final channels =
          await _resolveConfigured(detected.lives, uri, false, warnings);
      final count = _playableCount(channels.map((entry) => entry.channel));
      if (count == 0) {
        throw FormatException(warnings.isEmpty
            ? '配置里的直播没有可播放的频道'
            : '配置里的直播都无法加载：${warnings.first}');
      }
      return LiveSourceEntry(
        location: location,
        kind: LiveSourceKind.config,
        lastUsedAt: now,
        channelCount: count,
        lives: List.unmodifiable(detected.lives),
      );
    }
    if (detected.lives.isEmpty) {
      if (allowSingle) return _manualChannel(_streamName(uri), location);
      throw const FormatException('该地址是单个播放流，不是频道清单');
    }
    final playable = detected.lives.where(_isPlayable).toList();
    if (playable.isEmpty) throw const FormatException('频道清单里没有可播放的地址');
    if (allowSingle && _playableCount(playable) == 1) return playable.first;
    final entry = LiveSourceEntry(
      location: location,
      kind: LiveSourceKind.playlist,
      lastUsedAt: now,
      channelCount: _playableCount(playable),
    );
    // 预热缓存：随后 load() 直接用这次的结果，不再重复下载。
    final playlist = _livesOf(entry).single;
    _configuredCache.putBounded(
      _playlistCacheKey(LivePlaylistParser.resolveAddress(playlist.url, uri),
          playlist),
      List.unmodifiable(detected.lives),
      _maxConfiguredSources,
    );
    return entry;
  }

  /// 判断返回内容：配置 JSON → lives；频道清单 → 频道；HLS 播放流 → 空列表（playlist 类型）。
  ({LiveSourceKind kind, List<Live> lives}) _classifySourceText(
    String content, {
    Uri? baseUri,
  }) {
    final text = content.replaceFirst('\uFEFF', '').trim();
    if (text.isEmpty) throw const FormatException('地址返回的内容为空');
    final decoded = VodConfig.decodeRawString(text);
    if (decoded is Map) {
      return (
        kind: LiveSourceKind.config,
        lives: _configLives(Map<String, dynamic>.from(decoded)),
      );
    }
    if (decoded is List) {
      throw const FormatException('无法识别：既不是频道清单，也不是包含 lives 的配置 JSON');
    }
    if (_looksLikeHtml(text)) {
      throw const FormatException('地址返回的是网页，不是直播清单或配置');
    }
    try {
      return (
        kind: LiveSourceKind.playlist,
        lives: _parser.parse(text, baseUri: baseUri),
      );
    } on FormatException {
      if (_hlsTag.hasMatch(text)) {
        return (kind: LiveSourceKind.playlist, lives: const <Live>[]);
      }
      throw const FormatException(
          '无法识别：请填写 txt / m3u 频道清单，或包含 lives 的配置 JSON 地址');
    }
  }

  static List<Live> _configLives(Map<String, dynamic> json) {
    final VodConfig config;
    try {
      config = VodConfig.fromJson(json);
    } catch (_) {
      throw const FormatException('配置 JSON 格式无效');
    }
    if (config.lives.isNotEmpty) return config.lives;
    if (config.sites.isEmpty && json['urls'] is List) {
      throw const FormatException('这是多仓配置，请填写其中一个仓库的配置地址');
    }
    throw const FormatException('配置 JSON 里没有直播（lives）');
  }

  Future<LiveTextDocument> _fetchSourceText(Uri uri) async {
    try {
      return await loadLiveText(uri,
          dio: _dio, allowFile: true, maxBytes: 5 * 1024 * 1024);
    } catch (error) {
      throw FormatException(liveErrorMessage(error));
    }
  }

  Future<LiveSourceEntry> _activateSource(LiveSourceEntry entry) async {
    await _commitSourceHistory((history) => history.activate(entry));
    return entry;
  }

  /// 独立直播源设置落盘（与其它直播文件共用写队列，原子替换）。
  /// 当前直播源有变化时发出 [sourceChanges]。
  Future<void> _commitSourceHistory(
    LiveSourceHistory Function(LiveSourceHistory) change, {
    bool notify = true,
  }) {
    final future = _writeQueue.catchError((_) {}).then((_) async {
      if (_disposed) throw StateError('直播源仓库已关闭');
      await _initialize();
      final next = change(_sourceHistory);
      if (dataRestorePendingRestart) {
        throw const DataRestorePendingRestartException();
      }
      final directory = await _storage.getStorageDirectory();
      final file = File(p.join(directory.path, sourceHistoryFileName));
      final temp = File('${file.path}.tmp-${++_sequence}');
      try {
        await temp.writeAsString(jsonEncode(next.toJson()), flush: true);
        await temp.rename(file.path);
      } finally {
        if (await temp.exists()) await temp.delete();
      }
      final changed = !_sameEntry(_sourceHistory.activeEntry, next.activeEntry);
      _sourceHistory = next;
      _sourceHistoryWarning = null;
      if (notify && changed) _notifySourceChanged();
    });
    _writeQueue = future;
    return future;
  }

  static bool _sameEntry(LiveSourceEntry? a, LiveSourceEntry? b) =>
      a == null || b == null
          ? a == b
          : jsonEncode(a.toJson()) == jsonEncode(b.toJson());

  /// 单个播放地址：追加到「手动添加」，同地址只更新名称。
  Future<LiveSourceApplyResult> _saveManualChannel(Live channel) async {
    var updated = false;
    var changed = false;
    await _commit((current) {
      final index = current.indexWhere((source) => source.id == manualSourceId);
      final existing = index < 0 ? const <Live>[] : current[index].channels;
      final position = existing.indexWhere((item) => item.url == channel.url);
      updated = position >= 0;
      changed = !updated || existing[position].name != channel.name;
      final channels = List<Live>.of(existing);
      if (updated) {
        channels[position] = channel;
      } else {
        channels.add(channel);
      }
      final source = LiveSource(
        id: manualSourceId,
        name: manualSourceName,
        channels: List.unmodifiable(channels),
      );
      final next = List<LiveSource>.of(current);
      if (index < 0) {
        next.add(source);
      } else {
        next[index] = source;
      }
      return next;
    });
    if (changed) _notifySourceChanged();
    return LiveSourceApplyResult.channel(channel, updated: updated);
  }

  /// 从「手动添加」删除一个频道（按地址）；删空则去掉该分组。
  /// 返回是否真的删除了；删除后通知直播重载。
  Future<bool> removeManualChannel(String url) async {
    var removed = false;
    await _commit((current) {
      final index = current.indexWhere((source) => source.id == manualSourceId);
      if (index < 0) return current;
      final source = current[index];
      final channels =
          source.channels.where((channel) => channel.url != url).toList();
      removed = channels.length != source.channels.length;
      if (!removed) return current;
      final next = List<LiveSource>.of(current);
      if (channels.isEmpty) {
        next.removeAt(index);
      } else {
        next[index] = LiveSource(
          id: source.id,
          name: source.name,
          location: source.location,
          epg: source.epg,
          channels: List.unmodifiable(channels),
        );
      }
      return next;
    });
    if (removed) _notifySourceChanged();
    return removed;
  }

  static Live _manualChannel(String name, String url) =>
      Live(name: name, url: url, group: manualSourceName);

  void _notifySourceChanged() {
    if (!_sourceChanges.isClosed) _sourceChanges.add(null);
  }

  static String _playlistCacheKey(String url, Live source) =>
      jsonEncode([url, source.group, source.epg, source.logo, source.headers]);

  /// 输入框内容：一个地址，或「名称,地址」（地址是单个播放流时作为频道名）。
  static ({String? name, Uri uri}) _parseSourceInput(String input) {
    final value = input.trim();
    if (value.isEmpty) throw const FormatException('请输入直播源地址');
    if (value.contains('\n')) {
      throw const FormatException('一次只能填写一个地址');
    }
    final direct = _sourceUri(value);
    if (direct != null) return (name: null, uri: direct);
    final comma = value.indexOf(',');
    if (comma > 0) {
      final uri = _sourceUri(value.substring(comma + 1).trim());
      final name = value.substring(0, comma).trim();
      if (uri != null && name.isNotEmpty) return (name: name, uri: uri);
    }
    throw const FormatException(
        '地址无效：请填写 http(s) 链接、本地文件路径或 rtmp / rtsp 等播放地址');
  }

  static Uri? _sourceUri(String value) {
    if (RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value) || value.startsWith(r'\\')) {
      return File(value).absolute.uri;
    }
    final uri = Uri.tryParse(value);
    if (uri == null || !LivePlaylistParser.isStreamUrl(value)) return null;
    return uri;
  }

  static const _mediaExtensions = {
    '.flv', '.mp4', '.ts', '.mkv', '.avi', '.mov', '.webm', '.mp3', '.aac', //
    '.m4a', '.m4v', '.wmv',
  };

  static bool _isMediaPath(Uri uri) =>
      _mediaExtensions.contains(p.url.extension(uri.path).toLowerCase());

  static String _streamName(Uri uri) {
    final segments = uri.pathSegments.where((segment) => segment.isNotEmpty);
    final base = segments.isEmpty
        ? ''
        : p.url.basenameWithoutExtension(segments.last);
    const generic = {'index', 'playlist', 'master', 'live', 'stream', 'mono'};
    if (base.isNotEmpty && !generic.contains(base.toLowerCase())) return base;
    return uri.host.isNotEmpty ? uri.host : '直播频道';
  }

  static bool _looksLikeHtml(String text) {
    final head = text.length > 512 ? text.substring(0, 512) : text;
    final lower = head.toLowerCase();
    return lower.startsWith('<!doctype html') ||
        lower.startsWith('<html') ||
        lower.startsWith('<head') ||
        lower.contains('<html');
  }

  static final _hlsTag = RegExp(
      r'^#EXT-X-(TARGETDURATION|MEDIA-SEQUENCE|STREAM-INF|ENDLIST|BYTERANGE|DISCONTINUITY|KEY|MAP)',
      multiLine: true,
      caseSensitive: false);

  Future<LiveSource> importInput(String input,
      {String? name, String? epg}) async {
    final value = input.trim();
    if (value.isEmpty) throw const FormatException('请输入直播清单地址或内容');
    final uri = Uri.tryParse(value);
    if (!value.contains('\n') &&
        uri != null &&
        const {'http', 'https'}.contains(uri.scheme) &&
        uri.host.isNotEmpty) {
      final document =
          await loadLiveText(uri, dio: _dio, maxBytes: 5 * 1024 * 1024);
      return _import(document,
          name: _nonEmpty(name) ?? uri.host,
          location: uri.toString(),
          epg: epg);
    }
    return _import(LiveTextDocument(value, Uri()),
        name: _nonEmpty(name) ?? '自定义直播', epg: epg);
  }

  Future<LiveSource> importFile(String path,
      {String? name, String? epg}) async {
    final uri = File(path).absolute.uri;
    final document = await loadLiveText(uri,
        dio: _dio, allowFile: true, maxBytes: 5 * 1024 * 1024);
    return _import(document,
        name: _nonEmpty(name) ?? p.basename(path),
        location: uri.toString(),
        epg: epg);
  }

  Future<LiveSource> _import(
    LiveTextDocument document, {
    required String name,
    String? location,
    String? epg,
  }) async {
    final selectedEpg = _nonEmpty(epg);
    final channels = _parser.parse(document.content,
        baseUri: document.uri.hasScheme ? document.uri : null,
        epg: selectedEpg);
    final id = location ??
        'inline-${DateTime.now().microsecondsSinceEpoch}-${++_sequence}';
    var imported = LiveSource(
        id: id,
        name: name,
        location: location,
        epg: selectedEpg,
        channels: channels);
    await _commit((current) {
      final index = current.indexWhere((source) => location != null
          ? source.location == location
          : source.location == null &&
              source.name == name &&
              jsonEncode(source.channels.map((e) => e.toJson()).toList()) ==
                  jsonEncode(channels.map((e) => e.toJson()).toList()));
      final next = List<LiveSource>.of(current);
      if (index < 0) {
        next.add(imported);
      } else {
        imported = LiveSource(
            id: current[index].id,
            name: name,
            location: location,
            epg: selectedEpg,
            channels: channels);
        next[index] = imported;
      }
      return next;
    });
    return imported;
  }

  /// 移除一个自定义源；实际移除时通知直播重载（播放器抽屉等随之刷新）。
  Future<void> removeSource(String id) async {
    var removed = false;
    await _commit((current) {
      final next = current.where((source) => source.id != id).toList();
      removed = next.length != current.length;
      return next;
    });
    if (removed) _notifySourceChanged();
  }

  Future<void> _commit(List<LiveSource> Function(List<LiveSource>) change) {
    final future = _writeQueue.catchError((_) {}).then((_) async {
      if (_disposed) throw StateError('直播源仓库已关闭');
      await _initialize();
      final next = List<LiveSource>.unmodifiable(change(_sources));
      if (dataRestorePendingRestart) {
        // 恢复后禁止落盘，避免旧内存快照覆盖刚恢复的 live_sources.json。
        // 用户主动导入 / 删除：抛出让对话框提示「本次修改未保存」，内存保持不变。
        throw const DataRestorePendingRestartException();
      }
      final directory = await _storage.getStorageDirectory();
      final file = File(p.join(directory.path, 'live_sources.json'));
      final temp = File('${file.path}.tmp-${++_sequence}');
      try {
        await temp.writeAsString(
            jsonEncode(next.map((source) => source.toJson()).toList()),
            flush: true);
        // rename 替换成功后再发布内存快照；不提前删除旧文件。
        await temp.rename(file.path);
      } finally {
        if (await temp.exists()) await temp.delete();
      }
      _sources = next;
      _storageWarning = null;
    });
    _writeQueue = future;
    return future;
  }

  /// 等待当前直播源写入落定（SET-10 备份一致性）。
  Future<void> flushPendingWrites() => _writeQueue.catchError((_) {});

  void dispose() {
    _disposed = true;
    unawaited(_sourceChanges.close());
    if (_ownsDio) _dio.close(force: true);
  }

  static String? _nonEmpty(String? value) =>
      value == null || value.trim().isEmpty ? null : value.trim();
}
