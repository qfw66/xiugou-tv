import 'dart:async';

import '../player/models/player_state.dart';
import 'parse_engine.dart';
import 'search_cancel_token.dart';
import '../companion/companion_process_manager.dart';
import '../companion/companion_spider_api.dart';
import '../config/models/vod_config.dart';
import 'cms_json_api.dart';
import 'models/vod_models.dart';

/// 统一站源请求调度与分发 API (SiteApi)
/// 自动识别站源类型 (CMS JSON/XML vs Java Spider 伴随桥接)
/// 支持伴随进程按需懒加载 (Lazy Auto-Start) 与平滑降级
class SiteApi {
  final CmsJsonApi cmsApi;
  final CompanionSpiderApi companionSpiderApi;
  final CompanionProcessManager companionManager;

  /// 「站点自检」总开关读取器（由设置层注入）。
  ///
  /// 伴随服务是按需懒启动的：每次拉起后都必须把当前开关推给 Java 侧，
  /// 否则「设置里开着」与「进程内实际状态」会不一致（体检日志不出现、体检请求被拒）。
  final bool Function()? selfCheckEnabled;

  SiteApi({
    CmsJsonApi? cmsApi,
    CompanionSpiderApi? companionSpiderApi,
    CompanionProcessManager? companionManager,
    this.selfCheckEnabled,
  })  : cmsApi = cmsApi ?? CmsJsonApi(),
        companionManager = companionManager ?? CompanionProcessManager(),
        companionSpiderApi = companionSpiderApi ?? CompanionSpiderApi(processManager: companionManager);

  /// 确保在访问 Type 3 (Spider) 站源时，伴随服务自动按需拉起就绪
  Future<bool> _ensureCompanionReady(Site site) async {
    if (!site.usesCompanion) return false;
    if (companionManager.isRunning) return true;

    // 尝试按需自动启动 Java 伴随微服务
    try {
      final started = await companionManager.start();
      if (started && companionManager.isRunning) {
        // 新进程默认关闭自检：按当前设置补一次下发，失败不影响主流程。
        unawaited(companionSpiderApi.configureSelfCheck(selfCheckEnabled?.call() ?? false));
        return true;
      }
    } catch (_) {}
    return false;
  }

  /// 获取首页与分类
  Future<VodPageResult> fetchHome(Site site, {bool filter = true}) async {
    if (site.usesCompanion) {
      final ready = await _ensureCompanionReady(site);
      if (ready) {
        try {
          return await companionSpiderApi.fetchHome(site, filter: filter);
        } catch (_) {
          return const VodPageResult.empty();
        }
      }
    }
    return cmsApi.fetchHome(site.api, site: site);
  }

  /// 获取分类视频
  Future<VodPageResult> fetchCategory(Site site, {required String categoryId, int page = 1, bool filter = true}) async {
    if (site.usesCompanion) {
      final ready = await _ensureCompanionReady(site);
      if (ready) {
        try {
          return await companionSpiderApi.fetchCategory(site, categoryId: categoryId, page: page, filter: filter);
        } catch (_) {
          return const VodPageResult.empty();
        }
      }
    }
    return cmsApi.fetchCategory(site.api, categoryId, page: page, site: site);
  }

  /// 获取视频详情
  Future<VodDetail?> fetchDetail(Site site, {required String vodId}) async {
    if (site.usesCompanion) {
      final ready = await _ensureCompanionReady(site);
      if (ready) {
        try {
          return await companionSpiderApi.fetchDetail(site, vodId: vodId);
        } catch (_) {
          return null;
        }
      }
    }
    return cmsApi.fetchDetail(site.api, vodId, site: site);
  }

  /// 站源搜索
  Future<VodPageResult> search(Site site,
      {required String keyword,
      int page = 1,
      bool quick = false,
      SearchCancelToken? cancelToken}) async {
    if (cancelToken?.isCancelled ?? false) {
      return const VodPageResult.empty();
    }
    if (site.usesCompanion) {
      final ready = await _ensureCompanionReady(site);
      if (cancelToken?.isCancelled ?? false) {
        return const VodPageResult.empty();
      }
      if (ready) {
        try {
          // 伴随（Spider）请求把取消桥接成 Dio CancelToken：客户端立即停止等待；
          // Java 侧已开跑的 spider 无法强制中断（并发上限见 SearchEngine）。
          return await companionSpiderApi.search(
            site,
            keyword: keyword,
            page: page,
            quick: quick,
            cancelToken: cancelToken,
          );
        } catch (_) {
          return const VodPageResult.empty();
        }
      }
    }
    return cmsApi.search(site.api, keyword, page: page, site: site,
        cancelToken: cancelToken);
  }

  /// 统一点播解析入口：Spider 先解析选集标识，CMS 沿用通用解析策略。
  Future<MediaPlaySpec> resolvePlayback(Site? site, {
    required String id,
    required String flag,
    required ParseEngine parseEngine,
    List<Parse> parses = const [],
  }) async {
    MediaPlaySpec resolved;
    Map<String, String> spiderHeaders = const {};
    if (site != null && site.usesCompanion) {
      if (!await _ensureCompanionReady(site)) {
        throw const FormatException('Companion 服务不可用');
      }
      final result = await companionSpiderApi.fetchPlayResult(site, flag: flag, id: id);
      spiderHeaders = result.headers;
      resolved = result.needsParse
          ? await parseEngine.parse(result.url, flag: flag, parses: parses, requireResolved: true)
          : MediaPlaySpec(url: result.url);
      final uri = Uri.tryParse(resolved.url);
      if (uri == null || !['http', 'https', 'rtmp', 'rtsp', 'file'].contains(uri.scheme) ||
          (uri.scheme != 'file' && uri.host.isEmpty)) {
        throw const FormatException('Spider 未返回有效媒体地址');
      }
    } else {
      resolved = await parseEngine.parse(id, flag: flag, parses: parses);
      return MediaPlaySpec(url: resolved.url, headers: resolved.headers ?? site?.header);
    }
    // HTTP 头名称不区分大小写，后一级仅覆盖同名项而非整个集合。
    final headers = <String, String>{};
    for (final layer in [site.header, spiderHeaders, resolved.headers]) {
      if (layer == null) continue;
      for (final entry in layer.entries) {
        headers.removeWhere((key, _) => key.toLowerCase() == entry.key.toLowerCase());
        headers[entry.key] = entry.value;
      }
    }
    return MediaPlaySpec(url: resolved.url, headers: headers.isEmpty ? null : headers);
  }

  /// 触发站源动作（见 [CompanionSpiderApi.performAction]）；非 Spider 站源没有动作，返回空串。
  Future<String> performAction(Site site, String action) async {
    if (!site.usesCompanion) return '';
    if (!await _ensureCompanionReady(site)) {
      throw const FormatException('Companion 服务不可用');
    }
    return companionSpiderApi.performAction(site, action);
  }

  /// 仅获取地址的兼容入口，不用于应用选集播放。
  Future<String> fetchPlayUrl(Site site, {required String flag, required String id}) async {
    if (!site.usesCompanion) return id;
    if (!await _ensureCompanionReady(site)) {
      throw const FormatException('Companion 服务不可用');
    }
    return companionSpiderApi.fetchPlayUrl(site, flag: flag, id: id);
  }
}
