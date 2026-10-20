import 'package:dio/dio.dart';

import 'app_version.dart';
import 'update_cache_store.dart';
import 'update_client.dart';
import 'update_manifest.dart';
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

  const UpdateCheckResult({
    required this.status,
    this.manifest,
    this.installer,
    this.skipped = false,
    this.failure,
    this.sourceHost,
  });

  bool get hasUpdate => status == UpdateCheckStatus.available;
}

/// 检查更新：依次尝试候选源，命中即返回。
///
/// 候选顺序为「自定义源 → 官方源」：自定义源失败会回落到官方，官方失败时
/// 用户在自定义源里填的镜像仍然有效。
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
  }) async {
    final local = AppVersion.tryParse(localVersion);
    if (local == null) {
      return const UpdateCheckResult(
        status: UpdateCheckStatus.error,
        failure: '无法读取当前版本号，已跳过检查',
      );
    }

    final sources = _candidates(preferences.source);
    UpdateFetchFailure? lastFailure;
    int? lastStatus;
    String? lastError;

    for (final source in sources) {
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
      Map<String, dynamic>? payload = fetched.payload;
      if (fetched.notModified) {
        payload = cached?.payload;
        if (payload == null) {
          lastFailure = UpdateFetchFailure.invalidPayload;
          continue;
        }
      } else if (!fetched.ok) {
        lastFailure = fetched.failure;
        lastStatus = fetched.statusCode;
        continue;
      }

      final manifest = fetched.manifest ?? UpdateManifest.tryParse(payload);
      if (manifest == null) {
        lastFailure = UpdateFetchFailure.invalidPayload;
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
        lastError = '更新源返回的版本号无法识别（${manifest.tag}）';
        continue;
      }
      if (manifest.isPrerelease) {
        return UpdateCheckResult(
          status: UpdateCheckStatus.ignoredPrerelease,
          manifest: manifest,
          sourceHost: host,
        );
      }
      if (remote.compareTo(local) <= 0) {
        return UpdateCheckResult(
          status: UpdateCheckStatus.upToDate,
          manifest: manifest,
          sourceHost: host,
        );
      }
      final installer = manifest.installerFor(remote.toString());
      if (installer == null) {
        return UpdateCheckResult(
          status: UpdateCheckStatus.noInstaller,
          manifest: manifest,
          skipped: preferences.isSkipped(manifest.tag),
          sourceHost: host,
        );
      }
      return UpdateCheckResult(
        status: UpdateCheckStatus.available,
        manifest: manifest,
        installer: installer,
        skipped: preferences.isSkipped(manifest.tag),
        sourceHost: host,
      );
    }

    return UpdateCheckResult(
      status: UpdateCheckStatus.error,
      failure: lastError ??
          describeFetchFailure(lastFailure ?? UpdateFetchFailure.network,
              statusCode: lastStatus),
    );
  }

  /// 自定义源在前、官方源兜底；只接受 https 的自定义源。
  static List<String> _candidates(String customSource) {
    final sources = <String>[];
    final custom = customSource.trim();
    if (custom.isNotEmpty && UpdatePreferences.isValidSource(custom)) {
      sources.add(custom);
    }
    if (!sources.contains(officialUpdateSourceUrl)) {
      sources.add(officialUpdateSourceUrl);
    }
    return sources;
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
