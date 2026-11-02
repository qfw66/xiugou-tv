import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import '../api/models/vod_models.dart';
import '../api/search_cancel_token.dart';
import '../config/models/vod_config.dart';
import '../net/http_client_factory.dart';
import 'companion_process_manager.dart';
import 'site_self_check_report.dart';

/// 通过本地 Java 伴随服务执行 CatVod Spider 的 API 适配层
class CompanionSpiderApi {
  final CompanionProcessManager processManager;
  final Dio _dio;

  static const rpcReceiveTimeout = Duration(seconds: 75);
  static const rpcServerTimeout = Duration(seconds: 60);

  CompanionSpiderApi({
    CompanionProcessManager? processManager,
    Dio? dio,
  })  : processManager = processManager ?? CompanionProcessManager(),
        _dio = dio ??
            HttpClientFactory.createDio(BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 20),
            ));

  /// ext 已在模型层规范化为 JSON 字符串（对象形态会被序列化），可直接下发。
  String _extensionJson(Site site) => site.ext ?? '';

  Future<bool> loadSpider(Site site, {Duration? receiveTimeout}) async {
    if (!processManager.isRunning) return false;
    processManager.notifyActivity();

    try {
      final res = await _dio.post<dynamic>(
        '${processManager.baseUrl}/spider/load',
        data: {
          'key': site.key,
          'api': site.api,
          'ext': _extensionJson(site),
          'jar': site.jar ?? '',
          // 唯一取消标签：同站并发加载时，先结束的那次收尾不会误取消另一次的在途请求。
          'rpcId': 'load@${site.key}#${++_rpcSeq}',
        },
        // 冷启动首次要为加固载荷做「下载 → 解密 → dex2jar」，实测 10~20 秒，
        // 默认 20 秒的接收超时会把「正在正常加载」误判成失败（预热横幅一直红）。
        options: receiveTimeout == null ? null : Options(receiveTimeout: receiveTimeout),
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
    );
    return _parseVodPageResult(rawJson, site: site);
  }

  /// 获取分类视频列表
  Future<VodPageResult> fetchCategory(Site site,
      {required String categoryId, int page = 1, bool filter = true}) async {
    final rawJson = await _callSpider(
      site: site,
      method: 'categoryContent',
      params: {
        'tid': categoryId,
        'pg': page.toString(),
        'filter': filter.toString(),
      },
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
    if (raw.trim().isEmpty) throw const FormatException('Spider 未返回播放地址');
    dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      decoded = {'url': raw, 'parse': 0};
    }
    if (decoded is String) decoded = {'url': decoded, 'parse': 0};
    if (decoded is! Map) throw const FormatException('Spider 播放响应格式无效');
    final url = selectSpiderPlayUrl(decoded['url']);
    if (url == null) {
      throw const FormatException('Spider 未返回播放地址');
    }
    final parse = int.tryParse('${decoded['parse'] ?? 0}');
    final jx = int.tryParse('${decoded['jx'] ?? 0}');
    if (parse == null ||
        jx == null ||
        ![0, 1].contains(parse) ||
        ![0, 1].contains(jx)) {
      throw const FormatException('不支持的 Spider 解析类型');
    }
    if ('${decoded['playUrl'] ?? ''}'.trim().isNotEmpty) {
      throw const FormatException('暂不支持 Spider 网页解析前缀');
    }
    dynamic header = decoded['header'];
    if (header is String && header.trim().isNotEmpty) {
      header = jsonDecode(header);
    }
    if (header != null && header != '' && header is! Map) {
      throw const FormatException('Spider 请求头格式无效');
    }
    return SpiderPlayResult(
      url: url.trim(),
      needsParse: parse == 1 || jx == 1,
      headers: header is Map
          ? header.map((k, v) => MapEntry(k.toString(), v.toString()))
          : const {},
    );
  }

  /// 调用站源的 `action()`（FongMi 语义：列表项带 action 字段时点击触发）。
  ///
  /// 配置中心的设置项在这里弹出扫码 / 输入窗口，窗口经 [CompanionUiChannel] 呈现；
  /// 返回值是载荷的原始结果（通常为空或带 msg 的 JSON），失败返回空串。
  Future<String> performAction(Site site, String action) {
    return _callSpider(
      site: site,
      method: 'action',
      params: {'action': action},
    );
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
        final raw = await _callSpider(site: site, method: method, params: params);
        if (raw.trim().isNotEmpty || attempt == 1) return raw;
      } on SpiderCallException catch (error) {
        // Only transient service faults are worth a second attempt; timeouts and payload/upstream
        // failures would just double the user's wait.
        final retryable = const {'empty', 'service', 'transport'}.contains(error.stage) || error.httpStatus == 503;
        if (attempt == 1 || !retryable) rethrow;
      }
      await Future<void>.delayed(const Duration(milliseconds: 800));
    }
    return '';
  }

  Future<String> _callSpider({
    required Site site,
    required String method,
    required Map<String, String> params,
    SearchCancelToken? cancelToken,
    Duration? receiveTimeout,
  }) async {
    if (cancelToken?.isCancelled ?? false) return '';
    if (!processManager.isRunning) throw const SpiderCallException('站源服务尚未就绪，请重试', stage: 'service');
    processManager.notifyActivity();

    // 点叉后立即放弃这次 RPC：Dio 中止连接，Dart 侧不再等满 20 秒。
    final dioCancelToken = CancelToken();
    // Dio 断的只是「Flutter ↔ companion」这条 HTTP 连接；companion 内的 worker
    // 线程仍卡在 jar 里 OkHttp 的同步请求上，继续占着 callPool 的槽（上限 64，
    // 满了直接 503）。所以必须用同一个 rpcId 让 companion 把那次请求真正 cancel()。
    final rpcId = '$method@${site.key}#${++_rpcSeq}';
    var finished = false;
    cancelToken?.onCancel(() {
      if (finished) return;
      dioCancelToken.cancel('搜索已取消');
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
        'timeoutMs': '${rpcServerTimeout.inMilliseconds}',
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
      final dynamic data = res.data is String ? jsonDecode(res.data as String) : res.data;
      if (data is! Map) throw const FormatException('站源服务响应格式无效');
      if (res.statusCode != 200 || data['code'] != 0) {
        final stage = data['stage']?.toString() ?? (res.statusCode == 504 ? 'timeout' : null);
        final message = switch (stage) {
          'download' || 'resolve' || 'md5' => '站点资源加载失败，请稍后重试',
          'decrypt' || 'dex2jar' || 'init' || 'instantiate' || 'class' => '站点插件加载失败，请重试或更换站源',
          'timeout' => '站源请求超时，请稍后重试',
          'empty' || 'upstream' || 'interaction' => data['detail']?.toString() ?? '站源未返回内容',
          _ => res.statusCode == 503 ? '站源服务繁忙，请稍后重试' : data['error']?.toString() ?? '站源请求失败',
        };
        throw SpiderCallException(message, stage: stage, detail: data['detail']?.toString(),
            httpStatus: res.statusCode, siteKey: site.key, method: method, rpcId: rpcId);
      }
      final dynamic rawData = data['data'];
      if (rawData is String) return rawData;
      if (rawData is Map || rawData is List) return jsonEncode(rawData);
      throw const FormatException('站源服务未返回有效数据');
    } on DioException catch (error) {
      if (CancelToken.isCancel(error) || (cancelToken?.isCancelled ?? false)) return '';
      final timeout = [DioExceptionType.receiveTimeout, DioExceptionType.sendTimeout, DioExceptionType.connectionTimeout].contains(error.type);
      if (timeout) unawaited(_cancelRemote(rpcId));
      throw SpiderCallException(timeout ? '站源请求超时，请稍后重试' : '无法连接站源服务，请重试',
          stage: timeout ? 'timeout' : 'transport', httpStatus: error.response?.statusCode,
          siteKey: site.key, method: method, rpcId: rpcId);
    } finally {
      finished = true;
    }
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

  VodPageResult _parseVodPageResult(String rawJson, {Site? site}) {
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
        );
      }
    } on FormatException {
      throw const FormatException('站源返回的数据格式无效');
    }
    throw const FormatException('站源返回的数据格式无效');
  }
}

/// Spider 返回的播放意图；需要解析的页面地址不能直接交给播放器。
/// 从 playerContent 的 `url` 字段取实际播放地址。
///
/// FongMi / TVBox 允许 `url` 是多清晰度数组 `[名称, 地址, 名称, 地址, ...]`
/// （嗷呜「嗷嗚┃动漫」返回 `["4K", ..., "1080P", ...]`）。以前只认字符串，这类站源一律
/// 报「Spider 未返回播放地址」。现在与 FongMi 默认一致取第一档；数组里只有地址（无名称）
/// 时取第一个像地址的元素。都取不到返回 null。
String? selectSpiderPlayUrl(Object? raw) {
  if (raw is String) {
    final value = raw.trim();
    return value.isEmpty ? null : value;
  }
  if (raw is! List) return null;
  final items = raw.map((e) => e?.toString().trim() ?? '').toList();
  bool looksLikeUrl(String v) => v.contains('://');
  // 成对数组：奇数位是地址
  for (var i = 1; i < items.length; i += 2) {
    if (looksLikeUrl(items[i])) return items[i];
  }
  for (final item in items) {
    if (looksLikeUrl(item)) return item;
  }
  return null;
}

class SpiderPlayResult {
  final String url;
  final bool needsParse;
  final Map<String, String> headers;

  const SpiderPlayResult(
      {required this.url, required this.needsParse, this.headers = const {}});
}

/// 伴随服务给出的明确失败原因（SpiderServer 的 code/stage/detail 契约）。
/// toString 直接返回原因，便于上层 `'$e'` 拼出可读提示。
class SpiderCallException implements Exception {
  const SpiderCallException(this.message, {this.stage, this.detail, this.httpStatus, this.siteKey, this.method, this.rpcId});

  final String message;
  final String? stage;
  final String? detail;
  final int? httpStatus;
  final String? siteKey;
  final String? method;
  final String? rpcId;

  @override
  String toString() => message;
}
