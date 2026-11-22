import 'package:flutter/services.dart';

import 'models/player_state.dart';
import 'playback_http_headers.dart';

enum NativePlaybackBackend {
  mf('Media Foundation'),
  mdk('MDK');

  const NativePlaybackBackend(this.label);
  final String label;
}

class EmbeddedPlaybackChannel {
  const EmbeddedPlaybackChannel({
    this.channel = const MethodChannel('xiugou/native_playback'),
  });
  final MethodChannel channel;

  Future<Set<NativePlaybackBackend>> available() async {
    try {
      final result = await channel.invokeMapMethod<String, Object?>(
        'availability',
      );
      return {
        for (final b in NativePlaybackBackend.values)
          if (result?[b.name] == true) b,
      };
    } on MissingPluginException {
      return {};
    } on PlatformException {
      return {};
    }
  }

  static ({String? source, String? reason}) input(
    MediaPlaySpec spec, {
    required bool browserHeaders,
  }) {
    if (spec.isLive) return (source: null, reason: '直播继续使用 mpv');
    if (spec.subtitles.isNotEmpty) {
      return (source: null, reason: '此节目有外挂字幕，继续使用 mpv');
    }
    final raw = spec.url.trim();
    const invalid = (source: null, reason: '仅支持本机视频文件或普通 HTTP(S) 视频直链');
    if (raw.isEmpty || RegExp(r'[\x00-\x1f\x7f]').hasMatch(raw)) return invalid;
    if (withBrowserHeaderFallbacks(
          spec.headers,
          raw,
          enabled: browserHeaders,
        )?.isNotEmpty ==
        true) {
      return (source: null, reason: '此地址需要请求头，继续使用 mpv');
    }
    final drivePath = RegExp(r'^[A-Za-z]:[\\/]');
    final uri = Uri.tryParse(raw);
    if (uri != null &&
        uri.hasQuery &&
        (uri.isScheme('http') || uri.isScheme('https'))) {
      return (source: null, reason: '带查询参数的媒体地址继续使用 mpv');
    }
    String source;
    String path;
    if (drivePath.hasMatch(raw)) {
      source = path = raw;
    } else if (uri != null &&
        uri.isScheme('file') &&
        uri.host.isEmpty &&
        !uri.hasQuery &&
        !uri.hasFragment) {
      try {
        source = path = uri.toFilePath(windows: true);
      } on UnsupportedError {
        return invalid;
      } on ArgumentError {
        return invalid;
      }
      if (!drivePath.hasMatch(path)) return invalid;
    } else if (uri != null &&
        (uri.isScheme('http') || uri.isScheme('https')) &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty &&
        !uri.hasFragment &&
        !raw.contains('\\')) {
      source = uri.toString();
      path = uri.path;
    } else {
      return invalid;
    }
    if (RegExp(r'[\x00-\x1f\x7f]').hasMatch(source) ||
        !RegExp(
          r'\.(mp4|m4v|mov|mkv|avi|webm|wmv)$',
          caseSensitive: false,
        ).hasMatch(path)) {
      return invalid;
    }
    return (source: source, reason: null);
  }

  Future<EmbeddedPlaybackSession> open(
    NativePlaybackBackend backend,
    MediaPlaySpec spec, {
    required bool browserHeaders,
    required Duration position,
    required double volume,
    required bool paused,
  }) async {
    final request = input(spec, browserHeaders: browserHeaders);
    final source = request.source;
    if (source == null) throw StateError(request.reason!);
    final result = await channel.invokeMapMethod<String, Object?>('open', {
      'backend': backend.name,
      'source': source,
      'positionMs': position.isNegative ? 0 : position.inMilliseconds,
      'volume': _unitVolume(volume),
      'paused': paused,
    });
    final id = result?['id'];
    final texture = result?['textureId'];
    if (id is! int || id < 0) throw const FormatException('无效的播放会话');
    if (texture is! int || texture < 0) {
      await channel.invokeMapMethod<String, Object?>('close', {'id': id});
      throw const FormatException('未能创建视频纹理');
    }
    return EmbeddedPlaybackSession._(channel, backend, id, texture);
  }
}

double _unitVolume(double value) =>
    value.isFinite ? value.clamp(0, 100) / 100 : 0.0;

enum EmbeddedPhase { loading, playing, paused, ended, failed }

class EmbeddedPlaybackState {
  const EmbeddedPlaybackState({
    required this.phase,
    required this.position,
    required this.duration,
    required this.width,
    required this.height,
  });
  final EmbeddedPhase phase;
  final Duration position, duration;
  final int width, height;

  factory EmbeddedPlaybackState._fromWire(Map<String, Object?>? raw) {
    int nonnegative(String field) {
      final v = raw?[field];
      if (v is int && v >= 0) return v;
      throw const FormatException('无效的播放状态');
    }

    final phase = EmbeddedPhase.values
        .where((e) => e.name == raw?['phase'])
        .firstOrNull;
    if (phase == null) throw const FormatException('未知播放状态');
    return EmbeddedPlaybackState(
      phase: phase,
      position: Duration(milliseconds: nonnegative('positionMs')),
      duration: Duration(milliseconds: nonnegative('durationMs')),
      width: nonnegative('width'),
      height: nonnegative('height'),
    );
  }
}

class EmbeddedPlaybackSession {
  EmbeddedPlaybackSession._(
    this._channel,
    this.backend,
    this.id,
    this.textureId,
  );
  final MethodChannel _channel;
  final NativePlaybackBackend backend;
  final int id, textureId;
  Future<Duration?>? _closing;

  Future<EmbeddedPlaybackState> read() async => EmbeddedPlaybackState._fromWire(
    await _channel.invokeMapMethod<String, Object?>('state', {'id': id}),
  );
  Future<void> setPaused(bool paused) =>
      _channel.invokeMethod<void>('pause', {'id': id, 'paused': paused});
  Future<void> seek(Duration position) => _channel.invokeMethod<void>('seek', {
    'id': id,
    'positionMs': position.isNegative ? 0 : position.inMilliseconds,
  });
  Future<void> setVolume(double value) => _channel.invokeMethod<void>(
    'volume',
    {'id': id, 'volume': _unitVolume(value)},
  );

  Future<Duration?> close() => _closing ??= _close();
  Future<Duration?> _close() async {
    final result = await _channel.invokeMapMethod<String, Object?>('close', {
      'id': id,
    });
    final time = result?['positionMs'];
    if (time == null) return null;
    if (time is! int || time < 0) throw const FormatException('无效的返回进度');
    return Duration(milliseconds: time);
  }
}
