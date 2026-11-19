import 'dart:convert';
import 'dart:developer' as developer;
import 'package:dio/dio.dart';
import '../companion/companion_spider_api.dart' show SpiderPlayResult, playResultHint;
import '../config/models/vod_config.dart';
import '../net/ascii_url.dart';
import '../net/http_client_factory.dart';
import '../net/site_icon_url.dart';
import '../player/playback_diagnostics.dart';
import 'models/vod_models.dart';
import 'search_cancel_token.dart';

/// 标准 CMS (AppleCMS / MacCMS / XML / JSON / Direct) 站点数据接口客户端
class CmsJsonApi {
  final Dio _dio;

  CmsJsonApi({Dio? dio})
      : _dio = dio ??
            HttpClientFactory.createDio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 15),
                receiveTimeout: const Duration(seconds: 20),
                headers: {
                  'User-Agent':
                      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36 xiugou-tv/5.6.3',
                  'Accept': 'application/json, text/xml, application/xml, text/html, */*',
                },
              ),
            );

  /// 打印格式化调试日志到终端与控制台
  void _log(String tag, String message) {
    developer.log(message, name: 'xiugou-tv::$tag');
    // ignore: avoid_print
    print('[$tag] $message');
  }

  /// 辅助构建请求头
  Map<String, dynamic> _buildHeaders(Site? site) {
    final headers = <String, dynamic>{
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36 xiugou-tv/5.6.3',
      'Accept': 'application/json, text/xml, application/xml, text/html, */*',
    };
    if (site?.header != null) {
      headers.addAll(site!.header!);
    }
    return headers;
  }

  /// type:4 的 ext 是不透明扩展（包括 URL）；传统 CMS 保留 URL 作为端点的约定。
  String? _getExtendParam(Site? site) {
    if (site?.type == 4) {
      final ext = site?.ext;
      return ext == null || ext.isEmpty ? null : ext;
    }
    final ext = site?.ext?.trim();
    if (ext != null && ext.isNotEmpty && !ext.startsWith('http://') && !ext.startsWith('https://')) {
      return ext;
    }
    return null;
  }

  /// 解析站源的有效 HTTP 访问地址 (兼容 api 为 http/https、ext 为 http/https、或 csp_ 站源扩展地址)
  String? _resolveHttpEndpoint(String apiEndpoint, Site? site) {
    final rawApi = apiEndpoint.trim();
    if (rawApi.startsWith('http://') || rawApi.startsWith('https://')) {
      return rawApi;
    }
    if (site?.type == 4) return null;
    // 如果 api 是 csp_ 等非 HTTP 协议，但 ext 是以 http 开头的有效地址 (如 csp_AppYsV2, csp_XBPQ, 直连)
    final rawExt = site?.ext?.trim() ?? '';
    if (rawExt.startsWith('http://') || rawExt.startsWith('https://')) {
      return rawExt;
    }
    // 如果 ext 是 JSON 格式，尝试解析内部包含的 url / api / site 字段
    if (rawExt.startsWith('{') && rawExt.endsWith('}')) {
      try {
        final extMap = jsonDecode(rawExt);
        if (extMap is Map) {
          final candidate = extMap['url'] ?? extMap['api'] ?? extMap['site'];
          if (candidate is String && (candidate.startsWith('http://') || candidate.startsWith('https://'))) {
            return candidate;
          }
        }
      } catch (_) {}
    }
    return null;
  }

  /// 站源是否存在可解析的 HTTP 端点（供搜索范围判定复用，不改变请求行为）
  bool supportsHttpEndpoint(Site site) => _resolveHttpEndpoint(site.api, site) != null;

  /// 辅助执行 HTTP GET 请求并输出完整调试日志
  Future<String> _httpGet(
    String url, {
    Map<String, dynamic>? queryParams,
    Map<String, dynamic>? headers,
    String? logTag,
    CancelToken? cancelToken,
    void Function(Uri)? onResponseUrl,
  }) async {
    final tag = logTag ?? 'SiteApi::Http';
    final qStr = queryParams != null && queryParams.isNotEmpty
        ? '?${queryParams.entries.map((e) => "${e.key}=${e.key == 'extend' ? '***' : Uri.encodeComponent(e.value.toString())}").join("&")}'
        : '';
    final fullUrl = '$url$qStr';
    // 这两行会同时进 developer.log 与 stdout：地址 / 请求头里的凭据只留键名，
    // 真实请求仍用原值。
    _log(tag, '--> 发起 GET 请求: ${maskSensitiveUrl(fullUrl)}');
    if (headers != null && headers.isNotEmpty) {
      final loggable = headers.map((k, v) => MapEntry(k, '$v'));
      _log(tag, '    请求头: ${maskSensitiveHeaders(loggable)}');
    }

    final stopwatch = Stopwatch()..start();
    try {
      final response = await _dio.get<dynamic>(
        AsciiUrl.toAsciiHost(url),
        queryParameters: queryParams,
        cancelToken: cancelToken,
        options: Options(
          headers: headers,
          responseType: ResponseType.plain,
        ),
      );
      stopwatch.stop();
      onResponseUrl?.call(response.realUri);

      final rawData = response.data?.toString() ?? '';
      final snippet = rawData.length > 300 ? '${rawData.substring(0, 300)}...' : rawData;
      _log(tag, '<-- 请求成功 (耗时: ${stopwatch.elapsedMilliseconds}ms, 状态码: ${response.statusCode}, 长度: ${rawData.length} 字节)');
      _log(tag, '    响应摘要: $snippet');
      return rawData;
    } catch (e) {
      stopwatch.stop();
      _log(tag, '<-- 请求发生异常 (耗时: ${stopwatch.elapsedMilliseconds}ms): $e');
      rethrow;
    }
  }

  /// 1. 拉取站源首页推荐列表与动态分类 (参照 TVBox SiteApi.homeContent 与 TVBox)
  Future<VodPageResult> fetchHome(String apiEndpoint, {Site? site}) =>
      _fetchHome(apiEndpoint, site: site);

  Future<VodPageResult> fetchType4Home(Site site, {bool filter = true}) =>
      _fetchHome(site.api, site: site, filter: filter);

  Future<VodPageResult> _fetchHome(String apiEndpoint,
      {Site? site, bool filter = true}) async {
    final siteName = site?.name ?? '未知站源';
    final siteType = site?.type ?? 0;
    _log('SiteApi::fetchHome', '===========================================================');
    _log('SiteApi::fetchHome', '--> 开始拉取站源首页: [$siteName] (Type: $siteType, API: ${maskSensitiveUrl(apiEndpoint)})');
    if (site?.ext != null && site!.ext!.isNotEmpty) {
      // ext 是站源自定义内容，常夹带账号 / 令牌，且格式不定无法按字段打码，只记长度
      _log('SiteApi::fetchHome', '    站源 Ext 参数: ${site.ext!.length} 字符');
    }

    final effectiveEndpoint = _resolveHttpEndpoint(apiEndpoint, site);
    if (effectiveEndpoint == null) {
      _log('SiteApi::fetchHome', '<-- [$siteName] 该站源是爬虫插件 ($apiEndpoint)，没有 HTTP 端点，不能走 CMS 通道（须由爬虫服务加载）。');
      throw UnsupportedError('站源 [$siteName] 是爬虫插件（$apiEndpoint），需要由爬虫服务加载，不能按 CMS 接口直连');
    }

    try {
      // 策略 A (TVBox 原版标准): 直接 GET 站源 API (带 extend 参数)
      final extendParam = _getExtendParam(site);
      final paramsA = <String, dynamic>{
        if (siteType == 4) 'filter': filter ? '1' : '0',
      };
      if (extendParam != null) {
        paramsA['extend'] = extendParam;
      }
      var homeBaseUrl = effectiveEndpoint;

      String raw = await _httpGet(
        effectiveEndpoint,
        queryParams: paramsA.isNotEmpty ? paramsA : null,
        headers: _buildHeaders(site),
        logTag: 'SiteApi::fetchHome',
        onResponseUrl: (uri) => homeBaseUrl = uri.toString(),
      );

      var result = _parseContent(raw, type: siteType, site: site,
          homeBaseUrl: homeBaseUrl);

      // 策略 B fallback: 如果直接请求未获得分类且无影片，尝试附带 ac=videolist 或 ac=detail
      if (result.categories.isEmpty && result.list.isEmpty && siteType != 4) {
        _log('SiteApi::fetchHome', '--> 策略 A 未返回数据，尝试策略 B (附带 ac 参数)...');
        final paramsB = <String, dynamic>{
          'ac': (siteType == 0) ? 'videolist' : 'videolist',
          'pg': '1',
        };
        if (extendParam != null) {
          paramsB['extend'] = extendParam;
        }
        raw = await _httpGet(
          effectiveEndpoint,
          queryParams: paramsB,
          headers: _buildHeaders(site),
          logTag: 'SiteApi::fetchHome',
          onResponseUrl: (uri) => homeBaseUrl = uri.toString(),
        );
        final fallback = _parseContent(raw, type: siteType, site: site,
            homeBaseUrl: homeBaseUrl);
        result = fallback.copyWith(siteIcon: fallback.siteIcon ?? result.siteIcon);
      }

      // 策略 C fallback (针对 JSON CMS): 如果仍为空，尝试 ac=detail
      if (result.categories.isEmpty && result.list.isEmpty && siteType == 1) {
        _log('SiteApi::fetchHome', '--> 尝试策略 C (ac=detail)...');
        final paramsC = <String, dynamic>{
          'ac': 'detail',
          'pg': '1',
        };
        if (extendParam != null) {
          paramsC['extend'] = extendParam;
        }
        raw = await _httpGet(
          effectiveEndpoint,
          queryParams: paramsC,
          headers: _buildHeaders(site),
          logTag: 'SiteApi::fetchHome',
          onResponseUrl: (uri) => homeBaseUrl = uri.toString(),
        );
        final fallback = _parseContent(raw, type: siteType, site: site,
            homeBaseUrl: homeBaseUrl);
        result = fallback.copyWith(siteIcon: fallback.siteIcon ?? result.siteIcon);
      }

      // 如果站源配置中预先指定了 categories 过滤列表，进行过滤 (同 TVBox setTypes)
      if (site != null && site.categories != null && site.categories!.isNotEmpty && result.categories.isNotEmpty) {
        final allowedNames = site.categories!.toSet();
        final filteredCats = result.categories.where((c) => allowedNames.contains(c.name)).toList();
        if (filteredCats.isNotEmpty) {
          result = VodPageResult(
            page: result.page,
            pageCount: result.pageCount,
            limit: result.limit,
            total: result.total,
            categories: filteredCats,
            list: result.list,
            filters: result.filters,
            siteIcon: result.siteIcon,
          );
        }
      }

      // 调试日志：打印分类与影片统计
      final catSummary = result.categories.map((c) => '${c.name}(${c.id})').join(', ');
      _log('SiteApi::fetchHome', '<-- [$siteName] 首页拉取完成: 分类数=${result.categories.length} [ $catSummary ], 推荐影片数=${result.list.length}');
      if (result.list.isNotEmpty) {
        final preview = result.list.take(5).map((v) => '• ${v.name} [ID:${v.id}, 备注:${v.remarks ?? "无"}, 评分:${v.score ?? "无"}]').join('\n  ');
        _log('SiteApi::fetchHome', '  推荐影片预览:\n  $preview');
      }
      _log('SiteApi::fetchHome', '===========================================================');

      return result;
    } catch (e, stack) {
      _log('SiteApi::fetchHome', '<-- [$siteName] 首页拉取失败: $e\n$stack');
      rethrow;
    }
  }

  /// 2. 分类分页列表查询 (参照 TVBox SiteApi.categoryContent 与 TVBox)
  ///
  /// [extend] 为筛选条件：type:1 使用 `f=<JSON>`，type:4 使用 `ext=<Base64 UTF8 JSON>`。
  /// 站源扩展始终独立使用 `extend`；XML 源忽略筛选条件。
  /// [cancelToken] 取消后中止在途 HTTP、不再发后续回退，并返回空结果。
  Future<VodPageResult> fetchCategory(
    String apiEndpoint,
    String categoryId, {
    int page = 1,
    Site? site,
    Map<String, String> extend = const {},
    SearchCancelToken? cancelToken,
  }) async {
    final siteName = site?.name ?? '未知站源';
    final siteType = site?.type ?? 0;
    _log('SiteApi::fetchCategory', '--> 正在拉取分类数据: [$siteName] (分类ID: $categoryId, 页码: $page)');

    final effectiveEndpoint = _resolveHttpEndpoint(apiEndpoint, site);
    if (effectiveEndpoint == null) {
      _log('SiteApi::fetchCategory', '<-- [$siteName] 该站源是爬虫插件 ($apiEndpoint)，没有 HTTP 端点，不能走 CMS 通道拉取分类。');
      return const VodPageResult.empty();
    }

    final dioCancelToken = CancelToken();
    cancelToken?.onCancel(() => dioCancelToken.cancel('请求已取消'));
    final filterParam = (siteType == 1 && extend.isNotEmpty) ? jsonEncode(extend) : null;

    try {
      // 策略 1: 标准 CMS 分类参数
      // XML 源: ac=videolist&t=id&pg=page
      // JSON 源: ac=detail&t=id&pg=page
      final extendParam = _getExtendParam(site);
      final queryParams = <String, dynamic>{
        'ac': (siteType == 0) ? 'videolist' : 'detail',
        't': categoryId,
        'pg': page.toString(),
      };
      if (extendParam != null) {
        queryParams['extend'] = extendParam;
      }
      if (filterParam != null) {
        queryParams['f'] = filterParam;
      }
      if (siteType == 4) {
        queryParams['ext'] = base64Encode(utf8.encode(jsonEncode(extend)));
      }

      String raw = await _httpGet(
        effectiveEndpoint,
        queryParams: queryParams,
        headers: _buildHeaders(site),
        logTag: 'SiteApi::fetchCategory',
        cancelToken: dioCancelToken,
      );

      var result = _parseContent(raw, type: siteType, site: site);

      // 用户已取消（改了筛选 / 切了分类）：后续回退纯属浪费
      if (cancelToken?.isCancelled ?? false) return const VodPageResult.empty();

      // 如果返回为空，尝试 fallback 策略 2: ac=videolist
      if (result.list.isEmpty && siteType == 1) {
        _log('SiteApi::fetchCategory', '--> 策略 1 未返回数据，尝试 fallback 策略 2 (ac=videolist)...');
        queryParams['ac'] = 'videolist';
        raw = await _httpGet(
          effectiveEndpoint,
          queryParams: queryParams,
          headers: _buildHeaders(site),
          logTag: 'SiteApi::fetchCategory',
          cancelToken: dioCancelToken,
        );
        result = _parseContent(raw, type: siteType, site: site);
      }

      if (cancelToken?.isCancelled ?? false) return const VodPageResult.empty();

      // 如果仍为空，尝试 fallback 策略 3: 不带 ac 参数 (部分 CMS 仅支持 t=id&pg=page)
      if (result.list.isEmpty && siteType != 4) {
        _log('SiteApi::fetchCategory', '--> 尝试 fallback 策略 3 (纯 t/pg 参数)...');
        final noAcParams = <String, dynamic>{
          't': categoryId,
          'pg': page.toString(),
        };
        if (extendParam != null) {
          noAcParams['extend'] = extendParam;
        }
        if (filterParam != null) {
          noAcParams['f'] = filterParam;
        }
        raw = await _httpGet(
          effectiveEndpoint,
          queryParams: noAcParams,
          headers: _buildHeaders(site),
          logTag: 'SiteApi::fetchCategory',
          cancelToken: dioCancelToken,
        );
        result = _parseContent(raw, type: siteType, site: site);
      }

      _log('SiteApi::fetchCategory', '<-- [$siteName] 分类数据拉取成功: 分类ID=$categoryId, 影片数=${result.list.length}, 总页数=${result.pageCount}');
      if (result.list.isNotEmpty) {
        final preview = result.list.take(3).map((v) => '• ${v.name} [ID:${v.id}, 备注:${v.remarks ?? "无"}]').join('\n  ');
        _log('SiteApi::fetchCategory', '  分类影片预览:\n  $preview');
      }
      return result;
    } catch (e) {
      if (cancelToken?.isCancelled ?? false) return const VodPageResult.empty();
      _log('SiteApi::fetchCategory', '<-- [$siteName] 分类数据拉取失败: $e');
      rethrow;
    }
  }

  /// 3. 获取影片详情与播放源选集列表 (支持 XML 与 JSON 双格式)
  Future<VodDetail> fetchDetail(String apiEndpoint, String vodId, {Site? site}) async {
    final siteName = site?.name ?? '未知站源';
    final siteType = site?.type ?? 0;
    _log('SiteApi::fetchDetail', '--> 正在获取影片详情: [$siteName] (VodID: $vodId)');

    final effectiveEndpoint = _resolveHttpEndpoint(apiEndpoint, site);
    if (effectiveEndpoint == null) {
      _log('SiteApi::fetchDetail', '<-- [$siteName] 该站源是爬虫插件 ($apiEndpoint)，没有 HTTP 端点，不能走 CMS 通道获取详情。');
      throw UnsupportedError('站源 [$siteName] 是爬虫插件（$apiEndpoint），需要由爬虫服务加载，不能按 CMS 接口直连');
    }

    try {
      final extendParam = _getExtendParam(site);
      final queryParams = <String, dynamic>{
        'ac': (siteType == 0) ? 'videolist' : 'detail',
        'ids': vodId,
      };
      if (extendParam != null) {
        queryParams['extend'] = extendParam;
      }

      String raw = await _httpGet(
        effectiveEndpoint,
        queryParams: queryParams,
        headers: _buildHeaders(site),
        logTag: 'SiteApi::fetchDetail',
      );

      final trimmed = raw.trim();

      // 判断是 XML 还是 JSON
      if (siteType == 0 || trimmed.startsWith('<?xml') || trimmed.startsWith('<rss') || trimmed.startsWith('<root') || trimmed.startsWith('<')) {
        final detail = VodDetail.fromXml(trimmed, siteKey: site?.key, siteName: site?.name);
        _log('SiteApi::fetchDetail', '<-- [$siteName] XML 影片详情获取成功: ${detail.item.name}, 播放线路数=${detail.sources.length}');
        return detail;
      }

      final map = _ensureJsonMap(trimmed);
      final list = (map['list'] as List<dynamic>?) ?? (map['data'] as List<dynamic>?) ?? [];
      if (list.isEmpty) {
        if (siteType == 4) throw StateError('未找到影片详情 (ID: $vodId)');
        // Fallback: 尝试使用 id 代替 ids
        _log('SiteApi::fetchDetail', '--> 未找到详情，尝试 id 参数 fallback...');
        final fbParams = <String, dynamic>{
          'ac': 'detail',
          'id': vodId,
        };
        if (extendParam != null) {
          fbParams['extend'] = extendParam;
        }
        final fbRaw = await _httpGet(
          effectiveEndpoint,
          queryParams: fbParams,
          headers: _buildHeaders(site),
          logTag: 'SiteApi::fetchDetail',
        );
        final fbMap = _ensureJsonMap(fbRaw.trim());
        final fbList = (fbMap['list'] as List<dynamic>?) ?? (fbMap['data'] as List<dynamic>?) ?? [];
        if (fbList.isNotEmpty) {
          final detailJson = fbList.first as Map<String, dynamic>;
          final detail = VodDetail.fromJson(detailJson);
          _log('SiteApi::fetchDetail', '<-- [$siteName] 影片详情获取成功: ${detail.item.name}, 线路数=${detail.sources.length}');
          return detail;
        }
        throw StateError('未找到影片详情 (ID: $vodId)');
      }

      final detailJson = list.first as Map<String, dynamic>;
      final detail = VodDetail.fromJson(detailJson);
      _log('SiteApi::fetchDetail', '<-- [$siteName] 影片详情获取成功: ${detail.item.name}, 播放线路数=${detail.sources.length}');
      return detail;
    } catch (e) {
      _log('SiteApi::fetchDetail', '<-- [$siteName] 影片详情获取失败: $e');
      rethrow;
    }
  }

  /// 4. 关键词检索 (参照 TVBox SiteApi.searchContent 与 TVBox，支持全协议 CMS 搜索)
  Future<VodPageResult> search(
    String apiEndpoint,
    String keyword, {
    int page = 1,
    Site? site,
    SearchCancelToken? cancelToken,
  }) => _search(apiEndpoint, keyword,
      page: page, site: site, cancelToken: cancelToken);

  Future<VodPageResult> searchType4(Site site, String keyword, {
    int page = 1,
    bool quick = false,
    SearchCancelToken? cancelToken,
  }) => _search(site.api, keyword,
      page: page, quick: quick, site: site, cancelToken: cancelToken);

  Future<VodPageResult> _search(
    String apiEndpoint,
    String keyword, {
    int page = 1,
    bool quick = false,
    Site? site,
    SearchCancelToken? cancelToken,
  }) async {
    final siteName = site?.name ?? '未知站源';
    final siteType = site?.type ?? 0;
    final query = keyword.trim();
    if (query.isEmpty) return const VodPageResult.empty();

    // 把「用户取消」桥接成 Dio 的中止信号：点叉后在途 HTTP 立即断掉，
    // 不再白跑完 20 秒超时（§18）。
    final dioCancelToken = CancelToken();
    cancelToken?.onCancel(() => dioCancelToken.cancel('搜索已取消'));

    final effectiveEndpoint = _resolveHttpEndpoint(apiEndpoint, site);
    if (effectiveEndpoint == null) {
      throw UnsupportedError('站源没有可用的 HTTP 搜索接口');
    }

    _log('SiteApi::search', '--> 正在搜索站点: [$siteName] (关键词: "$query", 页码: $page)');

    try {
      final extendParam = _getExtendParam(site);
      // 策略 1 (TVBox 标准): wd=keyword&pg=page
      final queryParams = <String, dynamic>{
        'wd': query,
        'pg': page.toString(),
        if (siteType == 4) 'quick': quick ? '1' : '0',
      };
      if (extendParam != null) {
        queryParams['extend'] = extendParam;
      }

      String raw = await _httpGet(
        effectiveEndpoint,
        queryParams: queryParams,
        headers: _buildHeaders(site),
        logTag: 'SiteApi::search',
        cancelToken: dioCancelToken,
      );

      var result = _parseContent(raw, type: siteType, site: site);

      // 用户已取消：不再跑后续 fallback（那是纯浪费）
      if (cancelToken?.isCancelled ?? false) {
        return const VodPageResult.empty();
      }

      // 策略 2 fallback (TVBox 标准): 如果直接 wd 检索为空，尝试带 ac 参数 (ac=detail 或 ac=videolist)
      if (result.list.isEmpty && siteType != 4) {
        _log('SiteApi::search', '--> 策略 1 (纯wd) 未返回数据，尝试策略 2 (附带 ac 参数)...');
        final params2 = <String, dynamic>{
          'ac': (siteType == 0) ? 'videolist' : 'detail',
          'wd': query,
          'pg': page.toString(),
        };
        if (extendParam != null) {
          params2['extend'] = extendParam;
        }
        raw = await _httpGet(
          effectiveEndpoint,
          queryParams: params2,
          headers: _buildHeaders(site),
          logTag: 'SiteApi::search',
          cancelToken: dioCancelToken,
        );
        result = _parseContent(raw, type: siteType, site: site);
      }

      // 策略 2 结束后用户已取消：不再发策略 3。
      if (cancelToken?.isCancelled ?? false) {
        return const VodPageResult.empty();
      }

      // 策略 3 fallback: 如果仍为空且为 JSON，尝试 ac=videolist
      if (result.list.isEmpty && siteType == 1) {
        _log('SiteApi::search', '--> 尝试策略 3 (ac=videolist&wd)...');
        final params3 = <String, dynamic>{
          'ac': 'videolist',
          'wd': query,
          'pg': page.toString(),
        };
        if (extendParam != null) {
          params3['extend'] = extendParam;
        }
        raw = await _httpGet(
          effectiveEndpoint,
          queryParams: params3,
          headers: _buildHeaders(site),
          logTag: 'SiteApi::search',
          cancelToken: dioCancelToken,
        );
        result = _parseContent(raw, type: siteType, site: site);
      }

      // 如果搜索结果中没有封面图，自动触发 fetchPic 批量补齐海报 (同 TVBox SiteApi.fetchPic)
      if (siteType != 4 && result.list.isNotEmpty &&
          result.list.any((item) => item.pic.isEmpty) &&
          !(cancelToken?.isCancelled ?? false)) {
        _log('SiteApi::search', '--> 检索结果存在缺少海报的条目，正在执行 fetchPic 补全海报...');
        result = await _fetchPicFallback(effectiveEndpoint, result,
            site: site, cancelToken: dioCancelToken);
      }

      if (cancelToken?.isCancelled ?? false) {
        return const VodPageResult.empty();
      }

      _log('SiteApi::search', '<-- [$siteName] 搜索完成: 获得 ${result.list.length} 条结果');
      if (result.list.isNotEmpty) {
        final preview = result.list.take(3).map((v) => '• ${v.name} [ID:${v.id}, 备注:${v.remarks ?? "无"}]').join('\n  ');
        _log('SiteApi::search', '  搜索命中预览:\n  $preview');
      }
      return result;
    } catch (e) {
      // 取消导致的异常不必当成失败刷日志
      if (cancelToken?.isCancelled ?? false) {
        return const VodPageResult.empty();
      }
      _log('SiteApi::search', '<-- [$siteName] 搜索发生异常: $e');
      rethrow;
    }
  }

  /// drpy-node type:4 的播放接口始终请求源站，包括输入本身已是媒体 URL 的情况。
  Future<SpiderPlayResult> fetchPlayResult(Site site,
      {required String flag, required String id}) async {
    if (site.type != 4) throw UnsupportedError('只有 type:4 支持 HTTP 播放接口');
    final endpoint = _resolveHttpEndpoint(site.api, site);
    if (endpoint == null) throw const FormatException('type:4 站源没有有效的 HTTP API 地址');
    final extend = _getExtendParam(site);
    final String raw;
    try {
      raw = await _httpGet(endpoint,
          queryParams: {
            'play': id,
            'flag': flag,
            if (extend != null) 'extend': extend,
          },
          headers: _buildHeaders(site),
          logTag: 'SiteApi::fetchPlayResult');
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      throw StateError('站源 [${site.name}] type:4 播放请求失败'
          '（${status == null ? error.type.name : 'HTTP $status'}）');
    }
    final trimmed = raw.trim();
    if (trimmed.isEmpty) throw const FormatException('type:4 未返回播放地址');
    dynamic decoded;
    try {
      decoded = jsonDecode(trimmed);
    } on FormatException {
      decoded = {'url': trimmed};
    }
    if (decoded is String) decoded = {'url': decoded};
    if (decoded is! Map) throw const FormatException('type:4 播放响应格式无效');
    if (decoded['error'] != null) {
      throw FormatException('type:4 播放接口失败：${playResultHint(decoded) ?? '源站返回错误'}');
    }
    final result = SpiderPlayResult.fromJson(decoded, sourceLabel: 'type:4');
    final uri = Uri.tryParse(result.url);
    if (uri == null || !['http', 'https', 'rtmp', 'rtsp', 'file'].contains(uri.scheme) ||
        (uri.scheme != 'file' && uri.host.isEmpty)) {
      throw const FormatException('type:4 未返回有效媒体地址');
    }
    return result;
  }

  /// 补全搜索结果海报图片 (同 TVBox 原版 SiteApi.fetchPic)
  Future<VodPageResult> _fetchPicFallback(String apiEndpoint, VodPageResult result,
      {Site? site, CancelToken? cancelToken}) async {
    try {
      final needPicItems = result.list.where((i) => i.pic.isEmpty).toList();
      if (needPicItems.isEmpty) return result;

      final ids = needPicItems.map((i) => i.id).take(20).join(',');
      final raw = await _httpGet(
        apiEndpoint,
        queryParams: {
          'ac': (site?.type == 0) ? 'videolist' : 'detail',
          'ids': ids,
        },
        headers: _buildHeaders(site),
        logTag: 'SiteApi::fetchPic',
        cancelToken: cancelToken,
      );

      final detailResult = _parseContent(raw, type: site?.type ?? 1, site: site);
      if (detailResult.list.isEmpty) return result;

      final picMap = {for (final v in detailResult.list) v.id: v.pic};
      final updatedList = result.list.map((item) {
        if (item.pic.isEmpty && picMap.containsKey(item.id)) {
          return item.copyWith(pic: picMap[item.id]);
        }
        return item;
      }).toList();

      return VodPageResult(
        page: result.page,
        pageCount: result.pageCount,
        limit: result.limit,
        total: result.total,
        categories: result.categories,
        list: updatedList,
      );
    } catch (_) {
      return result;
    }
  }

  /// 统一解析 JSON / XML 内容
  VodPageResult _parseContent(String raw,
      {int type = 1, Site? site, String? homeBaseUrl}) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return const VodPageResult.empty();

    // 1. 如果以 { 或 [ 开头，优先按 JSON 解析
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      return _parseJsonContent(trimmed, site: site, homeBaseUrl: homeBaseUrl);
    }

    // 2. 如果以 XML 标签开头或 type == 0，按 XML 解析
    if (type == 0 || trimmed.startsWith('<?xml') || trimmed.startsWith('<rss') || trimmed.startsWith('<root') || trimmed.startsWith('<')) {
      return _parseXmlContent(trimmed, site: site, homeBaseUrl: homeBaseUrl);
    }

    // 3. 默认按 JSON 解析
    return _parseJsonContent(trimmed, site: site, homeBaseUrl: homeBaseUrl);
  }

  /// 解析 XML 格式采集源
  VodPageResult _parseXmlContent(String xmlString,
      {Site? site, String? homeBaseUrl}) {
    final categories = <VodCategory>[];
    final items = <VodItem>[];

    // 提取分类: <class><ty id="1">电影</ty></class>
    final classMatch = RegExp(r'<class>([\s\S]*?)<\/class>', caseSensitive: false).firstMatch(xmlString);
    if (classMatch != null) {
      final classContent = classMatch.group(1) ?? '';
      final tyMatches = RegExp(r'<ty\s+id="([^"]+)">([^<]+)<\/ty>', caseSensitive: false).allMatches(classContent);
      for (final m in tyMatches) {
        final id = m.group(1)?.trim() ?? '';
        final name = m.group(2)?.trim() ?? '';
        if (id.isNotEmpty && name.isNotEmpty) {
          categories.add(VodCategory(id: id, name: name));
        }
      }
    }

    // 提取视频列表: <video><id>1</id><name>...</name><pic>...</pic><des>...</des><type>...</type><last>...</last></video>
    final videoMatches = RegExp(r'<video>([\s\S]*?)<\/video>', caseSensitive: false).allMatches(xmlString);
    for (final vm in videoMatches) {
      final vContent = vm.group(1) ?? '';
      final id = _extractXmlTag(vContent, 'id');
      final name = _extractXmlTag(vContent, 'name');
      final pic = _extractXmlTag(vContent, 'pic');
      final des = _extractXmlTag(vContent, 'des');
      final type = _extractXmlTag(vContent, 'type');
      final note = _extractXmlTag(vContent, 'note').isNotEmpty ? _extractXmlTag(vContent, 'note') : _extractXmlTag(vContent, 'state');

      if (id.isNotEmpty || name.isNotEmpty) {
        items.add(
          VodItem(
            id: id,
            name: name,
            pic: pic,
            remarks: note.isNotEmpty ? note : null,
            typeName: type.isNotEmpty ? type : null,
            content: des.isNotEmpty ? des : null,
            siteKey: site?.key,
            siteName: site?.name,
          ),
        );
      }
    }

    return VodPageResult(
      page: 1,
      pageCount: 1,
      total: items.length,
      limit: items.length,
      categories: categories,
      list: items,
      siteIcon: homeBaseUrl == null ? null : parseHomeSiteIcon({
        'siteicon': _extractXmlTag(xmlString, 'siteicon'),
        'siteurl': _extractXmlTag(xmlString, 'siteurl'),
      }, baseUrl: homeBaseUrl),
    );
  }

  String _extractXmlTag(String xml, String tagName) {
    final match = RegExp('<$tagName(?:[^>]*)>(?:<\\!\\[CDATA\\[)?([\\s\\S]*?)(?:\\]\\]>)?<\\/$tagName>', caseSensitive: false).firstMatch(xml);
    return match?.group(1)?.trim() ?? '';
  }

  /// 解析 JSON 格式采集源
  VodPageResult _parseJsonContent(String jsonString,
      {Site? site, String? homeBaseUrl}) {
    final map = _ensureJsonMap(jsonString);

    // 提取视频列表 (兼容 list / data / items / results)
    List<dynamic> listJson = [];
    if (map.containsKey('list') && map['list'] is List) {
      listJson = map['list'] as List<dynamic>;
    } else if (map.containsKey('data') && map['data'] is List) {
      listJson = map['data'] as List<dynamic>;
    } else if (map.containsKey('items') && map['items'] is List) {
      listJson = map['items'] as List<dynamic>;
    } else if (map.containsKey('results') && map['results'] is List) {
      listJson = map['results'] as List<dynamic>;
    }

    // 提取分类列表 (兼容 class / types / classes / categories)
    List<dynamic> classJson = [];
    if (map.containsKey('class') && map['class'] is List) {
      classJson = map['class'] as List<dynamic>;
    } else if (map.containsKey('types') && map['types'] is List) {
      classJson = map['types'] as List<dynamic>;
    } else if (map.containsKey('classes') && map['classes'] is List) {
      classJson = map['classes'] as List<dynamic>;
    } else if (map.containsKey('categories') && map['categories'] is List) {
      classJson = map['categories'] as List<dynamic>;
    }

    final list = listJson
        .whereType<Map<String, dynamic>>()
        .map((j) {
          final item = VodItem.fromJson(j);
          return item.copyWith(
            siteKey: site?.key ?? item.siteKey,
            siteName: site?.name ?? item.siteName,
          );
        })
        .toList();

    final categories = classJson
        .whereType<Map<String, dynamic>>()
        .map(VodCategory.fromJson)
        .toList();

    return VodPageResult(
      page: _asInt(map['page'], fallback: 1),
      pageCount: _asInt(map['pagecount'], fallback: 1),
      limit: _asInt(map['limit'], fallback: 20),
      total: _asInt(map['total'], fallback: list.length),
      list: list,
      categories: categories,
      filters: parseVodFilters(map['filters']),
      siteIcon: homeBaseUrl == null
          ? null
          : parseHomeSiteIcon(map, baseUrl: homeBaseUrl),
    );
  }

  int _asInt(dynamic value, {required int fallback}) {
    if (value is num) return value.toInt();
    if (value is String) {
      final text = value.trim();
      final parsed = int.tryParse(text);
      if (parsed != null) return parsed;
      final decimal = double.tryParse(text);
      if (decimal != null && decimal.isFinite) return decimal.toInt();
    }
    return fallback;
  }

  Map<String, dynamic> _ensureJsonMap(dynamic data) {
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return Map<String, dynamic>.from(data);
    if (data is String) {
      try {
        final decoded = jsonDecode(data);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
        if (decoded is List) return <String, dynamic>{'list': decoded};
      } catch (_) {}
    }
    return <String, dynamic>{};
  }
}
