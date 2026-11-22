part of 'douban_repository.dart';

typedef _DoubanArt = ({String url, int width, int height});
typedef _GalleryResult = ({List<String> urls, bool complete});
final _imageHost = RegExp(r'^img\d*\.(?:doubanio|douban)\.com$');
final _thumbnail = RegExp(
  r'/(?:thumb(?:nail)?s?|sq\w*|[sml]_ratio_poster)/|/photo/[sm]/',
  caseSensitive: false,
);

String? _doubanImageUrl(Object? value) {
  if (value is! String ||
      value.isEmpty ||
      value.length > 2048 ||
      RegExp(r'[\s\\@%]').hasMatch(value)) {
    return null;
  }
  final uri = Uri.tryParse(value);
  if (uri == null ||
      !(uri.isScheme('https') || uri.isScheme('http')) ||
      !_imageHost.hasMatch(uri.host) ||
      uri.hasPort ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      uri.path.length < 2) {
    return null;
  }
  return uri.toString();
}

int _preferArt(_DoubanArt a, _DoubanArt b) {
  final secureA = a.url.startsWith('https:'), secureB = b.url.startsWith('https:');
  if (secureA != secureB) return secureA ? -1 : 1;
  final width = b.width.compareTo(a.width);
  return width != 0 ? width : b.height.compareTo(a.height);
}

/// 相册尺寸与实际解码使用相同门槛，防止近方图或缩略图占满背景候选。
bool isDoubanBackdropSize(int width, int height) =>
    width >= 640 && height >= 320 && width * 5 >= height * 7;

_DoubanArt? _wideArt(Object? photo, String owner) {
  if (photo is! Map || (photo['owner_uri'] != null && photo['owner_uri'] != owner)) return null;
  final image = photo['image'];
  if (image is! Map) return null;
  final raw = image['raw'];
  // 原图是方/竖图时，不能用被裁成横向的派生尺寸替代它。
  if (raw != null &&
      (raw is! Map ||
          raw['width'] is! int ||
          raw['height'] is! int ||
          !isDoubanBackdropSize(raw['width'] as int, raw['height'] as int))) {
    return null;
  }
  _DoubanArt? best;
  for (final size in [raw, image['large']]) {
    if (size is! Map) continue;
    final w = size['width'], h = size['height'];
    final url = _doubanImageUrl(size['url']);
    if (url == null ||
        _thumbnail.hasMatch(Uri.parse(url).path) ||
        w is! int ||
        h is! int ||
        !isDoubanBackdropSize(w, h)) {
      continue;
    }
    final art = (url: url, width: w, height: h);
    if (best == null || _preferArt(art, best) < 0) best = art;
  }
  return best;
}

class _DoubanBackdrops {
  _DoubanBackdrops(this.subjects, this.ttl);
  final _DoubanSubjects subjects;
  final Duration ttl;
  final cache = _DoubanMemo<_SubjectKey, _GalleryResult>();

  Future<List<String>> forFilm(DoubanDetailMetadata film, CancelToken? cancel) async {
    _checkDoubanCancel(cancel);
    if ((film.kind != 'movie' && film.kind != 'tv') || VodItem.validDoubanId(film.id) != film.id) {
      return const [];
    }
    final gallery = await cache.get(
      film._key,
      ttl,
      cancel,
      (token) => _load(film, token),
      cacheIf: (g) => g.complete,
    );
    _checkDoubanCancel(cancel);
    return gallery?.urls ?? const [];
  }

  Future<_GalleryResult> _load(DoubanDetailMetadata film, CancelToken token) async {
    final posters = <_DoubanArt>[], stills = <_DoubanArt>[];
    final checked = <String>{};
    var complete = true;
    Future<void> album(String type) async {
      try {
        final data = await subjects.read('${film._path}/photos', token, {
          'type': type,
          'start': '0',
          'count': '30',
          'items_only': '1',
        });
        final rows = data['photos'];
        if (rows is! List) throw const FormatException();
        final total = data['total'], bucket = data[type == 'R' ? 'o' : 'c'];
        // rexxar 有时忽略 type=R/S：同片返回相同的混合相册（total 大于分类数）。
        // 只核验最多四张原生横图；不把花絮/粉丝图片误列为海报或剧照。
        final singleCategory = total is int && total > 0 && total == bucket && rows.length <= total;
        final candidates = [
          for (final row in rows.take(30).whereType<Map>())
            if (_wideArt(row, film._owner) case final art?) (row: row, art: art),
        ]..sort((a, b) => _preferArt(a.art, b.art));
        final verify = <String>[];
        void classify(Object? category, _DoubanArt art) {
          if (category == 'poster') posters.add(art);
          if (category == 'still') stills.add(art);
        }

        for (final c in candidates) {
          if (c.row['photo_type'] != null || singleCategory) {
            classify(c.row['photo_type'] ?? (type == 'R' ? 'poster' : 'still'), c.art);
            continue;
          }
          final id = VodItem.validDoubanId(c.row['id']);
          if (id != null && checked.length < 4 && checked.add(id)) verify.add(id);
        }
        await Future.wait(
          verify.map((id) async {
            try {
              final row = await subjects.read('photo/$id', token);
              if (VodItem.validDoubanId(row['id']) != id || row['owner_uri'] != film._owner) return;
              final art = _wideArt(row, film._owner);
              if (art != null) classify(row['photo_type'], art);
            } catch (error) {
              _rethrowDoubanCancel(error, token);
              complete = false;
            }
          }),
        );
      } catch (error) {
        _rethrowDoubanCancel(error, token);
        complete = false;
      }
    }

    List<String> ranked() {
      final seen = <String>{};
      Iterable<String> distinct(Iterable<_DoubanArt> candidates) sync* {
        for (final a in candidates) {
          final path = Uri.parse(a.url).path;
          final photo = RegExp(r'/public/(p\d+)\.\w+$').firstMatch(path)?[1] ?? path;
          if (seen.add(photo)) yield a.url;
        }
      }

      final primary = distinct(posters..sort(_preferArt)).take(3).toList();
      final backups = distinct([
        ...(stills..sort(_preferArt)),
        if (film._cover case final cover?) cover,
      ]).take(3).toList();
      return List.unmodifiable([...primary.take(backups.isEmpty ? 3 : 2), ...backups].take(3));
    }

    await album('R');
    if (stills.isEmpty || ranked().length < 3) await album('S');
    return (urls: ranked(), complete: complete);
  }
}
