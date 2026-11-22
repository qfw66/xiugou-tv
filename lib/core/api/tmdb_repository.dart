import 'dart:async';

import 'package:dio/dio.dart';

import '../config/app_env.dart';
import '../danmaku/danmaku_api.dart';
import '../net/http_client_factory.dart';
import '../settings/models/tmdb_preferences.dart';
import 'detail_lookup_title.dart';
import 'models/vod_models.dart';
import 'tmdb_release_name.dart';

typedef TmdbActor = ({String name, String role, String? portrait});
typedef TmdbRecommendation = ({String title, String year, String? poster});
typedef _FilmQuery = ({String title, String year, String? kind});
typedef _CreditEvidence = ({String directors, String actors});
typedef _MovieKey = (
  String,
  String,
  TmdbImageEndpoint,
  _FilmQuery,
  TmdbReleaseName?,
  _CreditEvidence?,
);

/// 只有站源确认打开同片，预取才能重试故障请求或按单片文件名补查。
class _CardRequest extends CancelToken {
  final _confirmed = Completer<bool>();
  TmdbReleaseName? release;
  _CreditEvidence? credits;

  void confirm(TmdbReleaseName? value, _CreditEvidence? evidence) {
    if (_confirmed.isCompleted) return;
    release = value;
    credits = evidence;
    _confirmed.complete(true);
  }

  @override
  void cancel([Object? reason]) {
    super.cancel(reason);
    if (!_confirmed.isCompleted) _confirmed.complete(false);
  }
}

/// 只属于一次点片操作，不与别的窗口或影片共享取消令牌。
class TmdbCardPreview {
  TmdbCardPreview._(
    this._id,
    this._query,
    this._settings,
    this._cancel, {
    this.movie,
    this._completeSearch,
  });

  final String _id;
  final _FilmQuery _query;
  final TmdbPreferences _settings;
  final _CardRequest _cancel;
  final Future<TmdbMovie?>? movie;
  final Future<TmdbMovie?> Function(_FilmQuery)? _completeSearch;

  bool get cancelled => _cancel.isCancelled;
  void cancel() => _cancel.cancel();

  Future<TmdbMovie?>? forDetail(
    VodItem detail,
    TmdbPreferences settings, {
    List<PlayFrom> sources = const [],
  }) {
    final confirmed = TmdbRepository._queryFor(detail);
    if (!cancelled &&
        confirmed != null &&
        !detail.isFolder &&
        detail.action == null &&
        detail.id == _id &&
        settings == _settings &&
        confirmed.title == _query.title) {
      // 详情缺字段不等于否定片卡；但明确给出的年份或类型优先于片卡。
      final resolved = (
        title: confirmed.title,
        year: confirmed.year.isEmpty ? _query.year : confirmed.year,
        kind: confirmed.kind ?? _query.kind,
      );
      if (_completeSearch != null || resolved == _query) {
        _cancel.confirm(
          singleMovieReleaseName(detail.name, sources),
          TmdbRepository._creditEvidence(detail),
        );
        return _completeSearch?.call(resolved) ?? movie;
      }
    }
    cancel();
    return null;
  }
}

class TmdbMovie {
  const TmdbMovie({
    required this.kind,
    this.year = '',
    this.genres = const [],
    this.countries = const [],
    this.rating,
    this.overview = '',
    this.backdrop,
    this.backdropPreview,
    this.backdropFallbacks = const [],
    this.logo,
    this.cast = const [],
    this.recommendations = const [],
  });

  final String kind, year, overview;
  final List<String> genres, countries;
  final String? backdrop, backdropPreview, logo;
  final List<String> backdropFallbacks;
  final double? rating;
  final List<TmdbActor> cast;
  final List<TmdbRecommendation> recommendations;
}

/// TMDB 只补充展示信息。密钥只发送给选定的 HTTPS 主机，不跟随重定向。
class TmdbRepository {
  TmdbRepository({Dio? client, String Function()? defaultKey})
    : _client =
          client ??
          HttpClientFactory.createDio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 6),
              receiveTimeout: const Duration(seconds: 8),
            ),
            proxy: DanmakuApi.systemProxy,
          ),
      _defaultKey = defaultKey ?? (() => AppEnv.get('XIUGOU_TMDB_API_KEY'));

  final Dio _client;
  final String Function() _defaultKey;
  final _cache = <_MovieKey, TmdbMovie>{};
  static const _maxSearchPages = 3;
  static final _nonFilmTitle = RegExp(
    r'://|magnet:\?|^(?:[a-z]:[\\/]|[\\/])|(?:cookie|token)\s*=',
    caseSensitive: false,
  );

  static bool _searchableTitle(String title) =>
      title.isNotEmpty && title.length <= 160 && !_nonFilmTitle.hasMatch(title);

  static _FilmQuery? _queryFor(VodItem item) {
    final name = detailLookupTitle(item.name, _year(item.year));
    if (name == null || !_searchableTitle(name.title)) return null;
    return (
      title: name.title,
      year: name.year,
      kind: _mediaHint(item.typeName),
    );
  }

  static String _personName(Object? value) =>
      _text(value).toLowerCase().replaceAll(RegExp(r'[\s·•・‧.]'), '');

  static _CreditEvidence? _creditEvidence(VodItem item) {
    List<String> names(String? value) {
      if (value == null || value.length > 4096) return const [];
      return (value
          .split(RegExp(r'[、,，/;；|\r\n]+'))
          .map(_personName)
          .where((name) => name.length >= 2)
          .toSet()
          .toList()
        ..sort());
    }

    final directors = names(item.director);
    final actors = names(item.actor);
    if (directors.isEmpty || actors.length < 2) return null;
    return (directors: directors.join('\n'), actors: actors.join('\n'));
  }

  static bool _creditsMatch(Map data, _CreditEvidence evidence) {
    final credits = data['credits'];
    if (credits is! Map) return false;
    final directors = evidence.directors.split('\n').toSet();
    final actors = evidence.actors.split('\n').toSet();
    Set<String> names(Map person) => {
      _personName(person['name']),
      _personName(person['original_name']),
    };
    if (!_rows(credits['crew']).any(
      (person) =>
          person['job'] == 'Director' &&
          names(person).intersection(directors).isNotEmpty,
    )) {
      return false;
    }
    final matchedNames = <String>{};
    final matchedPeople = <Object>{};
    for (final person in _rows(credits['cast'])) {
      final matched = names(person).intersection(actors);
      if (matched.isEmpty) continue;
      matchedNames.addAll(matched);
      matchedPeople.add(
        person['id'] is int
            ? person['id'] as int
            : _personName(person['original_name'] ?? person['name']),
      );
    }
    return matchedNames.length >= 2 && matchedPeople.length >= 2;
  }

  TmdbCardPreview? preloadCard(
    VodItem item,
    TmdbPreferences settings, {
    required bool allowPosterOnly,
  }) {
    final query = _queryFor(item);
    if (!settings.cinematic ||
        item.action != null ||
        item.isFolder ||
        query == null ||
        RegExp(
          r'[/\\]|扫码|配置中心|cookie',
          caseSensitive: false,
        ).hasMatch(query.title)) {
      return null;
    }
    // 普通影视接口常只给海报和片名；可执行站源还会返回设置、登录等非影片卡片。
    final poster = Uri.tryParse(item.pic);
    if (query.year.isEmpty &&
        query.kind == null &&
        !(allowPosterOnly &&
            poster != null &&
            (poster.isScheme('https') || poster.isScheme('http')) &&
            poster.host.isNotEmpty)) {
      return null;
    }
    final token = _CardRequest();
    if (query.year.isEmpty || query.kind == null) {
      final key = _keyFor(settings);
      if (key.isEmpty) return null;
      // 搜索只用片名。等站源补齐年份、类型后用同一份候选匹配，不重复查询或提前下载错图。
      final search = _search(
        settings.endpoint.host,
        key,
        query.title,
        1,
        token,
      ).onError<Object>((_, _) => null);
      return TmdbCardPreview._(
        item.id,
        query,
        settings,
        token,
        completeSearch: (confirmed) =>
            _lookup(confirmed, settings, cancel: token, firstSearch: search),
      );
    }
    // 可选资料可能早于详情页返回；网络异常不应成为未处理异常，也不能中断站源取集。
    final movie = Future<TmdbMovie?>.sync(
      () => lookup(item, settings, cancel: token),
    ).onError<Object>((_, _) => null);
    return TmdbCardPreview._(item.id, query, settings, token, movie: movie);
  }

  String _keyFor(TmdbPreferences settings) =>
      settings.apiKey.isEmpty ? _defaultKey() : settings.apiKey;

  static bool _isTransient(DioException error) => switch (error.type) {
    DioExceptionType.connectionError ||
    DioExceptionType.connectionTimeout ||
    DioExceptionType.sendTimeout ||
    DioExceptionType.receiveTimeout => true,
    DioExceptionType.badResponse => const {
      408,
      500,
      502,
      503,
      504,
    }.contains(error.response?.statusCode),
    _ => false,
  };

  Future<Map?> _get(
    String host,
    String key,
    String path,
    Map<String, String> params,
    CancelToken? cancel,
  ) async {
    final uri = Uri.https(host, '/3/$path', {
      'api_key': key,
      'language': 'zh-CN',
      ...params,
    });
    Future<Response<Object?>> request() => _client.getUri<Object?>(
      uri,
      cancelToken: cancel,
      options: Options(
        followRedirects: false,
        headers: {'Accept': 'application/json'},
      ),
    );
    Response<Object?> res;
    try {
      res = await request();
    } on DioException catch (e) {
      if (!_isTransient(e)) rethrow;
      if (cancel is _CardRequest && !await cancel._confirmed.future) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 200));
      if (cancel?.isCancelled == true) rethrow;
      res = await request();
    }
    return res.data is Map ? res.data as Map : null;
  }

  Future<Map?> _search(
    String host,
    String key,
    String name,
    int page,
    CancelToken? cancel, {
    _FilmQuery? filter,
  }) => _get(host, key, 'search/${filter?.kind ?? 'multi'}', {
    'query': name,
    'include_adult': 'false',
    if (filter != null)
      (filter.kind == 'movie' ? 'primary_release_year' : 'first_air_date_year'):
          filter.year,
    if (page > 1) 'page': '$page',
  }, cancel);

  Future<TmdbMovie?> lookup(
    VodItem item,
    TmdbPreferences settings, {
    CancelToken? cancel,
    List<PlayFrom> sources = const [],
  }) async {
    if (item.isFolder || item.action != null) return null;
    final query = _queryFor(item);
    if (query == null) return null;
    return _lookup(
      query,
      settings,
      cancel: cancel,
      release: singleMovieReleaseName(item.name, sources),
      credits: cancel is _CardRequest ? null : _creditEvidence(item),
    );
  }

  Future<List<Map>?> _candidates(
    String host,
    String key,
    String name,
    CancelToken? cancel, {
    Map? firstPage,
    _FilmQuery? filter,
  }) async {
    final rows = <Map>[];
    var pages = 1;
    for (var page = 1; page <= pages; page++) {
      final search =
          (page == 1 ? firstPage : null) ??
          await _search(host, key, name, page, cancel, filter: filter);
      if (search == null ||
          search['results'] is! List ||
          (search['page'] != null && search['page'] != page)) {
        return null;
      }
      final results = search['results'] as List;
      final total = search['total_pages'] ?? 1;
      if (total == 0 && page == 1 && results.isEmpty) return rows;
      // 没有核对完整的查询不是「无匹配」，不能拿它触发另一部片的检索。
      if (total is! int ||
          total < 1 ||
          total > _maxSearchPages ||
          (page > 1 && total != pages)) {
        return null;
      }
      pages = total;
      // 分类搜索的原生结果没有 media_type，类型来自所请求的接口。
      for (final row in results.whereType<Map>()) {
        rows.add(filter == null ? row : {'media_type': filter.kind, ...row});
      }
    }
    return rows;
  }

  static List<Map> _matchesFor(
    List<Map> rows,
    String title,
    String year,
    String? hint,
  ) {
    final target = _normalized(title);
    return {
      for (final row in rows)
        if (_matches(row, target, year, hint))
          (row['media_type'], row['id']): row,
    }.values.toList();
  }

  Future<TmdbMovie?> _lookup(
    _FilmQuery query,
    TmdbPreferences settings, {
    CancelToken? cancel,
    Future<Map?>? firstSearch,
    TmdbReleaseName? release,
    _CreditEvidence? credits,
  }) async {
    final name = query.title;
    final target = _normalized(name);
    if (!settings.cinematic || target.isEmpty || !_searchableTitle(name)) {
      return null;
    }
    final key = _keyFor(settings);
    if (key.isEmpty) return null;
    final host = settings.endpoint.host;
    final year = query.year;
    final hint = query.kind;
    final imageEndpoint = settings.imageEndpoint;
    _MovieKey keyFor(TmdbReleaseName? file, [_CreditEvidence? evidence]) =>
        (host, key, imageEndpoint, query, file, evidence);
    var cacheKey = keyFor(null);
    final cached =
        _cache[cacheKey] ??
        (release == null ? null : _cache[keyFor(release)]) ??
        (credits == null ? null : _cache[keyFor(release, credits)]);
    if (cached != null) return cached;

    try {
      final first = await (firstSearch ?? _search(host, key, name, 1, cancel));
      if (first == null) return null;
      final pageCount = first['total_pages'];
      final narrow =
          hint != null &&
          year.isNotEmpty &&
          (first['page'] ?? 1) == 1 &&
          first['results'] is List &&
          pageCount is int &&
          pageCount > _maxSearchPages;
      final rows = await _candidates(
        host,
        key,
        name,
        cancel,
        firstPage: narrow ? null : first,
        filter: narrow ? query : null,
      );
      if (rows == null) return null;
      var matches = _matchesFor(rows, name, year, hint);
      var needsCredits = false;
      if (matches.isEmpty && hint != 'tv') {
        if (cancel is _CardRequest) {
          if (!await cancel._confirmed.future) return null;
          release = cancel.release;
          credits = cancel.credits;
        }
        if (cancel?.isCancelled == true) return null;
        final byTitle =
            credits != null && hint == 'movie' && year.isNotEmpty && !narrow
            ? _matchesFor(rows, name, '', 'movie')
            : const <Map>[];
        final file = release;
        if (byTitle.length == 1 &&
            _year(byTitle.single['release_date']).isNotEmpty &&
            (file == null ||
                _matches(
                  byTitle.single,
                  _normalized(file.title),
                  file.year,
                  'movie',
                ))) {
          matches = byTitle;
          needsCredits = true;
          cacheKey = keyFor(file, credits);
          final verified = _cache[cacheKey];
          if (verified != null) return verified;
        } else {
          if (file == null) return null;
          final differentYear = year.isNotEmpty && year != file.year;
          if (differentYear &&
              (int.parse(year) - int.parse(file.year)).abs() > 1) {
            return null;
          }
          // 按文件认出的资料只缓存到这份片名和年份证据，不能污染同中文译名的另一部片。
          cacheKey = keyFor(file);
          final byFile = _cache[cacheKey];
          if (byFile != null) return byFile;
          final sameTitle = _normalized(file.title) == target;
          final candidates = sameTitle && !(narrow && differentYear)
              ? rows
              : await _candidates(
                  host,
                  key,
                  file.title,
                  cancel,
                  filter: sameTitle && narrow
                      ? (title: file.title, kind: 'movie', year: file.year)
                      : null,
                );
          if (candidates == null ||
              (differentYear &&
                  _matchesFor(
                    candidates,
                    file.title,
                    year,
                    'movie',
                  ).isNotEmpty)) {
            return null;
          }
          matches = _matchesFor(candidates, file.title, file.year, 'movie');
        }
      }
      if (matches.length != 1 || cancel?.isCancelled == true) return null;
      final match = matches.single;
      final kind = match['media_type'] as String;
      final originalLanguage = _text(match['original_language']);
      final searchOverview = _text(match['overview']);
      Map? data;
      try {
        data = await _get(host, key, '$kind/${match['id']}', {
          'append_to_response': 'images,credits,recommendations,similar',
          'include_image_language': {
            'zh',
            if (originalLanguage.isNotEmpty) originalLanguage,
            'en',
            'null',
          }.join(','),
        }, cancel);
      } on DioException catch (e) {
        if (CancelToken.isCancel(e)) return null;
      }
      if (data == null) {
        if (needsCredits) return null;
        // 搜索结果已经唯一匹配；详情暂不可用时不缓存，下次打开仍取完整资料。
        return searchOverview.isEmpty
            ? null
            : _movie(
                match,
                kind,
                originalLanguage,
                searchOverview,
                imageEndpoint,
              );
      }
      if (data['id'] != match['id'] || cancel?.isCancelled == true) return null;
      if (needsCredits &&
          (!_matches(
                {...data, 'media_type': kind},
                target,
                _year(match['release_date']),
                kind,
              ) ||
              !_creditsMatch(data, credits!))) {
        return null;
      }
      final movie = _movie(
        data,
        kind,
        originalLanguage,
        searchOverview,
        imageEndpoint,
      );
      if (_cache.length >= 40) _cache.remove(_cache.keys.first);
      _cache[cacheKey] = movie;
      return movie;
    } on DioException {
      // 异常含带 key 的请求地址，不写入错误面板或日志；失败也不写缓存。
      return null;
    } on FormatException {
      return null;
    }
  }

  static bool _matches(Map row, String title, String year, String? hint) {
    final kind = row['media_type'];
    if ((kind != 'movie' && kind != 'tv') ||
        (hint != null && hint != kind) ||
        row['id'] is! int) {
      return false;
    }
    final date = kind == 'movie' ? row['release_date'] : row['first_air_date'];
    if (year.isNotEmpty && year != _year(date)) return false;
    return const [
      'title',
      'original_title',
      'name',
      'original_name',
    ].any((key) => _normalized(_text(row[key])) == title);
  }

  static String? _mediaHint(String? value) {
    final text = value ?? '';
    if (text.contains('电影') ||
        RegExp(r'(动作|喜剧|爱情|恐怖|剧情|科幻|动画)片').hasMatch(text)) {
      return 'movie';
    }
    return RegExp(r'电视剧|连续剧|剧集|国产剧|美剧|韩剧|日剧|综艺').hasMatch(text) ? 'tv' : null;
  }

  static TmdbMovie _movie(
    Map data,
    String kind,
    String lang,
    String searchOverview,
    TmdbImageEndpoint imageEndpoint,
  ) {
    final images = data['images'];
    final backdrops = _backdropPaths(
      images is Map ? images['backdrops'] : null,
      data['backdrop_path'],
    );
    final logos = _rows(images is Map ? images['logos'] : null).toList();
    String? logo;
    for (final language in {'zh', lang, 'en', ''}) {
      for (final row in logos.where((r) => _text(r['iso_639_1']) == language)) {
        logo = imageEndpoint.urlFor(row['file_path'], 'w500');
        if (logo != null) break;
      }
      if (logo != null) break;
    }
    final countries = <String>{};
    for (final row in _rows(data['production_countries'])) {
      final name = _countryNames[row['iso_3166_1']] ?? _text(row['name']);
      if (name.isNotEmpty) countries.add(name);
    }
    final origins = data['origin_country'];
    if (countries.isEmpty && origins is List) {
      for (final code in origins.whereType<String>()) {
        countries.add(_countryNames[code] ?? code);
      }
    }
    final credits = data['credits'];
    final votes = data['vote_count'];
    final rating = data['vote_average'];
    final overview = _text(data['overview']);
    return TmdbMovie(
      kind: kind == 'movie' ? '电影' : '剧集',
      year: _year(
        kind == 'movie' ? data['release_date'] : data['first_air_date'],
      ),
      genres: [
        for (final row in _rows(data['genres']))
          if (_text(row['name']).isNotEmpty) _text(row['name']),
      ],
      countries: countries.toList(),
      rating:
          votes is num &&
              votes > 0 &&
              rating is num &&
              rating >= 0 &&
              rating <= 10
          ? rating.toDouble()
          : null,
      overview: overview.isEmpty ? searchOverview : overview,
      backdrop: imageEndpoint.urlFor(backdrops.firstOrNull, 'original'),
      backdropPreview: imageEndpoint.urlFor(backdrops.firstOrNull, 'w1280'),
      backdropFallbacks: [
        for (final path in backdrops.skip(1))
          imageEndpoint.urlFor(path, 'original')!,
      ],
      logo: logo,
      recommendations: _recommendations(
        data,
        kind,
        imageEndpoint,
      ).take(20).toList(),
      cast: [
        for (final row in _rows(
          credits is Map ? credits['cast'] : null,
        ).where((r) => _text(r['name']).isNotEmpty).take(60))
          (
            name: _text(row['name']),
            role: _text(row['character']),
            portrait: imageEndpoint.urlFor(row['profile_path'], 'w185'),
          ),
      ],
    );
  }

  static List<String> _backdropPaths(Object? gallery, Object? defaultPath) {
    final scenes = <({String path, int rank, num width, int order})>[];
    var fallback = TmdbImageEndpoint.filePath(defaultPath);
    for (final row in _rows(gallery)) {
      final path = TmdbImageEndpoint.filePath(row['file_path']);
      if (path == null) continue;
      final ratio = row['aspect_ratio'];
      final width = row['width'], height = row['height'];
      if ((ratio is num && ratio <= 1) ||
          (width is num && height is num && (height <= 0 || width <= height))) {
        if (path == fallback) fallback = null;
        continue;
      }
      final pixels = width is num && width > 0 ? width : 0;
      // 先保住桌面全高清，再选无字剧照；同档按原图宽度、TMDB 原顺序择优。
      final rank =
          (pixels >= 1920 ? 0 : 2) + (_text(row['iso_639_1']).isEmpty ? 0 : 1);
      scenes.add((path: path, rank: rank, width: pixels, order: scenes.length));
    }
    scenes.sort((a, b) {
      final rank = a.rank.compareTo(b.rank);
      if (rank != 0) return rank;
      final width = b.width.compareTo(a.width);
      return width != 0 ? width : a.order.compareTo(b.order);
    });
    final selected = scenes.map((scene) => scene.path).toSet().take(3);
    return {...selected, ?fallback}.toList(growable: false);
  }

  static Iterable<TmdbRecommendation> _recommendations(
    Map data,
    String kind,
    TmdbImageEndpoint imageEndpoint,
  ) sync* {
    final seen = <(String, int)>{};
    for (final field in ['recommendations', 'similar']) {
      final section = data[field];
      for (final row in _rows(section is Map ? section['results'] : null)) {
        final type = row['media_type'] ?? kind;
        final id = row['id'];
        if (type is! String ||
            (type != 'movie' && type != 'tv') ||
            id is! int ||
            id <= 0 ||
            (type == kind && id == data['id'])) {
          continue;
        }
        final key = type == 'movie' ? 'title' : 'name';
        final localized = _text(row[key]);
        final title = localized.isEmpty
            ? _text(row['original_$key'])
            : localized;
        if (title.isEmpty || !seen.add((type, id))) continue;
        yield (
          title: title,
          year: _year(row[type == 'movie' ? 'release_date' : 'first_air_date']),
          poster: imageEndpoint.urlFor(row['poster_path'], 'w342'),
        );
      }
    }
  }

  static String _text(Object? value) => value is String ? value.trim() : '';
  static String _year(Object? date) =>
      RegExp(r'\b(?:18|19|20)\d{2}\b').firstMatch(_text(date))?.group(0) ?? '';
  static String _normalized(String name) =>
      name.toLowerCase().replaceAll(RegExp(r'''[\s·：:.,，。!！?？'"“”《》\-]'''), '');
  static Iterable<Map> _rows(Object? value) =>
      value is List ? value.whereType<Map>() : const [];
  static const _countryNames = {
    'CN': '中国大陆',
    'HK': '中国香港',
    'TW': '中国台湾',
    'US': '美国',
    'GB': '英国',
    'JP': '日本',
    'KR': '韩国',
    'CA': '加拿大',
    'FR': '法国',
    'DE': '德国',
    'IT': '意大利',
    'ES': '西班牙',
    'IN': '印度',
    'TH': '泰国',
    'AU': '澳大利亚',
  };

  void dispose() => _client.close(force: true);
}
