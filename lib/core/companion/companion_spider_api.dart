import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import '../api/models/vod_models.dart';
import '../api/search_cancel_token.dart';
import '../config/models/vod_config.dart';
import '../net/http_client_factory.dart';
import '../net/site_icon_url.dart';
import '../player/models/player_state.dart';
import 'companion_process_manager.dart';
import 'companion_recovery.dart';
import 'browser_verification_controller.dart';
import 'site_self_check_report.dart';

/// 通过本地 Java 伴随服务执行 CatVod Spider 的 API 适配层
class CompanionSpiderApi {
  final CompanionProcessManager processManager;
  final Dio _dio;
  late final browserVerification =
      BrowserVerificationController(processManager: processManager, dio: _dio);

  /// transport / service 失败后的自愈（健康探测 → 必要时重启 → 重放一次）。
  late final CompanionRecovery _recovery =
      CompanionRecovery(host: processManager);

  static const rpcReceiveTimeout = Duration(seconds: 75);
  static const rpcServerTimeout = Duration(seconds: 60);

  // 首次准备还包含脚本下载、运行时启动和插件初始化，独立于普通 RPC 预算。
  static const initializationServerTimeout = Duration(seconds: 90);
  static const initializationReceiveTimeout = Duration(seconds: 105);
  static const _maxInitializationServerTimeout = Duration(seconds: 120);
  static const _initializationResponseMargin = Duration(seconds: 5);

  CompanionSpiderApi({
    CompanionProcessManager? processManager,
    Dio? dio,
  })  : processManager = processManager ?? CompanionProcessManager(),
        _dio = dio ??
            HttpClientFactory.createDio(BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 20),
            ));

  /// 导入猫源校验入口，返回可持久化的站点描述（不含临时Node端口）。
  Future<String> importCatSource(String url, String md5) async {
    if (!await processManager.start()) {
      throw StateError('猫源运行服务启动失败：${processManager.lastError}');
    }
    processManager.notifyActivity();
    final response = await _dio.post<dynamic>(
      '${processManager.baseUrl}/cat/import',
      data: {'url': url, 'md5': md5},
      options: Options(
        receiveTimeout: const Duration(minutes: 3),
        validateStatus: (status) => status != null && status < 600,
      ),
    );
    final body = response.data is String
        ? jsonDecode(response.data as String)
        : response.data;
    if (body is! Map || body['code'] != 0 || body['data'] is! Map) {
      throw StateError(
          body is Map ? '${body['error'] ?? '猫源导入失败'}' : '猫源返回无效清单');
    }
    return jsonEncode(body['data']);
  }

  /// ext 已在模型层规范化为 JSON 字符串（对象形态会被序列化），可直接下发。
  String _extensionJson(Site site) => site.ext ?? '';

  Future<bool> loadSpider(Site site, {Duration? receiveTimeout}) async {
    if (!processManager.isRunning) return false;
    processManager.notifyActivity();

    try {
      final clientTimeout = receiveTimeout ?? initializationReceiveTimeout;
      final serverBudgetMs = receiveTimeout == null
          ? initializationServerTimeout.inMilliseconds
          : (receiveTimeout - _initializationResponseMargin).inMilliseconds;
      // 非正值会使服务端回落到默认 60 秒，无法留足响应时间时不发请求。
      if (serverBudgetMs <= 0) return false;
      final res = await _dio.post<dynamic>(
        '${processManager.baseUrl}/spider/load',
        data: {
          'key': site.key,
          'api': site.api,
          'ext': _extensionJson(site),
          'jar': site.jar ?? '',
          // 唯一取消标签：同站并发加载时，先结束的那次收尾不会误取消另一次的在途请求。
          'rpcId': 'load@${site.key}#${++_rpcSeq}',
          'timeoutMs':
              '${serverBudgetMs.clamp(1, _maxInitializationServerTimeout.inMilliseconds)}',
        },
        options: Options(receiveTimeout: clientTimeout),
      );
      if (res.statusCode == 200) {
        final dynamic data =
            res.data is String ? jsonDecode(res.data as String) : res.data;
        if (data is Map) {
          return data['code'] == 0;
        }
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// 换配置后释放伴随服务里旧配置的 spider、类加载器、代理端口与密码服务子进程。
  ///
  /// 伴随服务未运行时直接返回（下次懒启动的进程本来就是干净的）；失败静默，
  /// 最坏情况只是旧资源要等空闲停机或退出时才释放，不影响新配置使用。
  Future<void> resetSpiders() async {
    browserVerification.reset();
    if (!processManager.isRunning) return;
    try {
      await _dio.post<dynamic>(
        '${processManager.baseUrl}/spider/reset',
        data: const <String, dynamic>{},
        options: Options(receiveTimeout: const Duration(seconds: 10)),
      );
    } catch (_) {}
  }

  /// 把设置里的「站点自检」总开关同步给伴随服务（运行期生效，无需重启进程）。
  ///
  /// 开关决定两件事：是否打印 `[SelfCheck]` 载荷体检日志、是否接受逐站体检请求。
  /// 伴随服务未运行或下发失败时返回 false，由调用方决定是否提示。
  Future<bool> configureSelfCheck(bool enabled) async {
    if (!processManager.isRunning) return false;
    processManager.notifyActivity();
    try {
      final res = await _dio.post<dynamic>(
        '${processManager.baseUrl}/spider/call',
        data: {'method': 'selfCheckConfig', 'enabled': enabled.toString()},
      );
      if (res.statusCode == 200) {
        final dynamic data =
            res.data is String ? jsonDecode(res.data as String) : res.data;
        if (data is Map && data['code'] == 0) return true;
      }
    } catch (_) {}
    return false;
  }

  /// 逐站体检：对给定站点逐个探测首页分类与首个可播分类，返回结构化结论。
  ///
  /// 前置条件：伴随服务已运行且自检开关已开启（见 [configureSelfCheck]）。
  /// 单站耗时由服务端按 [perSiteTimeoutSeconds] 隔离；整体看门狗超时按站数放大，
  /// 避免站点较多时被默认 70s 提前截断。站点较多时调用方应分批（见设置页的体检弹窗）。
  Future<SelfCheckReport> runSelfCheck(
    List<Site> sites, {
    int maxCategories = 2,
    int perSiteTimeoutSeconds = 20,
  }) async {
    if (!processManager.isRunning || sites.isEmpty) {
      return const SelfCheckReport();
    }
    processManager.notifyActivity();

    final payloadSites = jsonEncode([
      for (final site in sites)
        {
          'key': site.key,
          'api': site.api,
          'ext': _extensionJson(site),
          'jar': site.jar ?? '',
        },
    ]);
    final budgetMs = (perSiteTimeoutSeconds * sites.length + 30) * 1000;

    try {
      final res = await _dio.post<dynamic>(
        '${processManager.baseUrl}/spider/call',
        data: {
          'method': 'selfCheck',
          'sites': payloadSites,
          'maxCategories': '$maxCategories',
          'perSiteTimeout': '$perSiteTimeoutSeconds',
          'timeoutMs': '$budgetMs',
        },
        // 单个批次可能跑满看门狗预算，接收超时按预算放大，避免客户端先于服务端放弃。
        options:
            Options(receiveTimeout: Duration(milliseconds: budgetMs + 15000)),
      );
      if (res.statusCode == 200) {
        final dynamic data =
            res.data is String ? jsonDecode(res.data as String) : res.data;
        if (data is Map && data['code'] == 0) {
          return SelfCheckReport.tryParse(data['data']) ??
              const SelfCheckReport();
        }
      }
    } catch (_) {}
    return const SelfCheckReport();
  }

  /// 获取首页分类与推荐视频
  Future<VodPageResult> fetchHome(Site site, {bool filter = true}) async {
    final rawJson = await _callSpider(
      site: site,
      method: 'homeContent',
      params: {'filter': filter.toString()},
      // homeContent 内也会懒初始化 spider，无需另发一次 load。
      serverTimeout: initializationServerTimeout,
      receiveTimeout: initializationReceiveTimeout,
    );
    return _parseVodPageResult(rawJson, site: site, isHome: true);
  }

  /// 获取分类视频列表
  ///
  /// [extend] 是用户选的筛选条件（key → v），为空时不下发，请求与无筛选时完全一致。
  Future<VodPageResult> fetchCategory(Site site,
      {required String categoryId,
      int page = 1,
      bool filter = true,
      Map<String, String> extend = const {},
      SearchCancelToken? cancelToken}) async {
    final rawJson = await _callSpider(
      site: site,
      method: 'categoryContent',
      params: {
        'tid': categoryId,
        'pg': page.toString(),
        'filter': filter.toString(),
        if (extend.isNotEmpty) 'extend': jsonEncode(extend),
      },
      cancelToken: cancelToken,
    );
    return _parseVodPageResult(rawJson, site: site);
  }

  /// 获取视频详情
  Future<VodDetail?> fetchDetail(Site site, {required String vodId}) async {
    final rawJson = await _callSpiderWithRetry(
      site: site,
      method: 'detailContent',
      params: {'id': vodId},
    );
    if (rawJson.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(rawJson);
      if (decoded is Map && decoded['list'] is List) {
        for (final entry in decoded['list']) {
          if (entry is Map<String, dynamic>) {
            return VodDetail.fromJson({
              ...entry,
              'site_key': site.key,
              'site_name': site.name,
            });
          }
        }
      }
    } on FormatException {
      throw const FormatException('站源详情响应格式无效');
    }
    return null;
  }

  /// 保留直播目录的原始 JSON / M3U / TXT，由直播仓库解析频道。
  Future<String> fetchLiveContent(
    Site site, {
    required String url,
    Duration? timeout,
  }) {
    final budget = timeout ?? rpcServerTimeout;
    return _callSpider(
      site: site,
      method: 'liveContent',
      params: {'url': url},
      serverTimeout: budget,
      receiveTimeout: budget + const Duration(seconds: 5),
    );
  }

  /// 搜索视频
  Future<VodPageResult> search(Site site,
      {required String keyword,
      int page = 1,
      bool quick = false,
      SearchCancelToken? cancelToken}) async {
    final rawJson = await _callSpider(
      site: site,
      method: 'searchContent',
      params: {
        'wd': keyword,
        'quick': quick.toString(),
        'pg': page.toString(),
      },
      cancelToken: cancelToken,
    );
    return _parseVodPageResult(rawJson, site: site);
  }

  /// 获取 Spider 播放结果；不将空响应或影片标识伪装成媒体地址。
  Future<SpiderPlayResult> fetchPlayResult(Site site,
      {required String flag, required String id}) async {
    final raw = await _callSpiderWithRetry(
      site: site,
      method: 'playerContent',
      params: {'flag': flag, 'id': id},
    );
    if (raw.trim().isEmpty) {
      debugPrint(
          '--> [播放地址为空] ${describeEmptyPlayResult(site.key, flag, id, raw)}');
      throw const FormatException('Spider 未返回播放地址');
    }
    dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      decoded = {'url': raw, 'parse': 0};
    }
    if (decoded is String) decoded = {'url': decoded, 'parse': 0};
    if (decoded is! Map) throw const FormatException('Spider 播放响应格式无效');
    final selection = _readSpiderQualities(decoded['url']);
    final qualities = selection.qualities;
    if (qualities.isEmpty) {
      debugPrint(
          '--> [播放地址为空] ${describeEmptyPlayResult(site.key, flag, id, raw)}');
      // 网盘载荷没给地址时常在 msg 里说明原因（如「还没有配置百度网盘 Cookie」），
      // 原样交给用户，比笼统的「站源没有返回播放地址」更能指明下一步。
      final hint = playResultHint(decoded);
      if (hint != null) {
        throw SpiderCallException(hint,
            stage: 'player', siteKey: site.key, method: 'playerContent');
      }
      throw const FormatException('Spider 未返回播放地址');
    }
    return SpiderPlayResult.fromJson(
      decoded,
      liveDanmakuSources: _readLiveDanmakuSources(
          decoded['danmaku'], processManager.baseUrl, site.key),
    );
  }

  /// 调用站源的 `action()`（FongMi 语义：列表项带 action 字段时点击触发）。
  ///
  /// 配置中心的设置项在这里弹出扫码 / 输入窗口，窗口经 [CompanionUiChannel] 呈现；
  /// 返回值是载荷的原始结果（通常为空或带 msg 的 JSON），失败返回空串。
  Future<String> performAction(Site site, String action) async {
    final interactiveLogin = site.api == 'csp_PanConfig' &&
        (action.endsWith('_scan') || action.endsWith('_import'));
    if (!interactiveLogin) {
      return _callSpider(
        site: site,
        method: 'action',
        params: {'action': action},
      );
    }
    // 扫码 / 导入可能挂几分钟：持租约期间不因空闲停用而重启 companion，
    // 否则登录态还没写回就被杀进程，用户看到的就是「扫完了但没保存」。
    // 测试替身没实现租约时按「无租约」处理，不影响主流程。
    final lease = _tryAcquireLease('pan-login:$action');
    try {
      return await _callSpider(
        site: site,
        method: 'action',
        params: {'action': action},
        serverTimeout: const Duration(minutes: 5),
        receiveTimeout: const Duration(seconds: 315),
      );
    } finally {
      lease?.release();
    }
  }

  /// 取一次活动租约；替身 manager 未实现租约时返回 null（不影响主流程）。
  CompanionLease? _tryAcquireLease(String reason) {
    try {
      return processManager.acquireLease(reason);
    } catch (_) {
      return null;
    }
  }

  /// 仅获取地址的兼容入口；播放调用应使用完整结果以保留解析标志与请求头。
  Future<String> fetchPlayUrl(Site site,
          {required String flag, required String id}) async =>
      (await fetchPlayResult(site, flag: flag, id: id)).url;

  /// 每次 RPC 的唯一序号，用于生成取消标签（见 CallRegistry 的 rpcId 口径）。
  static int _rpcSeq = 0;

  Future<String> _callSpiderWithRetry({
    required Site site,
    required String method,
    required Map<String, String> params,
  }) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final raw =
            await _callSpider(site: site, method: method, params: params);
        if (raw.trim().isNotEmpty || attempt == 1) return raw;
      } on SpiderCallException catch (error) {
        // Only transient service faults are worth a second attempt; timeouts and payload/upstream
        // failures would just double the user's wait. transport / service 已经在
        // `_callSpider` 里走过「健康探测 + 重启一次 + 重放一次」，这里不再重来，
        // 否则一次点击会连续拉起两次进程。
        final retryable =
            error.stage == 'empty' || error.httpStatus == 503;
        if (attempt == 1 || !retryable) rethrow;
      }
      await Future<void>.delayed(const Duration(milliseconds: 800));
    }
    return '';
  }

  /// 一次站源 RPC 的对外入口：transport / service 级失败先自愈，再重放一次。
  ///
  /// 自愈口径（见 [CompanionRecovery]）：先 `/health` 探测；进程确实死了（或卡死）
  /// 就重启一次，然后重放同一 RPC。只重放一次：仍然失败时抛「已自动重启但仍失败」并
  /// 带上诊断日志路径。用户取消（[cancelToken]）既不算失败也不触发重启；超时
  /// （服务还活着，只是慢）同样不触发重启。
  Future<String> _callSpider({
    required Site site,
    required String method,
    required Map<String, String> params,
    SearchCancelToken? cancelToken,
    Duration? receiveTimeout,
    Duration? serverTimeout,
  }) async {
    if (cancelToken?.isCancelled ?? false) return '';
    CompanionRecoveryOutcome? recovery;
    while (true) {
      try {
        return await _callSpiderOnce(
          site: site,
          method: method,
          params: params,
          cancelToken: cancelToken,
          receiveTimeout: receiveTimeout,
          serverTimeout: serverTimeout,
        );
      } on SpiderCallException catch (error) {
        if (cancelToken?.isCancelled ?? false) return '';
        if (!_isRecoverableStage(error.stage)) rethrow;
        _logCompanion(
            '[rpc] ${error.stage} 失败：$method@${site.key} ${error.message}');
        final previous = recovery;
        if (previous != null) throw _recoveryFailure(error, previous);
        final outcome = await _recovery.recover();
        recovery = outcome;
        _logCompanion('[rpc] 自愈结论：${outcome.kind.name}');
        if (cancelToken?.isCancelled ?? false) return '';
        if (!outcome.canRetry) throw _recoveryFailure(error, outcome);
      }
    }
  }

  /// 诊断日志；测试替身没有实现 companionLog 时静默跳过。
  void _logCompanion(String line) {
    try {
      processManager.companionLog.write(line);
    } catch (_) {}
  }

  /// transport（连不上）与 service（进程已退出）值得自愈；其余是站点 / 载荷自己的问题。
  static bool _isRecoverableStage(String? stage) =>
      stage == 'transport' || stage == 'service';

  SpiderCallException _recoveryFailure(
    SpiderCallException error,
    CompanionRecoveryOutcome outcome,
  ) {
    final message = outcome.canRetry
        ? (error.stage == 'service'
            ? '站源服务已自动重启，但站点仍未就绪，请稍后重试'
            : '站源服务在本次动作中退出了，已自动重启；该动作仍未完成（原因见日志）')
        : outcome.failureMessage;
    return SpiderCallException(
      withCompanionLogPath(message, outcome.logPath),
      stage: error.stage,
      detail: error.detail,
      httpStatus: error.httpStatus,
      siteKey: error.siteKey,
      method: error.method,
      rpcId: error.rpcId,
    );
  }

  Future<String> _callSpiderOnce({
    required Site site,
    required String method,
    required Map<String, String> params,
    SearchCancelToken? cancelToken,
    Duration? receiveTimeout,
    Duration? serverTimeout,
  }) async {
    if (cancelToken?.isCancelled ?? false) return '';
    if (!processManager.isRunning) {
      throw const SpiderCallException('站源服务尚未就绪，请重试', stage: 'service');
    }
    processManager.notifyActivity();
    final verificationGeneration = browserVerification.generation;

    // 点叉后立即放弃这次 RPC：Dio 中止连接，Dart 侧不再等满 20 秒。
    final dioCancelToken = CancelToken();
    // Dio 断的只是「Flutter ↔ companion」这条 HTTP 连接；companion 内的 worker
    // 线程仍卡在 jar 里 OkHttp 的同步请求上，继续占着 callPool 的槽（上限 64，
    // 满了直接 503）。所以必须用同一个 rpcId 让 companion 把那次请求真正 cancel()。
    final rpcId = '$method@${site.key}#${++_rpcSeq}';
    var finished = false;
    cancelToken?.onCancel(() {
      if (finished) return;
      dioCancelToken.cancel('请求已取消');
      unawaited(_cancelRemote(rpcId));
    });

    try {
      final reqBody = {
        'siteKey': site.key,
        'api': site.api,
        'ext': _extensionJson(site),
        'jar': site.jar ?? '',
        'method': method,
        'rpcId': rpcId,
        'timeoutMs': '${(serverTimeout ?? rpcServerTimeout).inMilliseconds}',
        ...params,
      };

      final res = await _dio.post<dynamic>(
        '${processManager.baseUrl}/spider/call',
        data: reqBody,
        cancelToken: dioCancelToken,
        options: Options(
          receiveTimeout: receiveTimeout ?? rpcReceiveTimeout,
          validateStatus: (status) => status != null,
        ),
      );

      if (cancelToken?.isCancelled ?? false) return '';
      final dynamic data =
          res.data is String ? jsonDecode(res.data as String) : res.data;
      if (data is! Map) throw const FormatException('站源服务响应格式无效');
      if (res.statusCode != 200 || data['code'] != 0) {
        final stage = data['stage']?.toString() ??
            (res.statusCode == 504 ? 'timeout' : null);
        if (stage == 'browser' && res.statusCode == 428) {
          browserVerification.record(
              site, method, data['browserChallenge'], verificationGeneration);
        }
        final message = switch (stage) {
          'browser' =>
            res.statusCode == 503 ? '站源服务繁忙，请稍后重试' : '站点需要网页验证，请打开验证网页后重试',
          'download' || 'resolve' || 'md5' => '站点资源加载失败，请稍后重试',
          'decrypt' ||
          'dex2jar' ||
          'init' ||
          'instantiate' ||
          'class' =>
            '站点插件加载失败，请重试或更换站源',
          'timeout' => '站源请求超时，请稍后重试',
          'empty' ||
          'upstream' ||
          'interaction' =>
            data['detail']?.toString() ?? '站源未返回内容',
          'call' => res.statusCode == 503
              ? '站源服务繁忙，请稍后重试'
              : _gmPlaybackMessage(site, method, data['detail']?.toString()) ??
                  data['error']?.toString() ??
                  '站源请求失败',
          _ => res.statusCode == 503
              ? '站源服务繁忙，请稍后重试'
              : data['error']?.toString() ?? '站源请求失败',
        };
        throw SpiderCallException(message,
            stage: stage,
            detail: data['detail']?.toString(),
            httpStatus: res.statusCode,
            siteKey: site.key,
            method: method,
            rpcId: rpcId);
      }
      final dynamic rawData = data['data'];
      if (rawData is String) return rawData;
      if (rawData is Map || rawData is List) return jsonEncode(rawData);
      throw const FormatException('站源服务未返回有效数据');
    } on DioException catch (error) {
      if (CancelToken.isCancel(error) || (cancelToken?.isCancelled ?? false)) {
        return '';
      }
      final timeout = [
        DioExceptionType.receiveTimeout,
        DioExceptionType.sendTimeout,
        DioExceptionType.connectionTimeout
      ].contains(error.type);
      if (timeout) unawaited(_cancelRemote(rpcId));
      throw SpiderCallException(timeout ? '站源请求超时，请稍后重试' : '无法连接站源服务，请重试',
          stage: timeout ? 'timeout' : 'transport',
          httpStatus: error.response?.statusCode,
          siteKey: site.key,
          method: method,
          rpcId: rpcId);
    } finally {
      finished = true;
    }
  }

  String? _gmPlaybackMessage(Site site, String method, String? detail) {
    if (method != 'playerContent' ||
        !const ['csp_GM', 'GM'].contains(site.api) ||
        detail == null) {
      return null;
    }
    if (detail.contains('GM playback reference expired; reload detail')) {
      return 'GM 播放引用已过期，请重新打开详情后重试';
    }
    if (detail.contains('GM desktop: netflav main source unavailable;') ||
        detail.contains(
            'GM playback API returned no main stream (preview excluded);')) {
      return '该 GM 站点未返回正片播放来源，请更换线路或站点';
    }
    if ((detail.contains('GM desktop:') ||
            detail.contains('GM original playerContent failed;')) &&
        detail.contains('browser') &&
        detail.contains('unsupported')) {
      return '该 GM 播放方式依赖浏览器，桌面暂不支持，请更换线路或站点';
    }
    return null;
  }

  /// 通知 companion 中止一次在途 RPC。尽力而为：这里失败不影响调用方，
  /// 服务端仍会被看门狗超时收尾（超时路径也会先 cancel socket 再 interrupt worker）。
  Future<void> _cancelRemote(String rpcId) async {
    if (!processManager.isRunning) return;
    try {
      await _dio.post<dynamic>(
        '${processManager.baseUrl}/spider/cancel',
        data: {'rpcId': rpcId},
        options: Options(
          sendTimeout: const Duration(seconds: 3),
          receiveTimeout: const Duration(seconds: 3),
        ),
      );
    } catch (_) {
      // 静默：取消请求本身不该再产生用户可见的错误。
    }
  }

  VodPageResult _parseVodPageResult(String rawJson,
      {Site? site, bool isHome = false}) {
    if (rawJson.isEmpty) {
      return const VodPageResult.empty();
    }

    try {
      final dynamic decoded = jsonDecode(rawJson);
      if (decoded is Map<String, dynamic>) {
        final List<VodCategory> categories = [];
        if (decoded['class'] is List) {
          for (final c in decoded['class']) {
            if (c is Map) {
              final id = (c['type_id'] ?? c['id'] ?? '').toString();
              final name = (c['type_name'] ?? c['name'] ?? '').toString();
              if (id.isNotEmpty && name.isNotEmpty) {
                categories.add(VodCategory(id: id, name: name));
              }
            }
          }
        }

        final List<VodItem> items = [];
        if (decoded['list'] is List) {
          for (final item in decoded['list']) {
            if (item is Map<String, dynamic>) {
              items.add(VodItem.fromJson({
                ...item,
                'site_key': site?.key,
                'site_name': site?.name,
              }));
            }
          }
        }

        return VodPageResult(
          page: int.tryParse(decoded['page']?.toString() ?? '1') ?? 1,
          pageCount: int.tryParse(decoded['pagecount']?.toString() ?? '1') ?? 1,
          total:
              int.tryParse(decoded['total']?.toString() ?? '${items.length}') ??
                  items.length,
          limit: int.tryParse(decoded['limit']?.toString() ?? '20') ?? 20,
          categories: categories,
          list: items,
          filters: parseVodFilters(decoded['filters']),
          siteIcon: isHome
              ? parseHomeSiteIcon(decoded,
                  baseUrl:
                      site != null && !site.usesCompanion ? site.api : null)
              : null,
        );
      }
    } on FormatException {
      throw const FormatException('站源返回的数据格式无效');
    }
    throw const FormatException('站源返回的数据格式无效');
  }
}

/// 从 playerContent 的地址、数组或 values/position 对象取默认档地址。
String? selectSpiderPlayUrl(Object? raw) {
  final selection = _readSpiderQualities(raw);
  return selection.qualities.isEmpty
      ? null
      : selection.qualities[selection.index].url;
}

({List<PlaybackQuality> qualities, int index}) _readSpiderQualities(
    Object? raw) {
  if (raw is String) {
    final url = raw.trim();
    return (
      qualities:
          url.isEmpty ? const [] : [PlaybackQuality(name: '默认', url: url)],
      index: 0
    );
  }
  bool looksLikeUrl(String value) => value.contains('://');
  final qualities = <PlaybackQuality>[];
  if (raw is Map) {
    final values = raw['values'];
    if (values is! List) return (qualities: qualities, index: 0);
    final position = raw['position'];
    var selected = 0;
    for (var originalIndex = 0;
        originalIndex < values.length;
        originalIndex++) {
      final item = values[originalIndex];
      if (item is! Map || item['v'] is! String) continue;
      final url = (item['v'] as String).trim();
      if (!looksLikeUrl(url)) continue;
      final name = item['n'] is String ? (item['n'] as String).trim() : '';
      if (position is int && position == originalIndex) {
        selected = qualities.length;
      }
      qualities.add(PlaybackQuality(
        name: name.isEmpty ? '线路 ${qualities.length + 1}' : name,
        url: url,
      ));
    }
    return (qualities: qualities, index: selected);
  }
  if (raw is! List) return (qualities: qualities, index: 0);
  final items = raw.map((item) => item?.toString().trim() ?? '').toList();
  for (var index = 0; index < items.length; index++) {
    final url = items[index];
    if (!looksLikeUrl(url)) continue;
    final previous = index == 0 ? '' : items[index - 1];
    final name = previous.isNotEmpty && !looksLikeUrl(previous)
        ? previous
        : '清晰度 ${qualities.length + 1}';
    qualities.add(PlaybackQuality(name: name, url: url));
  }
  return (qualities: qualities, index: 0);
}

List<LiveDanmakuSource> _readLiveDanmakuSources(
    Object? raw, String companionBase, String siteKey) {
  if (raw is! List) return const [];
  final base = Uri.tryParse(companionBase);
  if (base == null ||
      base.scheme != 'http' ||
      !const {'127.0.0.1', 'localhost', '::1'}.contains(base.host)) {
    return const [];
  }
  final sources = <LiveDanmakuSource>[];
  final seen = <String>{};
  for (final item in raw.take(64)) {
    if (item is! Map || item['url'] is! String) continue;
    final url = (item['url'] as String).trim();
    final uri = Uri.tryParse(url);
    if (uri == null ||
        uri.scheme != base.scheme ||
        uri.host != base.host ||
        uri.port != base.port ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        uri.path != '/script-danmaku/start') {
      continue;
    }
    final Map<String, List<String>> query;
    try {
      query = uri.queryParametersAll;
    } on FormatException {
      continue;
    }
    bool single(String key) =>
        query[key]?.length == 1 && query[key]!.single.isNotEmpty;
    if (!['token', 'do', 'siteKey', 'id'].every(single) ||
        query['do']!.single != 'py' ||
        query['siteKey']!.single != siteKey ||
        !seen.add(url)) {
      continue;
    }
    final name = item['name'] is String ? (item['name'] as String).trim() : '';
    sources
        .add(LiveDanmakuSource(name: name.isEmpty ? '实时弹幕' : name, url: url));
    if (sources.length == 16) break;
  }
  return List<LiveDanmakuSource>.unmodifiable(sources);
}

/// playerContent 没给地址时，载荷在 msg / message / error / tip 里写的原因；没有返回 null。
/// 只取短文本（≤200 字），避免把整段 HTML 或堆栈当提示。
String? playResultHint(Map<dynamic, dynamic> decoded) {
  for (final key in const ['msg', 'message', 'error', 'tip', 'tips', 'toast']) {
    final value = decoded[key];
    if (value is! String) continue;
    final text = value.trim();
    if (text.isNotEmpty && text.length <= 200) return text;
  }
  return null;
}

/// playerContent 没给地址时的排查摘要，只进日志。
///
/// 只列字段名和长度，提示类字段（msg/error/tip 等）给前 200 字；不输出 header、cookie、token
/// 之类的值，避免网盘凭据进日志。
String describeEmptyPlayResult(
    String siteKey, String flag, String id, String raw) {
  String clip(String s, int n) => s.length <= n ? s : '${s.substring(0, n)}…';
  final head =
      'site=$siteKey flag=$flag id=${clip(id, 120)} rawLen=${raw.length}';
  dynamic decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    return '$head (非 JSON)';
  }
  if (decoded is! Map) return '$head type=${decoded.runtimeType}';
  const hintKeys = {
    'msg',
    'message',
    'error',
    'err',
    'tip',
    'tips',
    'toast',
    'desc'
  };
  final fields = <String>[];
  for (final entry in decoded.entries) {
    final key = '${entry.key}';
    final value = entry.value;
    if (hintKeys.contains(key.toLowerCase()) && value is String) {
      fields.add('$key="${clip(value.trim(), 200)}"');
    } else if (value is String) {
      fields.add('$key(${value.length})');
    } else if (value is List) {
      fields.add('$key[${value.length}]');
    } else if (value is Map) {
      fields.add('$key{${value.length}}');
    } else {
      fields.add('$key=$value');
    }
  }
  return '$head fields: ${fields.join(', ')}';
}

/// Spider 返回的播放意图；单档时 [qualities] 为空，默认地址仍由 [url] 提供。
class SpiderPlayResult {
  final String url;
  final bool needsParse;
  final Map<String, String> headers;
  final List<PlaybackQuality> qualities;
  final int qualityIndex;
  final List<LiveDanmakuSource> liveDanmakuSources;

  const SpiderPlayResult({
    required this.url,
    required this.needsParse,
    this.headers = const {},
    this.qualities = const [],
    this.qualityIndex = 0,
    this.liveDanmakuSources = const [],
  });

  /// 纯播放载荷解析，HTTP type:4 与 Spider 共用，不访问伴随服务状态。
  factory SpiderPlayResult.fromJson(Map<dynamic, dynamic> decoded, {
    String sourceLabel = 'Spider',
    List<LiveDanmakuSource> liveDanmakuSources = const [],
  }) {
    final selection = _readSpiderQualities(decoded['url']);
    final qualities = selection.qualities;
    if (qualities.isEmpty) {
      final hint = playResultHint(decoded);
      throw FormatException('$sourceLabel 未返回播放地址${hint == null ? '' : '：$hint'}');
    }
    final parse = int.tryParse('${decoded['parse'] ?? 0}');
    final jx = int.tryParse('${decoded['jx'] ?? 0}');
    if (parse == null || jx == null ||
        ![0, 1].contains(parse) || ![0, 1].contains(jx)) {
      throw FormatException('不支持的 $sourceLabel 解析类型');
    }
    if ('${decoded['playUrl'] ?? ''}'.trim().isNotEmpty) {
      throw FormatException('暂不支持 $sourceLabel 网页解析前缀');
    }
    dynamic header = decoded['header'] ?? decoded['headers'];
    if (header is String && header.trim().isNotEmpty) {
      try {
        header = jsonDecode(header);
      } on FormatException {
        throw FormatException('$sourceLabel 请求头格式无效');
      }
    }
    // PHP 的空关联数组会编码成 []，语义仍是没有请求头。
    if (header is List && header.isEmpty) header = null;
    if (header != null && header != '' && header is! Map) {
      throw FormatException('$sourceLabel 请求头格式无效');
    }
    final headers = Map<String, String>.unmodifiable(header is Map
        ? header.map((k, v) => MapEntry(k.toString(), v.toString()))
        : const <String, String>{});
    final needsParse = parse == 1 || jx == 1;
    return SpiderPlayResult(
      url: qualities[selection.index].url,
      needsParse: needsParse,
      headers: headers,
      qualityIndex: selection.index,
      liveDanmakuSources: liveDanmakuSources,
      qualities: qualities.length < 2
          ? const []
          : List<PlaybackQuality>.unmodifiable([
              for (final quality in qualities)
                PlaybackQuality(
                  name: quality.name,
                  url: quality.url,
                  headers: headers,
                  needsParse: needsParse,
                ),
            ]),
    );
  }
}

/// 伴随服务给出的明确失败原因（SpiderServer 的 code/stage/detail 契约）。
/// toString 直接返回原因，便于上层 `'$e'` 拼出可读提示。
class SpiderCallException implements Exception {
  const SpiderCallException(this.message,
      {this.stage,
      this.detail,
      this.httpStatus,
      this.siteKey,
      this.method,
      this.rpcId});

  final String message;
  final String? stage;
  final String? detail;
  final int? httpStatus;
  final String? siteKey;
  final String? method;
  final String? rpcId;

  /// 排查用的一行摘要：阶段、调用、HTTP 状态与服务端 detail（如 NPE 的完整消息）。
  /// 只进日志，不进界面文案。
  String get diagnostic {
    final parts = <String>[
      message,
      if (stage != null) 'stage=$stage',
      if (method != null || siteKey != null)
        'call=${method ?? '?'}@${siteKey ?? '?'}',
      if (httpStatus != null) 'http=$httpStatus',
      if (rpcId != null) 'rpc=$rpcId',
      if (detail != null && detail!.trim().isNotEmpty)
        'detail=${detail!.trim()}',
    ];
    return parts.join(' | ');
  }

  @override
  String toString() => message;
}
