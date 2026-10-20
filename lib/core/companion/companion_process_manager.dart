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

  /// companion 进程的 JVM 调优参数（⑥ 内存批定案，对照数据见
  /// .do-it/tmp-mem/jvm-matrix.txt：空闲 PrivateBytes 628.9MB → 66.5MB）。
  static const List<String> companionJvmTuningArgs = [
    '-Xms16m',
    '-Xmx256m',
    '-XX:MaxMetaspaceSize=128m',
    '-XX:+UseSerialGC',
  ];

  /// 独立生命周期的实例；默认构造仍共享应用级实例。
  /// applicationDirectory 默认取应用可执行文件目录，测试可注入隔离安装布局。
  CompanionProcessManager.scoped({
    Dio? dio,
    String? applicationDirectory,
    Future<String?> Function()? javaResolver,
    Future<Process> Function(String, List<String>)? processStarter,
    // 关闭过慢优化：实测 JVM 正常关机 ≈1.05s；该值同时封顶 HTTP 通知、
    // 优雅等待与 kill 后确认三段等待，收紧默认值以缩短最坏关闭路径。
    this.exitTimeout = const Duration(milliseconds: 1500),
    // ⑥ 空闲停用：运行中的 companion 连续 idleTimeout 没有真实使用（spider RPC）
    // 就自动停用，下次使用经懒启动链路重新拉起；检测粒度 idleCheckInterval。
    this.idleTimeout = const Duration(minutes: 30),
    this.idleCheckInterval = const Duration(minutes: 1),
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
  final Duration idleTimeout;
  final Duration idleCheckInterval;

  final Dio _dio;

  Process? _process;
  Future<bool>? _starting;
  Future<void>? _stopping;
  Completer<void>? _cancelStartup;
  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;
  bool _closed = false;
  Timer? _idleWatch;
  DateTime _lastActivity = DateTime.now();

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
  Future<bool> start({String? jarPath, int targetPort = 0}) async {
    if (_closed) return false;
    // 空闲停用（或普通 stop）进行中：等待停止收尾后按需重启，避免恰逢停用
    // 窗口的请求直接失败；应用退出已被上面的 _closed 拦截。
    final stopping = _stopping;
    if (stopping != null) {
      try {
        await stopping;
      } catch (_) {
        // 停止失败会保留进程所有权，下面按既有规则返回 false。
      }
    }
    if (_closed) return false;
    if (isRunning) return true;
    if (_starting != null) return _starting!;
    // 清理失败仍保留进程所有权，不允许新进程覆盖旧引用。
    if (_process != null) return false;
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
      // ⑥ 内存收紧与孤儿回收：收紧 JVM 参数（对照实验见静态常量注释）；
      // --stdin-watch=on 让 Java 侧在主进程异常退出（stdin 管道关闭）时自杀，
      // 避免留下无人回收的孤儿进程（见 companion/src/.../Main.java）。
      final process = await _processStarter(javaCmd, [
        '-noverify',
        ...companionJvmTuningArgs,
        '-jar',
        resolvedJar,
        '--port=$targetPort',
        '--stdin-watch=on',
      ]);
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
          _disarmIdleWatch();
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
      _lastActivity = DateTime.now();
      _armIdleWatch();
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

  /// 真实使用上报：每次 spider RPC（加载/调用/自检）调用，推迟空闲停用。
  void notifyActivity() {
    _lastActivity = DateTime.now();
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
    _disarmIdleWatch();
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

  /// 进入 running 后启动空闲监视；重挂时取消旧计时器，避免重复。
  void _armIdleWatch() {
    _idleWatch?.cancel();
    _idleWatch = Timer.periodic(idleCheckInterval, (_) => _onIdleTick());
  }

  void _disarmIdleWatch() {
    _idleWatch?.cancel();
    _idleWatch = null;
  }

  void _onIdleTick() {
    if (!isRunning || _stopping != null || _starting != null) return;
    if (DateTime.now().difference(_lastActivity) < idleTimeout) return;
    // 空闲停用走普通 stop 链路（HTTP /shutdown → 兜底 kill）；失败静默，留待下轮。
    unawaited(stop().catchError((Object _) {}));
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
