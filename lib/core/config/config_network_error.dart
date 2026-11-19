import 'dart:io';

import 'package:dio/dio.dart';

bool isConfigCertificateFailure(DioException error) =>
    error.type == DioExceptionType.badCertificate ||
    (error.error is TlsException &&
        (error.error as TlsException)
            .message
            .toUpperCase()
            .contains('CERTIFICATE_VERIFY_FAILED'));

/// 配置加载、切换和连通性探测共用的网络摘要；不显示路径、凭据或查询参数。
String configNetworkErrorText(DioException error) {
  if (error.type == DioExceptionType.badResponse) {
    return 'HTTP ${error.response?.statusCode ?? '错误'}';
  }
  if (isConfigCertificateFailure(error)) return '证书无效';
  if (error.type == DioExceptionType.cancel) return '已取消';
  if (error.type.name.toLowerCase().contains('timeout')) return '连接超时';
  final cause = error.error;
  if (cause is TlsException) {
    final host = error.requestOptions.uri.host;
    final target = host.isEmpty ? '' : '（$host）';
    return 'TLS 握手失败$target，请检查网络、代理或源服务器后重试';
  }
  if (error.type == DioExceptionType.connectionError || cause is SocketException) {
    return '无法连接';
  }
  return '网络错误';
}
