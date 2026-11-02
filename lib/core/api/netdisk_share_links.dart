import 'models/vod_models.dart';

/// 已知网盘分享链接（backlog §49）。
class NetdiskShareLink {
  /// 网盘名称（夸克 / 阿里 / 百度 …）
  final String provider;

  /// 分享链接原文（保留提取码等查询参数；无协议头时补 `https://`）
  final String url;

  const NetdiskShareLink({required this.provider, required this.url});

  @override
  bool operator ==(Object other) =>
      other is NetdiskShareLink && other.provider == provider && other.url == url;

  @override
  int get hashCode => Object.hash(provider, url);

  @override
  String toString() => '$provider $url';
}

/// 网盘域名（含子域名）→ 名称。只认「分享」所在域名，直链 / CDN 域名不在此列。
const List<(String, String)> _providers = [
  ('pan.quark.cn', '夸克网盘'),
  ('alipan.com', '阿里云盘'),
  ('aliyundrive.com', '阿里云盘'),
  ('pan.baidu.com', '百度网盘'),
  ('drive.uc.cn', 'UC 网盘'),
  ('fast.uc.cn', 'UC 网盘'),
  ('cloud.189.cn', '天翼云盘'),
  ('115.com', '115 网盘'),
  ('115cdn.com', '115 网盘'),
  ('anxia.com', '115 网盘'),
  ('123pan.com', '123 云盘'),
  ('123pan.cn', '123 云盘'),
  ('123684.com', '123 云盘'),
  ('123865.com', '123 云盘'),
  ('123912.com', '123 云盘'),
  ('123592.com', '123 云盘'),
  ('pan.xunlei.com', '迅雷云盘'),
  ('caiyun.139.com', '移动云盘'),
  ('yun.139.com', '移动云盘'),
];

/// 分享链接：可选协议头 + （子域名.）已知域名 + 路径 / 查询。
///
/// - 左侧不能紧贴域名字符，避免 `abc115.com` 误中 `115.com`；
/// - 路径在空白、引号、尖括号、`$`（选集分隔）、`#`（选集分隔）、中文标点处截断；
///   但保留 `#/`（移动云盘等前端路由形如 `.../shareweb/#/w/i/xxx`）。
final RegExp _linkPattern = RegExp(
  r'(?<![\w.\-])(?:https?://)?((?:[\w-]+\.)*(?:'
  '${_providers.map((p) => RegExp.escape(p.$1)).join('|')}'
  r'))(?::\d+)?((?:[/?](?:#/|[^\s#$"' "'" r'<>，。；、！？（）【】「」《》])*)?)',
  caseSensitive: false,
);

/// 末尾常见的非链接标点（全角 / 半角）
final RegExp _trailingPunctuation = RegExp(r'[.,;:!?)\]}>。，；：！？）】]+$');

/// 从任意文本提取网盘分享链接（按出现顺序去重）。
List<NetdiskShareLink> extractNetdiskShareLinksFromText(String text) {
  final result = <NetdiskShareLink>[];
  for (final match in _linkPattern.allMatches(text)) {
    final host = match.group(1)!.toLowerCase();
    final path = (match.group(2) ?? '').replaceFirst(_trailingPunctuation, '');
    // 只有域名、没有分享路径的不算分享链接（如简介里提到「pan.baidu.com」）
    if (path.length <= 1) continue;
    final provider = _providerOf(host);
    if (provider == null) continue;
    result.add(NetdiskShareLink(provider: provider, url: 'https://$host$path'));
  }
  return _dedupe(result);
}

/// 从详情数据提取网盘分享链接：影片 ID、各线路各集地址、简介、备注。
///
/// 只认原文里出现的分享链接；载荷若只给代理 / 解析后的地址则提取不到（预期行为）。
List<NetdiskShareLink> extractNetdiskShareLinks(VodDetail detail) {
  final item = detail.item;
  final texts = <String>[
    item.id,
    for (final source in detail.sources)
      for (final episode in source.episodes) episode.url,
    if (item.content != null) item.content!,
    if (item.remarks != null) item.remarks!,
  ];
  return _dedupe([for (final text in texts) ...extractNetdiskShareLinksFromText(text)]);
}

String? _providerOf(String host) {
  for (final (domain, name) in _providers) {
    if (host == domain || host.endsWith('.$domain')) return name;
  }
  return null;
}

/// 去重：同一链接只留一次；同一分享既有带参数版本又有裸链接时只留带参数的（保留提取码）。
List<NetdiskShareLink> _dedupe(List<NetdiskShareLink> links) {
  final seen = <String>{};
  final unique = [for (final link in links) if (seen.add(link.url)) link];
  return [
    for (final link in unique)
      if (!unique.any((other) => other.url != link.url && other.url.startsWith('${link.url}?')))
        link,
  ];
}
