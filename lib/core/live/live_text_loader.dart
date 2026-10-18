import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';

import '../storage/data_restore_guard.dart';

class LiveTextDocument {
  final String content;
  final Uri uri;
  const LiveTextDocument(this.content, this.uri);
}

/// 保留重定向后的基址，统一处理文本编码、gzip 和大小限制。
Future<LiveTextDocument> loadLiveText(
  Uri uri, {
  required Dio dio,
  Map<String, String> headers = const {},
  int maxBytes = 20 * 1024 * 1024,
  bool allowFile = false,
}) async {
  List<int> bytes;
  var resolved = uri;
  if (allowFile && uri.scheme == 'file') {
    final file = File.fromUri(uri);
    if (await file.length() > maxBytes) {
      throw const FormatException('文件过大，请缩小清单或节目单范围');
    }
    bytes = await file.readAsBytes();
  } else {
    if (!const {'http', 'https'}.contains(uri.scheme) || uri.host.isEmpty) {
      throw const FormatException('订阅地址仅支持 HTTP / HTTPS');
    }
    final response = await dio.getUri<ResponseBody>(
      uri,
      options: Options(
        responseType: ResponseType.stream,
        headers: headers,
        receiveTimeout: const Duration(seconds: 20),
      ),
    );
    // Dio 的 realUri 可能仍是相对 Location，需按每一跳的基址依次解析。
    resolved = response.requestOptions.uri;
    for (final redirect in response.redirects) {
      resolved = resolved.resolveUri(redirect.location);
    }
    final body = response.data;
    if (body == null) throw const FormatException('地址返回了空内容');
    final buffer = BytesBuilder(copy: false);
    await for (final chunk
        in body.stream.timeout(const Duration(seconds: 20))) {
      if (buffer.length + chunk.length > maxBytes) {
        throw const FormatException('返回内容过大，请缩小清单或节目单范围');
      }
      buffer.add(chunk);
    }
    bytes = buffer.takeBytes();
  }
  if (bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b) {
    final decoded = BytesBuilder(copy: false);
    await for (final chunk
        in Stream<List<int>>.value(bytes).transform(gzip.decoder)) {
      if (decoded.length + chunk.length > maxBytes) {
        throw const FormatException('解压后的内容过大');
      }
      decoded.add(chunk);
    }
    bytes = decoded.takeBytes();
  }
  return LiveTextDocument(
    utf8.decode(bytes, allowMalformed: true).replaceFirst('\uFEFF', ''),
    resolved,
  );
}

String liveErrorMessage(Object error) {
  if (error is DataRestorePendingRestartException) return error.message;
  if (error is FormatException) return error.message;
  if (error is FileSystemException) return '无法读取或保存文件，请检查路径及权限';
  if (error is DioException) {
    final status = error.response?.statusCode;
    return status == null ? '网络请求失败，请检查地址或网络后重试' : '服务器返回 HTTP $status';
  }
  return '加载失败，请检查内容后重试';
}
