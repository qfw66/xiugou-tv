import 'app_version.dart';

/// 更新偏好（持久化于数据目录的 `update_preferences.json`，version 1）。
///
/// 读取规则与其余设置项一致：版本 / 顶层结构非法视为损坏并抛出 [FormatException]
/// （调用方保留原文件并提示），单字段类型非法同样按损坏处理——这里只有四个字段，
/// 没有「丢一条不拖垮全文件」的场景。
class UpdatePreferences {
  static const int formatVersion = 1;

  /// 启动后自动检查一次（默认开启）。
  final bool autoCheck;

  /// 自定义更新源（空串 = 只使用官方 GitHub Releases）。
  final String source;

  /// 已跳过的版本（原始 tag，如 `v1.2.0`；null = 未跳过）。
  final String? skippedVersion;

  /// 使用内置镜像（`gh-proxy.com`）作为兜底：清单在官方失败时回落，下载按
  /// 「上次成功源 → 官方 → 镜像」尝试。默认开启。
  final bool useMirror;

  const UpdatePreferences({
    this.autoCheck = true,
    this.source = '',
    this.skippedVersion,
    this.useMirror = true,
  });

  static const UpdatePreferences defaults = UpdatePreferences();

  /// 版本归一化：`v1.2.0`、`1.2.0`、`1.2.0+1` 都归到 `1.2.0`。
  static String normalizeVersion(String raw) {
    final parsed = AppVersion.tryParse(raw);
    if (parsed != null) return parsed.toString();
    return raw.trim().toLowerCase();
  }

  /// 给定 tag 是否属于「已跳过」。
  bool isSkipped(String rawTag) {
    final skipped = skippedVersion;
    if (skipped == null || skipped.trim().isEmpty) return false;
    return normalizeVersion(skipped) == normalizeVersion(rawTag);
  }

  /// 自定义更新源合法性：空串，或 https 绝对地址。
  static bool isValidSource(String value) {
    final text = value.trim();
    if (text.isEmpty) return true;
    final uri = Uri.tryParse(text);
    return uri != null && uri.scheme == 'https' && uri.host.isNotEmpty;
  }

  UpdatePreferences copyWith({
    bool? autoCheck,
    String? source,
    String? skippedVersion,
    bool? useMirror,
    bool clearSkipped = false,
  }) =>
      UpdatePreferences(
        autoCheck: autoCheck ?? this.autoCheck,
        source: source ?? this.source,
        skippedVersion:
            clearSkipped ? null : (skippedVersion ?? this.skippedVersion),
        useMirror: useMirror ?? this.useMirror,
      );

  static UpdatePreferences fromJson(Map<String, dynamic> json) {
    if (json['version'] != formatVersion) {
      throw const FormatException('更新偏好格式无效');
    }
    final rawAutoCheck = json['autoCheck'];
    if (rawAutoCheck != null && rawAutoCheck is! bool) {
      throw const FormatException('更新偏好格式无效');
    }
    final rawSource = json['source'];
    if (rawSource != null && rawSource is! String) {
      throw const FormatException('更新偏好格式无效');
    }
    final rawSkipped = json['skippedVersion'];
    if (rawSkipped != null && rawSkipped is! String) {
      throw const FormatException('更新偏好格式无效');
    }
    final rawUseMirror = json['useMirror'];
    if (rawUseMirror != null && rawUseMirror is! bool) {
      throw const FormatException('更新偏好格式无效');
    }
    final source = (rawSource as String? ?? '').trim();
    if (!isValidSource(source)) {
      throw const FormatException('更新偏好格式无效');
    }
    final skippedText = (rawSkipped as String?)?.trim();
    return UpdatePreferences(
      autoCheck: rawAutoCheck as bool? ?? true,
      source: source,
      skippedVersion:
          (skippedText == null || skippedText.isEmpty) ? null : skippedText,
      useMirror: rawUseMirror as bool? ?? true,
    );
  }

  Map<String, dynamic> toJson() => {
        'version': formatVersion,
        'autoCheck': autoCheck,
        'source': source,
        'skippedVersion': skippedVersion,
        'useMirror': useMirror,
      };

  @override
  bool operator ==(Object other) =>
      other is UpdatePreferences &&
      other.autoCheck == autoCheck &&
      other.source == source &&
      other.skippedVersion == skippedVersion &&
      other.useMirror == useMirror;

  @override
  int get hashCode => Object.hash(autoCheck, source, skippedVersion, useMirror);

  @override
  String toString() =>
      'UpdatePreferences(autoCheck: $autoCheck, source: $source, '
      'skippedVersion: $skippedVersion, useMirror: $useMirror)';
}
