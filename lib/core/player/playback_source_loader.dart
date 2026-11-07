import 'dart:async';

import 'models/player_state.dart';
import 'player_engine.dart';

/// A source is ready only after events from its load reach the requested position.
/// Returning from the native open command alone does not establish playback.
class PlaybackSourceLoader {
  PlaybackSourceLoader({
    required this.engine,
    required this.open,
    this.timeout = const Duration(seconds: 15),
  });

  final PlayerEngine engine;
  final Future<void> Function(MediaPlaySpec spec) open;
  final Duration timeout;

  Future<void> load(MediaPlaySpec spec,
      {required bool Function() isCurrent}) async {
    if (!isCurrent()) throw const PlaybackSourceCancelled();
    final done = Completer<void>();
    var opened = false;
    var duration = Duration.zero;
    Duration? position;
    VideoDimensions? dimensions;
    PlaybackStatus? status;
    final subscriptions = <StreamSubscription<dynamic>>[];
    final start = spec.startPosition ?? Duration.zero;
    final minimum = start > const Duration(seconds: 2)
        ? start - const Duration(seconds: 2)
        : Duration.zero;

    void fail(Object error, [StackTrace? stack]) {
      if (!done.isCompleted) {
        done.completeError(
            isCurrent() ? error : const PlaybackSourceCancelled(), stack);
      }
    }

    void check() {
      if (done.isCompleted) return;
      if (!isCurrent()) {
        fail(const PlaybackSourceCancelled());
        return;
      }
      // currentSpec and all evidence must belong to this load. Never accept a
      // snapshot from the previous video while the open command is in flight.
      if (!opened || !identical(engine.currentSpec, spec)) return;
      final currentPosition = position;
      if (currentPosition == null || currentPosition < minimum) return;
      final hasLiveFrame = spec.isLive &&
          (dimensions?.width ?? 0) > 0 &&
          (dimensions?.height ?? 0) > 0;
      final hasMedia = status == PlaybackStatus.paused
          ? duration > Duration.zero || hasLiveFrame
          : duration > Duration.zero || currentPosition > Duration.zero;
      if (hasMedia &&
          (status == PlaybackStatus.playing || status == PlaybackStatus.paused)) {
        done.complete();
      }
    }

    subscriptions.add(engine.statusStream.listen((value) {
      if (!identical(engine.currentSpec, spec)) return;
      status = value;
      if (value == PlaybackStatus.error) {
        fail(PlaybackSourceFailure(engine.currentError ?? '播放启动失败'));
      } else {
        check();
      }
    }));
    subscriptions.add(engine.positionStream.listen((value) {
      if (!identical(engine.currentSpec, spec)) return;
      position = value;
      check();
    }));
    subscriptions.add(engine.durationStream.listen((value) {
      if (!identical(engine.currentSpec, spec)) return;
      duration = value;
      check();
    }));
    if (spec.isLive) {
      subscriptions.add(engine.dimensionsStream.listen((value) {
        if (!identical(engine.currentSpec, spec)) return;
        dimensions = value;
        check();
      }));
    }
    // Cancellation caused by navigating away also works when the player is not
    // producing events (for example, a stalled network connection).
    final ownerTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!isCurrent()) fail(const PlaybackSourceCancelled());
    });
    final deadline = Timer(timeout, () {
      fail(const PlaybackSourceFailure('播放启动超时'));
    });
    try {
      // Attach error handling before starting open: synchronous native events
      // and a hanging open must both be bounded by the same deadline.
      final observed = done.future;
      unawaited(Future<void>.sync(() => open(spec)).then((_) {
        opened = true;
        check();
      }, onError: (Object error, StackTrace stack) {
        fail(error, stack);
      }));
      await observed;
    } finally {
      deadline.cancel();
      ownerTimer.cancel();
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
    }
  }
}

class PlaybackSourceFailure implements Exception {
  const PlaybackSourceFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

class PlaybackSourceCancelled implements Exception {
  const PlaybackSourceCancelled();
}

/// Expired signed URLs may be refreshed once; unrelated errors must not retry.
bool isExpiredPlaybackUrl(Object error) {
  final message = error.toString().replaceAll(RegExp(r'https?://\S+'), '');
  return RegExp(
    r'\b(?:http(?:/\d(?:\.\d)?)?(?:\s+(?:error|status(?:\s+code)?))?|'
    r'server\s+returned|status(?:\s+code)?)\s*[:=]?\s*(?:403|410)\b',
    caseSensitive: false,
  ).hasMatch(message);
}
