import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'config_snapshot.dart';
import 'builtin_sites.dart';
import 'vod_config.dart';

/// 首页默认站源的稳定引用；名称只用于失效提示，不参与匹配。
class HomeSitePreference {
  final String siteKey;
  final String siteIdentity;
  final String name;

  const HomeSitePreference({
    required this.siteKey,
    required this.siteIdentity,
    required this.name,
  });

  factory HomeSitePreference.fromSite(Site site) => HomeSitePreference(
        siteKey: site.key,
        siteIdentity: _siteIdentity(site),
        name: site.name,
      );

  bool matches(Site site) =>
      site.key == siteKey && _siteIdentity(site) == siteIdentity;

  static HomeSitePreference? tryFromJson(Object? value) {
    if (value is! Map) return null;
    final key = value['siteKey'];
    final identity = value['siteIdentity'];
    final name = value['name'];
    if (key is! String || key.trim().isEmpty ||
        identity is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(identity)) {
      return null;
    }
    return HomeSitePreference(
      siteKey: key,
      siteIdentity: identity,
      name: name is String && name.trim().isNotEmpty ? name : key,
    );
  }

  Map<String, dynamic> toJson() => {
        'siteKey': siteKey,
        'siteIdentity': siteIdentity,
        'name': name,
      };

  /// URL 保留输入身份；文件按平台规范化；粘贴按解码内容识别。
  static String sourceIdentity(ConfigSnapshot snapshot) {
    String? location = snapshot.sourceLocation?.trim();
    if (snapshot.sourceKind == ConfigSourceKind.file && location != null) {
      location = p.normalize(location);
      if (Platform.isWindows) location = location.toLowerCase();
    }
    return _digest([
      1,
      snapshot.sourceKind?.name ?? 'paste',
      snapshot.sourceKind == null
          ? VodConfig.decodeRawString(snapshot.rawContent)
          : location,
      snapshot.depotPath,
    ]);
  }

  static String _siteIdentity(Site site) => _digest([
        site.type,
        site.api.trim(),
        site.ext?.trim() ?? '',
        site.jar?.trim() ?? '',
      ]);

  /// 请求身份还包含请求头等参数；显示名称变化不清空浏览状态。
  static String requestIdentity(Site site) =>
      _digest(Map<String, dynamic>.from(site.toJson())..remove('name'));

  /// 只判断是否存在已接入的请求路径，不承诺远端或扩展运行成功。
  static bool canSelect(Site site) {
    if (site.key.trim().isEmpty) return false;
    // 内置虚拟站自带数据层（§17），不依赖配置里的请求端点
    if (isBuiltinSite(site)) return true;
    if (site.usesCompanion && site.api.trim().isNotEmpty) return true;
    bool isHttp(String value) {
      final uri = Uri.tryParse(value.trim());
      return uri != null &&
          (value.trim().startsWith('http://') ||
              value.trim().startsWith('https://')) &&
          uri.host.isNotEmpty;
    }
    if (isHttp(site.api) || isHttp(site.ext ?? '')) return true;
    try {
      final ext = jsonDecode(site.ext ?? '');
      if (ext is Map) {
        final endpoint = ext['url'] ?? ext['api'] ?? ext['site'];
        return endpoint is String && isHttp(endpoint);
      }
    } on FormatException {
      return false;
    }
    return false;
  }

  static String _digest(Object? value) =>
      sha256.convert(utf8.encode(jsonEncode(_canonical(value)))).toString();

  static Object? _canonical(Object? value) {
    if (value is Map) {
      final keys = value.keys.cast<String>().toList()..sort();
      return {for (final key in keys) key: _canonical(value[key])};
    }
    if (value is List) return value.map(_canonical).toList();
    return value;
  }

  @override
  bool operator ==(Object other) => other is HomeSitePreference &&
      other.siteKey == siteKey && other.siteIdentity == siteIdentity && other.name == name;

  @override
  int get hashCode => Object.hash(siteKey, siteIdentity, name);
}
