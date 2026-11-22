part of 'douban_repository.dart';

typedef _DoubanQuery = ({
  String title,
  String year,
  String? kind,
  String? id,
  int? total,
  int? current,
});
typedef _SearchHit = ({String id, String kind, String year});
typedef _SubjectIdentity = ({String title, String year, String kind, int? episodes});
typedef _SubjectDocument = ({_SubjectIdentity identity, DoubanDetailMetadata film});
String _doubanText(Object? value) => value is String ? value.trim() : '';
String _doubanYear(Object? value) => value is String || value is int
    ? RegExp(r'(?<!\d)(?:18|19|20)\d{2}(?!\d)').firstMatch('$value')?.group(0) ?? ''
    : '';

void _checkDoubanCancel(CancelToken? token) {
  if (token?.cancelError case final error?) throw error;
}

void _rethrowDoubanCancel(Object error, CancelToken? token) {
  _checkDoubanCancel(token);
  if (error is DioException && CancelToken.isCancel(error)) throw error;
}

/// 只合并实际工作；每个调用方独立等待、独立取消，最后一个退出才取消网络。
class _DoubanFlight<V> {
  final token = CancelToken();
  late final Future<V?> result;
  int listeners = 0;
  bool finished = false;

  Future<V?> listen(CancelToken? consumer) {
    listeners++;
    var left = false;
    void leave() {
      if (left) return;
      left = true;
      if (--listeners == 0 && !finished) token.cancel();
    }

    if (consumer == null) return result.whenComplete(leave);
    final canceled = Completer<V?>();
    final subscription = consumer.whenCancel.asStream().listen((error) {
      leave();
      canceled.completeError(error);
    });
    return Future.any([result, canceled.future]).whenComplete(() {
      unawaited(subscription.cancel());
      leave();
    });
  }
}

class _DoubanMemo<K, V extends Object> {
  final _values = <K, ({DateTime until, V value})>{};
  final _pending = <K, _DoubanFlight<V>>{};

  Future<V?> get(
    K key,
    Duration ttl,
    CancelToken? cancel,
    Future<V?> Function(CancelToken) load, {
    bool Function(V)? cacheIf,
  }) async {
    _checkDoubanCancel(cancel);
    final cached = _values[key];
    if (cached != null && cached.until.isAfter(DateTime.now())) return cached.value;
    var pending = _pending[key];
    if (pending == null || pending.token.isCancelled) {
      final flight = _DoubanFlight<V>();
      _pending[key] = pending = flight;
      flight.result = load(flight.token)
          .then((value) {
            _checkDoubanCancel(flight.token);
            if (value != null && (cacheIf == null || cacheIf(value))) {
              _values.putBounded(key, (until: DateTime.now().add(ttl), value: value), 64);
            }
            return value;
          })
          .whenComplete(() {
            flight.finished = true;
            if (identical(_pending[key], flight)) _pending.remove(key);
          });
    }
    final value = await pending.listen(cancel);
    _checkDoubanCancel(cancel);
    return value;
  }

  void clear() {
    _values.clear();
    for (final flight in _pending.values) {
      flight.token.cancel();
    }
    _pending.clear();
  }
}

class _DoubanSubjects {
  _DoubanSubjects(this.get, this.ttl);
  final Future<String> Function(Uri, {CancelToken? cancel}) get;
  final Duration ttl;
  final cache = _DoubanMemo<_DoubanQuery, DoubanDetailMetadata>();
  final _documents = _DoubanMemo<_SubjectKey, _SubjectDocument>();

  void clear() {
    cache.clear();
    _documents.clear();
  }

  static final _nonFilm = RegExp(
    r'[/\\=\x00-\x1f\x7f]|%[\da-f]{2}|www\.|^[a-z]:\S|(?:https?|magnet|file|data|content|msearch|thunder|ed2k|rtsp|smb):|'
    r'(?:cookie|token|api[_ -]?key|authorization|password|secret|referer|user-agent)\s*[:：]|'
    r'^(?:cookie|token|api[_ -]?key|bearer|basic)\s+\S|(?:^|\s)(?:bearer|basic)\s+[\w.-]{6,}|'
    r'扫码|配置中心|系统配置|设置中心|网盘设置|登录|清理缓存|(?:输入|填写)(?:口令|密钥|密码|token|cookie)|^(?:目录|设置|配置|@settings)$|'
    r'\.(?:m3u8?|mp4|mkv|avi|mov|strm|mpd|flv|webm|torrent|json|yaml|exe)(?:$|[?#])|'
    r'\beyJ[\w-]+\.[\w-]+\.[\w-]+|\b[a-f\d]{24,}\b|^[\w-]{28,}$',
    caseSensitive: false,
  );
  static final _season = RegExp(
    r'第\s*([一二两三四五六七八九十百零〇\d]+)\s*季|(?:\bseason\s*|\bs)(\d{1,2})(?!\d)',
    caseSensitive: false,
  );
  static final _allEpisodes = RegExp(
    r'(?:全|共)\s*(\d{1,4})\s*集|(\d{1,4})\s*集\s*(?:全|完结)|^(\d{1,4})\s*集$',
  );
  static final _currentEpisode = RegExp(r'(?:更新(?:至)?\s*(?:第)?|第)\s*(\d{1,4})\s*集');
  static int? _number(RegExp regex, String text) {
    final m = regex.firstMatch(text);
    if (m != null) {
      for (var i = 1; i <= m.groupCount; i++) {
        if (m[i] case final n?) return parseChineseNumber(n);
      }
    }
    return null;
  }

  static String _title(Object? value) =>
      _doubanText(value).toLowerCase().replaceAll(RegExp(r'[\s·：:]'), '');

  static _DoubanQuery? _query(VodItem item) {
    final name = detailLookupTitle(item.name, _doubanYear(item.year));
    if (item.isFolder ||
        item.action != null ||
        name == null ||
        _nonFilm.hasMatch(name.title) ||
        _title(name.title).isEmpty) {
      return null;
    }
    final type = (item.typeName ?? '').trim().toLowerCase();
    final notes = item.remarks ?? '';
    final season = _number(_season, name.title), noteSeason = _number(_season, notes);
    if (noteSeason != null && noteSeason != (season ?? 1)) return null;
    final total = _number(_allEpisodes, notes), current = _number(_currentEpisode, notes);
    final serial = season != null || noteSeason != null || total != null || current != null;
    final movie = type == 'movie' || RegExp(r'电影|片$').hasMatch(type);
    if (movie && serial) return null;
    final tv = serial || type == 'tv' || RegExp(r'电视剧|连续剧|剧集|剧$|综艺').hasMatch(type);
    return (
      title: name.title,
      year: name.year,
      kind: movie
          ? 'movie'
          : tv
          ? 'tv'
          : null,
      id: VodItem.validDoubanId(item.doubanId),
      total: total,
      current: current,
    );
  }

  Future<Map<String, dynamic>> read(
    String path,
    CancelToken token, [
    Map<String, String>? params,
  ]) async {
    _checkDoubanCancel(token);
    final body = await get(
      Uri.https('m.douban.com', '/rexxar/api/v2/$path', params),
      cancel: token,
    );
    _checkDoubanCancel(token);
    final data = jsonDecode(body);
    if (data is! Map<String, dynamic> || data['banned'] == true) throw const FormatException();
    return data;
  }

  Future<DoubanDetailMetadata?> forItem(VodItem item, CancelToken? cancel) async {
    _checkDoubanCancel(cancel);
    final query = _query(item);
    if (query == null) return null;
    return cache.get(query, ttl, cancel, (token) => _resolve(query, token));
  }

  static _SubjectIdentity _identity(Map row, String kind) {
    final n = row['episodes_count'];
    return (
      title: _title(row['title']),
      year: _doubanYear(row['year']),
      kind: kind,
      episodes: n is int || n == null ? n as int? : int.tryParse(_doubanText(n)) ?? -1,
    );
  }

  bool _matches(_DoubanQuery q, _SubjectIdentity identity) {
    if ((q.kind != null && q.kind != identity.kind) ||
        identity.title != _title(q.title) ||
        (q.year.isNotEmpty && identity.year != q.year)) {
      return false;
    }
    if (q.total == null && q.current == null) return true;
    final count = identity.episodes;
    if (count == null || count == 0) return true; // 搜索摘要/未定集数
    return count > 0 &&
        (q.total == null || q.total == count) &&
        (q.current == null || q.current! <= count);
  }

  Future<DoubanDetailMetadata?> _resolve(_DoubanQuery q, CancelToken token) async {
    Future<DoubanDetailMetadata?> verify(String id, String? kind, [String year = '']) async {
      bool matches(_SubjectDocument d) =>
          (kind == null || kind == d.identity.kind) &&
          (year.isEmpty || year == d.identity.year) &&
          _matches(q, d.identity);
      // 同一个 id 的显式入口和搜索命中可共读；缓存的是经核验的资料，不是对新查询的授权。
      final key = (id: id, kind: kind ?? 'movie');
      final doc = await _documents.get(key, ttl, token, (request) async {
        final row = await read('${key.kind}/$id', request);
        final actual = row['type'];
        if (row['id'] == null || actual == null || row['title'] is! String) {
          throw const FormatException();
        }
        if (VodItem.validDoubanId(row['id']) != id || (actual != 'movie' && actual != 'tv')) {
          return null;
        }
        return (
          identity: _identity(row, actual),
          film: DoubanDetailMetadata._subject(id, actual, row),
        );
      }, cacheIf: matches);
      return doc != null && matches(doc) ? doc.film : null;
    }

    if (q.id case final id?) {
      try {
        final direct = await verify(id, q.kind);
        if (direct != null) return direct;
      } on DioException catch (error) {
        if (error.response?.statusCode != 404) rethrow;
      }
    }
    // movie 搜索同时含电影与剧集。total/count 包含未展示的条目，必须排除下一页重名。
    const size = 50;
    _SearchHit? found;
    int? previousTotal;
    for (var start = 0; start < size * 2; start += size) {
      final page = (await read('search/subjects', token, {
        'q': q.title,
        'type': 'movie',
        'count': '$size',
        'start': '$start',
      }))['subjects'];
      if (page is! Map ||
          page['items'] is! List ||
          page['total'] is! int ||
          page['start'] != start ||
          page['count'] != size) {
        throw const FormatException();
      }
      final total = page['total'] as int;
      if (total < 0 || (previousTotal != null && total != previousTotal)) {
        throw const FormatException();
      }
      if (total > size * 2) return null;
      previousTotal = total;
      for (final row in (page['items'] as List).whereType<Map>()) {
        final target = row['target'], kind = row['target_type'];
        if (target is! Map ||
            (kind != 'movie' && kind != 'tv') ||
            (target['type'] != null && target['type'] != kind) ||
            !_matches(q, _identity(target, kind))) {
          continue;
        }
        final id = VodItem.validDoubanId(target['id']);
        if (id == null || (row['target_id'] != null && row['target_id'].toString() != id)) continue;
        final hit = (id: id, kind: kind as String, year: _doubanYear(target['year']));
        if (found != null && hit != found) return null;
        found = hit;
      }
      if (start + size >= total) break;
    }
    if (found == null) return null;
    if (found.id == q.id && found.kind == (q.kind ?? 'movie')) return null;
    return verify(found.id, found.kind, found.year);
  }
}
