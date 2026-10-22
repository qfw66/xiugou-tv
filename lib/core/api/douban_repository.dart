import 'dart:convert';

import 'package:dio/dio.dart';

import 'models/vod_models.dart';

/// 豆瓣首页分类（backlog §17）。
///
/// [id] 就是豆瓣的 `subject_collection` 标识：分类切换只换集合与缓存键。
class DoubanCategory {
  final String id;
  final String name;

  const DoubanCategory({required this.id, required this.name});
}

/// 固定 5 类（2026-10-22 逐一实测 200 且有数据）。
///
/// 原方案里的 `rank_list_movie` / `rank_list_tv` / `tv_variety` 已 404：
/// 电影榜改用 `movie_top250`，综艺改用 `show_hot`。口径见台账 §17。
const List<DoubanCategory> doubanCategories = <DoubanCategory>[
  DoubanCategory(id: 'movie_hot', name: '热播电影'),
  DoubanCategory(id: 'tv_hot', name: '热播剧集'),
  DoubanCategory(id: 'show_hot', name: '热播综艺'),
  DoubanCategory(id: 'tv_animation', name: '热门动漫'),
  DoubanCategory(id: 'movie_top250', name: 'Top250'),
];

/// 豆瓣条目。
///
/// 只承担「导航」：点卡片不会取豆瓣详情，而是拿 [title] 去已启用站源里搜索
/// （§17 合规口径：不代理播放、不转存豆瓣内容）。
class DoubanItem {
  final String id;
  final String title;
  final String poster;
  final String? score;
  final String? year;

  /// 角标文案：剧集用 `episodes_info`（更新至第 N 集），电影用卡片副标题前两段。
  final String? subtitle;

  const DoubanItem({
    required this.id,
    required this.title,
    required this.poster,
    this.score,
    this.year,
    this.subtitle,
  });

  /// 转成首页网格能直接渲染的 [VodItem]（不带 siteKey：豆瓣本身不可请求）。
  VodItem toVodItem() => VodItem(
        id: id,
        name: title,
        pic: poster,
        score: score,
        year: year,
        remarks: subtitle,
      );
}

/// 豆瓣接口失败（网络 / 结构 / 风控统一收敛到这一种错误，便于界面显示重试）。
class DoubanException implements Exception {
  final String message;

  const DoubanException(this.message);

  @override
  String toString() => message;
}

/// 一页豆瓣内容（§19 无限滚动）。
///
/// [total] 来自接口（实测可靠：`movie_showing`=33 / `tv_hot`=240 / `movie_top250`=250），
/// 用来判断「还有没有下一页」；接口缺失 `total` 时按本页已到末尾处理。
class DoubanPage {
  final List<DoubanItem> items;
  final int total;

  /// 本页的起始偏移（0 基）
  final int start;

  const DoubanPage({
    required this.items,
    required this.total,
    required this.start,
  });

  /// 已经加载到的位置，直接作为下一次请求的 `start`
  int get nextStart => start + items.length;

  /// 空页也视为到底：豆瓣越界请求返回 `total` 但 0 条，不能据此继续翻。
  bool get hasMore => items.isNotEmpty && nextStart < total;
}

/// 取回原始响应体；测试注入假实现即可完全离线。
typedef DoubanHttpGet = Future<String> Function(Uri uri);

/// 豆瓣「热播」数据源（backlog §17）。
///
/// 为什么在 Flutter 侧直连、不走 companion：省掉 JVM 冷启，也不依赖载荷里的
/// Douban 爬虫。接口实测（2026-10-22）：
/// - `frodo.douban.com/api/v2/...&apiKey=0ac44…`（载荷里那条）→ **400 / 997 已废**；
/// - `m.douban.com/rexxar/api/v2/subject_collection/<集合>/items` + `Referer: m.douban.com` → 200 可用。
///
/// 缓存：内存 8 分钟（豆瓣有频控）+ 同键请求合并（连点分类只发一次），
/// 失败不写缓存，交给界面「重试」。
class DoubanRepository {
  static const String collectionBase =
      'https://m.douban.com/rexxar/api/v2/subject_collection';

  /// 豆瓣接口与图床共用的浏览器 UA。
  ///
  /// 图床实测（2026-10-22，Flutter 同款 HttpClient）：**UA + Referer 必须同时带**，
  /// 只带 Referer 是 403、只带 UA 是 418、都不带 403/418。
  static const String browserUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36';

  /// 豆瓣图床必须的请求头（`img*.doubanio.com` 有防盗链）。
  static const Map<String, String> imageHeaders = <String, String>{
    'User-Agent': browserUserAgent,
    'Referer': 'https://m.douban.com/',
  };

  /// 逐条判定：只有豆瓣图床才该走 [DoubanPosterImage]（自带 UA + Referer）。
  ///
  /// 别的站源图床若收到外来的 `Referer`，有的会直接拒图，所以不能无脑全局加。
  static bool isDoubanPoster(String pic) {
    final host = Uri.tryParse(pic)?.host ?? '';
    if (host.isEmpty) return false;
    return host == 'douban.com' ||
        host.endsWith('.douban.com') ||
        host == 'doubanio.com' ||
        host.endsWith('.doubanio.com');
  }

  /// 把豆瓣图床的缩略尺寸段提升到原图：`s/m/l_ratio_poster` → `raw`。
  ///
  /// 接口给的多半是 `m_ratio_poster`（约 500px 宽）。横滑轨道用 500px 足够，
  /// 但首页大屏要把**竖版海报**横向铺满 480 高，500px 会被放大 2–3 倍、糊成
  /// 一片；`raw` 是上传原图（常见 1000–1500 宽），铺满才够清晰。
  ///
  /// 兼容两种携带参数的形式：`?` 查询串与站源常用的 `@Referer=…` 尾巴；
  /// 只替换路径里的尺寸段，其余原样带回。非豆瓣图床或没有尺寸段时原样返回。
  static String highResPosterUrl(String url) {
    if (url.isEmpty || !isDoubanPoster(url)) return url;
    final at = url.indexOf('@');
    final head = at == -1 ? url : url.substring(0, at);
    final tail = at == -1 ? '' : url.substring(at);
    for (final token in const <String>[
      's_ratio_poster',
      'm_ratio_poster',
      'l_ratio_poster',
    ]) {
      if (head.contains(token)) {
        return '${head.replaceFirst(token, 'raw')}$tail';
      }
    }
    return url;
  }

  final DoubanHttpGet _httpGet;
  final Duration cacheTtl;

  /// 键为 `集合:起始:数量`
  final Map<String, _CacheEntry> _cache = <String, _CacheEntry>{};

  /// 同一键的并发请求只发一次
  final Map<String, Future<DoubanPage>> _inflight =
      <String, Future<DoubanPage>>{};

  DoubanRepository({
    DoubanHttpGet? httpGet,
    this.cacheTtl = const Duration(minutes: 8),
  }) : _httpGet = httpGet ?? _dioGet;

  /// 一页分类内容：带上 `total` 才能判断「还有没有下一页」（§19 无限滚动）。
  Future<DoubanPage> fetchPage(
    String collection, {
    int start = 0,
    int count = 18,
    bool forceRefresh = false,
  }) {
    final key = '$collection:$start:$count';
    final cached = _cache[key];
    if (!forceRefresh && cached != null && !cached.isExpired) {
      return Future<DoubanPage>.value(cached.page);
    }
    final pending = _inflight[key];
    if (pending != null) return pending;
    final future = _fetch(collection, start, count, key);
    _inflight[key] = future;
    return future.whenComplete(() => _inflight.remove(key));
  }

  /// 只取条目（调用方不关心分页信息时用）。
  Future<List<DoubanItem>> fetchCategory(
    String collection, {
    int start = 0,
    int count = 18,
    bool forceRefresh = false,
  }) async =>
      (await fetchPage(collection,
              start: start, count: count, forceRefresh: forceRefresh))
          .items;

  /// 当前内存里是否已有未过期的该分类内容（界面切回时不闪骨架）。
  bool hasFresh(String collection, {int start = 0, int count = 18}) {
    final cached = _cache['$collection:$start:$count'];
    return cached != null && !cached.isExpired;
  }

  void clearCache() => _cache.clear();

  Future<DoubanPage> _fetch(
      String collection, int start, int count, String key) async {
    final uri = Uri.parse('$collectionBase/$collection/items'
        '?start=$start&count=$count');
    final String body;
    try {
      body = await _httpGet(uri);
    } on DoubanException {
      rethrow;
    } catch (error) {
      throw DoubanException('豆瓣接口请求失败：$error');
    }
    final page = parsePage(body, start: start);
    _cache[key] = _CacheEntry(page, DateTime.now().add(cacheTtl));
    return page;
  }

  /// 解析 rexxar 响应；缺片名或封面的条目跳过（渲染不了，留着只会占位）。
  static List<DoubanItem> parseItems(String body) =>
      parsePage(body, start: 0).items;

  /// 解析整页：`total` 缺失时按「本页已到末尾」处理，避免无限请求不存在的页。
  static DoubanPage parsePage(String body, {int start = 0}) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException catch (error) {
      throw DoubanException('豆瓣接口返回的不是 JSON：${error.message}');
    }
    if (decoded is! Map) {
      throw const DoubanException('豆瓣接口返回结构异常');
    }
    final raw = decoded['subject_collection_items'];
    if (raw is! List) {
      throw const DoubanException('豆瓣接口未返回条目列表');
    }
    final items = <DoubanItem>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      final item = parseItem(entry);
      if (item != null) items.add(item);
    }
    return DoubanPage(
      items: List<DoubanItem>.unmodifiable(items),
      total: (decoded['total'] as num?)?.toInt() ?? start + items.length,
      start: start,
    );
  }

  /// 单条解析：`movie_*` 用 `cover.url`，`tv_*` / `show_hot` 用 `pic.large`。
  static DoubanItem? parseItem(Map<dynamic, dynamic> raw) {
    final title = (raw['title'] ?? '').toString().trim();
    if (title.isEmpty) return null;
    final poster = _posterOf(raw);
    if (poster.isEmpty) return null;
    return DoubanItem(
      id: (raw['id'] ?? title).toString(),
      title: title,
      poster: poster,
      score: _scoreOf(raw),
      year: _nonEmpty(raw['year']),
      subtitle: _subtitleOf(raw),
    );
  }

  static String _posterOf(Map<dynamic, dynamic> raw) {
    final cover = raw['cover'];
    if (cover is Map) {
      final url = (cover['url'] ?? '').toString();
      if (url.isNotEmpty) return url;
    }
    final pic = raw['pic'];
    if (pic is Map) {
      for (final size in const <String>['large', 'normal', 'small']) {
        final url = (pic[size] ?? '').toString();
        if (url.isNotEmpty) return url;
      }
    }
    return '';
  }

  static String? _scoreOf(Map<dynamic, dynamic> raw) {
    final rating = raw['rating'];
    if (rating is! Map) return null;
    final value = rating['value'];
    if (value is! num || value <= 0) return null;
    return value.toStringAsFixed(1);
  }

  static String? _subtitleOf(Map<dynamic, dynamic> raw) {
    final episodes = _nonEmpty(raw['episodes_info']);
    if (episodes != null) return episodes;
    final card = _nonEmpty(raw['card_subtitle']);
    if (card == null) return null;
    // 形如「2026 / 中国大陆 / 剧情 …」：只取前两段，角标不至于长到溢出
    final parts = card
        .split('/')
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .take(2)
        .join(' / ');
    return parts.isEmpty ? null : parts;
  }

  static String? _nonEmpty(Object? value) {
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? null : text;
  }

  /// 点片搜索使用的关键词：把「第二季」「(2024)」「【】」这类噪声去掉。
  ///
  /// 豆瓣标题常带季数 / 年份，原样丢给站源搜索命中率会掉；归一后为空则退回原片名。
  static String searchKeyword(String title) {
    var value = title.trim();
    value = value.replaceAll('（', '(').replaceAll('）', ')');
    value = value.replaceAll(RegExp(r'[\(\[【][^\)\]】]*[\)\]】]'), ' ');
    value = value.replaceAll(RegExp(r'第[一二三四五六七八九十百0-9]+季'), ' ');
    value = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    return value.isEmpty ? title.trim() : value;
  }

  static final Dio _sharedDio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
      responseType: ResponseType.plain,
      headers: const <String, String>{
        'User-Agent': browserUserAgent,
        'Referer': 'https://m.douban.com/',
        'Accept': 'application/json, text/plain, */*',
      },
      validateStatus: (code) => code != null && code >= 200 && code < 300,
    ),
  );

  static Future<String> _dioGet(Uri uri) async {
    final response = await _sharedDio.get<String>(uri.toString());
    final body = response.data;
    if (body == null || body.isEmpty) {
      throw const DoubanException('豆瓣接口返回空响应');
    }
    return body;
  }
}

class _CacheEntry {
  final DoubanPage page;
  final DateTime expiresAt;

  const _CacheEntry(this.page, this.expiresAt);

  bool get isExpired => DateTime.now().isAfter(expiresAt);
}
