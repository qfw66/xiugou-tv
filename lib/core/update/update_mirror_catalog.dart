import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import '../config/windows_config_storage.dart';
import '../storage/data_restore_guard.dart';
import 'update_mirrors.dart';

void _throwIfCancelled(CancelToken? token) {
  if (token?.isCancelled ?? false) throw token!.cancelError!;
}

/// 远程目录只管理代理候选，不提供版本信息或替换安装包摘要。
class MirrorCatalogDocument {
  final int revision;
  final int ttlSeconds;
  final List<UpdateMirror> mirrors;

  MirrorCatalogDocument._(
      this.revision, this.ttlSeconds, List<UpdateMirror> mirrors)
      : mirrors = List.unmodifiable(mirrors);

  factory MirrorCatalogDocument.parse(Object? raw) {
    if (raw is! Map ||
        raw['version'] is! int ||
        raw['version'] != 1 ||
        raw['revision'] is! int ||
        raw['revision'] < 1 ||
        raw['revision'] > 9007199254740991 ||
        raw['ttlSeconds'] is! int ||
        raw['ttlSeconds'] < 60 ||
        raw['ttlSeconds'] > 86400 ||
        raw['mirrors'] is! List) {
      throw const FormatException('镜像目录格式无效');
    }
    final entries = raw['mirrors'] as List;
    if (entries.length > 16) throw const FormatException('镜像数量过多');
    final ids = <String>{};
    final prefixes = <String>{};
    final mirrors = <UpdateMirror>[];
    for (final entry in entries) {
      if (entry is! Map) throw const FormatException('镜像条目无效');
      final id = entry['id'];
      final label = entry['label'];
      final prefix = entry['prefix'];
      final api = entry['proxiesApi'];
      if (id is! String ||
          !RegExp(r'^[a-z0-9][a-z0-9-]{0,47}$').hasMatch(id) ||
          label is! String ||
          label.trim().isEmpty ||
          label.runes.length > 80 ||
          RegExp(r'[\p{Cc}\p{Cf}]', unicode: true).hasMatch(label) ||
          prefix is! String ||
          !isValidMirrorPrefix(prefix) ||
          api is! bool ||
          !ids.add(id) ||
          !prefixes.add('${Uri.parse(prefix).host}${Uri.parse(prefix).path}')) {
        throw const FormatException('镜像条目无效');
      }
      mirrors.add(
          UpdateMirror(id: id, label: label, prefix: prefix, proxiesApi: api));
    }
    return MirrorCatalogDocument._(raw['revision'], raw['ttlSeconds'], mirrors);
  }

  Map<String, Object> toJson() => {
        'version': 1,
        'revision': revision,
        'ttlSeconds': ttlSeconds,
        'mirrors': mirrors.map((mirror) => mirror.toJson()).toList(),
      };
}

class _CatalogCache {
  final MirrorCatalogDocument document;
  final String? etag;
  final DateTime fetchedAt;
  const _CatalogCache(this.document, this.etag, this.fetchedAt);
}

/// 64 KiB、总计六秒、禁用重定向；出错使用该端点最近一次有效目录，再退到内置。
/// 有效的空目录必须保留，不能把运营者停用的镜像重新加入候选。
class UpdateMirrorCatalog {
  static const maxResponseBytes = 64 * 1024;
  static const builtInEndpoint =
      String.fromEnvironment('XIUGOU_UPDATE_MIRRORS_URL');
  final Dio _dio;
  final Future<Directory> Function() _directory;
  final DateTime Function() _now;
  final String defaultEndpoint;
  final Duration timeout;
  final Map<String, _CatalogCache> _memory = {};
  int _generation = 0;
  static int _tempSequence = 0;

  UpdateMirrorCatalog({
    Dio? dio,
    Future<Directory> Function()? directory,
    DateTime Function()? now,
    this.defaultEndpoint = builtInEndpoint,
    this.timeout = const Duration(seconds: 6),
  })  : _dio =
            dio ?? Dio(BaseOptions(connectTimeout: const Duration(seconds: 3))),
        _directory = directory ?? WindowsConfigStorage().getStorageDirectory,
        _now = now ?? DateTime.now;

  void dispose() {
    _generation++;
    _dio.close(force: true);
  }

  Future<List<UpdateMirror>> resolve({
    String endpoint = '',
    bool enabled = true,
    CancelToken? cancelToken,
  }) async {
    final ticket = ++_generation;
    _throwIfCancelled(cancelToken);
    if (!enabled || dataRestorePendingRestart) return const [];
    final url =
        endpoint.trim().isEmpty ? defaultEndpoint.trim() : endpoint.trim();
    if (!isValidMirrorEndpoint(url)) return kBuiltinMirrors;
    final disk = await _read(url);
    _throwIfCancelled(cancelToken);
    if (dataRestorePendingRestart) return const [];
    // A newer request may have accepted a revision while this disk read waited.
    // Disk hydration has no side effects and never replaces that accepted value.
    final cached = _memory[url] ?? disk;
    if (ticket == _generation && cached != null && !_memory.containsKey(url)) {
      _remember(url, cached);
    }
    final age = cached == null ? null : _now().difference(cached.fetchedAt);
    if (age != null &&
        !age.isNegative &&
        age.inSeconds < cached!.document.ttlSeconds) {
      return cached.document.mirrors;
    }

    final request = CancelToken();
    // 与下载器共用用户取消，但目录自己的超时只终止目录请求。
    unawaited(cancelToken?.whenCancel.then((_) {
      if (!request.isCancelled) request.cancel('用户取消');
    }));
    final deadline = Timer(timeout, () => request.cancel('镜像目录请求超时'));
    try {
      final response = await _dio.get<ResponseBody>(
        url,
        cancelToken: request,
        options: Options(
          responseType: ResponseType.stream,
          followRedirects: false,
          validateStatus: (_) => true,
          receiveTimeout: timeout,
          headers: {
            'Accept': 'application/json',
            if (cached?.etag != null) 'If-None-Match': cached!.etag
          },
        ),
      );
      MirrorCatalogDocument document;
      String? etag;
      if (response.statusCode == 304 && cached != null) {
        await response.data?.stream.listen(null).cancel();
        document = cached.document;
        etag = cached.etag;
      } else {
        if (response.statusCode != 200 || response.data == null) {
          await response.data?.stream.listen(null).cancel();
          throw const FormatException('镜像目录响应无效');
        }
        final declared = int.tryParse(
            response.headers.value(Headers.contentLengthHeader) ?? '');
        if (declared != null && declared > maxResponseBytes) {
          await response.data!.stream.listen(null).cancel();
          throw const FormatException('镜像目录过大');
        }
        final bytes = <int>[];
        await for (final chunk in response.data!.stream) {
          _throwIfCancelled(request);
          if (bytes.length + chunk.length > maxResponseBytes) {
            request.cancel('镜像目录过大');
            throw const FormatException('镜像目录过大');
          }
          bytes.addAll(chunk);
        }
        document = MirrorCatalogDocument.parse(jsonDecode(utf8.decode(bytes)));
        etag = response.headers.value('etag');
        if (etag != null &&
            (etag.length > 256 || RegExp(r'[\x00-\x1f\x7f]').hasMatch(etag))) {
          etag = null;
        }
        final latest = _memory[url] ?? cached;
        if (latest != null &&
            (document.revision < latest.document.revision ||
                (document.revision == latest.document.revision &&
                    jsonEncode(document.toJson()) !=
                        jsonEncode(latest.document.toJson())))) {
          throw const FormatException('镜像目录修订号倒退或复用');
        }
      }
      _throwIfCancelled(cancelToken);
      if (dataRestorePendingRestart) return const [];
      final updated = _CatalogCache(document, etag, _now());
      if (ticket == _generation) {
        _remember(url, updated);
        await _save(url, updated, ticket, cancelToken);
      }
      _throwIfCancelled(cancelToken);
      return document.mirrors;
    } catch (_) {
      _throwIfCancelled(cancelToken);
      return dataRestorePendingRestart
          ? const []
          : (_memory[url] ?? cached)?.document.mirrors ?? kBuiltinMirrors;
    } finally {
      deadline.cancel();
      if (!request.isCancelled) request.cancel('目录读取结束');
    }
  }

  void _remember(String url, _CatalogCache cached) {
    if (!_memory.containsKey(url) && _memory.length >= 4) {
      _memory.remove(_memory.keys.first);
    }
    _memory[url] = cached;
  }

  Future<File> _file(String url) async => File(p.join((await _directory()).path,
      'update_mirrors_${sha256.convert(utf8.encode(url))}.json'));

  Future<_CatalogCache?> _read(String url) async {
    if (_memory.containsKey(url)) return _memory[url];
    try {
      if (dataRestorePendingRestart) return null;
      final file = await _file(url);
      if (!await file.exists() || await file.length() > maxResponseBytes * 2) {
        return null;
      }
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map || raw['url'] != url || raw['fetchedAt'] is! int) {
        return null;
      }
      final document = MirrorCatalogDocument.parse(raw['payload']);
      final etag = raw['etag'];
      if (etag != null &&
          (etag is! String ||
              etag.length > 256 ||
              RegExp(r'[\x00-\x1f\x7f]').hasMatch(etag))) {
        return null;
      }
      return _CatalogCache(document, etag,
          DateTime.fromMillisecondsSinceEpoch(raw['fetchedAt']));
    } catch (_) {
      return null;
    }
  }

  Future<void> _save(String url, _CatalogCache cached, int ticket,
      CancelToken? cancelToken) async {
    File? temporary;
    bool valid() =>
        !dataRestorePendingRestart &&
        ticket == _generation &&
        !(cancelToken?.isCancelled ?? false);
    try {
      if (!valid()) return;
      final file = await _file(url);
      if (!valid()) return;
      await file.parent.create(recursive: true);
      if (!valid()) return;
      temporary = File('${file.path}.tmp-$pid-${++_tempSequence}');
      await temporary.writeAsString(
          jsonEncode({
            'url': url,
            'fetchedAt': cached.fetchedAt.millisecondsSinceEpoch,
            'etag': cached.etag,
            'payload': cached.document.toJson(),
          }),
          flush: true);
      if (!valid()) return;
      await temporary.rename(file.path);
    } catch (_) {
      // 缓存失败保留内存目录，不妨碍本次更新。
    } finally {
      try {
        if (temporary != null && await temporary.exists()) {
          await temporary.delete();
        }
      } catch (_) {/* 临时缓存清理尽力而为 */}
    }
  }
}
