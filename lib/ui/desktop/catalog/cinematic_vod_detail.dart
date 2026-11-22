part of 'vod_detail_dialog.dart';

class _CinematicVodPage extends StatefulWidget {
  const _CinematicVodPage({
    super.key,
    required this.detail,
    required this.load,
    required this.onPlay,
    this.loadDoubanMetadata,
    this.loadDoubanBackdrops,
    this.loadHotComments,
    this.onSearchRecommendation,
    this.current,
    this.history,
    this.favorite,
    this.share,
    this.error,
  });
  final VodDetail detail;
  final Future<TmdbMovie?> Function(CancelToken) load;
  final Future<DoubanDetailMetadata?> Function(CancelToken)? loadDoubanMetadata;
  final Future<List<String>> Function(DoubanDetailMetadata, CancelToken)?
  loadDoubanBackdrops;
  final Future<List<DoubanComment>> Function(CancelToken)? loadHotComments;
  final PlayEpisodeCallback onPlay;
  final ValueChanged<String>? onSearchRecommendation;
  final CurrentEpisode? current;
  final EpisodeSelection? history;
  final Widget? favorite, share;
  final String? error;

  @override
  State<_CinematicVodPage> createState() => _CinematicVodPageState();
}

class _CinematicVodPageState extends State<_CinematicVodPage> {
  static const _perPage = 20;
  static const _sectionGap = SizedBox(height: 32);
  final _pageScroll = ScrollController();
  final _sourceScroll = ScrollController();
  late final _DetailEnrichment _metadata;
  late int _source;
  int _page = 0;
  bool _descending = false;
  bool _expanded = false;
  List<PlayFrom> get _sources => widget.detail.sources;
  List<VodEpisode> get _episodes =>
      _sources.isEmpty ? const [] : _sources[_source].episodes;

  int? _resumeIndex(int source) {
    final line = _sources[source];
    final c = widget.current;
    if (c != null &&
        c.index >= 0 &&
        c.index < line.episodes.length &&
        c.matches(
          sourceName: line.name,
          index: c.index,
          episodeName: line.episodes[c.index].name,
        )) {
      return c.index;
    }
    final h = widget.history;
    return h != null && h.sourceIndex == source ? h.index : null;
  }

  @override
  void initState() {
    super.initState();
    _metadata = _DetailEnrichment(
      widget.loadDoubanMetadata,
      widget.loadDoubanBackdrops,
    );
    unawaited(_metadata.start(widget.load));
    final current = widget.current;
    final currentLine = _sources.indexWhere(
      (s) =>
          current != null &&
          s.name == current.sourceName &&
          current.index >= 0 &&
          current.index < s.episodes.length &&
          s.episodes[current.index].name == current.episodeName,
    );
    final firstPlayable = _sources.indexWhere((s) => s.episodes.isNotEmpty);
    _source = currentLine >= 0
        ? currentLine
        : (widget.history?.sourceIndex ?? math.max(0, firstPlayable));
    if (_sources.isNotEmpty) _page = (_resumeIndex(_source) ?? 0) ~/ _perPage;
  }

  @override
  void dispose() {
    _metadata.dispose();
    _pageScroll.dispose();
    _sourceScroll.dispose();
    super.dispose();
  }

  void _play(int index) {
    final selected = EpisodeSelection(
      episode: _episodes[index],
      sourceName: _sources[_source].name,
      episodes: _episodes,
      index: index,
      sources: _sources,
      sourceIndex: _source,
    );
    Navigator.of(context).pop();
    widget.onPlay(selected);
  }

  @override
  Widget build(BuildContext context) => Material(
    key: const ValueKey('cinematic-detail'),
    color: context.palette.background,
    child: SafeArea(
      child: LayoutBuilder(
        builder: (context, size) {
          final windowBack = DesktopWindowFrame.hasDetailBackButton(context);
          final gutter = size.maxWidth < 640 ? 20.0 : 44.0;
          final insets = EdgeInsets.only(
            left: windowBack
                ? gutter
                : kMinInteractiveDimension + AppSpacing.xs,
            right: gutter,
          );
          return ListenableBuilder(
            listenable: _metadata,
            builder: (context, _) {
              final movie = _metadata.primary;
              final waiting = _metadata.waitingForPrimary;
              return Stack(
                children: [
                  ListView(
                    controller: _pageScroll,
                    padding: EdgeInsets.zero,
                    children: [
                      _hero(
                        movie,
                        size.biggest,
                        insets,
                        waitingForMetadata: waiting,
                      ),
                      Padding(
                        padding: insets.copyWith(
                          top: AppSpacing.xl,
                          bottom: 32,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _overviewAndActions(
                              movie,
                              waitingForMetadata: waiting,
                            ),
                            if (widget.error case final error?)
                              Text(
                                error,
                                style: TextStyle(color: context.palette.danger),
                              ),
                            _sectionGap,
                            _episodeSection(),
                            _sectionGap,
                            _cast(_metadata.cast),
                            if (widget.loadHotComments case final load?) ...[
                              _sectionGap,
                              _DetailComments(
                                key: ValueKey((
                                  widget.detail.item.siteKey,
                                  widget.detail.item.id,
                                  widget.detail.item.name,
                                  widget.detail.item.year,
                                  widget.detail.item.doubanId,
                                )),
                                load: load,
                              ),
                            ],
                            if (widget.onSearchRecommendation != null &&
                                movie != null &&
                                movie.recommendations.isNotEmpty) ...[
                              _sectionGap,
                              _DetailRail(
                                heading: '相似推荐',
                                pictureSize: const Size(126, 189),
                                placeholder: Icons.movie_outlined,
                                titleLines: 2,
                                entries: [
                                  for (final r in movie.recommendations)
                                    (
                                      title: r.title,
                                      subtitle: r.year,
                                      image: r.poster,
                                    ),
                                ],
                                onPick: (title) {
                                  Navigator.of(context).pop();
                                  widget.onSearchRecommendation!(title);
                                },
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (windowBack)
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      height: MediaTitleBar.height,
                      child: _windowBarScrim(),
                    )
                  else
                    Positioned(
                      top: 8,
                      left: 0,
                      child: IconButton.filled(
                        style: IconButton.styleFrom(
                          backgroundColor: Colors.black87,
                          foregroundColor: Colors.white,
                        ),
                        icon: const Icon(Icons.arrow_back_rounded),
                        tooltip: '返回',
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ),
                ],
              );
            },
          );
        },
      ),
    ),
  );

  Widget _windowBarScrim() => IgnorePointer(
    child: ListenableBuilder(
      listenable: _pageScroll,
      builder: (context, _) {
        final fade = _pageScroll.hasClients
            ? (_pageScroll.offset / MediaTitleBar.height).clamp(0.0, 1.0)
            : 0.0;
        final solid = AppPalette.dark.raised;
        return DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color.lerp(Colors.black54, solid, fade)!,
                Color.lerp(Colors.transparent, solid, fade)!,
              ],
            ),
          ),
        );
      },
    ),
  );

  Widget _filmTitle(String? logo, {required bool waitingForMetadata}) {
    final name = widget.detail.item.name;
    final title = Text(
      name,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 34,
        height: 1.16,
        fontWeight: FontWeight.w700,
      ),
    );
    return Semantics(
      container: true,
      header: true,
      label: name,
      excludeSemantics: true,
      child: Container(
        alignment: Alignment.bottomLeft,
        constraints: const BoxConstraints(minHeight: 72),
        child: waitingForMetadata
            ? const SizedBox.shrink()
            : logo == null || logo.isEmpty
            ? title
            : Image.network(
                logo,
                height: 72,
                width: 300,
                fit: BoxFit.contain,
                alignment: Alignment.bottomLeft,
                errorBuilder: (_, __, ___) => title,
              ),
      ),
    );
  }

  Widget _facts(TmdbMovie? movie) {
    final item = widget.detail.item;
    final db = _metadata.supplement;
    final year = _firstText([movie?.year, db?.year, item.year]);
    final type = _firstText([
      movie?.kind,
      if (db != null) db.kind == 'tv' ? '剧集' : '电影',
      item.typeName,
    ]);
    final genres = movie?.genres.isNotEmpty == true
        ? movie!.genres
        : db?.genres ?? const <String>[];
    final kind = {if (type != null) type, ...genres}.join(' · ');
    final countries = movie?.countries.isNotEmpty == true
        ? movie!.countries
        : db?.countries ?? const <String>[];
    final country = countries.isNotEmpty
        ? countries.join(' / ')
        : item.area?.trim();
    final score =
        movie?.rating?.toStringAsFixed(1) ??
        (db?.rating == null
            ? item.score?.trim()
            : '豆瓣 ${db!.rating!.toStringAsFixed(1)}');
    return DefaultTextStyle.merge(
      style: const TextStyle(
        color: Colors.white,
        fontSize: AppType.lead,
        fontWeight: FontWeight.w600,
      ),
      child: Wrap(
        spacing: AppSpacing.md,
        runSpacing: AppSpacing.xs,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (year != null && year.isNotEmpty) _factPill(year),
          if (kind.isNotEmpty) Text(kind),
          if (country != null && country.isNotEmpty) Text(country),
          if (score != null && score.isNotEmpty) _factPill(score, rating: true),
        ],
      ),
    );
  }

  Widget _factPill(String value, {bool rating = false}) {
    const palette = AppPalette.dark;
    final ink = rating ? palette.warning : palette.selectionInk;
    final fill = rating
        ? Color.alphaBlend(ink.withValues(alpha: .16), palette.background)
        : palette.selectionFill;
    return DecoratedBox(
      decoration: ShapeDecoration(shape: const StadiumBorder(), color: fill),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 3,
          children: [
            if (rating) Icon(Icons.star_rounded, color: ink, size: 16),
            Flexible(
              child: Text(
                value,
                style: TextStyle(
                  color: ink,
                  fontSize: AppType.title,
                  fontWeight: FontWeight.w700,
                ),
                semanticsLabel: rating ? '评分 $value' : null,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _hero(
    TmdbMovie? movie,
    Size viewport,
    EdgeInsets insets, {
    required bool waitingForMetadata,
  }) {
    final artwork = _metadata.primaryArt;
    final height = math.min(viewport.width * 9 / 16, viewport.height * .82);
    final preview = movie?.backdropPreview;
    Widget noPrimaryArt() => waitingForMetadata
        ? const SizedBox.shrink()
        : _ArtworkExhausted(_metadata.primaryArtUnavailable);
    Widget primaryArt(int index) => index == artwork.length
        ? (preview == null
              ? noPrimaryArt()
              : _backdropPreview(preview, onError: noPrimaryArt))
        : Image.network(
            artwork[index],
            key: ValueKey(artwork[index]),
            fit: BoxFit.cover,
            excludeFromSemantics: true,
            frameBuilder: preview == null
                ? null
                : (_, child, frame, _) => frame != null
                      ? child
                      : _SlowBackdropPreview(
                          key: ValueKey(preview),
                          url: preview,
                        ),
            errorBuilder: (_, _, _) => primaryArt(index + 1),
          );
    Widget doubanArt(int index) {
      final urls = _metadata.wideArt;
      if (urls.isEmpty) return const SizedBox.shrink();
      if (index == urls.length) {
        return _ArtworkExhausted(_metadata.doubanArtUnavailable);
      }
      return Image(
        key: ValueKey(urls[index]),
        image: DoubanPosterImage(urls[index], requireLandscape: true),
        fit: BoxFit.cover,
        excludeFromSemantics: true,
        errorBuilder: (_, _, _) => doubanArt(index + 1),
      );
    }

    return ColoredBox(
      color: AppPalette.dark.background,
      child: Stack(
        alignment: Alignment.bottomLeft,
        children: [
          SizedBox(
            width: double.infinity,
            height: _metadata.reserveArtwork ? height : 0,
          ),
          Positioned.fill(
            child: _metadata.usingDoubanArt ? doubanArt(0) : primaryArt(0),
          ),
          Container(
            width: double.infinity,
            padding: insets.copyWith(top: 60, bottom: 18),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, Colors.black54, Colors.black87],
                stops: [0, .36, 1],
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _filmTitle(movie?.logo, waitingForMetadata: waitingForMetadata),
                const SizedBox(height: AppSpacing.sm),
                _facts(movie),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _overviewAndActions(
    TmdbMovie? movie, {
    required bool waitingForMetadata,
  }) {
    final overview =
        _firstText([
          movie?.overview,
          _metadata.supplement?.overview,
          widget.detail.item.content,
        ]) ??
        '';
    final actions = _actions();
    if (!waitingForMetadata && overview.isEmpty) return actions;
    final copy = ConstrainedBox(
      constraints: const BoxConstraints(
        maxWidth: 860,
        minHeight: kMinInteractiveDimension,
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: waitingForMetadata
            ? const SizedBox.shrink()
            : _overview(overview),
      ),
    );
    return LayoutBuilder(
      builder: (context, box) {
        final font = MediaQuery.textScalerOf(context).scale(AppType.lead);
        if (box.maxWidth < font * 22 + 220) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: AppSpacing.sm,
            children: [copy, actions],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: AppSpacing.xl,
          children: [
            Expanded(
              child: Align(alignment: Alignment.centerLeft, child: copy),
            ),
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: box.maxWidth * .42),
              child: actions,
            ),
          ],
        );
      },
    );
  }

  Widget _overview(String text) => LayoutBuilder(
    builder: (context, constraints) {
      final style = DefaultTextStyle.of(context).style.copyWith(
        color: context.palette.textBody,
        fontSize: AppType.lead,
        height: 1.5,
      );
      final measure = TextPainter(
        text: TextSpan(text: text, style: style),
        maxLines: 3,
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout(maxWidth: constraints.maxWidth);
      final more = measure.didExceedMaxLines;
      measure.dispose();
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            text,
            style: style,
            maxLines: _expanded ? null : 3,
            overflow: _expanded ? null : TextOverflow.ellipsis,
          ),
          if (more)
            TextButton(
              onPressed: () => setState(() => _expanded = !_expanded),
              child: Text(_expanded ? '收起简介' : '展开简介'),
            ),
        ],
      );
    },
  );

  Widget _actions() {
    final index = _sources.isEmpty ? null : _resumeIndex(_source);
    final first = index ?? 0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: AppSpacing.sm,
      children: [
        Flexible(
          child: FilledButton.icon(
            key: const ValueKey('cinematic-resume'),
            onPressed: _episodes.isEmpty ? null : () => _play(first),
            icon: const Icon(Icons.play_arrow_rounded),
            label: Text(
              _episodes.isEmpty
                  ? '暂无选集'
                  : '${index == null ? '播放' : '继续'} ${_episodes[first].name}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        if (widget.favorite case final favorite?) favorite,
        if (widget.share case final share?) share,
      ],
    );
  }

  Widget _episodeSection() {
    final count = _episodes.length;
    final pages = (count + _perPage - 1) ~/ _perPage;
    final start = _page * _perPage,
        end = math.min(count, (_page + 1) * _perPage);
    String range(int p) =>
        '${p * _perPage + 1}-${math.min(count, (p + 1) * _perPage)}';
    void selectSource(int i) => setState(() {
      _source = i;
      final resume = _resumeIndex(i);
      _page = resume != null
          ? resume ~/ _perPage
          : _descending
          ? math.max(0, (_episodes.length - 1) ~/ _perPage)
          : 0;
    });
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 16,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('选集', style: Theme.of(context).textTheme.titleLarge),
            Text('共 $count 集'),
            if (count > 1)
              TextButton.icon(
                onPressed: () => setState(() {
                  _descending = !_descending;
                  _page = _descending ? pages - 1 : 0;
                }),
                icon: Icon(
                  _descending
                      ? Icons.arrow_downward_rounded
                      : Icons.arrow_upward_rounded,
                  size: 18,
                ),
                label: Text(_descending ? '倒序' : '正序'),
              ),
          ],
        ),
        if (_sources.length > 1)
          SizedBox(
            height: 48,
            child: HorizontalScrollArea(
              controller: _sourceScroll,
              child: ListView.separated(
                controller: _sourceScroll,
                scrollDirection: Axis.horizontal,
                itemCount: _sources.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (_, i) => Center(
                  child: ChoiceChip(
                    label: Text(_sources[i].name),
                    selected: i == _source,
                    onSelected: (_) => selectSource(i),
                  ),
                ),
              ),
            ),
          ),
        if (pages > 1 && pages <= 8)
          Wrap(
            spacing: 8,
            children: [
              for (int n = 0; n < pages; n++)
                Builder(
                  builder: (_) {
                    final p = _descending ? pages - 1 - n : n;
                    return ChoiceChip(
                      label: Text(range(p)),
                      selected: p == _page,
                      onSelected: (_) => setState(() => _page = p),
                    );
                  },
                ),
            ],
          )
        else if (pages > 8)
          DropdownButton<int>(
            value: _page,
            menuMaxHeight: 320,
            items: [
              for (int n = 0; n < pages; n++)
                DropdownMenuItem(
                  value: _descending ? pages - 1 - n : n,
                  child: Text(range(_descending ? pages - 1 - n : n)),
                ),
            ],
            onChanged: (p) {
              if (p != null) setState(() => _page = p);
            },
          ),
        const SizedBox(height: 8),
        if (count == 0)
          const Text('该播放源暂无选集')
        else
          LayoutBuilder(
            builder: (context, constraints) {
              final cols = (constraints.maxWidth / 150).floor().clamp(1, 8);
              return Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (int n = start; n < end; n++)
                    Builder(
                      builder: (_) {
                        final idx = _descending ? end - 1 - (n - start) : n;
                        return SizedBox(
                          width: (constraints.maxWidth - 8 * (cols - 1)) / cols,
                          height: 54,
                          child: _EpisodeButton(
                            key: ValueKey('detail-episode-$idx'),
                            label: _episodes[idx].name,
                            isCurrent: idx == _resumeIndex(_source),
                            onTap: () => _play(idx),
                          ),
                        );
                      },
                    ),
                ],
              );
            },
          ),
      ],
    );
  }

  Widget _cast(List<TmdbActor> cast) {
    final source = widget.detail.item.actor ?? '';
    return _DetailRail(
      heading: '剧集演员',
      pictureSize: const Size(94, 110),
      placeholder: Icons.person_outline_rounded,
      emptyText: '暂无演员资料',
      onImageUnavailable: (entry) =>
          _metadata.actorPortraitUnavailable(entry.title, entry.image!),
      entries: [
        for (final a in cast)
          (title: a.name, subtitle: a.role, image: a.portrait),
        if (cast.isEmpty)
          for (final name
              in source
                  .split(RegExp(r'[,，、/;；|]'))
                  .map((s) => s.trim())
                  .where((s) => s.isNotEmpty)
                  .toSet())
            (title: name, subtitle: '', image: null),
      ],
    );
  }
}

String? _firstText(List<String?> candidates) => candidates
    .whereType<String>()
    .map((s) => s.trim())
    .where((s) => s.isNotEmpty)
    .firstOrNull;

Widget _backdropPreview(String url, {Widget Function()? onError}) =>
    Image.network(
      url,
      fit: BoxFit.cover,
      excludeFromSemantics: true,
      errorBuilder: (_, _, _) => onError?.call() ?? const SizedBox.shrink(),
    );

/// 原图命中缓存或快速到达时，不额外请求小图。
class _SlowBackdropPreview extends StatefulWidget {
  const _SlowBackdropPreview({super.key, required this.url});
  final String url;

  @override
  State<_SlowBackdropPreview> createState() => _SlowBackdropPreviewState();
}

class _SlowBackdropPreviewState extends State<_SlowBackdropPreview> {
  late final Timer _timer;
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer(
      const Duration(seconds: 2),
      () => setState(() => _visible = true),
    );
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _visible ? _backdropPreview(widget.url) : const SizedBox.shrink();
}
