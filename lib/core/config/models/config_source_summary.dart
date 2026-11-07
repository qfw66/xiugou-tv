import 'package:path/path.dart' as p;

import '../../settings/models/config_source_entry.dart';
import '../config_repository.dart';

/// 顶栏「配置源」徽标的展示信息（方案 §4.1）。
///
/// 只做展示与文案推导，不访问仓库；由 [buildConfigSourceSummary] 纯函数生成，
/// 便于在播放器顶栏与设置页之外复用与测试。
class ConfigSourceSummary {
  const ConfigSourceSummary({
    this.kind,
    this.location,
    required this.displayName,
    this.fullLabel,
    required this.canSwitch,
  });

  /// 当前配置来源类型；来自粘贴内容或尚未加载时为 null。
  final ConfigSourceKind? kind;

  /// 当前配置来源地址（URL 或本地绝对路径）；粘贴内容为 null。
  final String? location;

  /// 胶囊上的短名称（别名优先，其次按 URL / 文件名派生）。
  final String displayName;

  /// 胶囊 tooltip：完整地址 / 路径，或粘贴配置的说明。
  final String? fullLabel;

  /// 历史中是否存在「当前项以外」的可切换来源。
  final bool canSwitch;
}

const String _pastedLabel = '粘贴配置';
const String _unloadedLabel = '未加载配置';
const int _maxDisplayLength = 32;

/// 按方案 §4.1 的表格推导当前配置源短名称。
///
/// - 历史别名优先；
/// - 远程 URL 无别名时取「主机名（去 www.）+ 路径末段」，总长不超过 32；
/// - 本地文件取去掉扩展名的文件名；
/// - 粘贴内容显示「粘贴配置」，没有配置时显示「未加载配置」；
/// - 来源地址不在历史中时，仍按来源推导短名称（菜单会合成当前项）。
ConfigSourceSummary buildConfigSourceSummary({
  required ConfigSourceKind? kind,
  required String? location,
  required List<ConfigSourceEntry> entries,
  required bool hasConfig,
}) {
  final normalized = location?.trim();
  final resolvedKind = kind ??
      (normalized == null || normalized.isEmpty
          ? null
          : _isHttpUrl(normalized)
              ? ConfigSourceKind.url
              : ConfigSourceKind.file);
  final matched = _findEntry(entries, normalized);

  if (matched != null) {
    final alias = matched.name.trim();
    final name =
        alias.isNotEmpty ? alias : _deriveName(normalized, resolvedKind);
    return ConfigSourceSummary(
      kind: resolvedKind,
      location: normalized,
      displayName: name,
      fullLabel: _fullLabel(normalized, resolvedKind, hasConfig: hasConfig),
      canSwitch: _hasSwitchableEntry(entries, normalized),
    );
  }

  if (normalized == null || normalized.isEmpty) {
    return ConfigSourceSummary(
      kind: null,
      location: null,
      displayName: hasConfig ? _pastedLabel : _unloadedLabel,
      fullLabel: hasConfig ? '当前配置来自粘贴内容，无法重新加载' : null,
      canSwitch: _hasSwitchableEntry(entries, null),
    );
  }

  return ConfigSourceSummary(
    kind: resolvedKind,
    location: normalized,
    displayName: _deriveName(normalized, resolvedKind),
    fullLabel: _fullLabel(normalized, resolvedKind, hasConfig: hasConfig),
    canSwitch: _hasSwitchableEntry(entries, normalized),
  );
}

ConfigSourceEntry? _findEntry(
    List<ConfigSourceEntry> entries, String? location) {
  if (location == null || location.isEmpty) return null;
  for (final entry in entries) {
    if (entry.location.trim() == location) return entry;
  }
  return null;
}

bool _hasSwitchableEntry(List<ConfigSourceEntry> entries, String? location) =>
    entries.any((entry) {
      final entryLocation = entry.location.trim();
      return entryLocation.isNotEmpty && entryLocation != location;
    });

String _deriveName(String? location, ConfigSourceKind? kind) {
  if (location == null || location.isEmpty) return _unloadedLabel;
  if (kind == ConfigSourceKind.file) return _fileDisplayName(location);
  return _urlDisplayName(location);
}

String _urlDisplayName(String location) {
  final parsed = Uri.tryParse(location);
  if (parsed == null || parsed.host.isEmpty) return _fileDisplayName(location);
  var host = parsed.host;
  if (host.startsWith('www.')) host = host.substring(4);
  final segments = parsed.pathSegments
      .where((segment) => segment.trim().isNotEmpty)
      .toList();
  final combined = segments.isEmpty ? host : '$host/${segments.last}';
  return _shorten(combined);
}

String _fileDisplayName(String location) {
  final name = p.basenameWithoutExtension(location);
  return _shorten(name.isEmpty ? location : name);
}

String _shorten(String value, {int max = _maxDisplayLength}) {
  if (value.length <= max) return value;
  const ellipsis = '…';
  const tailLength = 11;
  final headLength = max - tailLength - ellipsis.length;
  return '${value.substring(0, headLength)}$ellipsis'
      '${value.substring(value.length - tailLength)}';
}

String? _fullLabel(
  String? location,
  ConfigSourceKind? kind, {
  required bool hasConfig,
}) {
  if (location == null || location.isEmpty) {
    return hasConfig ? '当前配置来自粘贴内容，无法重新加载' : null;
  }
  return kind == ConfigSourceKind.file ? '本地文件：$location' : '远程订阅：$location';
}

bool _isHttpUrl(String value) {
  final uri = Uri.tryParse(value);
  return uri != null && (uri.scheme == 'http' || uri.scheme == 'https');
}
