/// 安全 DNS（DoH）可选服务。
class DohProviderOption {
  final String value;
  final String label;

  /// RFC 8484 端点（`application/dns-message`）；关闭 / 自定义为 null。
  final String? endpoint;

  const DohProviderOption(this.value, this.label, this.endpoint);
}

/// 网络偏好（§14 安全 DNS）。
///
/// 持久化于应用数据目录的 `network_preferences.json`（version 1）。
/// 读取规则：结构 / 版本 / 字段类型非法视为损坏并抛出 [FormatException]（调用方保留原文件）；
/// 不认识的服务名、或自定义 URL 不合法时按「关闭」运行，不静默改写文件。
///
/// 只影响应用内 Dart 侧 HTTP 请求；mpv 拉流与 Companion（Java 爬虫）不经过这里。
class NetworkPreferences {
  static const int formatVersion = 1;

  static const String off = 'off';
  static const String custom = 'custom';

  /// 内置服务一律走 RFC 8484 线格式（`/dns-query`），三家都支持同一协议，
  /// 自定义地址也按同一协议请求。
  static const List<DohProviderOption> providers = [
    DohProviderOption(off, '关闭（系统 DNS）', null),
    DohProviderOption('alidns', '阿里 DNS（dns.alidns.com）', 'https://dns.alidns.com/dns-query'),
    DohProviderOption('dnspod', '腾讯 DNSPod（doh.pub）', 'https://doh.pub/dns-query'),
    DohProviderOption('cloudflare', 'Cloudflare（cloudflare-dns.com）',
        'https://cloudflare-dns.com/dns-query'),
    DohProviderOption(custom, '自定义', null),
  ];

  /// 当前选择的服务（[providers] 的 value）
  final String dohProvider;

  /// 自定义 DoH 地址（仅 [dohProvider] 为 [custom] 时生效；切走后保留以便切回）
  final String customDohUrl;

  const NetworkPreferences({this.dohProvider = off, this.customDohUrl = ''});

  /// 校验自定义 DoH 地址：合法返回 null，否则返回给用户看的原因。
  ///
  /// 必须是 https（DoH 本身要防篡改），且不能带账号密码或片段。
  static String? validateCustomUrl(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return '请输入 DoH 地址';
    final uri = Uri.tryParse(value);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return '地址格式不正确';
    if (uri.scheme != 'https') return '只支持 https 地址';
    if (uri.userInfo.isNotEmpty) return '地址不能包含账号密码';
    if (uri.hasFragment) return '地址不能包含 # 片段';
    return null;
  }

  /// 生效的 DoH 端点；关闭、未知服务或自定义地址不合法时为 null（= 系统 DNS）。
  Uri? get endpoint {
    if (dohProvider == custom) {
      return validateCustomUrl(customDohUrl) == null ? Uri.parse(customDohUrl.trim()) : null;
    }
    for (final option in providers) {
      if (option.value == dohProvider && option.endpoint != null) {
        return Uri.parse(option.endpoint!);
      }
    }
    return null;
  }

  NetworkPreferences copyWith({String? dohProvider, String? customDohUrl}) => NetworkPreferences(
        dohProvider: dohProvider ?? this.dohProvider,
        customDohUrl: customDohUrl ?? this.customDohUrl,
      );

  static NetworkPreferences fromJson(Map<String, dynamic> json) {
    if (json['version'] != formatVersion) {
      throw const FormatException('网络偏好格式无效');
    }
    final provider = json['dohProvider'];
    final url = json['customDohUrl'];
    if ((provider != null && provider is! String) || (url != null && url is! String)) {
      throw const FormatException('网络偏好格式无效');
    }
    final known = providers.any((o) => o.value == provider);
    return NetworkPreferences(
      dohProvider: known ? provider as String : off,
      customDohUrl: url as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'version': formatVersion,
        'dohProvider': dohProvider,
        'customDohUrl': customDohUrl,
      };

  @override
  bool operator ==(Object other) =>
      other is NetworkPreferences &&
      other.dohProvider == dohProvider &&
      other.customDohUrl == customDohUrl;

  @override
  int get hashCode => Object.hash(dohProvider, customDohUrl);

  @override
  String toString() => 'NetworkPreferences(dohProvider: $dohProvider)';
}
