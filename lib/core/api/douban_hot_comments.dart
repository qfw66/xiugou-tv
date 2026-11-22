part of 'douban_repository.dart';

typedef DoubanComment = ({String author, String text, int? stars, int? votes});

class _DoubanHotComments {
  _DoubanHotComments(this.subjects);
  final _DoubanSubjects subjects;
  final cache = _DoubanMemo<_SubjectKey, List<DoubanComment>>();

  Future<List<DoubanComment>> forItem(VodItem item, CancelToken? cancel) async {
    try {
      final film = await subjects.forItem(item, cancel);
      _checkDoubanCancel(cancel);
      if (film == null) return const [];
      return await cache.get(film._key, subjects.ttl, cancel, (token) async {
            final data = await subjects.read('${film._path}/interests', token, {
              'order_by': 'hot',
              'start': '0',
              'count': '5',
            });
            final items = data['interests'];
            if (items is! List) throw const FormatException();
            return List.unmodifiable(_parse(items));
          }) ??
          const [];
    } catch (error) {
      _rethrowDoubanCancel(error, cancel);
      throw const DoubanException('豆瓣短评暂时不可用');
    }
  }

  Iterable<DoubanComment> _parse(List rows) sync* {
    final ids = <String>{};
    for (final row in rows.take(5).whereType<Map>()) {
      final text = _doubanText(row['comment']);
      final id = row['id']?.toString();
      if (text.isEmpty || (id != null && !ids.add(id))) continue;
      final user = row['user'], rating = row['rating'];
      final stars = rating is Map ? rating['value'] : null, votes = row['vote_count'];
      yield (
        text: text,
        author: user is Map ? _doubanText(user['name']) : '',
        stars: stars is int && stars >= 1 && stars <= 5 ? stars : null,
        votes: votes is int && votes >= 0 ? votes : null,
      );
    }
  }
}
