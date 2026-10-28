import 'dart:ui';

import '../../../core/config/models/desktop_window_config.dart';

/// 窗口几何守卫（2026-10-28 v1.0.2 启动不显示页面热修，§47）。
///
/// 事故：最小化状态下关闭软件（任务栏右键「关闭窗口」等），Windows 报告的窗口几何是
/// 「最小化占位」——位置 (-32000,-32000)（150% 缩放下即 -21333）、尺寸 158×26。
/// 旧逻辑原样落盘，下次启动窗口被摆到屏幕外，用户看到「进程在、页面不显示」。
///
/// 两道防线（都在这里收口，便于单测钉住）：
/// 1. 写入侧 [isPersistableGeometry]：最小化、或尺寸小到不可能是真实窗口时，不写几何；
/// 2. 读取侧 [sanitizeWindowGeometry]：启动时尺寸过小回落默认值、位置与任何显示器
///    工作区都没有足够重叠则清空位置（改为居中）——已被写坏配置的老用户升级后自动恢复。
abstract final class WindowGeometryGuard {
  /// 可信窗口尺寸下限：取画中画小窗的最小尺寸 320×180。比它还小的只可能是
  /// 最小化占位（158×26）或销毁瞬间的脏读，不是用户真实摆放的窗口。
  static const Size minimumSize = Size(320, 180);

  /// 默认窗口尺寸（与 [DesktopWindowConfig] 的默认值一致）。
  static const Size defaultSize = Size(1280, 720);

  /// 窗口与工作区至少要重叠这么大，才算「用户看得见、拖得回来」。
  /// 取标题栏级别的一小块：横向 120、纵向 40。
  static const double _minVisibleWidth = 120;
  static const double _minVisibleHeight = 40;

  /// 浮点误差容忍：DPI 换算后尺寸常见 959.9999 / 960.0000001 这类值。
  static const double _epsilon = 1;

  /// 当前窗口几何是否值得落盘。
  ///
  /// [minimized] 为 true（最小化）时一律不写；尺寸小于 [minimumSize] 也不写，
  /// 那只会是最小化占位或销毁瞬间的脏读。
  /// 画中画小窗不走这里（落盘用进入前的快照）。
  static bool isPersistableGeometry({
    required bool minimized,
    required Size size,
  }) {
    if (minimized) return false;
    return size.width + _epsilon >= minimumSize.width &&
        size.height + _epsilon >= minimumSize.height;
  }

  /// 启动前清洗已保存的窗口几何。
  ///
  /// [workAreas] 为各显示器工作区（逻辑像素）；为空表示取不到显示器信息，此时只剔除
  /// 明显的最小化占位坐标（≤ -10000），不误伤多屏用户的负坐标副屏。
  static DesktopWindowConfig sanitizeWindowGeometry(
    DesktopWindowConfig config,
    List<Rect> workAreas,
  ) {
    var width = config.width;
    var height = config.height;
    if (!width.isFinite ||
        !height.isFinite ||
        width + _epsilon < minimumSize.width ||
        height + _epsilon < minimumSize.height) {
      width = defaultSize.width;
      height = defaultSize.height;
    }

    final posX = config.posX;
    final posY = config.posY;
    var keepPosition = posX != null && posY != null;
    if (keepPosition) {
      if (!posX.isFinite || !posY.isFinite) {
        keepPosition = false;
      } else if (workAreas.isEmpty) {
        keepPosition = posX > -10000 && posY > -10000;
      } else {
        final window = Rect.fromLTWH(posX, posY, width, height);
        keepPosition = workAreas.any((area) {
          final overlap = window.intersect(area);
          return overlap.width >= _minVisibleWidth &&
              overlap.height >= _minVisibleHeight;
        });
      }
    }

    if (keepPosition &&
        width == config.width &&
        height == config.height) {
      return config;
    }
    return DesktopWindowConfig(
      width: width,
      height: height,
      posX: keepPosition ? posX : null,
      posY: keepPosition ? posY : null,
      isMaximized: config.isMaximized,
      isFullScreen: config.isFullScreen,
      alwaysOnTop: config.alwaysOnTop,
      playerEngine: config.playerEngine,
      hardwareDecoding: config.hardwareDecoding,
      volume: config.volume,
      lastConfigUrl: config.lastConfigUrl,
      depotPath: config.depotPath,
      themeMode: config.themeMode,
    );
  }
}
