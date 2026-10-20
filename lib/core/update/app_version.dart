/// 版本号比较。
///
/// 本机版本来自构建注入资源（`1.0.0+1`，build 号由 `+` 分隔），远端来自
/// Release tag（`v1.2.0`）。两者统一成三段数字比较：只比较 major/minor/patch，
/// **忽略 build 号**——tag 无法表达 `+1`，三段相等即视为同版本。
///
/// 缺段（`1.2`）、非数字（`v1.x`）、空串一律返回 null，由调用方按「无法识别」处理，
/// 不猜测、不默认放大版本，避免误判为有更新。
class AppVersion implements Comparable<AppVersion> {
  final int major;
  final int minor;
  final int patch;

  const AppVersion(this.major, this.minor, this.patch);

  /// 解析 `v1.2.0` / `1.2.0` / `1.2.0+1` / `1.2.0-beta.1`；无法解析返回 null。
  static AppVersion? tryParse(String? raw) {
    if (raw == null) return null;
    var text = raw.trim();
    if (text.isEmpty) return null;
    if (text.startsWith('v') || text.startsWith('V')) {
      text = text.substring(1);
    }
    // 先切掉 build 元数据与预发布后缀，只保留数字段
    text = text.split(RegExp(r'[+\-]')).first;
    final parts = text.split('.');
    if (parts.length != 3) return null;
    final numbers = <int>[];
    for (final part in parts) {
      if (part.isEmpty || !RegExp(r'^\d+$').hasMatch(part)) return null;
      numbers.add(int.parse(part));
    }
    return AppVersion(numbers[0], numbers[1], numbers[2]);
  }

  /// 是否为预发布标签（`v1.2.0-beta.1`）。
  ///
  /// build 元数据（`1.0.0+1`）不算预发布，只有 `-` 后缀才是。
  static bool isPrereleaseTag(String raw) {
    final text = raw.trim().replaceFirst(RegExp(r'^[vV]'), '');
    return text.contains('-');
  }

  @override
  int compareTo(AppVersion other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    return patch.compareTo(other.patch);
  }

  @override
  bool operator ==(Object other) =>
      other is AppVersion && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(major, minor, patch);

  @override
  String toString() => '$major.$minor.$patch';
}
