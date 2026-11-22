part of 'douban_repository.dart';

typedef DoubanActor = ({String name, String role, String? portrait});
typedef _SubjectKey = ({String kind, String id});

class DoubanDetailMetadata {
  const DoubanDetailMetadata({
    required this.id,
    required this.kind,
    this.year = '',
    this.overview = '',
    this.genres = const [],
    this.countries = const [],
    this.rating,
    this.cast = const [],
  }) : _cover = null;

  final String id, kind, year, overview;
  final List<String> genres, countries;
  final double? rating;
  final List<DoubanActor> cast;
  final _DoubanArt? _cover;
  _SubjectKey get _key => (kind: kind, id: id);
  String get _path => '$kind/$id';
  String get _owner => 'douban://douban.com/$_path';

  DoubanDetailMetadata._subject(this.id, this.kind, Map data)
    : year = _doubanYear(data['year']),
      overview = _doubanText(data['intro']),
      genres = _strings(data['genres']),
      countries = _strings(data['countries']),
      rating = _rating(data['rating']),
      cast = _actors(data['actors']),
      _cover = _wideArt(data['cover'], 'douban://douban.com/$kind/$id');

  DoubanDetailMetadata._withCast(DoubanDetailMetadata film, this.cast)
    : id = film.id,
      kind = film.kind,
      year = film.year,
      overview = film.overview,
      genres = film.genres,
      countries = film.countries,
      rating = film.rating,
      _cover = film._cover;

  static List<String> _strings(Object? rows) => rows is List
      ? List.unmodifiable(rows.map(_doubanText).where((s) => s.isNotEmpty).toSet())
      : const [];

  static double? _rating(Object? rating) {
    if (rating is! Map || (rating['max'] != null && rating['max'] != 10) || rating['count'] == 0) {
      return null;
    }
    final v = rating['value'];
    return v is num && v > 0 && v <= 10 ? v.toDouble() : null;
  }

  static List<DoubanActor> _actors(Object? rows, {bool credits = false}) {
    if (rows is! List) return const [];
    final actors = <String, DoubanActor>{};
    for (final row in rows.whereType<Map>()) {
      // roles 是影人的所有职业，只有 category 才是本片的职务。
      if (credits && row['category'] != '演员' && row['category'] != '配音') continue;
      final name = _doubanText(row['name']);
      if (name.isEmpty || actors.containsKey(name)) continue;
      final avatar = row['avatar'];
      final role = _doubanText(row['simple_character']);
      actors[name] = (
        name: name,
        role: role.isEmpty ? _doubanText(row['character']) : role,
        portrait: avatar is Map
            ? _doubanImageUrl(avatar['large']) ?? _doubanImageUrl(avatar['normal'])
            : null,
      );
      if (actors.length >= 60) break;
    }
    return List.unmodifiable(actors.values);
  }
}

class _DoubanDetails {
  _DoubanDetails(this.subjects);
  final _DoubanSubjects subjects;
  final credits = _DoubanMemo<_SubjectKey, List<DoubanActor>>();

  Future<DoubanDetailMetadata?> forItem(VodItem item, CancelToken? cancel) async {
    final DoubanDetailMetadata? film;
    try {
      film = await subjects.forItem(item, cancel);
      _checkDoubanCancel(cancel);
    } catch (error) {
      _rethrowDoubanCancel(error, cancel);
      return null;
    }
    if (film == null) return null;
    try {
      // actors 是完整演员表；credits 只含主要演职员，作为接口不可用时的回退。
      final actors = await credits.get(film._key, subjects.ttl, cancel, (token) async {
        try {
          final data = await subjects.read('${film!._path}/celebrities', token);
          if (data['actors'] is! List) throw const FormatException();
          final actors = DoubanDetailMetadata._actors(data['actors']);
          if (actors.isNotEmpty) return actors;
        } catch (error) {
          _rethrowDoubanCancel(error, token);
        }
        final data = await subjects.read('${film!._path}/credits', token);
        if (data['items'] is! List) throw const FormatException();
        return DoubanDetailMetadata._actors(data['items'], credits: true);
      });
      _checkDoubanCancel(cancel);
      if (actors == null || actors.isEmpty) return film;
      final names = actors.map((a) => a.name).toSet();
      return DoubanDetailMetadata._withCast(
        film,
        List.unmodifiable([...actors, ...film.cast.where((a) => names.add(a.name))].take(60)),
      );
    } catch (error) {
      _rethrowDoubanCancel(error, cancel);
      return film;
    }
  }
}
