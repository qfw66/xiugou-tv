import 'dart:convert';

/// 配置源需要的 HTTP Basic 凭据，按主机名归属。
///
/// 归属到主机而不是某个订阅地址：多仓与自建部署下，主订阅、子仓和同机接口
/// 往往共用一套账号；按地址存会在切子仓时反复弹窗。
class ConfigCredentials {
  const ConfigCredentials({
    required this.host,
    required this.username,
    required this.password,
  });

  final String host;
  final String username;
  final String password;

  /// 没有主机或没有用户名时视为「没有凭据」：宿主据此决定是否提示输入。
  bool get isUsable => host.trim().isNotEmpty && username.trim().isNotEmpty;

  bool matches(Uri uri) =>
      isUsable && uri.host.toLowerCase() == host.trim().toLowerCase();

  String get authorization =>
      'Basic ${base64Encode(utf8.encode('$username:$password'))}';

  /// 提示与日志用：绝不含密码。
  String get display => '$username@$host';

  Map<String, dynamic> toJson() => {
        'host': host,
        'username': username,
        'password': password,
      };

  /// 反序列化；缺主机或缺用户名的条目直接丢弃。
  static ConfigCredentials? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final credentials = ConfigCredentials(
      host: json['host']?.toString().trim() ?? '',
      username: json['username']?.toString() ?? '',
      password: json['password']?.toString() ?? '',
    );
    return credentials.isUsable ? credentials : null;
  }
}

/// 服务端要求认证（HTTP 401 / 407）。
///
/// [rejected] 为 true 表示已经带凭据请求过仍然被拒：界面据此提示
/// 「账号或密码错误」，而不是再弹一次同样的输入框。
class ConfigAuthRequired implements Exception {
  const ConfigAuthRequired({
    required this.host,
    required this.location,
    this.rejected = false,
  });

  final String host;
  final String location;
  final bool rejected;

  String get message =>
      rejected ? '账号或密码错误（$host）' : '配置源需要账号密码（$host）';

  @override
  String toString() => message;
}

/// 主机 → 凭据的内存表；落盘由 `ConfigRepository` 负责。
class ConfigCredentialStore {
  final Map<String, ConfigCredentials> _byHost = <String, ConfigCredentials>{};

  ConfigCredentials? forUri(Uri uri) => _byHost[uri.host.toLowerCase()];

  ConfigCredentials? forHost(String host) => _byHost[host.trim().toLowerCase()];

  List<ConfigCredentials> get entries =>
      List<ConfigCredentials>.unmodifiable(_byHost.values);

  void put(ConfigCredentials credentials) {
    if (!credentials.isUsable) return;
    _byHost[credentials.host.trim().toLowerCase()] = credentials;
  }

  void replaceAll(Iterable<ConfigCredentials> credentials) {
    _byHost.clear();
    for (final item in credentials) {
      put(item);
    }
  }
}
