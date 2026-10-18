import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

/// 伴随服务运行状态枚举
enum CompanionStatus {
  stopped,
  starting,
  stopping,
  running,
  failed,
  unsupported,
}

/// 本地 Java 伴随进程管理器
/// 负责 Java 伴随进程的生命周期管理、多级 Java 运行时探测与就绪验证
class CompanionProcessManager {
  static final CompanionProcessManager _instance =
      CompanionProcessManager.scoped();
  factory CompanionProcessManager() => _instance;

  /// 独立生命周期的实例；默认构造仍共享应用级实例。
  /// applicationDirectory 默认取应用可执行文件目录，测试可注入隔离安装布局。
  CompanionProcessManager.scoped({
    Dio? dio,
    String? applicationDirectory,
    Future<String?> Function()? javaResolver,
    Future<Process> Function(String, List<String>)? processStarter,
    this.exitTimeout = const Duration(seconds: 2),
  })  : _dio = dio ??
            Dio(BaseOptions(
                connectTimeout: const Duration(seconds: 3),
                receiveTimeout: const Duration(seconds: 3))),
        _applicationDirectory = applicationDirectory == null
            ? File(Platform.resolvedExecutable).parent.path
            : p.normalize(p.absolute(applicationDirectory)),
        _javaResolver = javaResolver,
        _processStarter = processStarter ??
            ((executable, arguments) => Process.start(executable, arguments));

  final String _applicationDirectory;
  final Future<String?> Function()? _javaResolver;
  final Future<Process> Function(String, List<String>) _processStarter;
  final Duration exitTimeout;

  final Dio _dio;

  Process? _process;
  Future<bool>? _starting;
  Future<void>? _stopping;
  Completer<void>? _cancelStartup;
  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;
  bool _closed = false;

  bool get _stopRequested => _closed || _stopping != null;
  int? _port;
  CompanionStatus _status = CompanionStatus.stopped;
  String _lastError = '';
  String? _resolvedJavaPath;

  CompanionStatus get status => _status;
  int? get port => _port;
  bool get isRunning => _status == CompanionStatus.running && _port != null;
  String get lastError => _lastError;
  String? get resolvedJavaPath => _resolvedJavaPath;
  String get baseUrl => isRunning ? 'http://127.0.0.1:$_port' : '';

  /// 多级探测可用的 Java 可执行文件路径
  /// 优先级:
  /// 1. 可执行文件目录: runtime/jre、jre、data/jre
  /// 2. 工作目录的开发回退: runtime/jre、jre、companion/runtime/jre
  /// 3. AppData 持久化目录: %APPDATA%/XiugouTV/runtime/jre/bin/java.exe
  /// 4. 环境变量: JAVA_HOME/bin/java.exe
  /// 5. 系统 PATH: java
  Future<String?> resolveJavaExecutable() async {
    if (_javaResolver != null) return _javaResolver();
    final isWindows = Platform.isWindows;
    final javaExe = isWindows ? 'java.exe' : 'java';

    final workingDirectory = Directory.current.path;
    final appData = isWindows ? Platform.environment['APPDATA'] : null;
    final javaHome = Platform.environment['JAVA_HOME'];
    final candidates = [
      p.join(_applicationDirectory, 'runtime/jre/bin/$javaExe'),
      p.join(_applicationDirectory, 'jre/bin/$javaExe'),
      p.join(_applicationDirectory, 'data/jre/bin/$javaExe'),
      p.join(workingDirectory, 'runtime/jre/bin/$javaExe'),
      p.join(workingDirectory, 'jre/bin/$javaExe'),
      p.join(workingDirectory, 'companion/runtime/jre/bin/$javaExe'),
      if (appData != null && appData.isNotEmpty)
        p.join(workingDirectory, appData, 'XiugouTV/runtime/jre/bin/$javaExe'),
      if (javaHome != null && javaHome.isNotEmpty)
        p.join(workingDirectory, javaHome, 'bin/$javaExe'),
    ];
    for (final candidate in candidates) {
      final absolutePath = p.normalize(candidate);
      if (File(absolutePath).existsSync()) {
        _resolvedJavaPath = absolutePath;
        return _resolvedJavaPath;
      }
    }

    try {
      final res = await Process.run('java', ['-version']);
      if (res.exitCode == 0) {
        _resolvedJavaPath = 'java';
        return 'java';
      }
    } catch (_) {}

    _resolvedJavaPath = null;
    return null;
  }

  /// 检查系统或内嵌环境是否安装 Java 运行时
  Future<bool> checkJavaAvailable() async {
    final javaCmd = await resolveJavaExecutable();
    return javaCmd != null;
  }

  /// 同一生命周期内的预热与按需请求共享一次启动。
  Future<bool> start({String? jarPath, int targetPort = 0}) {
    if (_stopRequested) return Future.value(false);
    if (isRunning) return Future.value(true);
    if (_starting != null) return _starting!;
    // 清理失败仍保留进程所有权，不允许新进程覆盖旧引用。
    if (_process != null) return Future.value(false);
    _cancelStartup = Completer<void>();
    return _starting = _start(jarPath, targetPort).whenComplete(() {
      _starting = null;
      _cancelStartup = null;
    });
  }

  Future<bool> _start(String? jarPath, int targetPort) async {
    _status = CompanionStatus.starting;
    _lastError = '';
    try {
      final workingDirectory = Directory.current.path;
      final resolvedJar = jarPath == null
          ? _findDefaultJarPath(workingDirectory)
          : p.normalize(p.join(workingDirectory, jarPath));
      final javaCmd = await resolveJavaExecutable();
      if (_stopRequested) return false;
      if (javaCmd == null) {
        _status = CompanionStatus.unsupported;
        _lastError =
            'Java Runtime Environment (JRE) not found in runtime/jre, APPDATA, JAVA_HOME or PATH.';
        return false;
      }
      if (!File(resolvedJar).existsSync()) {
        throw StateError('Companion service jar not found at $resolvedJar');
      }
      final ready = Completer<int?>();
      final process = await _processStarter(
          javaCmd, ['-noverify', '-jar', resolvedJar, '--port=$targetPort']);
      _process = process;
      _stdoutSubscription = process.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen((line) {
        final match =
            RegExp(r'^\[COMPANION_READY\] PORT=(\d+)$').firstMatch(line.trim());
        final port = int.tryParse(match?.group(1) ?? '');
        if (port != null && port > 0 && port <= 65535 && !ready.isCompleted) {
          ready.complete(port);
        }
      }, onError: (Object error) {
        if (!ready.isCompleted) ready.complete(null);
      }, onDone: () {
        if (!ready.isCompleted) ready.complete(null);
      });
      _stderrSubscription = process.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen((line) => _lastError = line, onError: (Object error) {
        _lastError = '$error';
      });
      unawaited(process.exitCode.then((_) {
        if (!ready.isCompleted) ready.complete(null);
        if (identical(_process, process)) {
          _process = null;
          _port = null;
          if (!_stopRequested) _status = CompanionStatus.stopped;
        }
      }));
      if (_stopRequested) return false;
      final port = await Future.any<int?>([
        ready.future,
        _cancelStartup!.future.then((_) => null),
      ]).timeout(const Duration(seconds: 5));
      if (_stopRequested) return false;
      if (port == null || !identical(_process, process)) {
        throw StateError('Companion exited before ready');
      }
      _port = port;
      final healthy = await Future.any<bool>([
        checkHealth(),
        _cancelStartup!.future.then((_) => false),
      ]);
      if (_stopRequested) return false;
      if (!healthy || !identical(_process, process)) {
        throw StateError('Health check failed after start');
      }
      _status = CompanionStatus.running;
      return true;
    } catch (error) {
      _lastError = '$error';
      if (!_stopRequested) {
        try {
          await _terminateProcess();
        } catch (cleanupError) {
          _lastError = '$error; cleanup: $cleanupError';
        }
        _status = CompanionStatus.failed;
      }
      return false;
    }
  }

  /// 发送健康检查
  Future<bool> checkHealth() async {
    if (_port == null) return false;
    try {
      final res = await _dio.get<dynamic>('http://127.0.0.1:$_port/health');
      if (res.statusCode == 200) {
        final dynamic data =
            res.data is String ? jsonDecode(res.data as String) : res.data;
        if (data is Map) {
          return data['status'] == 'ok';
        }
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// 停止完成后可重新启动；完成意味着已确认子进程退出。
  Future<void> stop() {
    if (_stopping != null) return _stopping!;
    final cancel = _cancelStartup;
    if (cancel != null && !cancel.isCompleted) cancel.complete();
    return _stopping = _stop().whenComplete(() => _stopping = null);
  }

  /// 应用退出后不再接收迟到的按需启动请求。
  Future<void> shutdown() {
    _closed = true;
    return stop();
  }

  Future<void> _stop() async {
    _status = CompanionStatus.stopping;
    try {
      // Process.start 不能撤销；等待所有权交接后再终止迟到的子进程。
      await _starting;
      await _terminateProcess();
      _port = null;
      _status = CompanionStatus.stopped;
    } catch (error) {
      _lastError = 'Companion shutdown failed: $error';
      _status = CompanionStatus.failed;
      rethrow;
    }
  }

  Future<void> _terminateProcess() async {
    final process = _process;
    if (process == null) return;
    final port = _port;
    if (port != null) {
      try {
        await _dio
            .post<dynamic>('http://127.0.0.1:$port/shutdown')
            .timeout(exitTimeout);
      } catch (_) {
        // HTTP 失败不代表进程消失；仍须等待或终止已持有的进程。
      }
      try {
        await process.exitCode.timeout(exitTimeout);
      } on TimeoutException {
        process.kill();
        await process.exitCode.timeout(exitTimeout);
      }
    } else {
      process.kill();
      await process.exitCode.timeout(exitTimeout);
    }
    await _stdoutSubscription?.cancel();
    await _stderrSubscription?.cancel();
    _stdoutSubscription = null;
    _stderrSubscription = null;
    if (identical(_process, process)) _process = null;
    _port = null;
  }

  String _findDefaultJarPath(String workingDirectory) {
    final candidates = [
      p.join(_applicationDirectory, 'companion/dist/companion-service.jar'),
      p.join(workingDirectory, 'companion/dist/companion-service.jar'),
      p.join(
          workingDirectory, 'xiugou-tv/companion/dist/companion-service.jar'),
      p.join(workingDirectory, '../companion/dist/companion-service.jar'),
    ];
    for (final c in candidates) {
      if (File(c).existsSync()) {
        return p.normalize(c);
      }
    }
    return p.normalize(candidates.first);
  }
}
