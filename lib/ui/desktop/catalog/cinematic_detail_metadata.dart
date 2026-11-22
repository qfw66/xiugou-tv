part of 'vod_detail_dialog.dart';

/// 每个详情页独立取消资料和背景请求；播放与选集不依赖这两项。
class _DetailEnrichment extends ChangeNotifier {
  _DetailEnrichment(this._subjectLoader, this._artLoader);

  final Future<DoubanDetailMetadata?> Function(CancelToken)? _subjectLoader;
  final Future<List<String>> Function(DoubanDetailMetadata, CancelToken)?
  _artLoader;
  final _cancel = CancelToken();
  TmdbMovie? primary;
  DoubanDetailMetadata? supplement;
  Future<DoubanDetailMetadata?>? _subject;
  bool waitingForPrimary = true;
  bool usingDoubanArt = false;
  bool _waitingForArt = false;
  List<String> wideArt = const [];
  final _failedPortraits = <(String, String)>{};

  bool get _active => !_cancel.isCancelled;
  bool get reserveArtwork =>
      waitingForPrimary ||
      (usingDoubanArt
          ? _waitingForArt || wideArt.isNotEmpty
          : primaryArt.isNotEmpty || primary?.backdropPreview != null);
  List<String> get primaryArt => [
    if (primary?.backdrop case final url? when url.isNotEmpty) url,
    ...?primary?.backdropFallbacks,
  ];

  Future<void> start(Future<TmdbMovie?> Function(CancelToken) load) async {
    TmdbMovie? movie;
    try {
      movie = await Future.sync(() => load(_cancel));
    } catch (_) {
      // 资料可选，仍保留站源内容和播放入口。
    }
    if (!_active) return;
    primary = movie;
    waitingForPrimary = false;
    notifyListeners();
    if (primaryArt.isEmpty &&
        primary?.backdropPreview == null &&
        _artLoader != null) {
      primaryArtUnavailable();
    } else if (movie == null ||
        movie.overview.trim().isEmpty ||
        movie.year.isEmpty ||
        movie.kind.isEmpty ||
        movie.genres.isEmpty ||
        movie.countries.isEmpty ||
        movie.rating == null ||
        movie.cast.isEmpty ||
        movie.cast.any((a) => a.portrait == null || a.role.isEmpty)) {
      unawaited(_readSubject());
    }
  }

  Future<DoubanDetailMetadata?> _readSubject() => _subject ??= _fetchSubject();

  Future<DoubanDetailMetadata?> _fetchSubject() async {
    try {
      final film = await _subjectLoader?.call(_cancel);
      if (!_active || film == null) return null;
      // TMDB 有时能从片源文件名认出版本，不能混入豆瓣的另一年或另一类型。
      final movie = primary;
      if (movie != null &&
          ((movie.year.isNotEmpty && movie.year != film.year) ||
              (movie.kind == '电影' && film.kind != 'movie') ||
              (movie.kind == '剧集' && film.kind != 'tv'))) {
        return null;
      }
      supplement = film;
      notifyListeners();
      return film;
    } catch (_) {
      return null;
    }
  }

  void primaryArtUnavailable() {
    if (!_active || usingDoubanArt) return;
    usingDoubanArt = true;
    _waitingForArt = _subjectLoader != null && _artLoader != null;
    notifyListeners();
    if (_waitingForArt) unawaited(_loadWideArt());
  }

  Future<void> _loadWideArt() async {
    final film = await _readSubject();
    if (!_active) return;
    try {
      if (film != null) wideArt = await _artLoader!(film, _cancel);
    } catch (_) {
      wideArt = const [];
    } finally {
      if (_active) {
        _waitingForArt = false;
        notifyListeners();
      }
    }
  }

  void doubanArtUnavailable() {
    if (!_active || wideArt.isEmpty) return;
    wideArt = const [];
    notifyListeners();
  }

  void actorPortraitUnavailable(String name, String url) {
    if (!_active ||
        primary?.cast.any((a) => a.name == name && a.portrait == url) != true ||
        !_failedPortraits.add((name, url))) {
      return;
    }
    if (supplement != null) {
      notifyListeners();
    } else {
      unawaited(_readSubject());
    }
  }

  List<TmdbActor> get cast {
    final base = primary?.cast ?? const <TmdbActor>[];
    final extra = supplement?.cast ?? const <TmdbActor>[];
    if (base.isEmpty) return extra;
    if (extra.isEmpty) return base;
    return [for (final person in base) _fillActor(person, extra)];
  }

  TmdbActor _fillActor(TmdbActor person, List<TmdbActor> extra) {
    final failed = _failedPortraits.contains((person.name, person.portrait));
    if (!failed && person.portrait != null && person.role.isNotEmpty) return person;
    final match = extra.where((a) => a.name == person.name).singleOrNull;
    if (match == null) return person;
    return (
      name: person.name,
      role: person.role.isEmpty ? match.role : person.role,
      portrait: failed
          ? (match.portrait == person.portrait ? null : match.portrait)
          : person.portrait ?? match.portrait,
    );
  }

  @override
  void dispose() {
    _cancel.cancel();
    super.dispose();
  }
}

/// errorBuilder 在构建期间运行；下一来源只在这帧绘制后启动一次。
class _ArtworkExhausted extends StatefulWidget {
  const _ArtworkExhausted(this.onExhausted);
  final VoidCallback onExhausted;
  @override
  State<_ArtworkExhausted> createState() => _ArtworkExhaustedState();
}

class _ArtworkExhaustedState extends State<_ArtworkExhausted> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onExhausted();
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
