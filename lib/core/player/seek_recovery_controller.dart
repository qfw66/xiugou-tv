import 'dart:async';

import 'package:flutter/foundation.dart';

enum SeekRecoveryPhase { idle, seeking, failed }

@immutable
class SeekRecoveryState {
  final SeekRecoveryPhase phase;
  final int generation;
  final Duration? originalPosition;
  final Duration? targetPosition;

  const SeekRecoveryState({
    this.phase = SeekRecoveryPhase.idle,
    this.generation = 0,
    this.originalPosition,
    this.targetPosition,
  });

  bool get isRecoverable => phase == SeekRecoveryPhase.failed;
}

/// Optional engine capability; callers without it retain their existing API.
abstract interface class SeekRecoveryCapable {
  ValueListenable<SeekRecoveryState> get seekRecovery;
  Future<void> retrySeek();
  Future<void> returnToPreSeekPosition();
  void cancelSeekRecovery();
}

/// Confirms seek arrival without treating a target preview as playback progress.
class SeekRecoveryController extends ValueNotifier<SeekRecoveryState> {
  final Duration timeout;
  final Duration targetTolerance;
  final Duration progressThreshold;

  SeekRecoveryController({
    this.timeout = const Duration(seconds: 10),
    this.targetTolerance = const Duration(seconds: 2),
    this.progressThreshold = const Duration(milliseconds: 250),
  }) : super(const SeekRecoveryState());

  Timer? _timer;
  Duration? _arrivalPosition;
  bool _disposed = false;

  int begin({
    required Duration originalPosition,
    required Duration targetPosition,
  }) {
    if (_disposed) throw StateError('Seek recovery controller is disposed');
    _timer?.cancel();
    _arrivalPosition = null;
    final generation = value.generation + 1;
    value = SeekRecoveryState(
      phase: SeekRecoveryPhase.seeking,
      generation: generation,
      originalPosition: originalPosition,
      targetPosition: targetPosition,
    );
    _timer = Timer(timeout, () => fail(generation));
    return generation;
  }

  void onPosition(
    Duration position, {
    required int generation,
    required bool isPaused,
    required bool isBuffering,
  }) {
    if (!_isCurrent(generation)) return;
    final target = value.targetPosition!;
    if (isBuffering || (position - target).abs() > targetTolerance) {
      _arrivalPosition = null;
      return;
    }
    if (isPaused) {
      cancel();
      return;
    }
    final arrival = _arrivalPosition;
    if (arrival == null || position < arrival) {
      _arrivalPosition = position;
      return;
    }
    if (position - arrival >= progressThreshold) cancel();
  }

  void fail(int generation) {
    if (!_isCurrent(generation) || value.isRecoverable) return;
    _timer?.cancel();
    _timer = null;
    value = SeekRecoveryState(
      phase: SeekRecoveryPhase.failed,
      generation: generation,
      originalPosition: value.originalPosition,
      targetPosition: value.targetPosition,
    );
  }

  void cancel() {
    if (_disposed) return;
    _timer?.cancel();
    _timer = null;
    _arrivalPosition = null;
    value = SeekRecoveryState(generation: value.generation + 1);
  }

  bool _isCurrent(int generation) =>
      !_disposed &&
      value.generation == generation &&
      value.phase != SeekRecoveryPhase.idle;

  @override
  void dispose() {
    if (_disposed) return;
    cancel();
    _disposed = true;
    super.dispose();
  }
}
