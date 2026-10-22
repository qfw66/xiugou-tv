import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../config/windows_config_storage.dart';

/// 单个镜像的健康状态（毫秒时间戳，0 表示从未发生）。
class MirrorHealth {
  final int lastOkAt;
  final int lastFailAt;
  final int consecutiveFailures;

  const MirrorHealth({
    this.lastOkAt = 0,
    this.lastFailAt = 0,
    this.consecutiveFailures = 0,
  });

  bool get hasFailed => consecutiveFailures > 0 && lastFailAt > 0;

  bool isCoolingDown(DateTime now, Duration cooldown) {
    if (!hasFailed) return false;
    return now.millisecondsSinceEpoch - lastFailAt < cooldown.inMilliseconds;
  }

  Map<String, dynamic> toJson() => {
        'lastOkAt': lastOkAt,
        'lastFailAt': lastFailAt,
        'consecutiveFailures': consecutiveFailures,
      };

  static MirrorHealth fromJson(Object? raw) {
    if (raw is! Map) return const MirrorHealth();
    final ok = raw['lastOkAt'];
    final fail = raw['lastFailAt'];
    final count = raw['consecutiveFailures'];
    return MirrorHealth(
      lastOkAt: ok is int ? ok : 0,
      lastFailAt: fail is int ? fail : 0,
      consecutiveFailures: count is int && count >= 0 ? count : 0,
    );
  }
}

/// `update_mirror_health.json` 的内存快照。
class MirrorHealthSnapshot {
  final Map<String, MirrorHealth> mirrors;

  /// 上次下载成功的镜像 id；null 表示直连成功（或从未下载过）。
  final String? lastGoodDownloadSource;

  const MirrorHealthSnapshot({
    this.mirrors = const {},
    this.lastGoodDownloadSource,
  });

  static const MirrorHealthSnapshot empty = MirrorHealthSnapshot();

  MirrorHealth healthOf(String id) => mirrors[id] ?? const MirrorHealth();

  bool isCoolingDown(
    String id, {
    DateTime? now,
    Duration cooldown = UpdateMirrorHealthStore.cooldown,
  }) =>
      healthOf(id).isCoolingDown(now ?? DateTime.now(), cooldown);

  Set<String> coolingDownIds({
    DateTime? now,
    Duration cooldown = UpdateMirrorHealthStore.cooldown,
  }) =>
      mirrors.keys
          .where((id) => isCoolingDown(id, now: now, cooldown: cooldown))
          .toSet();
}

/// 镜像健康缓存：记录成功 / 失败与「上次下载成功的源」。
///
/// 与 ETag 缓存一样属于**尽力而为**：任何读写异常都不阻断检查或下载，
/// 只是退化为「没有历史记录」。
class UpdateMirrorHealthStore {
  static const String fileName = 'update_mirror_health.json';
  static const int formatVersion = 1;

  /// 连续失败后跳过该镜像的时长。
  static const Duration cooldown = Duration(minutes: 30);

  final Future<Directory> Function() _directory;
  static int _temporarySequence = 0;

  UpdateMirrorHealthStore({Future<Directory> Function()? directory})
      : _directory = directory ?? WindowsConfigStorage().getStorageDirectory;

  Future<File> _file() async => File(p.join((await _directory()).path, fileName));

  Future<MirrorHealthSnapshot> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return MirrorHealthSnapshot.empty;
      final content = await file.readAsString();
      if (content.trim().isEmpty) return MirrorHealthSnapshot.empty;
      final decoded = jsonDecode(content);
      if (decoded is! Map || decoded['version'] != formatVersion) {
        return MirrorHealthSnapshot.empty;
      }
      final mirrors = <String, MirrorHealth>{};
      final rawMirrors = decoded['mirrors'];
      if (rawMirrors is Map) {
        rawMirrors.forEach((key, value) {
          if (key is String && key.isNotEmpty) {
            mirrors[key] = MirrorHealth.fromJson(value);
          }
        });
      }
      final lastGood = decoded['lastGoodDownloadSource'];
      return MirrorHealthSnapshot(
        mirrors: Map.unmodifiable(mirrors),
        lastGoodDownloadSource:
            lastGood is String && lastGood.isNotEmpty ? lastGood : null,
      );
    } catch (_) {
      return MirrorHealthSnapshot.empty;
    }
  }

  /// 检验成功：清零失败计数。
  Future<void> recordCheckSuccess(String mirrorId, {DateTime? now}) =>
      _mutate(mirrorId, (health, stamp) => MirrorHealth(
            lastOkAt: stamp,
            lastFailAt: health.lastFailAt,
            consecutiveFailures: 0,
          ), now: now);

  /// 检验失败：失败计数 +1，进入冷却窗口。
  Future<void> recordCheckFailure(String mirrorId, {DateTime? now}) =>
      _mutate(mirrorId, (health, stamp) => MirrorHealth(
            lastOkAt: health.lastOkAt,
            lastFailAt: stamp,
            consecutiveFailures: health.consecutiveFailures + 1,
          ), now: now);

  /// 下载成功：记录「上次成功源」；[mirrorId] 为 null 表示直连成功。
  Future<void> recordDownloadSuccess(String? mirrorId, {DateTime? now}) async {
    final stamp = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final current = await load();
    final mirrors = Map<String, MirrorHealth>.from(current.mirrors);
    if (mirrorId != null) {
      final health = current.healthOf(mirrorId);
      mirrors[mirrorId] = MirrorHealth(
        lastOkAt: stamp,
        lastFailAt: health.lastFailAt,
        consecutiveFailures: 0,
      );
    }
    await _write(MirrorHealthSnapshot(
      mirrors: Map.unmodifiable(mirrors),
      lastGoodDownloadSource: mirrorId,
    ));
  }

  /// 下载失败：与检查失败共享计数，让下一次检查更早跳过它。
  Future<void> recordDownloadFailure(String mirrorId, {DateTime? now}) =>
      recordCheckFailure(mirrorId, now: now);

  Future<void> _mutate(
    String mirrorId,
    MirrorHealth Function(MirrorHealth current, int stamp) update, {
    DateTime? now,
  }) async {
    final stamp = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final current = await load();
    final mirrors = Map<String, MirrorHealth>.from(current.mirrors);
    mirrors[mirrorId] = update(current.healthOf(mirrorId), stamp);
    await _write(MirrorHealthSnapshot(
      mirrors: Map.unmodifiable(mirrors),
      lastGoodDownloadSource: current.lastGoodDownloadSource,
    ));
  }

  Future<void> _write(MirrorHealthSnapshot snapshot) async {
    try {
      final target = await _file();
      await target.parent.create(recursive: true);
      final temp = File('${target.path}.tmp-$pid-${++_temporarySequence}');
      await temp.writeAsString(
        jsonEncode({
          'version': formatVersion,
          'lastGoodDownloadSource': snapshot.lastGoodDownloadSource,
          'mirrors': snapshot.mirrors.map((k, v) => MapEntry(k, v.toJson())),
        }),
        flush: true,
      );
      await temp.rename(target.path);
    } catch (_) {
      // 健康缓存写失败不影响主流程
    }
  }
}
