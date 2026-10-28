import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'spider_ui_models.dart';

/// 载荷界面通道：companion 就绪后持续长轮询 `/ui/events`，把弹窗 / Toast 等事件广播给界面层；
/// 界面层通过 [send] 把用户操作回放给载荷。
///
/// 生命周期跟随 [readyPort]：端口变化（重启）时从头同步（cursor = -1，服务端返回当前弹窗全集）；
/// 端口变为 null（停止 / 退出）时广播一次空的 [SpiderUiReset]，让界面关掉所有残留弹窗。
/// 长轮询本身不计为「使用」，不会阻止 companion 空闲停用；只有用户操作才调用 [onActivity]。
class CompanionUiChannel {
  final ValueListenable<int?> readyPort;
  final Dio _dio;
  final Duration pollWait;
  final Duration retryDelay;
  final void Function()? onActivity;

  final StreamController<SpiderUiEvent> _events =
      StreamController<SpiderUiEvent>.broadcast();
  int? _port;
  int _generation = 0;
  bool _started = false;
  bool _disposed = false;
  DateTime? _lastDialogShownAt;

  CompanionUiChannel({
    required this.readyPort,
    Dio? dio,
    this.pollWait = const Duration(seconds: 25),
    this.retryDelay = const Duration(seconds: 1),
    this.onActivity,
  }) : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 5),
              sendTimeout: const Duration(seconds: 5),
            ));

  Stream<SpiderUiEvent> get events => _events.stream;

  /// 最近一次有新弹窗出现的时间（用于判断「这次点击已经由载荷弹窗接管」）。
  DateTime? get lastDialogShownAt => _lastDialogShownAt;

  void start() {
    if (_started || _disposed) return;
    _started = true;
    readyPort.addListener(_onPortChanged);
    _onPortChanged();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    if (_started) readyPort.removeListener(_onPortChanged);
    unawaited(_events.close());
  }

  void _onPortChanged() {
    final port = readyPort.value;
    if (port == _port) return;
    final hadPort = _port != null;
    _port = port;
    final generation = ++_generation;
    if (port == null) {
      if (hadPort) _emit(const SpiderUiReset([]));
      return;
    }
    unawaited(_pollLoop(port, generation));
  }

  bool _alive(int generation) => !_disposed && generation == _generation;

  Future<void> _pollLoop(int port, int generation) async {
    var cursor = -1;
    while (_alive(generation)) {
      try {
        final res = await _dio.get<dynamic>(
          'http://127.0.0.1:$port/ui/events',
          queryParameters: {'after': cursor, 'wait': pollWait.inMilliseconds},
          options:
              Options(receiveTimeout: pollWait + const Duration(seconds: 10)),
        );
        if (!_alive(generation)) return;
        final raw =
            res.data is String ? jsonDecode(res.data as String) : res.data;
        final result = SpiderUiPollResult.tryParse(raw);
        if (result == null) {
          throw const FormatException('invalid /ui/events response');
        }
        cursor = result.cursor;
        for (final event in result.events) {
          _emit(event);
        }
      } catch (_) {
        if (!_alive(generation)) return;
        // 服务刚就绪 / 短暂不可达：稍后重试；进程真的退出时 readyPort 会变为 null 终止本循环
        await Future<void>.delayed(retryDelay);
      }
    }
  }

  void _emit(SpiderUiEvent event) {
    if (_disposed) return;
    if ((event is SpiderDialogShown && !event.isUpdate) ||
        (event is SpiderUiReset && event.dialogs.isNotEmpty)) {
      _lastDialogShownAt = DateTime.now();
    }
    _events.add(event);
  }

  /// 回放一次用户操作；返回 false 表示服务不可达或该弹窗已不存在（界面应自行关闭它）。
  Future<bool> send(SpiderUiInput input) async {
    final port = _port;
    if (port == null || _disposed) return false;
    onActivity?.call();
    try {
      final res = await _dio.post<dynamic>(
        'http://127.0.0.1:$port/ui/input',
        data: input.toJson(),
        options: Options(receiveTimeout: const Duration(seconds: 10)),
      );
      final raw =
          res.data is String ? jsonDecode(res.data as String) : res.data;
      return raw is Map && raw['accepted'] == true;
    } catch (_) {
      return false;
    }
  }
}
