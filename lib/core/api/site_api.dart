import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';

import '../player/models/player_state.dart';
import 'parse_engine.dart';
import 'search_cancel_token.dart';
import '../companion/companion_process_manager.dart';
import '../diagnostics/error_log.dart';
import '../companion/companion_spider_api.dart';
import '../config/models/vod_config.dart';
import '../live/live_script_catalog.dart';
import 'cms_json_api.dart';
import 'models/vod_models.dart';
import 'play_failure_text.dart';

/// 首次启动「站点资源准备」的可见状态：准备中显示进度，失败可重试，成功后隐藏。
class PrewarmStatus {
  const PrewarmStatus._(this.running, this.failed, this.message);

  final bool running;
  final bool failed;
  final String message;

  static const PrewarmStatus idle = PrewarmStatus._(false, false, '');

  const PrewarmStatus.running(this.message)
      : running = true,
        failed = false;

  const PrewarmStatus.failed(this.message)
      : running = false,
        failed = true;
}

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

  /// 首次启动预热状态的对外窗口（UI 顶部提示条监听它）。
  final ValueNotifier<PrewarmStatus> prewarm = ValueNotifier(PrewarmStatus.idle);

  SiteApi({
    CmsJsonApi? cmsApi,
    CompanionSpiderApi? companionSpiderApi,
    CompanionProcessManager? companionManager,
    this.selfCheckEnabled,
  })  : cmsApi = cmsApi ?? CmsJsonApi(),
        companionManager = companionManager ?? CompanionProcessManager(),
        companionSpiderApi = companionSpiderApi ?? CompanionSpiderApi(processManager: companionManager);

  /// 预热诊断落盘：失败时写 ~/.xiugou_tv_companion/prewarm.log，
  /// 便于在虚拟机/用户机上直接把文件回传（不依赖界面能否打开）。
  static void _writePrewarmLog(String line) {
    try {
      final home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '.';
      final dir = Directory('$home/.xiugou_tv_companion');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final f = File('${dir.path}/prewarm.log');
      final stamp = DateTime.now().toIso8601String();
      f.writeAsStringSync('[$stamp] $line${String.fromCharCode(10)}',
          mode: FileMode.append, flush: true);
    } catch (_) {
      // 诊断失败不影响主流程
    }
  }

  /// 配置加载后预热：按 jar 去重，各取一个代表站点在后台加载一次。
  ///
  /// 冷缓存下首次加载一个 spider jar 要「下载壳 → 解密载荷 → dex2jar」，实测十几秒；
  /// 如果等用户第一次点详情/播放才做，必然踩超时或报错——表现出来就是
  /// 「必须先做一次全局搜索，站点才被激活」。这里在配置加载完就把它做掉。
  int _prewarmRun = 0;
  /// 是否已经自动预热过（每进程一次；手动「重试」用 force 绕过）。
  bool _prewarmAttempted = false;

  Future<void> prewarmCompanionJars(List<Site> sites,
      {int limit = 1, bool force = false}) async {
    // 已有一次预热在跑就不重复（启动触发 + 配置加载触发可能同时到）。
    if (prewarm.value.running) return;
    // 每个进程只自动预热一次：loadSiteData 会在切站 / 换分类 / 刷新时反复调用，
    // 若每次都重跑，网络差时会变成无休止的重试，反把首屏（豆瓣等）拖垮。
    if (_prewarmAttempted && !force) return;
    final run = ++_prewarmRun;
    final seen = <String>{};
    final targets = <Site>[];
    for (final site in sites) {
      if (targets.length >= limit) break;
      if (!site.usesCompanion) continue;
      final jar = site.jar ?? '';
      if (jar.isEmpty || !seen.add(jar)) continue;
      targets.add(site);
    }
    if (targets.isEmpty) {
      // 站点还没加载好时不要静默跳过：留一条诊断，便于排查“预热没跑”。
      ErrorLog.instance.record('预热', '没有可预热的站点（sites=${sites.length}）');
      return;
    }

    _prewarmAttempted = true;
    prewarm.value = const PrewarmStatus.running('正在准备站点资源（首次启动约 10–20 秒）');
    // 预热是尽力而为：45 秒还没结束就把提示收起来，不能让横幅一直挂着。
    Future<void>.delayed(const Duration(seconds: 45), () {
      if (run == _prewarmRun && prewarm.value.running) {
        prewarm.value = PrewarmStatus.idle;
      }
    });

    var startFailed = false;
    var anyOk = false;
    for (final site in targets) {
      for (var attempt = 0; attempt < 2 && !anyOk; attempt++) {
        final ready = await _ensureCompanionReady(site);
        if (!ready) {
          startFailed = true;
          final why = '伴随服务未能启动（site=${site.key}）'
              '｜原因=${companionManager.lastError.isEmpty ? '(空)' : companionManager.lastError}'
              '｜java=${companionManager.resolvedJavaPath ?? '(未解析到)'}';
          ErrorLog.instance.record('预热', why);
          _writePrewarmLog(why);
        } else {
          startFailed = false;
          // 加固源首载 10~20 秒很常见，给足 90 秒；超时只当「还没好」，不算失败。
          anyOk = await companionSpiderApi.loadSpider(site,
              receiveTimeout: const Duration(seconds: 90));
          if (!anyOk) {
            ErrorLog.instance.record('预热',
                '加载未完成（site=${site.key}, api=${site.api}, jar=${site.jar}）');
          }
        }
        if (!anyOk && attempt == 0) {
          await Future<void>.delayed(const Duration(seconds: 3));
        }
      }
    }
    if (run != _prewarmRun) return;
    // 只有「伴随服务起不来」才提示失败；加载超时/慢一律保持静默，交给按需加载。
    prewarm.value = (startFailed && !anyOk)
        ? const PrewarmStatus.failed('站点服务启动失败，可稍后重试')
        : PrewarmStatus.idle;
  }

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

  Future<void>? _resettingSpiders;
  int _scriptGeneration = 0;

  Future<void> resetCompanionSpiders() {
    _scriptGeneration++;
    final previous = _resettingSpiders;
    return _resettingSpiders = () async {
      await previous;
      await companionSpiderApi.resetSpiders();
    }();
  }

  // 入口和扩展参与隔离；同一个显式 key 的不同脚本不能共享 Local 或代理。
  Future<String> fetchLiveSource(Live source) async {
    if (!source.isScripted) {
      throw ArgumentError('直播源没有脚本 API');
    }
    final site = Site(
      key: LiveScriptCatalog.sourceKey(source),
      name: source.name,
      type: 3,
      api: source.api!.trim(),
      ext: LiveScriptCatalog.encodeExt(source.ext),
      header: source.headers,
    );
    Future<void>? reset;
    do {
      reset = _resettingSpiders;
      await reset;
    } while (!identical(reset, _resettingSpiders));
    final generation = _scriptGeneration;
    if (!await _ensureCompanionReady(site)) {
      throw StateError(companionUnavailableText(source.name, companionManager.status));
    }
    if (generation != _scriptGeneration) {
      throw StateError('直播源已更新，请重新加载');
    }
    final result = await companionSpiderApi.fetchLiveContent(
      site,
      url: source.url,
      timeout: Duration(seconds: (source.timeout ?? 60).clamp(1, 90)),
    );
    if (generation != _scriptGeneration) {
      throw StateError('直播源已更新，请重新加载');
    }
    return result;
  }

  /// 获取首页与分类
  Future<VodPageResult> fetchHome(Site site, {bool filter = true}) async {
    if (site.usesCompanion) {
      final ready = await _ensureCompanionReady(site);
      if (ready) {
        return companionSpiderApi.fetchHome(site, filter: filter);
      }
    }
    return _cmsFallback(site, () => cmsApi.fetchHome(site.api, site: site));
  }

  /// 爬虫类站源在伴随服务没就绪时会退到 CMS 通道（个别站的 ext 里带 HTTP 端点，CMS 能直连）。
  /// CMS 也没法直连时抛 UnsupportedError（旧文案「属于 Android Dex 爬虫插件，桌面端暂不支持」已不成立），
  /// 这里换成按伴随服务状态给出的真实原因（缺 Java 运行环境 / 服务没启动成功），首页红字显示的就是它。
  Future<T> _cmsFallback<T>(Site site, Future<T> Function() call) async {
    try {
      return await call();
    } on UnsupportedError {
      if (!site.usesCompanion) rethrow;
      throw UnsupportedError(companionUnavailableText(site.name, companionManager.status));
    }
  }

  /// 获取分类视频
  ///
  /// [extend] 为筛选条件（为空不下发）；[cancelToken] 取消后在途请求被真正中止，
  /// 返回空结果——调用方须自行判断结果是否仍有效，不能把它当作「真的没数据」。
  Future<VodPageResult> fetchCategory(Site site,
      {required String categoryId,
      int page = 1,
      bool filter = true,
      Map<String, String> extend = const {},
      SearchCancelToken? cancelToken}) async {
    if (cancelToken?.isCancelled ?? false) return const VodPageResult.empty();
    if (site.usesCompanion) {
      final ready = await _ensureCompanionReady(site);
      if (ready) {
        return companionSpiderApi.fetchCategory(site,
            categoryId: categoryId,
            page: page,
            filter: filter,
            extend: extend,
            cancelToken: cancelToken);
      }
    }
    return _cmsFallback(
        site,
        () => cmsApi.fetchCategory(site.api, categoryId,
            page: page, site: site, extend: extend, cancelToken: cancelToken));
  }

  /// 获取视频详情
  Future<VodDetail?> fetchDetail(Site site, {required String vodId}) async {
    if (site.usesCompanion) {
      final ready = await _ensureCompanionReady(site);
      if (ready) {
        return companionSpiderApi.fetchDetail(site, vodId: vodId);
      }
    }
    return _cmsFallback(site, () => cmsApi.fetchDetail(site.api, vodId, site: site));
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
        return companionSpiderApi.search(
          site, keyword: keyword, page: page, quick: quick, cancelToken: cancelToken,
        );
      }
    }
    return _cmsFallback(site, () => cmsApi.search(site.api, keyword, page: page, site: site,
        cancelToken: cancelToken));
  }

  /// parse=1 时判断地址本身是否已是媒体直链：
  /// http(s) 地址的**路径**以媒体扩展名结尾才算直链；查询串、域名里出现扩展名不算
  /// （解析页常见 `?url=xxx.m3u8`）。`.ts` 分片不算可独立播放的媒体。
  static bool isDirectMediaPath(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty) {
      return false;
    }
    final path = uri.path.toLowerCase();
    const extensions = [
      '.m3u8', '.mp4', '.flv', '.mkv', '.webm', '.mov', '.mpd',
      '.mp3', '.m4a', '.aac', '.flac',
    ];
    return extensions.any(path.endsWith);
  }

  /// 统一点播解析入口；记忆的档名不存在时默认第一档，其余档位保持未解析。
  Future<MediaPlaySpec> resolvePlayback(Site? site, {
    required String id,
    required String flag,
    required ParseEngine parseEngine,
    List<Parse> parses = const [],
    String? preferredQualityName,
  }) async {
    if (site == null || !site.usesCompanion) {
      final resolved = await parseEngine.parse(id, flag: flag, parses: parses);
      return MediaPlaySpec(url: resolved.url, headers: resolved.headers ?? site?.header);
    }
    if (!await _ensureCompanionReady(site)) {
      throw const FormatException('Companion 服务不可用');
    }
    final result = await companionSpiderApi.fetchPlayResult(site, flag: flag, id: id);
    final hasQualities = result.qualities.length > 1;
    final sourceQualities = hasQualities
        ? result.qualities
        : [PlaybackQuality(name: '默认', url: result.url, needsParse: result.needsParse)];
    final qualities = [
      for (final quality in sourceQualities)
        PlaybackQuality(
          name: quality.name,
          url: quality.url,
          headers: _mergePlaybackHeaders([site.header, result.headers, quality.headers]),
          needsParse: quality.needsParse,
        ),
    ];
    final preferredIndex = preferredQualityName == null
        ? -1
        : qualities.indexWhere((quality) => quality.name == preferredQualityName);
    final defaultIndex = result.qualityIndex >= 0 && result.qualityIndex < qualities.length
        ? result.qualityIndex : 0;
    final index = preferredIndex < 0 ? defaultIndex : preferredIndex;
    final selected = await _resolveSpiderQuality(
      qualities[index],
      flag: flag,
      parseEngine: parseEngine,
      parses: parses,
      siteKey: site.key,
    );
    qualities[index] = selected;
    return MediaPlaySpec(
      url: selected.url,
      headers: selected.headers.isEmpty ? null : selected.headers,
      qualities: hasQualities ? List<PlaybackQuality>.unmodifiable(qualities) : const [],
      qualityIndex: index,
      liveDanmakuSources: result.liveDanmakuSources,
      mode: result.liveDanmakuSources.isEmpty ? PlaybackMode.vod : PlaybackMode.live,
      modeSource: result.liveDanmakuSources.isEmpty
          ? PlaybackModeSource.defaultMode : PlaybackModeSource.defaultLive,
      startPosition: result.liveDanmakuSources.isEmpty ? null : Duration.zero,
    );
  }

  /// 仅解析所选档，不重新请求 playerContent；失败时原 [spec] 保持不变。
  /// 返回值保留会话元数据，并缓存成功档位的解析地址与请求头。
  Future<MediaPlaySpec> resolveQuality(MediaPlaySpec spec, {
    required int index,
    required String flag,
    required ParseEngine parseEngine,
    List<Parse> parses = const [],
  }) async {
    RangeError.checkValidIndex(index, spec.qualities, 'index');
    final selected = await _resolveSpiderQuality(
      spec.qualities[index],
      flag: flag,
      parseEngine: parseEngine,
      parses: parses,
    );
    final qualities = List<PlaybackQuality>.of(spec.qualities);
    qualities[index] = selected;
    return spec.copyWith(
      url: selected.url,
      headers: selected.headers,
      qualities: List<PlaybackQuality>.unmodifiable(qualities),
      qualityIndex: index,
    );
  }

  Future<PlaybackQuality> _resolveSpiderQuality(PlaybackQuality quality, {
    required String flag,
    required ParseEngine parseEngine,
    required List<Parse> parses,
    String? siteKey,
  }) async {
    final resolved = quality.needsParse && !isDirectMediaPath(quality.url)
        ? await parseEngine.parse(quality.url, flag: flag, parses: parses, requireResolved: true)
        : MediaPlaySpec(url: quality.url);
    final uri = Uri.tryParse(resolved.url);
    if (uri == null || !['http', 'https', 'rtmp', 'rtsp', 'file'].contains(uri.scheme) ||
        (uri.scheme != 'file' && uri.host.isEmpty)) {
      debugPrint('--> [播放地址无效] site=${siteKey ?? '(清晰度切换)'} flag=$flag needsParse=${quality.needsParse} '
          'scheme=${uri?.scheme} host=${uri?.host} len=${resolved.url.length}');
      throw const FormatException('Spider 未返回有效媒体地址');
    }
    return PlaybackQuality(
      name: quality.name,
      url: resolved.url,
      headers: _mergePlaybackHeaders([quality.headers, resolved.headers]),
    );
  }

  static Map<String, String> _mergePlaybackHeaders(
      Iterable<Map<String, String>?> layers) {
    final headers = <String, String>{};
    for (final layer in layers) {
      if (layer == null) continue;
      for (final entry in layer.entries) {
        headers.removeWhere((key, _) => key.toLowerCase() == entry.key.toLowerCase());
        headers[entry.key] = entry.value;
      }
    }
    return Map<String, String>.unmodifiable(headers);
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
