import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../config/models/vod_config.dart';
import 'browser_verification_request.dart';
import 'companion_process_manager.dart';

class BrowserVerificationController
    extends ValueNotifier<Map<String, BrowserVerificationRequest>> {
  BrowserVerificationController(
      {required this.processManager, required Dio dio})
      : _dio = dio,
        super(const {}) {
    final port = _readReadyPort();
    _readyPort = port;
    _port = port?.value;
    port?.addListener(_onPort);
  }

  final CompanionProcessManager processManager;
  final Dio _dio;
  ValueListenable<int?>? _readyPort;
  int? _port;
  int _generation = 0;
  bool _disposed = false;
  int get generation => _generation;

  /// 测试替身（`Fake implements CompanionProcessManager`）不一定实现
  /// `readyPort`，此时按「端口不变」处理，不影响验证请求本身。
  ValueListenable<int?>? _readReadyPort() {
    try {
      return processManager.readyPort;
    } on UnimplementedError {
      return null;
    }
  }

  void _onPort() {
    final next = _readyPort?.value;
    if (_port != null && next != _port) reset();
    _port = next;
  }

  void record(
      Site site, String method, Object? payload, int expectedGeneration) {
    if (_disposed || expectedGeneration != _generation) return;
    final request =
        BrowserVerificationRequest.fromResponse(site, method, payload);
    if (request == null) return;
    final previous = value[site.key];
    if (previous?.id == request.id) return;
    final requests = {...value};
    if (requests.length >= 8 && !requests.containsKey(site.key)) {
      requests.remove(requests.keys.first);
    }
    requests[site.key] = request;
    value = Map.unmodifiable(requests);
  }

  bool isCurrent(BrowserVerificationRequest request) =>
      !_disposed && identical(value[request.site.key], request);

  void dismiss(BrowserVerificationRequest request) {
    if (!isCurrent(request)) return;
    value = Map.unmodifiable({...value}..remove(request.site.key));
  }

  void reset() {
    _generation++;
    if (!_disposed && value.isNotEmpty) value = const {};
  }

  Future<String> command(
      BrowserVerificationRequest request, String operation) async {
    if (!isCurrent(request) ||
        !const {'open', 'complete'}.contains(operation)) {
      throw StateError('验证请求已失效，请重新打开站点后重试');
    }
    final generation = _generation;
    final result = await _send(request, operation);
    if (_disposed || generation != _generation || !isCurrent(request)) {
      throw StateError('验证请求已取消或站点已切换');
    }
    return result;
  }

  Future<void> cancel(BrowserVerificationRequest request) async {
    if (!isCurrent(request)) return;
    dismiss(request);
    try {
      await _send(request, 'cancel');
    } catch (_) {}
  }

  Future<void> cancelAll() async {
    final requests = value.values.toList(growable: false);
    reset();
    await Future.wait(requests.map((request) async {
      try {
        await _send(request, 'cancel');
      } catch (_) {}
    }));
  }

  Future<String> _send(
      BrowserVerificationRequest request, String operation) async {
    if (!processManager.isRunning) {
      reset();
      throw StateError('站源服务已停止，请重新打开站点后重试');
    }
    processManager.notifyActivity();
    String? proxy;
    if (operation == 'open') {
      try {
        proxy = processManager.fallbackProxy?.call();
      } catch (_) {}
    }
    final response = await _dio.post<dynamic>(
      '${processManager.baseUrl}/spider/call',
      data: {
        'siteKey': request.site.key,
        'api': request.site.api,
        'ext': request.site.ext ?? '',
        'jar': request.site.jar ?? '',
        'method': 'browserVerification',
        'operation': operation,
        'challengeId': request.id,
        'timeoutMs': '30000',
        if (proxy != null && proxy.isNotEmpty) 'proxy': proxy,
      },
      options: Options(
        receiveTimeout: const Duration(seconds: 35),
        validateStatus: (status) => status != null,
      ),
    );
    final body = response.data is String
        ? jsonDecode(response.data as String)
        : response.data;
    if (response.statusCode != 200 || body is! Map || body['code'] != 0) {
      throw StateError('站点验证未完成，请重试或取消');
    }
    final raw = body['data'];
    final data = raw is String ? jsonDecode(raw) : raw;
    final state = data is Map ? data['state'] : null;
    if (state is! String ||
        !const {'required', 'waiting', 'verified', 'cancelled'}
            .contains(state)) {
      throw const FormatException('无效的站点验证状态');
    }
    return state;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _readyPort?.removeListener(_onPort);
    super.dispose();
  }
}
