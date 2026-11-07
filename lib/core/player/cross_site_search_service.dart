import 'dart:async';
import 'dart:developer' as developer;

import '../api/models/vod_models.dart';
import '../api/search_cancel_token.dart';
import '../api/search_engine.dart';
import '../api/site_api.dart';
import '../config/models/vod_config.dart';
import 'cross_site_failover_planner.dart';

/// Matches [SearchEngine.searchAllIncremental], including request cancellation.
typedef CrossSiteSearchLoader = Stream<SearchBatch> Function(
  List<Site> sites,
  String keyword, {
  SearchCancelToken? cancelToken,
});

/// Matches [SiteApi.fetchDetail]; its in-flight I/O cannot currently be cancelled.
typedef CrossSiteDetailLoader = Future<VodDetail?> Function(
  Site site, {
  required String vodId,
});

enum CrossSiteSearchStatus { completed, cancelled, timedOut, failed }

/// A timeout may retain verified candidates. Cancellation always discards them.
class CrossSiteSearchResult {
  CrossSiteSearchResult({
    required this.status,
    List<CrossSiteCandidate> candidates = const <CrossSiteCandidate>[],
    this.searchedSiteCount = 0,
    this.detailProbeCount = 0,
    this.searchTimedOut = false,
    this.detailTimeoutCount = 0,
    this.searchErrorCount = 0,
    this.detailErrorCount = 0,
  }) : candidates = List<CrossSiteCandidate>.unmodifiable(candidates);

  final CrossSiteSearchStatus status;
  final List<CrossSiteCandidate> candidates;

  /// Sites handed to the search engine; queued requests may never start.
  final int searchedSiteCount;
  final int detailProbeCount;
  final bool searchTimedOut;
  final int detailTimeoutCount;
  final int searchErrorCount;
  final int detailErrorCount;
}

/// Explicit, user-requested cross-site lookup. Construction performs no I/O.
///
/// The host calls [search] only after a source-switch click and cancels its token
/// on exit, episode/configuration changes, or a replacement request. This service
/// has no playback, history, or application-state side effects.
class CrossSiteSearchService {
  CrossSiteSearchService({
    required SearchEngine searchEngine,
    required SiteApi siteApi,
  }) : this.withLoaders(
          search: searchEngine.searchAllIncremental,
          detail: siteApi.fetchDetail,
        );

  CrossSiteSearchService.withLoaders({
    required CrossSiteSearchLoader search,
    required CrossSiteDetailLoader detail,
  })  : _search = search,
        _detail = detail;

  static const Duration searchBudget = Duration(seconds: 8);
  static const Duration detailTimeout = Duration(seconds: 8);

  final CrossSiteSearchLoader _search;
  final CrossSiteDetailLoader _detail;

  /// Searches up to eight configured sites, then probes at most three details
  /// concurrently. Missing current-site/title/episode context performs no I/O.
  Future<CrossSiteSearchResult> search({
    required CrossSiteTarget target,
    required List<Site> sites,
    required SearchCancelToken cancelToken,
    Set<String> visitedSiteKeys = const <String>{},
  }) async {
    if (cancelToken.isCancelled) {
      return CrossSiteSearchResult(status: CrossSiteSearchStatus.cancelled);
    }
    final currentSiteKey = target.siteKey ?? target.item.siteKey;
    if (currentSiteKey == null ||
        currentSiteKey.trim().isEmpty ||
        !target.identity.isValid ||
        target.episodeName.trim().isEmpty) {
      return CrossSiteSearchResult(status: CrossSiteSearchStatus.completed);
    }

    final configured = List<Site>.of(sites);
    final visited = Set<String>.of(visitedSiteKeys);
    final configIndices = <String, int>{};
    final distinctSites = <Site>[];
    for (var index = 0; index < configured.length; index++) {
      final site = configured[index];
      if (site.key.trim().isEmpty || configIndices.containsKey(site.key)) {
        continue;
      }
      configIndices[site.key] = index;
      distinctSites.add(site);
    }
    final selected = buildCrossSiteSiteList(
      sites: distinctSites,
      currentSiteKey: currentSiteKey,
      visitedSiteKeys: visited,
    );
    if (selected.isEmpty) {
      return CrossSiteSearchResult(status: CrossSiteSearchStatus.completed);
    }

    final cancellation = Completer<void>();
    cancelToken.onCancel(() {
      if (!cancellation.isCompleted) cancellation.complete();
    });
    try {
      final collected = await _collectSearch(
        target: target,
        sites: selected,
        configIndices: configIndices,
        cancelToken: cancelToken,
        cancellation: cancellation.future,
      );
      final hits = collected.hits;
      hits.sort((left, right) {
        final score = right.score.compareTo(left.score);
        if (score != 0) return score;
        final config = left.configIndex.compareTo(right.configIndex);
        return config != 0 ? config : left.order.compareTo(right.order);
      });
      final shortlist = hits.take(maxCrossSiteCandidateCount).toList();
      final probes = <Future<_DetailOutcome>>[];
      for (final hit in shortlist) {
        if (cancelToken.isCancelled) break;
        probes.add(_probeDetail(hit, cancellation.future));
      }
      final outcomes = await Future.wait(probes);
      final candidates = <CrossSiteCandidate>[];
      var detailTimeoutCount = 0;
      var detailErrorCount = 0;
      for (var index = 0; index < outcomes.length; index++) {
        final outcome = outcomes[index];
        if (outcome.timedOut) detailTimeoutCount++;
        if (outcome.failed) detailErrorCount++;
        if (cancelToken.isCancelled || outcome.detail == null) continue;
        final hit = shortlist[index];
        final detail = outcome.detail!;
        if (detail.item.id.trim().isEmpty ||
            (detail.item.action?.trim().isNotEmpty ?? false)) {
          continue;
        }
        final candidate = planCrossSiteCandidate(
          target: target,
          site: hit.site,
          detail: VodDetail(
            item: detail.item.copyWith(
              siteKey: hit.site.key,
              siteName: hit.site.name,
            ),
            sources: detail.sources,
          ),
          configIndex: hit.configIndex,
          currentSiteKey: currentSiteKey,
          visitedSiteKeys: visited,
        );
        if (candidate != null) candidates.add(candidate);
      }
      final status = cancelToken.isCancelled
          ? CrossSiteSearchStatus.cancelled
          : collected.timedOut || detailTimeoutCount > 0
              ? CrossSiteSearchStatus.timedOut
              : candidates.isEmpty &&
                      (collected.errorCount > 0 || detailErrorCount > 0)
                  ? CrossSiteSearchStatus.failed
                  : CrossSiteSearchStatus.completed;
      return CrossSiteSearchResult(
        status: status,
        candidates: cancelToken.isCancelled
            ? const <CrossSiteCandidate>[]
            : rankCrossSiteCandidates(candidates),
        searchedSiteCount: selected.length,
        detailProbeCount: probes.length,
        searchTimedOut: collected.timedOut,
        detailTimeoutCount: detailTimeoutCount,
        searchErrorCount: collected.errorCount,
        detailErrorCount: detailErrorCount,
      );
    } finally {
      if (!cancellation.isCompleted) cancellation.complete();
    }
  }

  Future<_SearchCollection> _collectSearch({
    required CrossSiteTarget target,
    required List<Site> sites,
    required Map<String, int> configIndices,
    required SearchCancelToken cancelToken,
    required Future<void> cancellation,
  }) {
    final completion = Completer<_SearchCollection>();
    final stopwatch = Stopwatch()..start();
    final childToken = SearchCancelToken();
    final byKey = {for (final site in sites) site.key: site};
    final hits = <(String, String), _SearchHit>{};
    var order = 0;
    var errorCount = 0;
    Timer? timer;
    StreamSubscription<SearchBatch>? subscription;

    void finish({bool timedOut = false}) {
      if (completion.isCompleted) return;
      timer?.cancel();
      stopwatch.stop();
      completion.complete(_SearchCollection(
        hits.values.toList(),
        timedOut: timedOut || stopwatch.elapsed >= searchBudget,
        errorCount: errorCount,
      ));
      try {
        childToken.cancel();
      } catch (error, stack) {
        _reportCleanupError(error, stack);
      }
      final active = subscription;
      if (active != null) unawaited(_cancelSubscription(active));
    }

    cancellation.then((_) => finish());
    timer = Timer(searchBudget, () => finish(timedOut: true));
    if (cancelToken.isCancelled) {
      finish();
      return completion.future;
    }
    try {
      final stream = _search(
        sites,
        target.item.name.trim(),
        cancelToken: childToken,
      );
      if (cancelToken.isCancelled) {
        finish();
        return completion.future;
      }
      subscription = stream.listen(
        (batch) {
          if (completion.isCompleted) return;
          if (cancelToken.isCancelled || stopwatch.elapsed >= searchBudget) {
            finish();
            return;
          }
          final site = byKey[batch.site.key];
          if (site == null) return;
          if (batch.error != null) {
            errorCount++;
            return;
          }
          for (final item in batch.items) {
            if (stopwatch.elapsed >= searchBudget) {
              finish();
              return;
            }
            if (!_matchesSearchItem(target, item)) continue;
            final score = scoreCrossSiteMatch(
              target: target.item,
              candidate: item,
              targetEpisodeName: target.episodeName,
              targetEpisodeCount: target.episodeCount,
              candidateEpisodeCount: 0,
            ).score;
            if (stopwatch.elapsed >= searchBudget) {
              finish();
              return;
            }
            final key = (site.key, item.id);
            final previous = hits[key];
            if (previous != null && previous.score >= score) continue;
            hits[key] = _SearchHit(
              site: site,
              item: item,
              configIndex: configIndices[site.key]!,
              score: score,
              order: previous?.order ?? order++,
            );
          }
        },
        onError: (Object error, StackTrace stack) {
          if (completion.isCompleted) return;
          if (stopwatch.elapsed < searchBudget) errorCount++;
          finish();
        },
        onDone: finish,
      );
      final active = subscription;
      if (completion.isCompleted) {
        unawaited(_cancelSubscription(active));
      }
    } catch (_) {
      if (!completion.isCompleted) {
        if (stopwatch.elapsed < searchBudget) errorCount++;
        finish();
      }
    }
    return completion.future;
  }

  Future<_DetailOutcome> _probeDetail(
    _SearchHit hit,
    Future<void> cancellation,
  ) {
    final completion = Completer<_DetailOutcome>();
    final stopwatch = Stopwatch()..start();
    late final Timer timer;
    void finish(_DetailOutcome outcome) {
      if (completion.isCompleted) return;
      timer.cancel();
      stopwatch.stop();
      // Futures can run before an overdue timer when the event loop was busy.
      completion.complete(stopwatch.elapsed >= detailTimeout
          ? const _DetailOutcome(timedOut: true)
          : outcome);
    }

    timer = Timer(detailTimeout, () {
      finish(const _DetailOutcome(timedOut: true));
    });
    cancellation.then((_) => finish(const _DetailOutcome()));
    Future<VodDetail?>.sync(() => _detail(hit.site, vodId: hit.item.id)).then(
      (detail) => finish(_DetailOutcome(detail: detail)),
      onError: (Object error, StackTrace stack) {
        finish(const _DetailOutcome(failed: true));
      },
    );
    return completion.future;
  }
}

bool _matchesSearchItem(CrossSiteTarget target, VodItem item) {
  if (item.id.trim().isEmpty ||
      (item.action?.trim().isNotEmpty ?? false) ||
      containsCrossSiteContentMarker(item.name) ||
      !parseCrossSiteTitle(item.name).matches(target.identity)) {
    return false;
  }
  final year = parseCrossSiteYear(item.year);
  if (target.year != null && year != null && target.year != year) return false;
  final type = inferCrossSiteCoarseType(item.typeName);
  return target.coarseType == null || type == null || target.coarseType == type;
}

Future<void> _cancelSubscription(
    StreamSubscription<SearchBatch> subscription) async {
  try {
    await subscription.cancel();
  } catch (error, stack) {
    _reportCleanupError(error, stack);
  }
}

void _reportCleanupError(Object error, StackTrace stack) {
  developer.log(
    'Cross-site search cleanup failed',
    name: 'CrossSiteSearchService',
    error: error,
    stackTrace: stack,
  );
}

class _SearchHit {
  const _SearchHit({
    required this.site,
    required this.item,
    required this.configIndex,
    required this.score,
    required this.order,
  });

  final Site site;
  final VodItem item;
  final int configIndex;
  final int score;
  final int order;
}

class _SearchCollection {
  const _SearchCollection(
    this.hits, {
    required this.timedOut,
    required this.errorCount,
  });

  final List<_SearchHit> hits;
  final bool timedOut;
  final int errorCount;
}

class _DetailOutcome {
  const _DetailOutcome(
      {this.detail, this.timedOut = false, this.failed = false});

  final VodDetail? detail;
  final bool timedOut;
  final bool failed;
}
