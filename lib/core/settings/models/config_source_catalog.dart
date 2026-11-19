import 'config_source_entry.dart';
import 'source_categories.dart';

/// 配置源历史与独立分类目录一起提交到 config_sources.json；兼容旧版数组。
class ConfigSourceCatalog {
  final List<ConfigSourceEntry> entries;
  final SourceCategories categories;

  ConfigSourceCatalog(Iterable<ConfigSourceEntry> entries,
      [SourceCategories? categories])
      : entries = List.unmodifiable(entries),
        categories = (categories ?? SourceCategories())
            .include(entries.map((entry) => entry.category));

  factory ConfigSourceCatalog.fromJson(Object? raw) {
    if (raw is List) {
      return ConfigSourceCatalog(raw
          .map(ConfigSourceEntry.tryFromJson)
          .whereType<ConfigSourceEntry>());
    }
    if (raw is! Map || raw['version'] != 1 || raw['entries'] is! List) {
      throw const FormatException('配置源目录格式无效');
    }
    return ConfigSourceCatalog(
        (raw['entries'] as List)
            .map(ConfigSourceEntry.tryFromJson)
            .whereType<ConfigSourceEntry>(),
        SourceCategories.fromJson(raw['categories']));
  }

  Map<String, dynamic> toJson() => {
        'version': 1,
        'categories': categories.names,
        'entries': entries.map((entry) => entry.toJson()).toList(),
      };
}

/// 支持独立目录的存储必须将分类与源条目作为一个原子快照写入。
abstract interface class ConfigSourceCatalogStorage {
  Future<ConfigSourceCatalog?> readConfigSourceCatalog();
  Future<void> saveConfigSourceCatalog(ConfigSourceCatalog catalog);
}
