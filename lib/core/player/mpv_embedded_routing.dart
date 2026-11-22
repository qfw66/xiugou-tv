part of 'mpv_player_engine.dart';

// A route owns the open, reads and commands for exactly one backend selection.
// A null backend is also a route: mpv must not be resumed while close is pending.
class _EmbeddedRoute {
  _EmbeddedRoute(this.backend);

  final NativePlaybackBackend? backend;
  final selected = Completer<bool>();
  EmbeddedPlaybackSession? session;
  Timer? poll, deadline;
  bool ready = false, reading = false, ended = false;
  bool sentPaused = true;
  double sentVolume = 0;
  Duration? pendingSeek;
  int revision = 0, writes = 0;
}

const _pollInterval = Duration(milliseconds: 200);
const _frameTimeout = Duration(seconds: 10);

extension _EmbeddedRouting on MpvPlayerEngine {
  bool _owns(_EmbeddedRoute route) => !_disposed && identical(_route, route);

  Future<bool> _selectBackend(
    NativePlaybackBackend? backend,
    EmbeddedPlaybackChannel channel, {
    bool failed = false,
  }) {
    final spec = _currentSpec;
    final old = _route;
    if (_disposed || spec == null || _externalPlaybackPaused) {
      return Future.value(false);
    }
    if (old?.backend == backend) {
      return old?.selected.future ?? Future.value(_mpvOwnsPlayback);
    }
    if (backend != null) {
      final started =
          _status == PlaybackStatus.playing || _status == PlaybackStatus.paused;
      if (old == null && !started) return Future.value(false);
      final input = EmbeddedPlaybackChannel.input(
        spec,
        browserHeaders: playbackSettings.browserHeaders,
      );
      if (input.source == null) return Future.value(false);
    }
    if (old == null) {
      _parkedPosition = _position;
      _parkedDimensions = _dimensions;
    } else if (old.backend == null) {
      // A superseded mpv restore may have already issued a seek or play.
      _parkedPosition = null;
    }
    final route = _EmbeddedRoute(backend)
      ..pendingSeek = old?.pendingSeek
      ..ended = old?.ended ?? _status == PlaybackStatus.completed;
    _sessionEpoch++;
    _cancelLiveReconnect();
    _cancelErrorConfirm();
    cancelSeekRecovery();
    final closing = _retireEmbedded(
      next: route,
      completeOld: !failed,
      trustPosition: !failed,
    );
    if (!_owns(route)) return route.selected.future;
    if (!route.ended) _updateStatus(PlaybackStatus.buffering);
    _publishBackendCapabilities();
    if (backend != null) {
      route.deadline = Timer(_frameTimeout, () => unawaited(_fallback(route)));
    }
    unawaited(_enterBackend(route, closing, spec, channel));
    return route.selected.future;
  }

  // Known sessions (including ones still preparing) are closed immediately.
  // Every subsequent owner shares that fence. An open with no id yet was sent
  // paused; its continuation will close its own id without blocking a new show.
  Future<Duration?>? _retireEmbedded({
    _EmbeddedRoute? next,
    bool completeOld = true,
    bool trustPosition = false,
  }) {
    final old = _route;
    _route = next;
    if (old == null) return _embeddedClosing;
    old.poll?.cancel();
    old.deadline?.cancel();
    if (completeOld && !old.selected.isCompleted) old.selected.complete(false);
    final session = old.session;
    if (session != null) {
      final closing = _releaseSession(
        session,
        trustPosition && old.ready && !old.ended,
      );
      _embeddedClosing = closing;
      unawaited(
        closing.then<void>(
          (_) {
            if (identical(_embeddedClosing, closing)) _embeddedClosing = null;
          },
          onError: (Object _, StackTrace __) {
            // Neither close nor pause was acknowledged: do not start a second audio stream.
          },
        ),
      );
    }
    _embeddedTexture.value = null;
    return _embeddedClosing;
  }

  Future<Duration?> _releaseSession(
    EmbeddedPlaybackSession session,
    bool trustPosition,
  ) async {
    try {
      final last = await session.close();
      return trustPosition ? last : null;
    } on FormatException {
      // The close was acknowledged, but its final timestamp was unreadable.
      return null;
    } catch (_) {
      await session.setPaused(true);
      return null;
    }
  }

  Future<void> _enterBackend(
    _EmbeddedRoute route,
    Future<Duration?>? closing,
    MediaPlaySpec spec,
    EmbeddedPlaybackChannel channel,
  ) async {
    try {
      if (closing != null) {
        final last = await closing;
        if (!_owns(route)) return;
        if (last != null && !last.isNegative) _setBackendPosition(last);
      }
      final backend = route.backend;
      if (backend == null) {
        await _restoreMpv(route);
        return;
      }
      await _player.pause();
      if (!_owns(route)) return;
      route.sentVolume = _volume;
      final start = route.pendingSeek ?? _position;
      route.pendingSeek = null;
      final session = await channel.open(
        backend,
        spec,
        browserHeaders: playbackSettings.browserHeaders,
        position: start,
        volume: route.sentVolume,
        paused: true,
      );
      if (!_owns(route)) {
        await _releaseSession(session, false);
        return;
      }
      route.session = session;
      await _pollEmbedded(route);
    } catch (_) {
      if (!_owns(route)) return;
      if (route.backend != null) {
        await _fallback(route);
      } else {
        _route = null;
        _currentError = '无法恢复 mpv 播放';
        _errorController.add(_currentError);
        _updateStatus(PlaybackStatus.error);
        route.selected.complete(false);
      }
    }
  }

  Future<void> _fallback(_EmbeddedRoute route) async {
    if (!_owns(route)) return;
    _recentLogs.add('[embedded] ${route.backend!.label} 播放未就绪或已中断，返回 mpv');
    await _selectBackend(null, const EmbeddedPlaybackChannel(), failed: true);
    if (!route.selected.isCompleted) route.selected.complete(false);
  }

  Future<void> _restoreMpv(_EmbeddedRoute route) async {
    // Control calls made while closing update intent here, not the parked mpv.
    var at = _parkedPosition;
    double? appliedVolume;
    bool? paused;
    while (_owns(route)) {
      final target = route.pendingSeek ?? _position;
      if (target != at) {
        await _player.seek(target);
        at = target;
        continue;
      }
      if (appliedVolume != _volume) {
        appliedVolume = _volume;
        await _player.setVolume(appliedVolume);
        continue;
      }
      if (paused != (_pauseIntent || route.ended)) {
        paused = _pauseIntent || route.ended;
        await (paused ? _player.pause() : _player.play());
        continue;
      }
      _route = null;
      _volumeNeedsSync = false;
      _setBackendPosition(target);
      _dimensions = _parkedDimensions;
      _dimensionsController.add(_dimensions);
      _publishBackendCapabilities();
      _nativeBuffering = false;
      _updateStatus(
        route.ended
            ? PlaybackStatus.completed
            : _pauseIntent
            ? PlaybackStatus.paused
            : PlaybackStatus.playing,
      );
      route.selected.complete(true);
    }
  }

  void _scheduleEmbeddedRead(
    _EmbeddedRoute route, [
    Duration delay = _pollInterval,
  ]) {
    if (!_owns(route) ||
        route.reading ||
        route.writes != 0 ||
        (route.ended && route.ready)) {
      return;
    }
    route.poll?.cancel();
    route.poll = Timer(delay, () => unawaited(_pollEmbedded(route)));
  }

  Future<void> _pollEmbedded(_EmbeddedRoute route) async {
    if (!_owns(route) || route.reading || route.writes != 0) return;
    route.reading = true;
    final revision = route.revision;
    var delay = _pollInterval;
    route.deadline ??= Timer(_frameTimeout, () => unawaited(_fallback(route)));
    try {
      final session = route.session!;
      final state = await session.read();
      if (!_owns(route) || revision != route.revision || route.writes != 0) {
        return;
      }
      if (state.phase == EmbeddedPhase.failed ||
          !route.ready && state.phase == EmbeddedPhase.ended) {
        await _fallback(route);
        return;
      }
      final ended = state.phase == EmbeddedPhase.ended;
      if (!ended &&
          (state.phase == EmbeddedPhase.loading ||
              state.width <= 0 ||
              state.height <= 0)) {
        _updateStatus(PlaybackStatus.buffering);
        return; // Registration, duration or a requested pause is not a decoded frame.
      }
      if (!route.ready) {
        final target = route.pendingSeek;
        if (target != null) {
          route.pendingSeek = null;
          await session.seek(target);
          delay = Duration.zero;
          return;
        }
        if (route.sentVolume != _volume) {
          route.sentVolume = _volume;
          await session.setVolume(_volume);
          delay = Duration.zero;
          return;
        }
        if (route.sentPaused != (_pauseIntent || route.ended)) {
          route.sentPaused = _pauseIntent || route.ended;
          await session.setPaused(route.sentPaused);
          delay = Duration.zero;
          return; // Read back the new playback phase before exposing the texture.
        }
        if ((state.phase == EmbeddedPhase.paused) != route.sentPaused) return;
        route.ready = true;
      }
      route.deadline?.cancel();
      route.deadline = null;
      route.ended = ended;
      if (state.duration != _duration &&
          (!ended || state.duration > Duration.zero)) {
        _duration = state.duration;
        _durationController.add(_duration);
      }
      if (state.width > 0 &&
          state.height > 0 &&
          (_dimensions.width != state.width ||
              _dimensions.height != state.height)) {
        _dimensions = VideoDimensions(width: state.width, height: state.height);
        _dimensionsController.add(_dimensions);
      }
      _setBackendPosition(
        ended && state.position == Duration.zero
            ? (_duration > Duration.zero ? _duration : _position)
            : state.position,
      );
      _updateStatus(
        ended
            ? PlaybackStatus.completed
            : state.phase == EmbeddedPhase.paused
            ? PlaybackStatus.paused
            : PlaybackStatus.playing,
      );
      _embeddedTexture.value = session;
      if (_owns(route) && !route.selected.isCompleted) {
        route.selected.complete(true);
      }
    } catch (_) {
      if (_owns(route) && revision == route.revision) await _fallback(route);
    } finally {
      route.reading = false;
      _scheduleEmbeddedRead(route, delay);
    }
  }

  void _setBackendPosition(Duration value) {
    if (_position == value) return;
    _position = value;
    _positionController.add(value);
  }

  void _publishBackendCapabilities() {
    _rateController.add(rate);
    _bufferController.add(buffer);
    _audioTracksController.add(audioTracks);
    _subtitleTracksController.add(subtitleTracks);
    _videoTracksController.add(videoTracks);
  }

  Future<void> _embeddedCommand(
    _EmbeddedRoute? route,
    Future<void> Function(EmbeddedPlaybackSession) write,
  ) async {
    if (route == null) return;
    route.revision++;
    if (!route.ready) return;
    route.writes++;
    try {
      await write(route.session!);
    } catch (_) {
      if (_owns(route)) await _fallback(route);
    } finally {
      route.writes--;
      _scheduleEmbeddedRead(route, Duration.zero);
    }
  }

  Future<void> _embeddedPause(bool paused) async {
    final route = _route;
    if (!paused && route != null && route.ended) {
      await _embeddedSeek(Duration.zero);
      if (!_owns(route) || _pauseIntent != paused) return;
    }
    await _embeddedCommand(route, (s) => s.setPaused(paused));
  }

  Future<void> _embeddedSeek(Duration position) async {
    final route = _route;
    if (route == null) return;
    final target = position.isNegative
        ? Duration.zero
        : _duration > Duration.zero && position > _duration
        ? _duration
        : position;
    route.ended = false;
    if (!route.ready) route.pendingSeek = target;
    await _embeddedCommand(route, (s) => s.seek(target));
  }

  Future<void> _embeddedVolume(double value) async {
    _volumeNeedsSync = true;
    _volume = value;
    _volumeController.add(value);
    await _embeddedCommand(_route, (s) => s.setVolume(value));
  }
}
