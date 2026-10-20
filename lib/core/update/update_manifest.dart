import 'app_version.dart';

/// 发布包中的一个可下载资产。
class UpdateAsset {
  final String name;
  final String url;
  final int? size;

  /// 归一化后的 SHA-256（64 位小写 hex）；发布方未提供时为 null。
  final String? sha256;

  const UpdateAsset({
    required this.name,
    required this.url,
    this.size,
    this.sha256,
  });

  /// 安装版安装包（`*-setup.exe`）。
  bool get isInstaller => name.toLowerCase().endsWith('-setup.exe');

  /// 校验和清单（`SHA256SUMS` / `sha256sums.txt`）。
  bool get isChecksums =>
      RegExp(r'^sha256sums(\.txt)?$').hasMatch(name.toLowerCase());

  /// 资产地址必须是 https；http 或非法地址一律视为不安全。
  bool get isHttps => Uri.tryParse(url)?.scheme == 'https';

  @override
  String toString() => 'UpdateAsset($name, size: $size)';
}

/// 更新清单：同时接受 GitHub Releases API 形状与自建镜像的精简清单。
///
/// - GitHub：`tag_name` / `body` / `published_at` / `prerelease` / `assets[]`
///   中的 `browser_download_url` 与 `digest`。
/// - 自建：`version` / `notes` / `publishedAt` / `assets[]` 中的 `url` 与 `sha256`。
///
/// 两种形状都只取客户端真正需要的字段；其余字段忽略，不因上游新增字段而失败。
class UpdateManifest {
  /// 原始版本串（GitHub 的 `tag_name` 或自建的 `version`），如 `v1.2.0`。
  final String tag;
  final String notes;
  final DateTime? publishedAt;

  /// GitHub 的 `prerelease` 标记；自建清单视为 false。
  final bool prerelease;
  final List<UpdateAsset> assets;

  const UpdateManifest({
    required this.tag,
    required this.notes,
    required this.assets,
    this.publishedAt,
    this.prerelease = false,
  });

  /// 解析后的三段版本；无法识别时为 null。
  AppVersion? get version => AppVersion.tryParse(tag);

  /// 是否预发布（字段标记或 tag 带 `-`）。
  bool get isPrerelease => prerelease || AppVersion.isPrereleaseTag(tag);

  /// 挑选安装版资产：优先精确命名，其次任意 `*-setup.exe`（容忍发布时命名微调）。
  UpdateAsset? installerFor(String version) {
    final exact = 'xiugou-tv-windows-x64-v$version-setup.exe'.toLowerCase();
    for (final asset in assets) {
      if (asset.name.toLowerCase() == exact) return asset;
    }
    for (final asset in assets) {
      if (asset.isInstaller) return asset;
    }
    return null;
  }

  /// 校验和清单资产（可能没有）。
  UpdateAsset? get checksums {
    for (final asset in assets) {
      if (asset.isChecksums) return asset;
    }
    return null;
  }

  /// 解析远端 JSON；形状无法识别时返回 null（调用方按「内容无法识别」提示）。
  static UpdateManifest? tryParse(Object? raw) {
    if (raw is! Map) return null;
    if (raw['tag_name'] is String) return _fromGithub(raw);
    if (raw['version'] is String) return _fromStatic(raw);
    return null;
  }

  static UpdateManifest _fromGithub(Map<dynamic, dynamic> raw) {
    final assets = <UpdateAsset>[];
    final rawAssets = raw['assets'];
    if (rawAssets is List) {
      for (final item in rawAssets) {
        if (item is! Map) continue;
        final name = item['name'];
        final url = item['browser_download_url'];
        if (name is! String || name.isEmpty) continue;
        if (url is! String || url.isEmpty) continue;
        assets.add(UpdateAsset(
          name: name,
          url: url,
          size: _asInt(item['size']),
          sha256: normalizeSha256(item['digest']),
        ));
      }
    }
    return UpdateManifest(
      tag: raw['tag_name'] as String,
      notes: _asString(raw['body']),
      publishedAt: _asDate(raw['published_at']),
      prerelease: raw['prerelease'] == true,
      assets: List.unmodifiable(assets),
    );
  }

  static UpdateManifest _fromStatic(Map<dynamic, dynamic> raw) {
    final assets = <UpdateAsset>[];
    final rawAssets = raw['assets'];
    if (rawAssets is List) {
      for (final item in rawAssets) {
        if (item is! Map) continue;
        final name = item['name'];
        final url = item['url'];
        if (name is! String || name.isEmpty) continue;
        if (url is! String || url.isEmpty) continue;
        assets.add(UpdateAsset(
          name: name,
          url: url,
          size: _asInt(item['size']),
          sha256: normalizeSha256(item['sha256'] ?? item['digest']),
        ));
      }
    }
    return UpdateManifest(
      tag: raw['version'] as String,
      notes: _asString(raw['notes'] ?? raw['body']),
      publishedAt: _asDate(raw['publishedAt'] ?? raw['published_at']),
      prerelease: raw['prerelease'] == true,
      assets: List.unmodifiable(assets),
    );
  }

  static int? _asInt(Object? raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw.trim());
    return null;
  }

  static String _asString(Object? raw) => raw is String ? raw : '';

  static DateTime? _asDate(Object? raw) =>
      raw is String ? DateTime.tryParse(raw) : null;
}

/// 归一化 SHA-256：容忍 `sha256:` 前缀、大写与空白；非法返回 null。
String? normalizeSha256(Object? raw) {
  if (raw is! String) return null;
  var text = raw.trim().toLowerCase();
  if (text.startsWith('sha256:')) text = text.substring(7);
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(text)) return null;
  return text;
}
