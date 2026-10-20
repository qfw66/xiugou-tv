import 'dart:convert';

import 'package:dio/dio.dart';

import 'update_manifest.dart';

/// 拉取更新清单的失败类型（供 UI 分型提示，不做字符串匹配）。
enum UpdateFetchFailure {
  /// 地址不是 https 或无法解析
  insecure,
  network,
  timeout,
  cancelled,
  rateLimited,
  notFound,
  forbidden,
  server,
  invalidPayload,
}

class UpdateFetchResult {
  final UpdateManifest? manifest;
  final Map<String, dynamic>? payload;
  final String? etag;
  final bool notModified;
  final UpdateFetchFailure? failure;
  final int? statusCode;

  const UpdateFetchResult({
    this.manifest,
    this.payload,
    this.etag,
    this.notModified = false,
    this.failure,
    this.statusCode,
  });

  bool get ok => failure == null;

  static UpdateFetchResult fail(UpdateFetchFailure failure,
          {int? statusCode}) =>
      UpdateFetchResult(failure: failure, statusCode: statusCode);
}

/// 读取更新清单。只接受 https，不携带任何凭据。
class UpdateClient {
  final Dio _dio;
  final bool _ownsDio;

  UpdateClient({Dio? dio})
      : _ownsDio = dio == null,
        _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 20),
              headers: const {
                'Accept': 'application/vnd.github+json',
                'User-Agent': 'xiugou-tv',
              },
            ));

  void close() {
    if (_ownsDio) _dio.close(force: true);
  }

  Future<UpdateFetchResult> fetch(
    String url, {
    String? etag,
    CancelToken? cancelToken,
  }) async {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      return UpdateFetchResult.fail(UpdateFetchFailure.insecure);
    }

    Response<dynamic> response;
    try {
      response = await _dio.get<dynamic>(
        uri.toString(),
        options: Options(
          responseType: ResponseType.json,
          validateStatus: (_) => true,
          headers: {
            if (etag != null && etag.isNotEmpty) 'If-None-Match': etag,
          },
        ),
        cancelToken: cancelToken,
      );
    } on DioException catch (error) {
      return UpdateFetchResult.fail(_mapDioFailure(error));
    }

    final status = response.statusCode ?? 0;
    if (status == 304) {
      return UpdateFetchResult(
        notModified: true,
        etag: etag,
        statusCode: status,
      );
    }
    if (status == 404) {
      return UpdateFetchResult.fail(UpdateFetchFailure.notFound,
          statusCode: status);
    }
    if (status == 403 || status == 429) {
      final rateLimited = _looksRateLimited(response);
      return UpdateFetchResult.fail(
        rateLimited
            ? UpdateFetchFailure.rateLimited
            : UpdateFetchFailure.forbidden,
        statusCode: status,
      );
    }
    if (status != 200) {
      return UpdateFetchResult.fail(UpdateFetchFailure.server,
          statusCode: status);
    }

    final payload = _asPayload(response.data);
    if (payload == null) {
      return UpdateFetchResult.fail(UpdateFetchFailure.invalidPayload,
          statusCode: status);
    }
    final manifest = UpdateManifest.tryParse(payload);
    if (manifest == null) {
      return UpdateFetchResult.fail(UpdateFetchFailure.invalidPayload,
          statusCode: status);
    }
    return UpdateFetchResult(
      manifest: manifest,
      payload: payload,
      etag: response.headers.value('etag'),
      statusCode: status,
    );
  }

  static UpdateFetchFailure _mapDioFailure(DioException error) {
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.transformTimeout:
        return UpdateFetchFailure.timeout;
      case DioExceptionType.cancel:
        return UpdateFetchFailure.cancelled;
      case DioExceptionType.badCertificate:
      case DioExceptionType.connectionError:
        return UpdateFetchFailure.network;
      case DioExceptionType.badResponse:
        return UpdateFetchFailure.server;
      case DioExceptionType.unknown:
        return UpdateFetchFailure.network;
    }
  }

  static bool _looksRateLimited(Response<dynamic> response) {
    final remaining = response.headers.value('x-ratelimit-remaining');
    if (remaining != null && remaining.trim() == '0') return true;
    final data = response.data;
    if (data is Map) {
      final message = data['message'];
      if (message is String && message.toLowerCase().contains('rate limit')) {
        return true;
      }
    }
    return false;
  }

  static Map<String, dynamic>? _asPayload(Object? data) {
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return Map<String, dynamic>.from(data);
    if (data is String && data.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(data);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {
        return null;
      }
    }
    return null;
  }
}
