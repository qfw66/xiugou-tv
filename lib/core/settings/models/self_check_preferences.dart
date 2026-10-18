/// 站点自检偏好（载荷静态体检与逐站探测的总开关）。
///
/// 持久化于应用数据目录的 `self_check_preferences.json`（version 1）。
/// 读取规则：结构 / 版本 / 字段类型非法视为损坏并抛出 [FormatException]（由调用方处理）。
///
/// 默认关闭：体检会给每个加固壳载荷做一次 zip 扫描并打印诊断日志，
/// 属于排查手段而非日常能力；普通用户不需要承担这部分噪音与开销，
/// 需要定位「某个站点为什么 0 数据」时再到「通用」里手动开启。
class SelfCheckPreferences {
  static const int formatVersion = 1;

  /// 默认值：关闭
  static const bool defaultEnabled = false;

  /// 是否启用站点自检
  final bool enabled;

  const SelfCheckPreferences({this.enabled = defaultEnabled});

  SelfCheckPreferences copyWith({bool? enabled}) =>
      SelfCheckPreferences(enabled: enabled ?? this.enabled);

  /// 严格解析：结构 / 版本 / 字段类型非法时抛出 [FormatException]。
  static SelfCheckPreferences fromJson(Map<String, dynamic> json) {
    if (json['version'] != formatVersion) {
      throw const FormatException('自检偏好格式无效');
    }
    final rawEnabled = json['enabled'];
    if (rawEnabled != null && rawEnabled is! bool) {
      throw const FormatException('自检偏好格式无效');
    }
    return SelfCheckPreferences(enabled: rawEnabled as bool? ?? defaultEnabled);
  }

  Map<String, dynamic> toJson() => {'version': formatVersion, 'enabled': enabled};

  @override
  bool operator ==(Object other) => other is SelfCheckPreferences && other.enabled == enabled;

  @override
  int get hashCode => enabled.hashCode;

  @override
  String toString() => 'SelfCheckPreferences(enabled: $enabled)';
}
