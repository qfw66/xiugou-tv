import '../../config/config_repository.dart';

/// 配置源历史条目：一个曾成功加载过的远程订阅地址或本地配置文件
class ConfigSourceEntry {
  final ConfigSourceKind kind;

  /// 远程地址或本地文件绝对路径（同时作为唯一标识）
  final String location;

  /// 用户自定义名称；为空时界面显示地址
  final String name;

  /// 最近一次成功加载时间（毫秒时间戳）
  final int lastUsedAt;
  final int siteCount;
  final int liveCount;

  const ConfigSourceEntry({
    required this.kind,
    required this.location,
    this.name = '',
    this.lastUsedAt = 0,
    this.siteCount = 0,
    this.liveCount = 0,
  });

  String get displayName => name.trim().isNotEmpty ? name.trim() : location;

  /// 反序列化；缺少有效地址时返回 null（由调用方丢弃）
  static ConfigSourceEntry? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final location = json['location']?.toString().trim() ?? '';
    if (location.isEmpty) return null;

    int asInt(Object? raw) {
      if (raw is num && raw.isFinite) return raw.toInt();
      return int.tryParse(raw?.toString() ?? '') ?? 0;
    }

    final kindName = json['kind']?.toString();
    final kind = kindName == ConfigSourceKind.file.name ? ConfigSourceKind.file : ConfigSourceKind.url;
    return ConfigSourceEntry(
      kind: kind,
      location: location,
      name: json['name']?.toString() ?? '',
      lastUsedAt: asInt(json['lastUsedAt']),
      siteCount: asInt(json['siteCount']),
      liveCount: asInt(json['liveCount']),
    );
  }

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'location': location,
        if (name.isNotEmpty) 'name': name,
        'lastUsedAt': lastUsedAt,
        'siteCount': siteCount,
        'liveCount': liveCount,
      };

  ConfigSourceEntry copyWith({String? name, int? lastUsedAt, int? siteCount, int? liveCount}) {
    return ConfigSourceEntry(
      kind: kind,
      location: location,
      name: name ?? this.name,
      lastUsedAt: lastUsedAt ?? this.lastUsedAt,
      siteCount: siteCount ?? this.siteCount,
      liveCount: liveCount ?? this.liveCount,
    );
  }
}
