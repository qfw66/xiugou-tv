/// 更新镜像仅改写 GitHub 自有域名的 HTTPS 地址。
library;

class UpdateMirror {
  final String id;
  final String label;
  final String prefix;
  final bool proxiesApi;

  const UpdateMirror({
    required this.id,
    required this.label,
    required this.prefix,
    this.proxiesApi = false,
  });

  String? resolve(String originalUrl) {
    if (!isValidMirrorPrefix(prefix)) return null;
    final uri = Uri.tryParse(originalUrl);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.port != 443 ||
        uri.hasFragment ||
        originalUrl.contains('\\')) {
      return null;
    }
    if (!kMirrorableHosts.contains(uri.host.toLowerCase())) return null;
    return '$prefix$originalUrl';
  }

  String? resolveApi(String originalUrl) =>
      proxiesApi ? resolve(originalUrl) : null;

  Map<String, Object> toJson() => {
        'id': id,
        'label': label,
        'prefix': prefix,
        'proxiesApi': proxiesApi,
      };

  @override
  String toString() => 'UpdateMirror($id, $prefix)';
}

/// 配置端点和代理前缀都只能指向普通公网 DNS 名称，拒绝编码、用户信息及非 HTTPS。
/// 目录请求不跟随重定向；代理下载仍沿用下载器的重定向与 SHA-256 校验。
bool isValidMirrorEndpoint(String value) {
  if (value.isEmpty ||
      value.length > 2048 ||
      RegExp(r'[\s\x00-\x1f\x7f\\%]').hasMatch(value)) {
    return false;
  }
  if (!RegExp(
          r"^https://[a-z0-9.-]+(?::443)?(?:/[a-z0-9._~!$&'()*+,;=:@/\-]*)?$",
          caseSensitive: false)
      .hasMatch(value)) {
    return false;
  }
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.userInfo.isNotEmpty ||
      uri.port != 443 ||
      uri.hasQuery ||
      uri.hasFragment) {
    return false;
  }
  final host = uri.host.toLowerCase();
  if (host.length > 253 ||
      !host.contains('.') ||
      host.endsWith('.localhost') ||
      host.endsWith('.local') ||
      host.endsWith('.internal') ||
      host.endsWith('.localdomain') ||
      host.endsWith('.home.arpa')) {
    return false;
  }
  final labels = host.split('.');
  final labelPattern = RegExp(r'^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$');
  if (labels.any((label) => !labelPattern.hasMatch(label)) ||
      !RegExp(r'^[a-z]{2,63}$').hasMatch(labels.last)) {
    return false;
  }
  // 检查原始路径，避免 Uri 归一化先消除 ../ 或 ./。
  final rawPath = value.substring(value.indexOf('://') + 3);
  final pathStart = rawPath.indexOf('/');
  final path = pathStart < 0 ? '' : rawPath.substring(pathStart);
  if (path.split('/').any((part) => part == '.' || part == '..')) return false;
  return true;
}

bool isValidMirrorPrefix(String value) =>
    value.length <= 512 && value.endsWith('/') && isValidMirrorEndpoint(value);

const Set<String> kMirrorableHosts = {
  'github.com',
  'objects.githubusercontent.com',
  'release-assets.githubusercontent.com',
  'api.github.com',
};

/// 保留已有可用源，加入用户提供的候选；不表示各站当前都可用。
/// 清单 API 仅允许已知支持的 gh-proxy，其余只用于资产下载。
const List<UpdateMirror> kBuiltinMirrors = [
  UpdateMirror(
      id: 'gh-proxy',
      label: 'gh-proxy.com',
      prefix: 'https://gh-proxy.com/',
      proxiesApi: true),
  UpdateMirror(
      id: 'down-mxw',
      label: 'down.mxw.xx.kg',
      prefix: 'https://down.mxw.xx.kg/'),
  UpdateMirror(id: 'tvv', label: 'tvv.tw', prefix: 'https://tvv.tw/'),
  UpdateMirror(
      id: 'fastgit', label: 'fastgit.cc', prefix: 'https://fastgit.cc/'),
  UpdateMirror(
      id: 'imciel',
      label: 'ghproxy.imciel.com',
      prefix: 'https://ghproxy.imciel.com/'),
  UpdateMirror(
      id: 'felicity',
      label: 'ghproxy.felicity.land',
      prefix: 'https://ghproxy.felicity.land/'),
  UpdateMirror(
      id: 'z321', label: 'gg.z321.cc.cd', prefix: 'https://gg.z321.cc.cd/'),
  UpdateMirror(
      id: 'xsadwsd',
      label: 'xsadwsd.kdns.fr',
      prefix: 'https://xsadwsd.kdns.fr/'),
  UpdateMirror(
      id: 'ghfast', label: 'ghfast.top', prefix: 'https://ghfast.top/'),
];

UpdateMirror? builtinMirror(String id) {
  for (final mirror in kBuiltinMirrors) {
    if (mirror.id == id) return mirror;
  }
  return null;
}

class DownloadCandidate {
  final String url;
  final String? mirrorId;
  final String label;

  const DownloadCandidate(
      {required this.url, required this.label, this.mirrorId});

  bool get viaMirror => mirrorId != null;

  @override
  String toString() => 'DownloadCandidate($label, $url)';
}

/// 可用的上次成功镜像 → 其余可用镜像 → 直连 → 冷却镜像。
/// 自定义的非 GitHub 资产和明确关闭镜像的请求均只走原地址。
List<DownloadCandidate> downloadCandidates({
  required String assetUrl,
  required bool useMirror,
  String? lastGoodMirrorId,
  Set<String> coolingDown = const {},
  List<UpdateMirror> mirrors = kBuiltinMirrors,
}) {
  final direct =
      DownloadCandidate(url: assetUrl, label: _labelForUrl(assetUrl));
  if (!useMirror) return [direct];
  final available = <DownloadCandidate>[];
  final cooling = <DownloadCandidate>[];
  final urls = <String>{assetUrl};
  final ids = <String>{};
  for (final mirror in mirrors) {
    final url = mirror.resolve(assetUrl);
    if (url == null || !urls.add(url) || !ids.add(mirror.id)) continue;
    final isCooling = coolingDown.contains(mirror.id);
    final candidate = DownloadCandidate(
      url: url,
      mirrorId: mirror.id,
      label: '镜像 ${mirror.label}${isCooling ? '（近期失败）' : ''}',
    );
    if (isCooling) {
      cooling.add(candidate);
    } else if (mirror.id == lastGoodMirrorId) {
      available.insert(0, candidate);
    } else {
      available.add(candidate);
    }
  }
  return [...available, direct, ...cooling];
}

String _labelForUrl(String url) {
  final host = Uri.tryParse(url)?.host ?? '';
  return host.isEmpty ? '直连' : '直连 $host';
}
