/// 内置镜像：GitHub 前缀代理。
///
/// 这类镜像不是「自建清单源」，而是把 `前缀 + 完整 GitHub URL` 拼成一个可直连
/// 地址。因此改写必须严格限定：只接受 https、且 host 在 [kMirrorableHosts]
/// 白名单内的绝对 URL；用户自定义源给出的任意地址永不参与拼接，避免把镜像
/// 当成 SSRF 跳板。
///
/// 实测（2026-10-21）：用户给出的 5 个镜像里只有 `gh-proxy.com` 同时支持
/// 清单接口、Range 与 ETag 透传；`ghfast.top` 只支持资产（API 返回 403
/// `Invalid input`），作为第二下载兜底；其余为 404 / 403 / 已停服。
/// 详见 `docs/UPDATE_CHECK_PLAN.md` §14。
library;

class UpdateMirror {
  /// 稳定标识：写进健康缓存与偏好文件，不随展示名变化。
  final String id;

  /// 展示名（关于页与错误文案使用）。
  final String label;

  /// 前缀，必须以 `/` 结尾。
  final String prefix;

  /// 是否支持代理 `api.github.com`（清单接口）。
  final bool proxiesApi;

  const UpdateMirror({
    required this.id,
    required this.label,
    required this.prefix,
    this.proxiesApi = false,
  });

  /// 把 GitHub 自有域名地址改写为镜像地址；不满足条件时返回 null（调用方保持原样）。
  String? resolve(String originalUrl) {
    if (!prefix.endsWith('/')) return null;
    final uri = Uri.tryParse(originalUrl);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return null;
    if (!kMirrorableHosts.contains(uri.host.toLowerCase())) return null;
    return '$prefix$originalUrl';
  }

  /// 清单接口地址的改写；不支持 API 代理的镜像返回 null。
  String? resolveApi(String originalUrl) =>
      proxiesApi ? resolve(originalUrl) : null;

  @override
  String toString() => 'UpdateMirror($id, $prefix)';
}

/// 允许参与前缀拼接的 GitHub 自有域名。
///
/// 只放 GitHub 的域名：`github.com` 是资产入口，后两个是重定向后的实际存储域。
const Set<String> kMirrorableHosts = {
  'github.com',
  'objects.githubusercontent.com',
  'release-assets.githubusercontent.com',
  'api.github.com',
};

/// 内置镜像清单（按尝试顺序）。
///
/// 只有 `gh-proxy.com` 支持清单接口；`ghfast.top` 仅参与下载候选。
const List<UpdateMirror> kBuiltinMirrors = [
  UpdateMirror(
    id: 'gh-proxy',
    label: 'gh-proxy.com',
    prefix: 'https://gh-proxy.com/',
    proxiesApi: true,
  ),
  UpdateMirror(
    id: 'ghfast',
    label: 'ghfast.top',
    prefix: 'https://ghfast.top/',
  ),
];

/// 按 id 取内置镜像；未知 id 返回 null。
UpdateMirror? builtinMirror(String id) {
  for (final mirror in kBuiltinMirrors) {
    if (mirror.id == id) return mirror;
  }
  return null;
}

/// 一个下载候选：原始地址，或经某个镜像改写后的地址。
class DownloadCandidate {
  final String url;

  /// null 表示直连（官方或自定义源）。
  final String? mirrorId;

  /// 展示用标签，如 `官方` / `镜像 gh-proxy.com`。
  final String label;

  const DownloadCandidate({
    required this.url,
    required this.label,
    this.mirrorId,
  });

  bool get viaMirror => mirrorId != null;

  @override
  String toString() => 'DownloadCandidate($label, $url)';
}

/// 组装下载候选：上次成功源 → 官方 → 其余镜像。
///
/// - 地址不是 GitHub 自有域名时（自定义源）只返回原地址，绝不改写；
/// - 关闭镜像开关时同样只返回原地址；
/// - 冷却中的镜像排在最后（下载是用户主动动作，不清空候选，只是降权）。
List<DownloadCandidate> downloadCandidates({
  required String assetUrl,
  required bool useMirror,
  String? lastGoodMirrorId,
  Set<String> coolingDown = const {},
}) {
  final direct = DownloadCandidate(
    url: assetUrl,
    label: _labelForUrl(assetUrl),
  );
  if (!useMirror) return [direct];

  final rewritten = <UpdateMirror, String>{};
  for (final mirror in kBuiltinMirrors) {
    final resolved = mirror.resolve(assetUrl);
    if (resolved != null) rewritten[mirror] = resolved;
  }
  if (rewritten.isEmpty) return [direct];

  final ordered = <DownloadCandidate>[];
  final lastGood = lastGoodMirrorId == null
      ? null
      : rewritten.keys.where((m) => m.id == lastGoodMirrorId).firstOrNull;
  if (lastGood != null) {
    ordered.add(DownloadCandidate(
      url: rewritten[lastGood]!,
      mirrorId: lastGood.id,
      label: '镜像 ${lastGood.label}',
    ));
  }
  ordered.add(direct);
  for (final entry in rewritten.entries) {
    if (entry.key.id == lastGoodMirrorId) continue;
    ordered.add(DownloadCandidate(
      url: entry.value,
      mirrorId: entry.key.id,
      label: coolingDown.contains(entry.key.id)
          ? '镜像 ${entry.key.label}（近期失败）'
          : '镜像 ${entry.key.label}',
    ));
  }
  return ordered;
}

String _labelForUrl(String url) {
  final host = Uri.tryParse(url)?.host ?? '';
  return host.isEmpty ? '直连' : '直连 $host';
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
