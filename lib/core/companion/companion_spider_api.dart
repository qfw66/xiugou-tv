import 'dart:convert';
import 'package:dio/dio.dart';
import '../api/models/vod_models.dart';
import '../config/models/vod_config.dart';
import 'companion_process_manager.dart';
import 'site_self_check_report.dart';

/// 通过本地 Java 伴随服务执行 CatVod Spider 的 API 适配层
class CompanionSpiderApi {
  final CompanionProcessManager processManager;
  final Dio _dio;

  CompanionSpiderApi({
    CompanionProcessManager? processManager,
    Dio? dio,
  })  : processManager = processManager ?? CompanionProcessManager(),
        _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 20),
            ));

  /// ext 已在模型层规范化为 JSON 字符串（对象形态会被序列化），可直接下发。
  String _extensionJson(Site site) => site.ext ?? '';

  Future<bool> loadSpider(Site site) async {
    if (!processManager.isRunning) return false;

    try {
      final res = await _dio.post<dynamic>(
        '${processManager.baseUrl}/spider/load',
        data: {
          'key': site.key,
          'api': site.api,
          'ext': _extensionJson(site),
          'jar': site.jar ?? '',
        },
      );
      if (res.statusCode == 200) {
        final dynamic data = res.data is String ? jsonDecode(res.data as String) : res.data;
        if (data is Map) {
          return data['code'] == 0;
        }
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// 把设置里的「站点自检」总开关同步给伴随服务（运行期生效，无需重启进程）。
  ///
  /// 开关决定两件事：是否打印 `[SelfCheck]` 载荷体检日志、是否接受逐站体检请求。
  /// 伴随服务未运行或下发失败时返回 false，由调用方决定是否提示。
  Future<bool> configureSelfCheck(bool enabled) async {
    if (!processManager.isRunning) return false;
    try {
      final res = await _dio.post<dynamic>(
        '${processManager.baseUrl}/spider/call',
        data: {'method': 'selfCheckConfig', 'enabled': enabled.toString()},
      );
      if (res.statusCode == 200) {
        final dynamic data = res.data is String ? jsonDecode(res.data as String) : res.data;
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
    if (!processManager.isRunning || sites.isEmpty) return const SelfCheckReport();

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
        options: Options(receiveTimeout: Duration(milliseconds: budgetMs + 15000)),
      );
      if (res.statusCode == 200) {
        final dynamic data = res.data is String ? jsonDecode(res.data as String) : res.data;
        if (data is Map && data['code'] == 0) {
          return SelfCheckReport.tryParse(data['data']) ?? const SelfCheckReport();
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
  Future<VodPageResult> fetchCategory(Site site, {required String categoryId, int page = 1, bool filter = true}) async {
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
    final rawJson = await _callSpider(
      site: site,
      method: 'detailContent',
      params: {'id': vodId},
    );
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
      return null;
    }
    return null;
  }

  /// 搜索视频
  Future<VodPageResult> search(Site site, {required String keyword, int page = 1, bool quick = false}) async {
    final rawJson = await _callSpider(
      site: site,
      method: 'searchContent',
      params: {
        'wd': keyword,
        'quick': quick.toString(),
        'pg': page.toString(),
      },
    );
    return _parseVodPageResult(rawJson, site: site);
  }

  /// 获取 Spider 播放结果；不将空响应或影片标识伪装成媒体地址。
  Future<SpiderPlayResult> fetchPlayResult(Site site, {required String flag, required String id}) async {
    final raw = await _callSpider(
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
    final url = decoded['url'];
    if (url is! String || url.trim().isEmpty) {
      throw const FormatException('Spider 未返回播放地址');
    }
    final parse = int.tryParse('${decoded['parse'] ?? 0}');
    final jx = int.tryParse('${decoded['jx'] ?? 0}');
    if (parse == null || jx == null || ![0, 1].contains(parse) || ![0, 1].contains(jx)) {
      throw const FormatException('不支持的 Spider 解析类型');
    }
    if ('${decoded['playUrl'] ?? ''}'.trim().isNotEmpty) {
      throw const FormatException('暂不支持 Spider 网页解析前缀');
    }
    dynamic header = decoded['header'];
    if (header is String && header.trim().isNotEmpty) header = jsonDecode(header);
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

  /// 仅获取地址的兼容入口；播放调用应使用完整结果以保留解析标志与请求头。
  Future<String> fetchPlayUrl(Site site, {required String flag, required String id}) async =>
      (await fetchPlayResult(site, flag: flag, id: id)).url;

  Future<String> _callSpider({
    required Site site,
    required String method,
    required Map<String, String> params,
  }) async {
    if (!processManager.isRunning) return '';

    try {
      final reqBody = {
        'siteKey': site.key,
        'api': site.api,
        'ext': _extensionJson(site),
        'jar': site.jar ?? '',
        'method': method,
        ...params,
      };

      final res = await _dio.post<dynamic>(
        '${processManager.baseUrl}/spider/call',
        data: reqBody,
      );

      if (res.statusCode == 200) {
        final dynamic data = res.data is String ? jsonDecode(res.data as String) : res.data;
        if (data is Map && data['code'] == 0) {
          final dynamic rawData = data['data'];
          if (rawData is String) {
            return rawData;
          } else if (rawData is Map || rawData is List) {
            return jsonEncode(rawData);
          }
        }
      }
    } catch (_) {}
    return '';
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
          total: int.tryParse(decoded['total']?.toString() ?? '${items.length}') ?? items.length,
          limit: int.tryParse(decoded['limit']?.toString() ?? '20') ?? 20,
          categories: categories,
          list: items,
        );
      }
    } catch (_) {}

    return const VodPageResult.empty();
  }
}

/// Spider 返回的播放意图；需要解析的页面地址不能直接交给播放器。
class SpiderPlayResult {
  final String url;
  final bool needsParse;
  final Map<String, String> headers;

  const SpiderPlayResult({required this.url, required this.needsParse, this.headers = const {}});
}
