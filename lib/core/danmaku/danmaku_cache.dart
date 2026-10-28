import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// 弹幕磁盘缓存：按「取数地址」哈希落盘原始 JSON。
///
/// 单集可达 4 MB、取一次 10–40 s，同一集重看 / 切回不应再拉一次。
/// 淘汰：超过 [maxAge] 的文件读时视为未命中并删除；写入后按修改时间 LRU 把总量压到 [maxBytes] 以内。
class DanmakuCache {
  DanmakuCache(this.directory,
      {this.maxAge = const Duration(days: 7), this.maxBytes = 200 * 1024 * 1024, DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final String directory;
  final Duration maxAge;
  final int maxBytes;
  final DateTime Function() _clock;

  static String keyOf(String url) => sha1.convert(utf8.encode(url)).toString();

  File _file(String url) => File(p.join(directory, '${keyOf(url)}.json'));

  /// 命中返回原文；过期 / 不存在 / 读失败返回 null。命中会刷新修改时间（LRU）。
  Future<String?> read(String url) async {
    final file = _file(url);
    try {
      if (!await file.exists()) return null;
      final modified = await file.lastModified();
      if (_clock().difference(modified) > maxAge) {
        await file.delete();
        return null;
      }
      final body = await file.readAsString();
      await file.setLastModified(_clock());
      return body;
    } catch (_) {
      return null;
    }
  }

  /// 写入（先写临时文件再改名，避免半截文件）；随后做容量淘汰。失败静默。
  Future<void> write(String url, String body) async {
    try {
      final dir = Directory(directory);
      await dir.create(recursive: true);
      final file = _file(url);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(body, flush: true);
      if (await file.exists()) await file.delete();
      await tmp.rename(file.path);
      await file.setLastModified(_clock());
      await evict();
    } catch (_) {
      // 缓存只是加速，写不进去不影响播放
    }
  }

  /// 按修改时间从旧到新删除，直到总量 ≤ [maxBytes]；顺带清掉过期文件与残留 .tmp。
  Future<void> evict() async {
    final dir = Directory(directory);
    if (!await dir.exists()) return;
    final entries = <(File, DateTime, int)>[];
    await for (final e in dir.list()) {
      if (e is! File) continue;
      final stat = await e.stat();
      if (e.path.endsWith('.tmp') || _clock().difference(stat.modified) > maxAge) {
        await e.delete().catchError((_) => e);
        continue;
      }
      if (e.path.endsWith('.json')) entries.add((e, stat.modified, stat.size));
    }
    var total = entries.fold<int>(0, (s, e) => s + e.$3);
    if (total <= maxBytes) return;
    entries.sort((a, b) => a.$2.compareTo(b.$2));
    for (final e in entries) {
      if (total <= maxBytes) break;
      await e.$1.delete().catchError((_) => e.$1);
      total -= e.$3;
    }
  }
}
