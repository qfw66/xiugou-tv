import 'dart:async';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';
import '../../../core/config/config_repository.dart';
import '../../../core/config/models/desktop_window_config.dart';

/// Windows 桌面原生窗口生命周期与几何形态管理控制器
class DesktopWindowManager with WindowListener {
  final ConfigRepository _configRepository;
  final Future<void> Function()? beforeClose;

  final ValueNotifier<bool> isFullScreenNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<bool> isMaximizedNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<bool> isAlwaysOnTopNotifier = ValueNotifier<bool>(false);

  Future<void>? _closing;
  Timer? _debounceSaveTimer;
  StreamSubscription<DesktopWindowConfig>? _configSubscription;
  static const Duration _debounceDuration = Duration(milliseconds: 500);

  DesktopWindowManager(
      {required ConfigRepository configRepository, this.beforeClose})
      : _configRepository = configRepository;

  /// 初始化原生窗口尺寸、位置、标题与无边框属性
  Future<void> initialize() async {
    await windowManager.ensureInitialized();
    windowManager.addListener(this);
    await windowManager.setPreventClose(true);

    final initialConfig = _configRepository.currentWindowConfig;

    const windowOptions = WindowOptions(
      size: Size(1280, 720),
      minimumSize: Size(960, 540),
      center: true,
      backgroundColor: Color(0xFF101014),
      skipTaskbar: false,
      titleBarStyle: TitleBarStyle.hidden,
      title: '修狗TV',
    );

    // 异步等待原生窗口就绪后展示，不阻塞 main() 中 runApp 挂载
    windowManager.waitUntilReadyToShow(windowOptions, () async {
      final targetSize = Size(initialConfig.width, initialConfig.height);
      await windowManager.setSize(targetSize);

      if (initialConfig.posX != null && initialConfig.posY != null) {
        await windowManager.setPosition(
          Offset(initialConfig.posX!, initialConfig.posY!),
        );
      } else {
        await windowManager.center();
      }

      if (initialConfig.isMaximized) {
        await windowManager.maximize();
        isMaximizedNotifier.value = true;
      }

      if (initialConfig.alwaysOnTop) {
        await windowManager.setAlwaysOnTop(true);
        isAlwaysOnTopNotifier.value = true;
      }

      await windowManager.show();
      await windowManager.focus();
    });

    // 监听配置仓库外部变动
    _configSubscription =
        _configRepository.windowConfigStream.listen(_onConfigChanged);
  }

  void _onConfigChanged(DesktopWindowConfig config) {
    if (isAlwaysOnTopNotifier.value != config.alwaysOnTop) {
      isAlwaysOnTopNotifier.value = config.alwaysOnTop;
    }
  }

  /// 切换全屏播放状态
  Future<void> toggleFullScreen() async {
    final currentlyFullScreen = await windowManager.isFullScreen();
    final nextState = !currentlyFullScreen;
    await windowManager.setFullScreen(nextState);
    isFullScreenNotifier.value = nextState;
    _schedulePersistWindowGeometry();
  }

  /// 切换置顶状态
  Future<void> toggleAlwaysOnTop() async {
    final nextState = !isAlwaysOnTopNotifier.value;
    await windowManager.setAlwaysOnTop(nextState);
    isAlwaysOnTopNotifier.value = nextState;
    _schedulePersistWindowGeometry();
  }

  /// 切换窗口最大化 / 还原
  Future<void> toggleMaximize() async {
    final isMax = await windowManager.isMaximized();
    if (isMax) {
      await windowManager.unmaximize();
      isMaximizedNotifier.value = false;
    } else {
      await windowManager.maximize();
      isMaximizedNotifier.value = true;
    }
    _schedulePersistWindowGeometry();
  }

  /// 开始拖拽移动窗口
  Future<void> startDragging() async {
    await windowManager.startDragging();
  }

  /// 最小化窗口到任务栏
  Future<void> minimize() async {
    await windowManager.minimize();
  }

  /// 关闭窗口
  Future<void> close() =>
      _closing ??= _close().catchError((Object error, StackTrace stack) {
        _closing = null;
        Error.throwWithStackTrace(error, stack);
      });

  Future<void> _close() async {
    _debounceSaveTimer?.cancel();
    await beforeClose?.call();
    await _flushPersistWindowGeometry();
    await windowManager.destroy();
  }

  // --- WindowListener 回调处理 ---

  @override
  void onWindowMoved() {
    _schedulePersistWindowGeometry();
  }

  @override
  void onWindowResized() {
    _schedulePersistWindowGeometry();
  }

  @override
  void onWindowMaximize() {
    isMaximizedNotifier.value = true;
    _schedulePersistWindowGeometry();
  }

  @override
  void onWindowUnmaximize() {
    isMaximizedNotifier.value = false;
    _schedulePersistWindowGeometry();
  }

  @override
  void onWindowClose() {
    unawaited(close().catchError((Object error, StackTrace stack) {
      debugPrint('[xiugou-tv] close failed; window kept open: $error\n$stack');
    }));
  }

  /// 防抖保存窗口几何参数至持久化配置，避免高频拖拽导致频繁磁盘 I/O
  void _schedulePersistWindowGeometry() {
    if (_closing != null) return;
    _debounceSaveTimer?.cancel();
    _debounceSaveTimer = Timer(_debounceDuration, () {
      _flushPersistWindowGeometry();
    });
  }

  /// 立即强制执行几何状态持久化
  Future<void> _flushPersistWindowGeometry() async {
    try {
      final isMax = await windowManager.isMaximized();
      final isFull = await windowManager.isFullScreen();
      final size = await windowManager.getSize();
      final pos = await windowManager.getPosition();

      final current = _configRepository.currentWindowConfig;
      final updated = current.copyWith(
        width: isMax || isFull ? current.width : size.width,
        height: isMax || isFull ? current.height : size.height,
        posX: isMax || isFull ? current.posX : pos.dx,
        posY: isMax || isFull ? current.posY : pos.dy,
        isMaximized: isMax,
        isFullScreen: isFull,
        alwaysOnTop: isAlwaysOnTopNotifier.value,
      );

      await _configRepository.updateWindowConfig(updated);
    } catch (_) {
      // 忽略窗口在销毁瞬间获取尺寸失败的偶发异常
    }
  }

  /// 释放窗口监听与定时器资源
  void dispose() {
    _debounceSaveTimer?.cancel();
    _configSubscription?.cancel();
    windowManager.removeListener(this);
    isFullScreenNotifier.dispose();
    isMaximizedNotifier.dispose();
    isAlwaysOnTopNotifier.dispose();
  }
}
