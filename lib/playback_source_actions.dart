part of 'app.dart';

enum PlaybackSourceChangeKind { quality, source, external }

class PlaybackSourceChange {
  const PlaybackSourceChange(this.kind, this.cancelToken, this.statusText);
  final PlaybackSourceChangeKind kind;
  final SearchCancelToken cancelToken;
  final String statusText;
}

final playbackSourceChangeProvider =
    StateProvider<PlaybackSourceChange?>((ref) => null);

final _sourceRecoverySnapshotProvider =
    StateProvider<_SourcePlaybackSnapshot?>((ref) {
  ref.watch(activePlaySpecProvider);
  return null;
});

/// Preferences live only as long as the current configuration, keyed by site.
final playbackQualityPreferencesProvider =
    StateProvider<Map<String, String>>((ref) {
  ref.watch(vodConfigProvider);
  return const {};
});

final switchPlaybackQualityProvider = Provider<Future<void> Function(int)>(
    (ref) => (index) => _switchPlaybackQuality(ref, index));

final switchLiveLineProvider = Provider<Future<void> Function(int)>(
    (ref) => (index) => _switchLiveLine(ref, index));

typedef PlaybackSourceChooser = Future<CrossSiteCandidate?> Function(
    List<CrossSiteCandidate> candidates);

final switchPlaybackSourceProvider =
    Provider<Future<void> Function(PlaybackSourceChooser)>(
        (ref) => (choose) => _switchPlaybackSource(ref, choose));

bool _sourceChangeBlocked(Ref ref) =>
    ref.read(playbackSourceChangeProvider) != null ||
    ref.read(playerRefreshBusyProvider) ||
    ref.read(playerAutoSwitchBusyProvider) ||
    (ref.read(activePlaybackSessionProvider)?.switching ?? false);

class _SourceChangeOwner {
  _SourceChangeOwner(this.ref, this.kind)
      : epoch = ++_playbackSessionEpoch,
        config = ref.read(configRepositoryProvider).currentVodConfig,
        siteKey = ref.read(configRepositoryProvider).selectedSite?.key,
        cancelToken = SearchCancelToken() {
    ref.read(playbackSourceChangeProvider.notifier).state =
        PlaybackSourceChange(kind, cancelToken, '正在查找…');
    final autoLine = ref.read(autoLineSwitchProvider);
    if (kind == PlaybackSourceChangeKind.external) {
      // invariant: external launch preserves the existing early-error window and timer.
      autoLine.rebindEpoch(epoch);
    } else {
      autoLine.disarm();
    }
    _configSubscription = ref.listen(vodConfigProvider, (_, next) {
      if (!identical(config, next)) cancelToken.cancel();
    });
    _siteSubscription = ref.listen(currentSiteProvider, (_, next) {
      if (next?.key != siteKey) cancelToken.cancel();
    });
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!isCurrent) cancelToken.cancel();
    });
    ref.onDispose(() {
      if (_disposed) return;
      _disposed = true;
      _closeSubscriptions();
      cancelToken.cancel();
    });
  }

  final Ref ref;
  final PlaybackSourceChangeKind kind;
  final int epoch;
  final VodConfig config;
  final String? siteKey;
  final SearchCancelToken cancelToken;
  late final Timer _timer;
  late final ProviderSubscription<VodConfig> _configSubscription;
  late final ProviderSubscription<Site?> _siteSubscription;

  bool _disposed = false;

  // invariant: context cancellation still permits rollback until new playback owns the engine.
  bool get ownsPlayback =>
      !_disposed &&
      epoch == _playbackSessionEpoch &&
      identical(
          ref.read(playbackSourceChangeProvider)?.cancelToken, cancelToken);
  bool get isCurrent =>
      ownsPlayback &&
      !cancelToken.isCancelled &&
      identical(config, ref.read(configRepositoryProvider).currentVodConfig) &&
      siteKey == ref.read(configRepositoryProvider).selectedSite?.key;

  void status(String text) {
    final current = ref.read(playbackSourceChangeProvider);
    if (identical(current?.cancelToken, cancelToken)) {
      ref.read(playbackSourceChangeProvider.notifier).state =
          PlaybackSourceChange(current!.kind, cancelToken, text);
    }
  }

  Future<T> wait<T>(Future<T> future) {
    final cancelled = Completer<T>();
    cancelToken.onCancel(() {
      if (!cancelled.isCompleted) {
        cancelled.completeError(const PlaybackSourceCancelled());
      }
    });
    return Future.any([future, cancelled.future]);
  }

  void _closeSubscriptions() {
    _timer.cancel();
    _configSubscription.close();
    _siteSubscription.close();
  }

  void dispose({bool rearm = true}) {
    if (_disposed) return;
    final owned = ownsPlayback;
    _closeSubscriptions();
    if (identical(
        ref.read(playbackSourceChangeProvider)?.cancelToken, cancelToken)) {
      ref.read(playbackSourceChangeProvider.notifier).state = null;
    }
    _disposed = true;
    if (owned && rearm && ref.read(_sourceRecoverySnapshotProvider) == null) {
      if (kind == PlaybackSourceChangeKind.external) {
        ref.read(autoLineSwitchProvider).resumePendingAttempt();
      } else {
        _armSourceSession(ref);
      }
    }
  }
}

void _armSourceSession(Ref ref) {
  final session = ref.read(activePlaybackSessionProvider);
  if (session == null ||
      session.episodes.isEmpty ||
      ref.read(activePlaySpecProvider)?.isLive != false) {
    return;
  }
  ref.read(autoLineSwitchProvider).arm(
        sources: session.sources,
        currentSourceIndex: session.sourceIndex,
        currentSourceName: session.sourceName,
        episodeName: session.episodes[session.index].name,
        currentEpisodeUrl: session.episodes[session.index].url,
        tried: session.triedLines,
        epoch: _playbackSessionEpoch,
        startPosition: ref.read(playerEngineProvider).position,
      );
}

/// Snapshotted immediately before replacing the source, after a search ends.
class _SourcePlaybackSnapshot {
  factory _SourcePlaybackSnapshot(Ref ref) =>
      ref.read(_sourceRecoverySnapshotProvider) ??
      _SourcePlaybackSnapshot._(ref);

  _SourcePlaybackSnapshot._(Ref ref)
      : spec = ref.read(activePlaySpecProvider),
        liveCatalog = _LiveCatalogPlaybackSnapshot(
            ref.read(activePlaySpecProvider), ref.read(liveRuntimeProvider)),
        recordId = ref.read(playbackHistoryTrackerProvider).activeRecordId,
        position = ref.read(playerEngineProvider).position,
        rate = ref.read(playerEngineProvider).rate,
        volume = ref.read(playerEngineProvider).volume,
        paused = _sourceIsPaused(ref.read(playerEngineProvider));

  final MediaPlaySpec? spec;
  final _LiveCatalogPlaybackSnapshot liveCatalog;
  final String? recordId;
  final Duration position;
  final double rate;
  final double volume;
  final bool paused;

  Future<void> open(MpvPlayerEngine engine, MediaPlaySpec target,
      {required bool Function() ownsPlayback}) async {
    if (!ownsPlayback()) throw const PlaybackSourceCancelled();
    if (engine.runtimeType == MpvPlayerEngine) {
      await engine.switchSource(target);
    } else {
      // Tests and alternate adapters retain the base PlayerEngine contract.
      await engine.play(target);
    }
    bool ownsTarget() =>
        ownsPlayback() && identical(engine.currentSpec, target);
    if (!ownsTarget()) return;
    await engine.setRate(rate);
    if (!ownsTarget()) return;
    await engine.setVolume(volume);
    if (!ownsTarget()) return;
    if (paused) await engine.pause();
  }

  Future<void> restore(Ref ref, _SourceChangeOwner owner) async {
    if (!owner.ownsPlayback) return;
    owner.status('正在恢复原播放…');
    final engine = ref.read(playerEngineProvider);
    final original = spec;
    if (original == null) {
      await engine.stop();
      return;
    }
    final rollback = original.copyWith(
        startPosition: original.isLive ? Duration.zero : position);
    try {
      await PlaybackSourceLoader(
              engine: engine,
              open: (s) =>
                  open(engine, s, ownsPlayback: () => owner.ownsPlayback))
          .load(rollback, isCurrent: () => owner.ownsPlayback);
      if (!owner.ownsPlayback) return;
      final committed = liveCatalog.rebase(rollback, ref.read(liveRuntimeProvider));
      ref.read(liveRuntimeProvider.notifier).state = committed.runtime;
      ref.read(activePlaySpecProvider.notifier).state = committed.spec;
      resumeTracking(ref);
    } catch (_) {
      if (owner.ownsPlayback) {
        // invariant: failed media cannot write progress; refresh retains the saved record and position.
        ref.read(_sourceRecoverySnapshotProvider.notifier).state = this;
        ref.read(lineSwitchNoticeProvider.notifier).state =
            '原播放也未能恢复，请刷新或重新选择来源';
      }
    }
  }

  void resumeTracking(Ref ref) =>
      ref.read(playbackHistoryTrackerProvider).track(recordId,
          flushPrevious: false,
          baseline: position,
          floor: position > Duration.zero ? position : null);
}

bool _sourceIsPaused(MpvPlayerEngine engine) =>
    engine.runtimeType == MpvPlayerEngine
        ? engine.isPlaybackPaused
        : engine.status == PlaybackStatus.paused;

Future<void> _switchLiveLine(Ref ref, int index) async {
  final previous = ref.read(activePlaySpecProvider);
  final runtime = ref.read(liveRuntimeProvider);
  final session = ref.read(activePlaybackSessionProvider);
  if (_sourceChangeBlocked(ref) || previous == null ||
      index < 0 || index >= previous.qualities.length ||
      index == previous.qualityIndex) {
    return;
  }
  final scriptedRoom = previous.isLive &&
      previous.liveDanmakuSources.isNotEmpty && session != null;
  if (!scriptedRoom && _livePlayingIndex(previous, runtime) < 0) return;
  final owner = _SourceChangeOwner(ref, PlaybackSourceChangeKind.quality);
  final selected = previous.qualities[index];
  _SourcePlaybackSnapshot? snapshot;
  var opened = false;
  try {
    owner.status('正在切换到${selected.name}…');
    var target = scriptedRoom
        ? await owner.wait(ref.read(siteApiProvider).resolveQuality(previous,
            index: index,
            flag: session.sourceName,
            parseEngine: ref.read(parseEngineProvider),
            parses: owner.config.parses).timeout(const Duration(seconds: 20)))
        : previous.copyWith(
            url: selected.url,
            headers: selected.headers,
            qualityIndex: index,
          );
    if (!owner.isCurrent) return;
    snapshot = _SourcePlaybackSnapshot(ref);
    target = target.copyWith(
        startPosition: target.isLive ? Duration.zero : snapshot.position);
    final engine = ref.read(playerEngineProvider);
    opened = true;
    await PlaybackSourceLoader(
      engine: engine,
      open: (spec) => snapshot!.open(engine, spec,
          ownsPlayback: () => owner.ownsPlayback),
    ).load(target, isCurrent: () => owner.isCurrent);
    if (!owner.isCurrent) throw const PlaybackSourceCancelled();
    final committed = snapshot.liveCatalog.rebase(target, ref.read(liveRuntimeProvider));
    ref.read(liveRuntimeProvider.notifier).state = committed.runtime;
    ref.read(activePlaySpecProvider.notifier).state = committed.spec;
    ref.read(lineSwitchNoticeProvider.notifier).state = '已切换到${selected.name}';
  } catch (error) {
    if (owner.ownsPlayback) {
      ref.read(lineSwitchNoticeProvider.notifier).state =
          error is PlaybackSourceCancelled ? '已取消切换' : '直播线路切换失败';
      if (opened && snapshot != null) await snapshot.restore(ref, owner);
    }
  } finally {
    owner.dispose(rearm: false);
  }
}

Future<void> _switchPlaybackQuality(Ref ref, int index) async {
  final previous = ref.read(activePlaySpecProvider);
  final session = ref.read(activePlaybackSessionProvider);
  if (_sourceChangeBlocked(ref) ||
      previous == null ||
      session == null ||
      previous.isLive ||
      index < 0 ||
      index >= previous.qualities.length ||
      index == previous.qualityIndex) {
    return;
  }
  final owner = _SourceChangeOwner(ref, PlaybackSourceChangeKind.quality);
  final name = previous.qualities[index].name;
  final api = ref.read(siteApiProvider);
  _SourcePlaybackSnapshot? snapshot;
  var opened = false;
  try {
    owner.status('正在切换到$name…');
    var target = await owner.wait(api
        .resolveQuality(previous,
            index: index,
            flag: session.sourceName,
            parseEngine: ref.read(parseEngineProvider),
            parses: owner.config.parses)
        .timeout(const Duration(seconds: 20)));
    if (!owner.isCurrent) return;
    snapshot = _SourcePlaybackSnapshot(ref);
    final tracker = ref.read(playbackHistoryTrackerProvider);
    await tracker.flush();
    if (!owner.isCurrent) return;
    tracker.track(null, flushPrevious: false);
    target = target.copyWith(startPosition: snapshot.position);
    final engine = ref.read(playerEngineProvider);
    final loader = PlaybackSourceLoader(
        engine: engine,
        open: (s) =>
            snapshot!.open(engine, s, ownsPlayback: () => owner.ownsPlayback));
    opened = true;
    try {
      await loader.load(target, isCurrent: () => owner.isCurrent);
    } catch (error) {
      if (!owner.isCurrent || !isExpiredPlaybackUrl(error)) rethrow;
      owner.status('地址已过期，正在刷新$name…');
      target = await owner.wait(api
          .resolvePlayback(session.site,
              id: session.episodes[session.index].url,
              flag: session.sourceName,
              preferredQualityName: name,
              parseEngine: ref.read(parseEngineProvider),
              parses: owner.config.parses)
          .timeout(const Duration(seconds: 20)));
      // A removed quality must not silently become a different selection.
      if (target.qualities.isEmpty ||
          target.qualities[target.qualityIndex].name != name) {
        throw const PlaybackSourceFailure('原清晰度已不可用');
      }
      if (!owner.isCurrent) throw const PlaybackSourceCancelled();
      target = target.copyWith(
          title: previous.title, startPosition: snapshot.position);
      await loader.load(target, isCurrent: () => owner.isCurrent);
    }
    if (!owner.isCurrent) throw const PlaybackSourceCancelled();
    ref.read(activePlaySpecProvider.notifier).state = target;
    snapshot.resumeTracking(ref);
    final siteKey = session.site?.key;
    if (siteKey != null) {
      ref.read(playbackQualityPreferencesProvider.notifier).state = {
        ...ref.read(playbackQualityPreferencesProvider),
        siteKey: name,
      };
    }
    final recordId = snapshot.recordId;
    if (recordId != null) {
      unawaited(ref.read(configRepositoryProvider).updateHistorySource(recordId,
          sourceName: session.sourceName,
          playUrl: target.url,
          episodeUrl: session.episodes[session.index].url));
    }
    ref.read(lineSwitchNoticeProvider.notifier).state = '已切换到$name';
  } catch (error) {
    if (owner.ownsPlayback) {
      ref.read(lineSwitchNoticeProvider.notifier).state =
          error is PlaybackSourceCancelled ? '已取消切换' : '清晰度切换失败';
      if (opened && snapshot != null) await snapshot.restore(ref, owner);
    }
  } finally {
    owner.dispose();
  }
}

PlaybackSession? _sourceSearchContext(Ref ref) {
  final pending = ref.read(pendingPlayProvider);
  if (ref.read(playbackIntentProvider)?.isFailed == true && pending != null) {
    final selection = pending.selection;
    return PlaybackSession(
        item: pending.item,
        sourceName: selection.sourceName,
        episodes: selection.episodes,
        index: selection.index,
        site: pending.site ?? ref.read(configRepositoryProvider).selectedSite,
        sources: selection.sources,
        sourceIndex: selection.sourceIndex);
  }
  return ref.read(activePlaybackSessionProvider);
}

Future<void> _switchPlaybackSource(
    Ref ref, PlaybackSourceChooser choose) async {
  if (_sourceChangeBlocked(ref)) return;
  final session = _sourceSearchContext(ref);
  if (session == null ||
      session.site == null ||
      session.episodes.isEmpty ||
      ref.read(liveRuntimeProvider) != null &&
          _isLivePage(ref.read(activePlaySpecProvider),
              ref.read(liveRuntimeProvider))) {
    return;
  }
  final owner = _SourceChangeOwner(ref, PlaybackSourceChangeKind.source);
  _SourcePlaybackSnapshot? snapshot;
  var opened = false;
  try {
    owner.status('正在其他站点查找同片同集…');
    final result = await CrossSiteSearchService(
            searchEngine: ref.read(searchEngineProvider),
            siteApi: ref.read(siteApiProvider))
        .search(
            target: CrossSiteTarget(
                item: session.item,
                episodeName: session.episodes[session.index].name,
                episodeCount: session.episodes.length,
                siteKey: session.site!.key),
            sites: owner.config.sites,
            cancelToken: owner.cancelToken);
    if (!owner.isCurrent) return;
    final candidates = result.candidates;
    if (candidates.isEmpty) {
      ref.read(lineSwitchNoticeProvider.notifier).state =
          result.status == CrossSiteSearchStatus.timedOut
              ? '查找超时，当前播放已保留，请稍后重试'
              : result.status == CrossSiteSearchStatus.failed
                  ? '站点查找失败，当前播放已保留'
                  : '没有找到可信的同片同集，当前播放已保留';
      return;
    }
    CrossSiteCandidate? candidate;
    if (candidates.length == 1 &&
        candidates.single.confidence == CrossSiteConfidence.high) {
      candidate = candidates.single;
    } else {
      owner.status('请选择播放来源');
      // Cancellation does not wait for an unanswered dialog.
      final cancelled = Completer<CrossSiteCandidate?>();
      owner.cancelToken.onCancel(() {
        if (!cancelled.isCompleted) cancelled.complete(null);
      });
      candidate = await Future.any([choose(candidates), cancelled.future]);
    }
    if (!owner.isCurrent || candidate == null) return;
    owner.status('正在解析${candidate.site.name}…');
    var target = await owner.wait(ref
        .read(siteApiProvider)
        .resolvePlayback(candidate.site,
            id: candidate.episodeMatch.episode.url,
            flag: candidate.source.name,
            preferredQualityName: ref
                .read(playbackQualityPreferencesProvider)[candidate.site.key],
            parseEngine: ref.read(parseEngineProvider),
            parses: owner.config.parses)
        .timeout(const Duration(seconds: 20)));
    if (!owner.isCurrent) return;
    snapshot = _SourcePlaybackSnapshot(ref);
    // An unrelated old video can still sit behind an initial preparation error.
    // Only carry the actual target's playhead into the new site.
    final continuing =
        identical(session, ref.read(activePlaybackSessionProvider));
    final position = continuing ? snapshot.position : Duration.zero;
    target = target.copyWith(
        title:
            '${candidate.item.name} - ${candidate.episodeName} (${candidate.source.name})',
        startPosition: position);
    final tracker = ref.read(playbackHistoryTrackerProvider);
    await tracker.flush();
    if (!owner.isCurrent) return;
    tracker.track(null, flushPrevious: false);
    owner.status('正在启动${candidate.site.name}…');
    final engine = ref.read(playerEngineProvider);
    opened = true;
    await PlaybackSourceLoader(
            engine: engine,
            open: (s) => snapshot!
                .open(engine, s, ownsPlayback: () => owner.ownsPlayback))
        .load(target, isCurrent: () => owner.isCurrent);
    if (!owner.isCurrent) throw const PlaybackSourceCancelled();
    final item = candidate.item;
    final recordId =
        '${candidate.site.key}::${HistoryRecord.buildId(item.id, candidate.episodeName)}';
    final record = HistoryRecord(
        id: recordId,
        vodId: item.id,
        vodName: item.name,
        vodPic: item.pic,
        episodeName: candidate.episodeName,
        sourceName: candidate.source.name,
        playUrl: target.url,
        episodeUrl: candidate.episodeMatch.episode.url,
        siteKey: candidate.site.key,
        siteName: candidate.site.name,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        positionMs: position.inMilliseconds,
        durationMs: engine.duration.inMilliseconds);
    // addHistory updates memory synchronously. A disk error cannot undo a
    // successful media load or turn a candidate into a false playback failure.
    unawaited(ref
        .read(configRepositoryProvider)
        .addHistory(record)
        .catchError((Object _) {}));
    ref.read(activePlaySpecProvider.notifier).state = target;
    ref.read(activePlaybackSessionProvider.notifier).state = PlaybackSession(
        item: item,
        sourceName: candidate.source.name,
        episodes: candidate.source.episodes,
        index: candidate.episodeMatch.episodeIndex,
        site: candidate.site,
        sources: candidate.detail.sources,
        sourceIndex: candidate.sourceIndex,
        triedLines: {
          lineSwitchKey(candidate.sourceIndex, candidate.source.name)
        });
    ref.read(episodeBrowseSourceIndexProvider.notifier).state = null;
    tracker.track(recordId,
        flushPrevious: false,
        baseline: position,
        floor: position > Duration.zero ? position : null);
    _playPreparationEpoch++;
    ref.read(pendingPlayProvider.notifier).state = null;
    ref.read(playbackIntentProvider.notifier).state = null;
    ref.read(lineSwitchNoticeProvider.notifier).state =
        '已换到「${candidate.site.name}」 · ${candidate.episodeName}';
  } catch (error) {
    if (owner.ownsPlayback) {
      ref.read(lineSwitchNoticeProvider.notifier).state =
          error is PlaybackSourceCancelled ? '已取消换源' : '换源失败，当前会话已保留';
      if (opened && snapshot != null) await snapshot.restore(ref, owner);
    }
  } finally {
    owner.dispose();
  }
}

Future<CrossSiteCandidate?> _choosePlaybackSource(BuildContext context,
    WidgetRef ref, List<CrossSiteCandidate> candidates) async {
  final token = ref.read(playbackSourceChangeProvider)?.cancelToken;
  final navigator = Navigator.of(context, rootNavigator: true);
  final route = DialogRoute<CrossSiteCandidate>(
      context: context,
      builder: (dialogContext) => AlertDialog(
            title: const Text('选择播放来源'),
            content: SizedBox(
                width: 440,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  for (final candidate in candidates)
                    ListTile(
                      title: Text(
                          '${candidate.site.name} · ${candidate.item.name}'),
                      subtitle: Text(
                          '${candidate.source.name} · ${candidate.episodeName}'
                          '${candidate.item.year?.isNotEmpty == true ? ' · ${candidate.item.year}' : ''}'
                          '\n${candidate.confidence == CrossSiteConfidence.high ? '匹配度高' : '请确认同片同集'}'),
                      onTap: () => Navigator.of(dialogContext).pop(candidate),
                    ),
                ])),
            actions: [
              TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('取消'))
            ],
          ));
  token?.onCancel(() {
    if (route.isActive) navigator.removeRoute(route);
  });
  return navigator.push(route);
}
