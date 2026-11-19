import 'dart:async';

import 'companion_log.dart';

/// 一次自愈的结果。
enum CompanionRecoveryKind {
  /// 进程还活着且 `/health` 正常：多半只是单次连接抖动，直接重试即可。
  healthy,

  /// 进程确实死了（或卡死），已经重新拉起。
  restarted,

  /// 想重启但没成功（jar 缺失 / JRE 缺失 / 启动超时 / 进程清理失败……）。
  restartFailed,

  /// 应用正在退出（manager 已 shutdown），不该再拉起新进程。
  unavailable,
}

/// 自愈结论 + 用户可读的原因。
class CompanionRecoveryOutcome {
  const CompanionRecoveryOutcome(
    this.kind, {
    this.detail = '',
    this.logPath,
  });

  final CompanionRecoveryKind kind;

  /// 失败原因（通常取 manager.lastError 的最后一行有效信息）。
  final String detail;

  /// 诊断日志路径；有值时提示里会带上，方便用户回报。
  final String? logPath;

  /// 自愈之后是否值得再发一次同样的 RPC。
  bool get canRetry =>
      kind == CompanionRecoveryKind.healthy ||
      kind == CompanionRecoveryKind.restarted;

  /// 不能重试时给用户的说明（带日志路径）。
  String get failureMessage {
    final reason = detail.trim();
    final base = switch (kind) {
      CompanionRecoveryKind.restartFailed => '站源服务已退出，已尝试自动重启失败'
          '${reason.isEmpty ? '' : '（$reason）'}，请稍后重试',
      CompanionRecoveryKind.unavailable => '站源服务正在关闭，暂时无法自动重启，请稍后重试',
      CompanionRecoveryKind.healthy => '无法连接站源服务，请重试',
      CompanionRecoveryKind.restarted => '站源服务已重启，请重试',
    };
    return withCompanionLogPath(base, logPath);
  }
}

/// 给任意提示补上「诊断日志：<路径>」后缀（没有路径时原样返回）。
String withCompanionLogPath(String message, String? logPath) {
  final path = logPath?.trim();
  if (path == null || path.isEmpty) return message;
  return '$message。诊断日志：$path';
}

/// [CompanionRecovery] 需要的最小进程管理能力。
///
/// 抽成接口是为了让自愈逻辑可以脱离 `Process` 单测；实现方是
/// `CompanionProcessManager`（复用已有的 `/health`、`start`、`restart`）。
abstract interface class CompanionRecoveryHost {
  bool get isRunning;

  /// 应用正在退出：不再拉起新进程。
  bool get isClosed;

  /// 现有 `/health` 探测（未就绪 / 不可达都返回 false）。
  Future<bool> checkHealth();

  /// 复用懒启动链路（内部带 singleflight，并发调用只会拉起一个进程）。
  Future<bool> start();

  /// 进程还在但 HTTP 不可达时：先停（必要时杀进程树）再起。
  Future<bool> restart();

  String get lastError;

  /// 诊断日志；为 null 时提示里不带路径。
  CompanionLog? get companionLog;
}

/// transport / service 失败后的自愈：健康探测 → 必要时重启一次，并把结论写进日志。
///
/// 并发语义：多个在途 RPC 同时失败时共享同一次自愈（[recover] 复用同一个 future），
/// 因此不会因为并发失败拉起多个 companion 进程。
class CompanionRecovery {
  CompanionRecovery({
    required this.host,
    this.recheckDelay = const Duration(milliseconds: 250),
  });

  final CompanionRecoveryHost host;

  /// 第一次探测失败后隔多久再探一次：用来把「单次连接抖动」和「进程真死了」分开，
  /// 避免播放中因为一次抖动就把正在转发视频的 companion 重启掉。
  final Duration recheckDelay;

  Future<CompanionRecoveryOutcome>? _inflight;

  Future<CompanionRecoveryOutcome> recover() {
    final running = _inflight;
    if (running != null) return running;
    final future = _recover();
    _inflight = future;
    return future.whenComplete(() {
      if (identical(_inflight, future)) _inflight = null;
    });
  }

  Future<CompanionRecoveryOutcome> _recover() async {
    final logPath = _path;
    try {
      final healthy = await host.checkHealth();
      _write('[recovery] health=${healthy ? 'ok' : 'fail'} running=${host.isRunning}');
      if (healthy) {
        return CompanionRecoveryOutcome(
          CompanionRecoveryKind.healthy,
          logPath: logPath,
        );
      }
      // 复查一次：偶发的连接抖动不值得重启（重启会打断正在进行的播放转发）。
      if (recheckDelay > Duration.zero) {
        await Future<void>.delayed(recheckDelay);
        final rechecked = await host.checkHealth();
        _write('[recovery] 复查 health=${rechecked ? 'ok' : 'fail'}');
        if (rechecked) {
          return CompanionRecoveryOutcome(
            CompanionRecoveryKind.healthy,
            logPath: logPath,
          );
        }
      }
      if (host.isClosed) {
        _write('[recovery] 应用正在退出，不再拉起 companion');
        return CompanionRecoveryOutcome(
          CompanionRecoveryKind.unavailable,
          logPath: logPath,
        );
      }
      // 进程管理器认为还活着（端口还在、状态还没刷新）时先 stop 再 start：
      // 只调 start() 会因为 isRunning 为 true 直接返回 true，等于没重启。
      _write('[recovery] 重启 companion（running=${host.isRunning}）');
      final started = host.isRunning ? await host.restart() : await host.start();
      if (!started) {
        final detail = host.lastError;
        _write('[recovery] 重启失败：$detail');
        return CompanionRecoveryOutcome(
          CompanionRecoveryKind.restartFailed,
          detail: detail,
          logPath: logPath,
        );
      }
      _write('[recovery] 重启成功（running=${host.isRunning}）');
      return CompanionRecoveryOutcome(
        CompanionRecoveryKind.restarted,
        logPath: logPath,
      );
    } catch (error) {
      _write('[recovery] 自愈异常：$error');
      return CompanionRecoveryOutcome(
        CompanionRecoveryKind.restartFailed,
        detail: '$error',
        logPath: logPath,
      );
    }
  }

  String? get _path {
    try {
      return host.companionLog?.path;
    } catch (_) {
      // 某些测试替身没有实现 companionLog：退化为不带路径
      return null;
    }
  }

  void _write(String line) {
    try {
      host.companionLog?.write(line);
    } catch (_) {
      // 日志失败不影响自愈
    }
  }
}
