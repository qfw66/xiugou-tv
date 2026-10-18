enum ConfigSourceKind { url, file }

/// 配置内容与来源同次保存；sourceKind 为 null 表示粘贴内容。
class ConfigSnapshot {
  final String rawContent;
  final ConfigSourceKind? sourceKind;
  final String? sourceLocation;
  final List<String> depotPath;

  ConfigSnapshot({
    required this.rawContent,
    this.sourceKind,
    this.sourceLocation,
    List<String> depotPath = const [],
  }) : depotPath = List.unmodifiable(depotPath);

  factory ConfigSnapshot.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1 || json['rawContent'] is! String) {
      throw const FormatException('当前配置快照格式无效');
    }
    final kind = switch (json['sourceKind']) {
      'url' => ConfigSourceKind.url,
      'file' => ConfigSourceKind.file,
      'paste' => null,
      _ => throw const FormatException('当前配置来源类型无效'),
    };
    final location = json['sourceLocation'];
    if (kind != null && (location is! String || location.trim().isEmpty)) {
      throw const FormatException('当前配置来源位置缺失');
    }
    return ConfigSnapshot(
      rawContent: json['rawContent'] as String,
      sourceKind: kind,
      sourceLocation: kind == null ? null : location as String,
      depotPath:
          (json['depotPath'] as List<dynamic>?)?.cast<String>() ?? const [],
    );
  }

  Map<String, dynamic> toJson() => {
        'version': 1,
        'rawContent': rawContent,
        'sourceKind': sourceKind?.name ?? 'paste',
        if (sourceLocation != null) 'sourceLocation': sourceLocation,
        'depotPath': depotPath,
      };
}
