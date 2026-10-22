import 'package:dio/dio.dart';

import 'app_version.dart';
import 'update_cache_store.dart';
import 'update_client.dart';
import 'update_manifest.dart';
import 'update_mirrors.dart';
import 'update_preferences.dart';

/// 官方更新源（公开仓库，Releases API 无需鉴权）。
const String officialUpdateSourceUrl =
    'https://api.github.com/repos/qfw66/xiugou-tv/releases/latest';

/// 发布页（无安装版资产 / 便携版时引导用户手动下载）。
const String releasePageUrl =
    'https://github.com/qfw66/xiugou-tv/releases/latest';

enum UpdateCheckStatus {
  upToDate,
  available,
  noInstaller,
  ignoredPrerelease,
  error,
  cancelled,
}

class UpdateCheckResult {
  final UpdateCheckStatus status;
  final UpdateManifest? manifest;
  final UpdateAsset? installer;

  /// 该版本在「已跳过」列表里（只影响自动检查是否打扰，不影响手动查看）。
  final bool skipped;

  /// 失败原因（人类可读，已分型）。
  final String? failure;

  /// 实际响应的源 host，便于用户判断是官方还是镜像。
  final String? sourceHost;

  /// 实际使用的源标签：`官方` / `自定义：host` / `镜像 gh-proxy.com`。
  final String? sourceLabel;

  /// 是否经内置镜像取得清单（此时摘要与镜像同源，提示文案要降级）。
  final bool viaMirror;

  const UpdateCheckResult({
    required this.status,
    this.manifest,
    this.installer,
    this.skipped = false,
    this.failure,
    this.sourceHost,
    this.sourceLabel,
    this.viaMirror = false,
  });

  bool get hasUpdate => status == UpdateCheckStatus.available;
}

/// 一个候选更新源：官方 / 自定义 / 内置镜像。
class UpdateSourceCandidate {
  final String url;

  /// 内置镜像 id；null 表示直连（官方或自定义源）。
  final String? mirrorId;

  /// 展示用标签：`官方` / `自定义：host` / `镜像 gh-proxy.com`。
  final String label;

  const UpdateSourceCandidate({
    required this.url,
    required this.label,
    this.mirrorId,
  });

  bool get viaMirror => mirrorId != null;

  @override
  String toString() => 'UpdateSourceCandidate($label, $url)';
}

/// 检查更新：依次尝试候选源，命中即返回。
///
/// 候选顺序为「自定义源 → 官方源 → 内置镜像（开关打开且不在冷却期）」。
/// 清单优先走官方：SHA-256 摘要必须来自可信通道，镜像只做兜底
/// （见 `docs/UPDATE_CHECK_PLAN.md` §14.2）。
class UpdateService {
  final UpdateClient _client;
  final UpdateCacheStore _cache;

  UpdateService({UpdateClient? client, UpdateCacheStore? cache})
      : _client = client ?? UpdateClient(),
        _cache = cache ?? UpdateCacheStore();

  void dispose() => _client.close();

  Future<UpdateCheckResult> check({
    required String localVersion,
    required UpdatePreferences preferences,
    CancelToken? cancelToken,
    Set<String> coolingDownMirrors = const {},
    void Function(String mirrorId, bool success)? onMirrorResult,
  }) async {
    final local = AppVersion.tryParse(localVersion);
    if (local == null) {
      return const UpdateCheckResult(
        status: UpdateCheckStatus.error,
        failure: '无法读取当前版本号，已跳过检查',
      );
    }

    final candidates = _candidates(
      preferences,
      coolingDownMirrors: coolingDownMirrors,
    );
    UpdateFetchFailure? lastFailure;
    int? lastStatus;
    // 直连源的失败更能说明问题：镜像常见 403/404 只是代理限制，不应当成结论
    UpdateFetchFailure? directFailure;
    int? directStatus;
    String? lastError;

    for (final candidate in candidates) {
      final source = candidate.url;
      final cached = await _cache.read(source);
      final fetched = await _client.fetch(
        source,
        etag: cached?.etag,
        cancelToken: cancelToken,
      );

      if (fetched.failure == UpdateFetchFailure.cancelled) {
        return const UpdateCheckResult(status: UpdateCheckStatus.cancelled);
      }

      final host = Uri.tryParse(source)?.host;

      void markMirror(bool success) {
        final id = candidate.mirrorId;
        if (id != null) onMirrorResult?.call(id, success);
      }

      void recordFailure(UpdateFetchFailure failure, int? status) {
        lastFailure = failure;
        lastStatus = status;
        if (candidate.mirrorId == null) {
          directFailure = failure;
          directStatus = status;
        }
      }

      Map<String, dynamic>? payload = fetched.payload;
      if (fetched.notModified) {
        payload = cached?.payload;
        if (payload == null) {
          markMirror(false);
          recordFailure(UpdateFetchFailure.invalidPayload, null);
          continue;
        }
      } else if (!fetched.ok) {
        markMirror(false);
        recordFailure(fetched.failure!, fetched.statusCode);
        continue;
      }

      final manifest = fetched.manifest ?? UpdateManifest.tryParse(payload);
      if (manifest == null) {
        markMirror(false);
        recordFailure(UpdateFetchFailure.invalidPayload, fetched.statusCode);
        continue;
      }

      if (fetched.ok && fetched.etag != null) {
        await _cache.save(UpdateCacheEntry(
          url: source,
          etag: fetched.etag!,
          payload: payload!,
          fetchedAt: DateTime.now().millisecondsSinceEpoch,
        ));
      }

      final remote = manifest.version;
      if (remote == null) {
        markMirror(false);
        lastError = '更新源返回的版本号无法识别（${manifest.tag}）';
        continue;
      }
      markMirror(true);
      if (manifest.isPrerelease) {
        return UpdateCheckResult(
          status: UpdateCheckStatus.ignoredPrerelease,
          manifest: manifest,
          sourceHost: host,
          sourceLabel: candidate.label,
          viaMirror: candidate.viaMirror,
        );
      }
      if (remote.compareTo(local) <= 0) {
        return UpdateCheckResult(
          status: UpdateCheckStatus.upToDate,
          manifest: manifest,
          sourceHost: host,
          sourceLabel: candidate.label,
          viaMirror: candidate.viaMirror,
        );
      }
      final installer = manifest.installerFor(remote.toString());
      if (installer == null) {
        return UpdateCheckResult(
          status: UpdateCheckStatus.noInstaller,
          manifest: manifest,
          skipped: preferences.isSkipped(manifest.tag),
          sourceHost: host,
          sourceLabel: candidate.label,
          viaMirror: candidate.viaMirror,
        );
      }
      return UpdateCheckResult(
        status: UpdateCheckStatus.available,
        manifest: manifest,
        installer: installer,
        skipped: preferences.isSkipped(manifest.tag),
        sourceHost: host,
        sourceLabel: candidate.label,
        viaMirror: candidate.viaMirror,
      );
    }

    return UpdateCheckResult(
      status: UpdateCheckStatus.error,
      failure: lastError ??
          describeFetchFailure(
            directFailure ?? lastFailure ?? UpdateFetchFailure.network,
            statusCode: directFailure != null ? directStatus : lastStatus,
          ),
    );
  }

  /// 自定义源 → 官方源 → 内置镜像（开关打开且不在冷却期）。
  static List<UpdateSourceCandidate> _candidates(
    UpdatePreferences preferences, {
    required Set<String> coolingDownMirrors,
  }) {
    final candidates = <UpdateSourceCandidate>[];
    final custom = preferences.source.trim();
    if (custom.isNotEmpty && UpdatePreferences.isValidSource(custom)) {
      candidates.add(UpdateSourceCandidate(
        url: custom,
        label: '自定义：${Uri.tryParse(custom)?.host ?? custom}',
      ));
    }
    if (!candidates.any((c) => c.url == officialUpdateSourceUrl)) {
      candidates.add(const UpdateSourceCandidate(
        url: officialUpdateSourceUrl,
        label: '官方',
      ));
    }
    if (preferences.useMirror) {
      for (final mirror in kBuiltinMirrors) {
        if (coolingDownMirrors.contains(mirror.id)) continue;
        final resolved = mirror.resolveApi(officialUpdateSourceUrl);
        if (resolved == null) continue;
        if (candidates.any((c) => c.url == resolved)) continue;
        candidates.add(UpdateSourceCandidate(
          url: resolved,
          mirrorId: mirror.id,
          label: '镜像 ${mirror.label}',
        ));
      }
    }
    return candidates;
  }
}

/// 把失败类型翻译成用户能读懂的一句话。
String describeFetchFailure(UpdateFetchFailure failure, {int? statusCode}) {
  switch (failure) {
    case UpdateFetchFailure.insecure:
      return '更新源地址无效（必须使用 https）';
    case UpdateFetchFailure.network:
      return '无法连接更新源，请检查网络；也可在更新源里填写镜像地址';
    case UpdateFetchFailure.timeout:
      return '连接更新源超时，请稍后重试';
    case UpdateFetchFailure.cancelled:
      return '检查已取消';
    case UpdateFetchFailure.rateLimited:
      return 'GitHub 接口访问受限（未登录约每小时 60 次），请稍后再试或使用镜像源';
    case UpdateFetchFailure.notFound:
      return '未找到发布信息（可能尚未发布 Release）';
    case UpdateFetchFailure.forbidden:
      return '更新源拒绝了请求（HTTP 403）';
    case UpdateFetchFailure.server:
      return statusCode == null ? '更新源服务异常' : '更新源服务异常（HTTP $statusCode）';
    case UpdateFetchFailure.invalidPayload:
      return '更新源返回内容无法识别';
  }
}
