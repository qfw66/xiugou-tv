import 'app_version.dart';
import 'update_mirrors.dart';

/// 与旧版 version 1 兼容；缺少 mirrorsUrl 时使用发布时的默认目录或内置镜像。
class UpdatePreferences {
  static const int formatVersion = 1;
  final bool autoCheck;
  final String source;
  final String? skippedVersion;
  final bool useMirror;
  final String mirrorsUrl;

  const UpdatePreferences({
    this.autoCheck = true,
    this.source = '',
    this.skippedVersion,
    this.useMirror = true,
    this.mirrorsUrl = '',
  });

  static const UpdatePreferences defaults = UpdatePreferences();

  static String normalizeVersion(String raw) {
    final parsed = AppVersion.tryParse(raw);
    if (parsed != null) return parsed.toString();
    return raw.trim().toLowerCase();
  }

  bool isSkipped(String rawTag) {
    final skipped = skippedVersion;
    if (skipped == null || skipped.trim().isEmpty) return false;
    return normalizeVersion(skipped) == normalizeVersion(rawTag);
  }

  static bool isValidSource(String value) {
    final text = value.trim();
    if (text.isEmpty) return true;
    final uri = Uri.tryParse(text);
    return uri != null && uri.scheme == 'https' && uri.host.isNotEmpty;
  }

  static bool isValidMirrorsUrl(String value) =>
      value.trim().isEmpty || isValidMirrorEndpoint(value.trim());

  UpdatePreferences copyWith({
    bool? autoCheck,
    String? source,
    String? skippedVersion,
    bool? useMirror,
    String? mirrorsUrl,
    bool clearSkipped = false,
  }) =>
      UpdatePreferences(
        autoCheck: autoCheck ?? this.autoCheck,
        source: source ?? this.source,
        skippedVersion:
            clearSkipped ? null : (skippedVersion ?? this.skippedVersion),
        useMirror: useMirror ?? this.useMirror,
        mirrorsUrl: mirrorsUrl ?? this.mirrorsUrl,
      );

  static UpdatePreferences fromJson(Map<String, dynamic> json) {
    if (json['version'] != formatVersion) {
      throw const FormatException('更新偏好格式无效');
    }
    for (final key in ['autoCheck', 'useMirror']) {
      if (json[key] != null && json[key] is! bool) {
        throw const FormatException('更新偏好格式无效');
      }
    }
    for (final key in ['source', 'skippedVersion', 'mirrorsUrl']) {
      if (json[key] != null && json[key] is! String) {
        throw const FormatException('更新偏好格式无效');
      }
    }
    final source = (json['source'] as String? ?? '').trim();
    final mirrorsUrl = (json['mirrorsUrl'] as String? ?? '').trim();
    if (!isValidSource(source) || !isValidMirrorsUrl(mirrorsUrl)) {
      throw const FormatException('更新偏好格式无效');
    }
    final skipped = (json['skippedVersion'] as String?)?.trim();
    return UpdatePreferences(
      autoCheck: json['autoCheck'] as bool? ?? true,
      source: source,
      skippedVersion: skipped == null || skipped.isEmpty ? null : skipped,
      useMirror: json['useMirror'] as bool? ?? true,
      mirrorsUrl: mirrorsUrl,
    );
  }

  Map<String, dynamic> toJson() => {
        'version': formatVersion,
        'autoCheck': autoCheck,
        'source': source,
        'skippedVersion': skippedVersion,
        'useMirror': useMirror,
        'mirrorsUrl': mirrorsUrl,
      };

  @override
  bool operator ==(Object other) =>
      other is UpdatePreferences &&
      other.autoCheck == autoCheck &&
      other.source == source &&
      other.skippedVersion == skippedVersion &&
      other.useMirror == useMirror &&
      other.mirrorsUrl == mirrorsUrl;

  @override
  int get hashCode =>
      Object.hash(autoCheck, source, skippedVersion, useMirror, mirrorsUrl);

  @override
  String toString() =>
      'UpdatePreferences(autoCheck: $autoCheck, source: $source, '
      'skippedVersion: $skippedVersion, useMirror: $useMirror, mirrorsUrl: $mirrorsUrl)';
}
