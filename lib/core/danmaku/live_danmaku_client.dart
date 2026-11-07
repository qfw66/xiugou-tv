import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'live_danmaku_models.dart';

/// Owns one companion subscription independently of the player's media clock.
class LiveDanmakuClient extends ChangeNotifier {
  LiveDanmakuClient({Dio? dio, void Function()? onActivity})
      : _dio = dio ?? Dio(),
        _ownsDio = dio == null,
        _onActivity = onActivity;

  final Dio _dio;
  final bool _ownsDio;
  final void Function()? _onActivity;
  final StreamController<List<LiveDanmakuMessage>> _messages =
      StreamController<List<LiveDanmakuMessage>>.broadcast();

  LiveDanmakuStatus _status = LiveDanmakuStatus.idle;
  String? _error;
  int _dropped = 0;
  int _version = 0;
  int _pendingStarts = 0;
  int _pendingStops = 0;
  bool _disposed = false;
  bool _dioClosed = false;
  _Subscription? _subscription;

  Stream<List<LiveDanmakuMessage>> get messages => _messages.stream;
  LiveDanmakuStatus get status => _status;
  String? get error => _error;
  int get dropped => _dropped;

  Future<void> start(String url) async {
    final version = ++_version;
    final previous = _detach();
    if (previous != null) unawaited(_closeSubscription(previous));
    if (_disposed) return;

    final origin = _startUri(url);
    if (origin == null) {
      _publish(LiveDanmakuStatus.error,
          error: 'Invalid live danmaku start URL.', dropped: 0);
      return;
    }
    _publish(LiveDanmakuStatus.connecting, dropped: 0);
    if (!_current(version)) return;

    _pendingStarts++;
    Uri? stopUrl;
    var attached = false;
    try {
      // invariant: start survives replacement so its acquired handle can be closed.
      final response = await _request(origin, 'POST');
      if (response.statusCode != 200) {
        throw const FormatException('Start response was not successful.');
      }
      final body = _object(response.data);
      stopUrl = _endpoint(body['stopUrl'], origin, 'stop');
      final eventsUrl = _endpoint(body['eventsUrl'], origin, 'events');
      final id = body['subscriptionId'];
      final generation = body['generation'];
      final cursor = body['cursor'];
      if (stopUrl == null ||
          eventsUrl == null ||
          id is! String ||
          id.isEmpty ||
          id.length > 512 ||
          generation is! String ||
          generation.length != 32 ||
          !RegExp(r'^[0-9a-f]{32}$').hasMatch(generation) ||
          cursor is! int ||
          cursor < 0) {
        throw const FormatException('Invalid subscription response.');
      }
      final subscription = _Subscription(
        id: id,
        generation: generation,
        cursor: cursor,
        eventsUrl: eventsUrl,
        stopUrl: stopUrl,
      );
      if (!_current(version)) {
        await _closeSubscription(subscription);
        return;
      }
      _subscription = subscription;
      attached = true;
      _applyState(body['state']);
      if (_active(subscription, version)) {
        unawaited(_poll(subscription, version));
      }
    } catch (_) {
      if (stopUrl != null && !attached) await _postStop(stopUrl);
      if (_current(version)) {
        _publish(LiveDanmakuStatus.error,
            error: 'Unable to start live danmaku.');
      }
    } finally {
      _pendingStarts--;
      _closeOwnedDioIfUnused();
    }
  }

  Future<void> stop() async {
    ++_version;
    final previous = _detach();
    final cleanup = previous == null ? null : _closeSubscription(previous);
    if (!_disposed) _publish(LiveDanmakuStatus.closed);
    if (cleanup != null) await cleanup;
  }

  @override
  void dispose() {
    ++_version;
    if (_disposed) return;
    _disposed = true;
    final previous = _detach();
    _status = LiveDanmakuStatus.closed;
    _error = null;
    if (previous != null) unawaited(_closeSubscription(previous));
    unawaited(_messages.close());
    _closeOwnedDioIfUnused();
    super.dispose();
  }

  bool _current(int version) => !_disposed && version == _version;

  bool _active(_Subscription subscription, int version) =>
      _current(version) && identical(subscription, _subscription);

  _Subscription? _detach() {
    final previous = _subscription;
    _subscription = null;
    previous?.cancel();
    return previous;
  }

  Future<void> _poll(_Subscription subscription, int version) async {
    var failures = 0;
    while (_active(subscription, version)) {
      final elapsed = Stopwatch()..start();
      final token = CancelToken();
      subscription.pollToken = token;
      try {
        final url = subscription.eventsUrl.replace(queryParameters: {
          ...subscription.eventsUrl.queryParametersAll,
          'after': ['${subscription.cursor}'],
          'wait': ['20000'],
        });
        final response = await _request(url, 'GET', cancelToken: token);
        if (!_active(subscription, version)) return;
        if (response.statusCode == 404) {
          _terminate(subscription, version, LiveDanmakuStatus.closed);
          return;
        }
        if (response.statusCode != 200) {
          throw _HttpFailure(response.statusCode ?? 0);
        }
        final body = _object(response.data);
        final cursor = body['cursor'];
        final events = body['events'];
        final dropped = body['dropped'];
        final closed = body['closed'];
        if (body['subscriptionId'] != subscription.id ||
            body['generation'] is! String ||
            body['generation'] != subscription.generation ||
            cursor is! int ||
            cursor < subscription.cursor ||
            events is! List ||
            dropped is! int ||
            dropped < 0 ||
            closed is! bool) {
          throw const FormatException('Invalid subscription poll response.');
        }

        final previousCursor = subscription.cursor;
        final unique = <int, Map>{};
        for (final event in events.take(256)) {
          if (event is! Map) continue;
          final seq = event['seq'];
          final item = event['item'];
          if (seq is int &&
              seq > previousCursor &&
              seq <= cursor &&
              item is Map) {
            unique.putIfAbsent(seq, () => item);
          }
        }
        final ordered = unique.entries.toList()
          ..sort((a, b) => a.key.compareTo(b.key));
        final batch = <LiveDanmakuMessage>[];
        subscription.cursor = cursor;
        for (final event in ordered) {
          if (event.value.containsKey('state')) {
            _applyState(event.value);
            if (!_active(subscription, version)) return;
          } else {
            final message = _message(event.key, event.value);
            if (message != null) batch.add(message);
          }
        }
        _applyState(body['state']);
        if (!_active(subscription, version)) return;
        _publish(_status,
            error: _error, dropped: dropped > _dropped ? dropped : _dropped);
        if (!_active(subscription, version)) return;
        _activity();
        if (!_active(subscription, version)) return;
        if (batch.isNotEmpty) {
          _messages.add(List<LiveDanmakuMessage>.unmodifiable(batch));
        }
        failures = 0;
        if (closed) {
          _terminate(
              subscription,
              version,
              _status == LiveDanmakuStatus.error
                  ? LiveDanmakuStatus.error
                  : LiveDanmakuStatus.closed,
              error: _status == LiveDanmakuStatus.error ? _error : null);
          return;
        }
        const minimumEmptyPoll = Duration(milliseconds: 100);
        if (cursor == previousCursor && elapsed.elapsed < minimumEmptyPoll) {
          await subscription.pause(minimumEmptyPoll - elapsed.elapsed);
        }
      } catch (failure) {
        if (!_active(subscription, version)) return;
        if (!_transient(failure) || ++failures >= 5) {
          _terminate(subscription, version, LiveDanmakuStatus.error,
              error: failure is FormatException
                  ? 'Invalid live danmaku response.'
                  : 'Live danmaku connection failed.');
          return;
        }
        _publish(LiveDanmakuStatus.retrying,
            error: 'Live danmaku connection interrupted.');
        if (!_active(subscription, version)) return;
        await subscription
            .pause(Duration(milliseconds: 250 * (1 << (failures - 1))));
      } finally {
        if (identical(subscription.pollToken, token)) {
          subscription.pollToken = null;
        }
      }
    }
  }

  void _terminate(
      _Subscription subscription, int version, LiveDanmakuStatus status,
      {String? error}) {
    if (!_active(subscription, version)) return;
    _detach();
    unawaited(_closeSubscription(subscription));
    _publish(status, error: error);
  }

  void _publish(LiveDanmakuStatus status, {String? error, int? dropped}) {
    if (_disposed) return;
    final nextDropped = dropped ?? _dropped;
    if (_status == status && _error == error && _dropped == nextDropped) return;
    _status = status;
    _error = error;
    _dropped = nextDropped;
    notifyListeners();
  }

  void _applyState(Object? raw) {
    if (raw is! Map) return;
    final state = switch (raw['state']) {
      'connecting' => LiveDanmakuStatus.connecting,
      'ready' => LiveDanmakuStatus.ready,
      'retrying' => LiveDanmakuStatus.retrying,
      'error' => LiveDanmakuStatus.error,
      _ => null,
    };
    if (state == null) return;
    final message = raw['msg'];
    _publish(state,
        error: state == LiveDanmakuStatus.error ||
                state == LiveDanmakuStatus.retrying
            ? message is String && message.trim().isNotEmpty
                ? _boundedText(message)
                : state == LiveDanmakuStatus.error
                    ? 'Live danmaku upstream failed.'
                    : null
            : null);
  }

  void _activity() {
    try {
      _onActivity?.call();
    } catch (error, stack) {
      FlutterError.reportError(FlutterErrorDetails(
        exception: error,
        stack: stack,
        library: 'live danmaku',
        context: ErrorDescription('while reporting companion activity'),
      ));
    }
  }

  Future<Response<Object?>> _request(Uri url, String method,
      {CancelToken? cancelToken,
      Duration timeout = const Duration(seconds: 30)}) {
    final token = cancelToken ?? CancelToken();
    return _dio
        .requestUri<Object?>(url,
            cancelToken: token,
            options: Options(
              method: method,
              responseType: ResponseType.json,
              followRedirects: false,
              maxRedirects: 0,
              validateStatus: (_) => true,
              sendTimeout: const Duration(seconds: 5),
              receiveTimeout: timeout,
            ))
        .timeout(timeout, onTimeout: () {
      token.cancel('Live danmaku request deadline.');
      throw TimeoutException('Live danmaku request deadline.', timeout);
    });
  }

  Future<void> _closeSubscription(_Subscription subscription) =>
      subscription.stopRequest ??= _postStop(subscription.stopUrl);

  Future<void> _postStop(Uri url) async {
    _pendingStops++;
    try {
      final response =
          await _request(url, 'POST', timeout: const Duration(seconds: 5));
      if (response.statusCode != 200 && response.statusCode != 404) {
        debugPrint('Live danmaku cleanup will use the companion lease expiry.');
      }
    } catch (_) {
      // invariant: the companion's 60-second lease bounds failed remote cleanup.
      debugPrint('Live danmaku cleanup will use the companion lease expiry.');
    } finally {
      _pendingStops--;
      _closeOwnedDioIfUnused();
    }
  }

  void _closeOwnedDioIfUnused() {
    if (_disposed &&
        _ownsDio &&
        !_dioClosed &&
        _pendingStarts == 0 &&
        _pendingStops == 0) {
      _dioClosed = true;
      _dio.close(force: true);
    }
  }

  static Uri? _startUri(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        uri.scheme != 'http' ||
        !const {'127.0.0.1', 'localhost', '::1', '[::1]'}.contains(uri.host) ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        uri.path != '/script-danmaku/start') {
      return null;
    }
    return uri;
  }

  static Uri? _endpoint(Object? raw, Uri origin, String action) {
    if (raw is! String) return null;
    final uri = Uri.tryParse(raw);
    if (uri == null ||
        uri.scheme != origin.scheme ||
        uri.host != origin.host ||
        uri.port != origin.port ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        uri.path != '/script-danmaku/$action') {
      return null;
    }
    return uri;
  }

  static Map _object(Object? raw) {
    final decoded = raw is String ? jsonDecode(raw) : raw;
    if (decoded is! Map) throw const FormatException('Expected a JSON object.');
    return decoded;
  }

  static bool _transient(Object failure) {
    if (failure is TimeoutException) return true;
    if (failure is _HttpFailure) {
      return failure.status == 408 ||
          failure.status == 429 ||
          failure.status >= 500 && failure.status < 600;
    }
    if (failure is! DioException || failure.error is FormatException) {
      return false;
    }
    return switch (failure.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout ||
      DioExceptionType.connectionError ||
      DioExceptionType.unknown =>
        true,
      _ => false,
    };
  }

  static LiveDanmakuMessage? _message(int seq, Map item) {
    final text = item['text'];
    if (text is! String || text.trim().isEmpty) return null;
    final colors = <int>[];
    final palette = item['colors'];
    if (palette is List) {
      for (final raw in palette.take(8)) {
        final color = _color(raw);
        if (color != null) colors.add(color);
      }
    }
    return LiveDanmakuMessage(
      seq: seq,
      text: _boundedText(text),
      color: _color(item['color']) ?? 0xFFFFFF,
      colors: List<int>.unmodifiable(colors),
    );
  }

  static String _boundedText(String text) =>
      String.fromCharCodes(text.runes.take(512));

  static int? _color(Object? raw) {
    int? value;
    if (raw is int) {
      value = raw;
    } else if (raw is String && raw.length <= 16) {
      final text = raw.trim();
      if (RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(text)) {
        value = int.tryParse(text.substring(1), radix: 16);
      } else if (RegExp(r'^\d{1,8}$').hasMatch(text)) {
        value = int.tryParse(text);
      }
    }
    return value != null && value >= 0 && value <= 0xFFFFFF ? value : null;
  }
}

class _Subscription {
  _Subscription({
    required this.id,
    required this.generation,
    required this.cursor,
    required this.eventsUrl,
    required this.stopUrl,
  });

  final String id;
  final String generation;
  final Uri eventsUrl;
  final Uri stopUrl;
  int cursor;
  CancelToken? pollToken;
  Future<void>? stopRequest;
  Timer? _timer;
  Completer<void>? _pause;

  Future<void> pause(Duration duration) {
    final pause = Completer<void>();
    _pause = pause;
    _timer = Timer(duration, () {
      _timer = null;
      _pause = null;
      pause.complete();
    });
    return pause.future;
  }

  void cancel() {
    pollToken?.cancel('Live danmaku subscription ended.');
    _timer?.cancel();
    _timer = null;
    _pause?.complete();
    _pause = null;
  }
}

class _HttpFailure implements Exception {
  const _HttpFailure(this.status);

  final int status;
}
