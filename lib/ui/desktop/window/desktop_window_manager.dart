import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';
import '../../../core/config/config_repository.dart';
import '../../../core/config/models/desktop_window_config.dart';
import 'window_geometry_guard.dart';

/// Windows 桌面原生窗口生命周期与几何形态管理控制器
class DesktopWindowManager with WindowListener {
  final ConfigRepository _configRepository;
  final Future<void> Function()? beforeClose;

  final ValueNotifier<bool> isFullScreenNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<bool> isMaximizedNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<bool> isAlwaysOnTopNotifier = ValueNotifier<bool>(false);

  /// 画中画（PiP）小窗模式：true 期间宿主隐藏自绘标题栏（无边框），
  /// 保留原生边缘拖拽缩放（自由比例），且窗口几何不写入配置
  /// （落盘用进入前的快照，避免下次启动开成小窗）。
  final ValueNotifier<bool> isPipNotifier = ValueNotifier<bool>(false);

  /// 沉浸播放（§38）：播放页激活且用户开启「播放时隐藏标题栏」期间为 true。
  ///
  /// 与 PiP 并列放在窗口层：业务页销毁不会让窗口卡在无标题栏状态，
  /// 退出播放页时由播放器 `dispose` 复位。
  final ValueNotifier<bool> isImmersiveNotifier = ValueNotifier<bool>(false);


  /// PiP 小窗尺寸（16:9）。
  static const Size pipWindowSize = Size(400, 225);
  static const Size _normalMinimumSize = Size(960, 540);
  static const Size _pipMinimumSize = Size(320, 180);

  // 进入 PiP 前的几何 / 状态快照（还原用）。
  Size? _pipRestoreSize;
  Offset? _pipRestorePos;
  bool _pipRestoreMaximized = false;
  bool _pipRestoreFullScreen = false;
  bool _pipRestoreAlwaysOnTop = false;
  bool _pipBusy = false;
  Future<void>? _closing;
  Timer? _debounceSaveTimer;
  StreamSubscription<DesktopWindowConfig>? _configSubscription;
  static const Duration _debounceDuration = Duration(milliseconds: 500);

  DesktopWindowManager(
      {required ConfigRepository configRepository, this.beforeClose})
      : _configRepository = configRepository;

  /// 初始化原生窗口尺寸、位置、标题与无边框属性
  ///
  /// [backgroundColor] 由调用方按已保存的主题给出，避免浅色主题启动时闪深色边；
  /// [iconPath] 是任务栏 / 窗口图标的磁盘路径（随主题选择浅色或深色版）。
  Future<void> initialize({
    // 原生窗口默认底色；调用方会传入当前主题的 background，这里只覆盖极早期窗口。
    Color backgroundColor = const Color(0xFF101014),
    String? iconPath,
  }) async {
    await windowManager.ensureInitialized();
    windowManager.addListener(this);
    await windowManager.setPreventClose(true);

    // §47 启动不显示页面热修：已保存的几何若是最小化占位 / 屏幕外坐标，先清洗再用。
    final initialConfig = WindowGeometryGuard.sanitizeWindowGeometry(
      _configRepository.currentWindowConfig,
      await _displayWorkAreas(),
    );

    final windowOptions = WindowOptions(
      size: const Size(1280, 720),
      minimumSize: const Size(960, 540),
      center: true,
      backgroundColor: backgroundColor,
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

      if (iconPath != null) {
        await _setIconQuietly(iconPath);
      }

      await windowManager.show();
      await windowManager.focus();
    });

    // 监听配置仓库外部变动
    _configSubscription =
        _configRepository.windowConfigStream.listen(_onConfigChanged);
  }

  /// 各显示器工作区（逻辑像素）。取不到时返回空列表，由守卫退化为只剔除占位坐标。
  Future<List<Rect>> _displayWorkAreas() async {
    try {
      final displays = await screenRetriever.getAllDisplays();
      return [
        for (final d in displays)
          if (d.visiblePosition != null && d.visibleSize != null)
            d.visiblePosition! & d.visibleSize!
          else
            Offset.zero & d.size,
      ];
    } catch (_) {
      return const [];
    }
  }

  /// 主题切换时更新原生窗口底色；失败不影响界面（最多是缩放时露旧色）。
  void applyBackgroundColor(Color color) {
    unawaited(
        windowManager.setBackgroundColor(color).catchError((Object _) {}));
  }

  /// 主题切换时更新任务栏 / 窗口图标；文件缺失时静默保留旧图标。
  void applyIcon(String iconPath) {
    unawaited(_setIconQuietly(iconPath));
  }

  Future<void> _setIconQuietly(String iconPath) async {
    try {
      if (!File(iconPath).existsSync()) return;
      await windowManager.setIcon(iconPath);
    } catch (_) {
      // 图标设置失败不影响启动
    }
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

  /// 进入画中画小窗：先退全屏 / 取消最大化，记住原几何与置顶值，缩为
  /// [pipWindowSize] 贴主屏右下角并置顶；[isPipNotifier] 置位后宿主隐藏自绘
  /// 标题栏（无边框）。小窗保持可缩放：可拖四边 / 四角自由拉伸，退出时仍按
  /// 进入前快照全量还原。PiP 期间窗口几何不写入配置（见 [_flushPersistWindowGeometry]）。
  Future<void> enterPip() async {
    if (_pipBusy || isPipNotifier.value) return;
    _pipBusy = true;
    _debounceSaveTimer?.cancel();
    try {
      _pipRestoreFullScreen = await windowManager.isFullScreen();
      if (_pipRestoreFullScreen) {
        await windowManager.setFullScreen(false);
        isFullScreenNotifier.value = false;
      }
      _pipRestoreMaximized = await windowManager.isMaximized();
      if (_pipRestoreMaximized) {
        await windowManager.unmaximize();
        isMaximizedNotifier.value = false;
      }
      _pipRestoreSize = await windowManager.getSize();
      _pipRestorePos = await windowManager.getPosition();
      _pipRestoreAlwaysOnTop = isAlwaysOnTopNotifier.value;
      await windowManager.setMinimumSize(_pipMinimumSize);
      // 小窗保留原生边缘拖拽缩放（自由比例，下限 _pipMinimumSize）：
      // setResizable(false) 会摘掉 WS_THICKFRAME 并令窗口边缘命中返回
      // HTNOWHERE，用户将完全无法拉伸小窗；保持 true 让四边 / 四角可拖。
      await windowManager.setResizable(true);
      await windowManager.setAlwaysOnTop(true);
      isAlwaysOnTopNotifier.value = true;
      await windowManager.setSize(pipWindowSize);
      await windowManager.setPosition(await _pipBottomRight());
      isPipNotifier.value = true;
    } finally {
      _pipBusy = false;
    }
  }

  /// 小窗右下角落点：以主屏工作区为准留 16px 边距；显示器信息不可用时
  /// 保持当前位置（不阻断小窗链路）。
  Future<Offset> _pipBottomRight() async {
    const margin = 16.0;
    try {
      final display = await screenRetriever.getPrimaryDisplay();
      final pos = display.visiblePosition ?? Offset.zero;
      final size = display.visibleSize ?? display.size;
      return Offset(
        pos.dx + size.width - pipWindowSize.width - margin,
        pos.dy + size.height - pipWindowSize.height - margin,
      );
    } catch (_) {
      return await windowManager.getPosition();
    }
  }

  /// 退出画中画：恢复原尺寸 / 位置 / 置顶值与最小窗口，并恢复几何落盘。
  Future<void> exitPip() async {
    if (_pipBusy || !isPipNotifier.value) return;
    _pipBusy = true;
    try {
      await windowManager.setAlwaysOnTop(_pipRestoreAlwaysOnTop);
      isAlwaysOnTopNotifier.value = _pipRestoreAlwaysOnTop;
      await windowManager.setResizable(true);
      await windowManager.setMinimumSize(_normalMinimumSize);
      final size = _pipRestoreSize;
      final pos = _pipRestorePos;
      if (size != null) await windowManager.setSize(size);
      if (pos != null) await windowManager.setPosition(pos);
      if (_pipRestoreMaximized) {
        await windowManager.maximize();
        isMaximizedNotifier.value = true;
      }
      if (_pipRestoreFullScreen) {
        await windowManager.setFullScreen(true);
        isFullScreenNotifier.value = true;
      }
      isPipNotifier.value = false;
      _schedulePersistWindowGeometry();
    } finally {
      _pipBusy = false;
    }
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

  /// 切换「沉浸播放」状态（§38）。只在值真的变化时才通知，避免逐帧重建。
  void setImmersive(bool value) {
    if (isImmersiveNotifier.value == value) return;
    isImmersiveNotifier.value = value;
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
    // 关闭过慢优化：先把窗口从用户眼前移除（原生调用，瞬时），再在后台完成
    // 退出钩子与几何落盘，最后 destroy。companion 正常关机实测约 1s（JVM 自身
    // 收尾耗时），旧顺序会让窗口干等这段时间，用户感知为「点了 X 不关」。
    try {
      await windowManager.hide();
    } catch (_) {
      // 隐藏失败（罕见）不阻断关闭链：窗口保持可见，行为退化为旧路径。
    }
    try {
      await beforeClose?.call();
      await _flushPersistWindowGeometry();
      await windowManager.destroy();
    } catch (error, stack) {
      // 保留「失败不销毁窗口、可重试」语义（test/desktop_shutdown_test.dart 钉住）：
      // 把已隐藏的窗口恢复出来，让用户能再次点关闭；外层 close() 会清空
      // _closing 以允许重试。
      try {
        await windowManager.show();
      } catch (_) {
        // 恢复显示失败也不能掩盖原始错误。
      }
      Error.throwWithStackTrace(error, stack);
    }
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
    // PiP 期间的小窗移动 / 缩放不入队落盘（关闭时由 _flush 用快照兜底）。
    if (_closing != null || isPipNotifier.value) return;
    _debounceSaveTimer?.cancel();
    _debounceSaveTimer = Timer(_debounceDuration, () {
      _flushPersistWindowGeometry();
    });
  }

  /// 立即强制执行几何状态持久化
  Future<void> _flushPersistWindowGeometry() async {
    try {
      // PiP 期间窗口处于小窗几何：落盘必须用进入前的快照，避免把
      // 400×225 写进配置导致下次启动开成小窗；小窗中关闭应用同理。
      final pip = isPipNotifier.value;
      final isMax =
          pip ? _pipRestoreMaximized : await windowManager.isMaximized();
      final isFull =
          pip ? _pipRestoreFullScreen : await windowManager.isFullScreen();
      final size = pip
          ? (_pipRestoreSize ?? const Size(1280, 720))
          : await windowManager.getSize();
      final pos = pip
          ? (_pipRestorePos ?? await windowManager.getPosition())
          : await windowManager.getPosition();

      final current = _configRepository.currentWindowConfig;
      // §47：最小化（任务栏右键关闭）时 Windows 报告的是占位几何 (-32000,-32000) / 158×26，
      // 此时 isMaximized 也读不准——几何与最大化状态都保留旧值，只同步置顶。
      final minimized = !pip && await windowManager.isMinimized();
      final skipGeometry = minimized ||
          (!pip &&
              !(isMax || isFull) &&
              !WindowGeometryGuard.isPersistableGeometry(
                  minimized: false, size: size));
      if (skipGeometry) {
        if (current.alwaysOnTop != isAlwaysOnTopNotifier.value) {
          await _configRepository.updateWindowConfig(
              current.copyWith(alwaysOnTop: isAlwaysOnTopNotifier.value));
        }
        return;
      }
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
    isPipNotifier.dispose();
    isImmersiveNotifier.dispose();
  }
}
