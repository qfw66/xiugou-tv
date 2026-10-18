import 'dart:convert';

/// 单个数据文件的备份条目：原文 + UTF-8 字节数 + SHA-256。
class DataBackupEntry {
  final String name;
  final int size;
  final String sha256;
  final String content;

  const DataBackupEntry({
    required this.name,
    required this.size,
    required this.sha256,
    required this.content,
  });

  Map<String, dynamic> toJson() => {
        'size': size,
        'sha256': sha256,
        'content': content,
      };

  factory DataBackupEntry.fromJson(String name, Object? raw) {
    if (raw is! Map) {
      throw FormatException('备份条目 $name 格式无效');
    }
    final map = Map<String, dynamic>.from(raw);
    final size = map['size'];
    final hash = map['sha256'];
    final content = map['content'];
    if (size is! int || size < 0) {
      throw FormatException('备份条目 $name 大小无效');
    }
    if (hash is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
      throw FormatException('备份条目 $name 校验值无效');
    }
    if (content is! String) {
      throw FormatException('备份条目 $name 内容无效');
    }
    return DataBackupEntry(
      name: name,
      size: size,
      sha256: hash,
      content: content,
    );
  }
}

/// 数据备份信封 v1。
///
/// 只存文件原文，不二次 JSON 编码对象；这样能原样保留未知字段与格式，
/// 避免「备份再恢复」造成语义漂移。
class DataBackup {
  static const String format = 'xiugou-tv-backup';
  static const int version = 1;

  final DateTime createdAt;
  final String? appVersion;

  /// false 表示读取期间有文件正在写入，备份可能不是同一时刻。
  final bool consistent;

  /// name -> entry；顺序由服务按白名单排序。
  final Map<String, DataBackupEntry> files;

  const DataBackup({
    required this.createdAt,
    this.appVersion,
    this.consistent = true,
    required this.files,
  });

  int get totalBytes =>
      files.values.fold<int>(0, (sum, entry) => sum + entry.size);

  Map<String, dynamic> toJson() => {
        'format': format,
        'version': version,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'appVersion': appVersion,
        'consistent': consistent,
        'files': {
          for (final entry in files.entries) entry.key: entry.value.toJson(),
        },
      };

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());

  factory DataBackup.fromJson(Map<String, dynamic> json) {
    if (json['format'] != format) {
      throw const FormatException('不是 修狗TV 数据备份文件');
    }
    if (json['version'] != version) {
      throw const FormatException('备份格式版本不受支持');
    }
    final rawCreatedAt = json['createdAt'];
    final createdAt =
        rawCreatedAt is String ? DateTime.tryParse(rawCreatedAt) : null;
    if (createdAt == null) {
      throw const FormatException('备份创建时间无效');
    }
    final rawFiles = json['files'];
    if (rawFiles is! Map || rawFiles.isEmpty) {
      throw const FormatException('备份不包含任何数据文件');
    }
    final files = <String, DataBackupEntry>{};
    for (final entry in rawFiles.entries) {
      final name = entry.key;
      if (name is! String) {
        throw const FormatException('备份文件名无效');
      }
      files[name] = DataBackupEntry.fromJson(name, entry.value);
    }
    final rawAppVersion = json['appVersion'];
    return DataBackup(
      createdAt: createdAt,
      appVersion: rawAppVersion is String ? rawAppVersion : null,
      consistent: json['consistent'] != false,
      files: Map.unmodifiable(files),
    );
  }
}
