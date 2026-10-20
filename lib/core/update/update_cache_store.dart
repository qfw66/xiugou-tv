import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../config/windows_config_storage.dart';

/// 一个更新源的 ETag 缓存条目。
class UpdateCacheEntry {
  final String url;
  final String etag;
  final Map<String, dynamic> payload;
  final int fetchedAt;

  const UpdateCacheEntry({
    required this.url,
    required this.etag,
    required this.payload,
    required this.fetchedAt,
  });
}

/// `update_cache.json`：按源地址保存 ETag 与上次响应。
///
/// 只是缓存，任何异常都按「没有缓存」处理，绝不阻断检查流程，也不向用户报错。
class UpdateCacheStore {
  static const String fileName = 'update_cache.json';
  static const int formatVersion = 1;

  final Future<Directory> Function() _directory;
  static int _temporarySequence = 0;

  UpdateCacheStore({Future<Directory> Function()? directory})
      : _directory = directory ?? WindowsConfigStorage().getStorageDirectory;

  Future<File> _file() async =>
      File(p.join((await _directory()).path, fileName));

  Future<Map<String, dynamic>> _load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return {};
      final content = await file.readAsString();
      if (content.trim().isEmpty) return {};
      final decoded = jsonDecode(content);
      if (decoded is! Map || decoded['version'] != formatVersion) return {};
      final entries = decoded['entries'];
      if (entries is! Map) return {};
      return Map<String, dynamic>.from(entries);
    } catch (_) {
      return {};
    }
  }

  Future<UpdateCacheEntry?> read(String url) async {
    final entries = await _load();
    final raw = entries[url];
    if (raw is! Map) return null;
    final etag = raw['etag'];
    final payload = raw['payload'];
    final fetchedAt = raw['fetchedAt'];
    if (etag is! String || etag.isEmpty) return null;
    if (payload is! Map) return null;
    return UpdateCacheEntry(
      url: url,
      etag: etag,
      payload: Map<String, dynamic>.from(payload),
      fetchedAt: fetchedAt is int ? fetchedAt : 0,
    );
  }

  Future<void> save(UpdateCacheEntry entry) async {
    final entries = await _load();
    entries[entry.url] = {
      'etag': entry.etag,
      'payload': entry.payload,
      'fetchedAt': entry.fetchedAt,
    };
    await _write(entries);
  }

  Future<void> remove(String url) async {
    final entries = await _load();
    if (entries.remove(url) == null) return;
    await _write(entries);
  }

  Future<void> _write(Map<String, dynamic> entries) async {
    try {
      final target = await _file();
      await target.parent.create(recursive: true);
      final temp = File('${target.path}.tmp-$pid-${++_temporarySequence}');
      await temp.writeAsString(
        jsonEncode({'version': formatVersion, 'entries': entries}),
        flush: true,
      );
      await temp.rename(target.path);
    } catch (_) {
      // 缓存写失败无所谓
    }
  }
}
