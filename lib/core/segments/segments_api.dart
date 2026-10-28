import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../config/app_env.dart';
import '../danmaku/danmaku_api.dart' show DanmakuApi;
import 'segment_models.dart';

/// §44 共享片段服务地址与令牌：与弹幕同口径，由维护者在 `config/app.env` 配置、打包注入，
/// 用户无需配置也看不到；其他开发者不配置即不启用（播放页不出现「片段」按钮）。
/// 服务端代码与部署说明：`server/segments-worker/README.md`。
String get kSegmentsApiBase {
  var base = AppEnv.get('XIUGOU_SEGMENTS_URL').trim();
  while (base.endsWith('/')) {
    base = base.substring(0, base.length - 1);
  }
  return base;
}

bool get segmentsServiceConfigured => kSegmentsApiBase.isNotEmpty;

class SegmentsException implements Exception {
  const SegmentsException(this.message, {this.code});
  final String message;
  final String? code;
  @override
  String toString() => message;
}

/// 一集的服务端返回。
class SegmentsResponse {
  const SegmentsResponse(this.segments, this.submitted);
  final List<SharedSegment> segments;
  final Set<SegmentCategory> submitted;

  static SegmentsResponse fromJson(Object? raw) {
    if (raw is! Map) throw const SegmentsException('片段服务返回格式错误');
    final list = raw['segments'];
    final sub = raw['submitted'];
    return SegmentsResponse(
      [
        if (list is List) ...list.map(SharedSegment.tryFromJson).whereType<SharedSegment>(),
      ],
      {
        if (sub is List)
          ...sub.map((e) => SegmentCategory.of(e is String ? e : null)).whereType<SegmentCategory>(),
      },
    );
  }
}

/// Worker 客户端。跟随 Windows 系统代理（与弹幕同一套读取）。
class SegmentsApi {
  SegmentsApi({String? base, String? token, HttpClient? client, String? Function()? proxy})
      : _base = base ?? kSegmentsApiBase,
        _token = token ?? AppEnv.get('XIUGOU_SEGMENTS_TOKEN'),
        _client = client ?? _defaultClient(proxy ?? DanmakuApi.systemProxy);

  final String _base;
  final String _token;
  final HttpClient _client;

  static const Duration timeout = Duration(seconds: 15);

  static HttpClient _defaultClient(String? Function() proxy) {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10)
      ..userAgent = 'xiugou-tv';
    client.findProxy = (uri) {
      final p = proxy();
      return p == null || p.isEmpty ? 'DIRECT' : 'PROXY $p; DIRECT';
    };
    return client;
  }

  Future<SegmentsResponse> fetch(String key, {required String clientId}) async {
    final body = await _send('GET', Uri.parse('$_base/v1/segments').replace(queryParameters: {'key': key}),
        clientId: clientId);
    return SegmentsResponse.fromJson(body);
  }

  Future<SegmentsResponse> submit(SegmentEpisodeKey episode, SegmentDraft d, {required String clientId}) async {
    final body = await _send('POST', Uri.parse('$_base/v1/segments'), clientId: clientId, json: {
      'key': episode.key,
      'clientId': clientId,
      'category': d.category.key,
      'action': d.action.key,
      'startMs': d.startMs,
      'endMs': d.endMs,
      'durationMs': d.durationMs,
      'title': episode.title,
      'episode': episode.episode,
    });
    return SegmentsResponse.fromJson(body);
  }

  /// 自动执行后的反馈：up = 没撤销（认可），down = 撤销（异议）。返回服务端是否已撤下该片段。
  Future<bool> feedback(String key, SharedSegment s, {required bool disputed, required String clientId}) async {
    final body = await _send('POST', Uri.parse('$_base/v1/feedback'), clientId: clientId, json: {
      'key': key,
      'clientId': clientId,
      'category': s.category.key,
      'verdict': disputed ? 'down' : 'up',
      'startMs': s.startMs,
      'endMs': s.endMs,
      'durationMs': s.durationMs,
    });
    return body is Map && body['hidden'] == true;
  }

  Future<Object?> _send(String method, Uri uri, {required String clientId, Map<String, Object?>? json}) async {
    if (_base.isEmpty) throw const SegmentsException('未配置片段服务');
    HttpClientRequest? request;
    try {
      request = await _client.openUrl(method, uri).timeout(timeout);
      request.headers
        ..set('x-xiugou-token', _token)
        ..set('x-xiugou-client', clientId)
        ..set(HttpHeaders.acceptHeader, 'application/json');
      if (json != null) {
        request.headers.contentType = ContentType.json;
        request.add(utf8.encode(jsonEncode(json)));
      }
      final response = await request.close().timeout(timeout);
      final text = await response.transform(utf8.decoder).join().timeout(timeout);
      Object? decoded;
      try {
        decoded = jsonDecode(text);
      } catch (_) {
        decoded = null;
      }
      if (response.statusCode >= 200 && response.statusCode < 300) return decoded;
      final map = decoded is Map ? decoded : const {};
      throw SegmentsException(
        (map['message'] as String?) ?? '片段服务返回 ${response.statusCode}',
        code: map['code'] as String?,
      );
    } on SegmentsException {
      rethrow;
    } on TimeoutException {
      request?.abort();
      throw const SegmentsException('片段服务超时');
    } catch (e) {
      throw SegmentsException('片段服务不可达（$e）');
    }
  }

  void close() => _client.close(force: true);
}
