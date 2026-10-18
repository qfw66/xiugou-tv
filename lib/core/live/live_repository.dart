import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import '../config/models/vod_config.dart';
import '../config/windows_config_storage.dart';
import '../storage/data_restore_guard.dart';
import 'live_playlist_parser.dart';
import 'live_source.dart';
import 'live_text_loader.dart';

/// 直播源独立落盘；配置内的源与用户导入源不会修改点播配置。
class LiveRepository {
  final WindowsConfigStorage _storage;
  final Dio _dio;
  final bool _ownsDio;
  final _parser = const LivePlaylistParser();
  final _configuredCache = <String, List<Live>>{};
  List<LiveSource> _sources = const [];
  Future<void>? _initializing;
  Future<void> _writeQueue = Future.value();
  String? _storageWarning;
  var _sequence = 0;
  var _disposed = false;

  LiveRepository({WindowsConfigStorage? storage, Dio? dio})
      : _storage = storage ?? WindowsConfigStorage(),
        _ownsDio = dio == null,
        _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 20),
            ));

  List<LiveSource> get sources => List.unmodifiable(_sources);

  Future<void> _initialize() => _initializing ??= _readSources();

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

  Future<LiveCatalog> load(
    List<Live> configured, {
    Uri? baseUri,
    bool refresh = false,
  }) async {
    await _initialize();
    final warnings = <String>[
      if (_storageWarning != null) _storageWarning!,
    ];
    final configuredResults =
        List<List<Live>>.generate(configured.length, (_) => []);
    // 限制订阅并发，不因一条慢源阻断已知直链，也不同时请求所有站点。
    for (var offset = 0; offset < configured.length; offset += 4) {
      final end = (offset + 4).clamp(0, configured.length);
      await Future.wait([
        for (var index = offset; index < end; index++)
          _loadConfigured(configured[index], baseUri, refresh, warnings)
              .then((value) => configuredResults[index] = value),
      ]);
    }
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
    final channels = <String, Live>{};
    for (final channel in [
      ...configuredResults.expand((value) => value),
      ..._sources.expand((source) => source.channels),
    ]) {
      if (!channel.isPlaylist && LivePlaylistParser.isStreamUrl(channel.url)) {
        channels.putIfAbsent(channel.key, () => channel);
      }
    }
    return LiveCatalog(
      channels: List.unmodifiable(channels.values),
      warnings: List.unmodifiable(warnings),
    );
  }

  Future<List<Live>> _loadConfigured(
    Live source,
    Uri? baseUri,
    bool refresh,
    List<String> warnings,
  ) async {
    final url = LivePlaylistParser.resolveAddress(source.url, baseUri);
    if (!source.isPlaylist) {
      if (!LivePlaylistParser.isStreamUrl(url)) {
        warnings.add('${source.name}：频道地址无效');
        return const [];
      }
      return [
        source.copyWith(
          url: url,
          logo: LivePlaylistParser.resolveAddress(source.logo ?? '', baseUri),
          epg: LivePlaylistParser.resolveAddress(source.epg ?? '', baseUri),
        )
      ];
    }
    final key = jsonEncode(
        [url, source.group, source.epg, source.logo, source.headers]);
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
      _configuredCache[key] = channels;
      return channels;
    } catch (error) {
      final cached = _configuredCache[key];
      warnings.add(
          '${source.name}：${liveErrorMessage(error)}${cached == null ? '' : '，已保留缓存频道'}');
      return cached ?? const [];
    }
  }

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

  Future<void> removeSource(String id) =>
      _commit((current) => current.where((source) => source.id != id).toList());

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
    if (_ownsDio) _dio.close(force: true);
  }

  static String? _nonEmpty(String? value) =>
      value == null || value.trim().isEmpty ? null : value.trim();
}
