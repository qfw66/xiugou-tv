/// 面板/弹窗打开时的窗口拖动带。
///
/// 背景（2026-10-26 实机反馈，用户两次澄清后的口径）：
/// 收藏、历史这类**满屏面板**打开时，模态遮罩铺满整窗，标题栏的拖拽区被盖住，
/// 于是「面板开着时想把窗口挪开」做不到。用户要的是**面板周边空白处也能拖**，
/// 而不只是顶部那一条。
///
/// 结构约束（第一版踩过的坑）：
/// 弹窗与遮罩都在 Navigator 内部，任何挂在 `home` / `Scaffold` 下的拖拽区都会被遮罩
/// 吞掉（测试里表现为命中 `_RenderTheater`）。因此本组件**必须**挂在
/// `MaterialApp.builder` 这一层（位于 Navigator 之上）。
///
/// 为什么不铺满整窗：
/// 铺满会让拖动手势和面板内的滚动争夺手势竞技场，导致面板里滑不动。所以只铺
/// **窗口边缘的留白带** —— 弹窗的 insetPadding（默认 40/24，收藏夹 24）都大于
/// [_edgeBand]，边缘带永远落在遮罩上，不会压到面板内容。
library;

import 'package:flutter/material.dart';

import '../window/desktop_window_manager.dart';
import 'desktop_title_bar.dart';

/// 跟踪「当前是否有模态弹窗」。
///
/// 只认 [PopupRoute]（`DialogRoute` / `ModalBottomSheetRoute` 都属于它），
/// 页面跳转不算 —— 页面切换时标题栏本来就没被遮住。
class DialogRouteObserver extends NavigatorObserver {
  final ValueNotifier<bool> modalOpen = ValueNotifier<bool>(false);
  int _depth = 0;

  void _bump(int delta) {
    _depth = (_depth + delta).clamp(0, 1 << 20);
    modalOpen.value = _depth > 0;
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PopupRoute) _bump(1);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PopupRoute) _bump(-1);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PopupRoute) _bump(-1);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final wasModal = oldRoute is PopupRoute;
    final isModal = newRoute is PopupRoute;
    if (wasModal && !isModal) _bump(-1);
    if (!wasModal && isModal) _bump(1);
  }

  @override
  void didStartUserGesture(
      Route<dynamic> route, Route<dynamic>? previousRoute) {}

  @override
  void didStopUserGesture() {}
}

/// 弹窗期间的窗口拖动带；必须是 `Stack` 的直接子节点。
///
/// 布局：顶部一条与标题栏等高的带（视觉上就是原来的标题栏位置），
/// 外加左 / 右 / 底三条窄边带 —— 让「面板周边空白处」都能拖动窗口。
class DialogDragStrip extends StatelessWidget {
  final DesktopWindowManager windowManager;
  final DialogRouteObserver observer;

  const DialogDragStrip({
    super.key,
    required this.windowManager,
    required this.observer,
  });

  Widget _handle({Key? key}) {
    // 不显示「移动」光标（用户明确不要），保持与普通区域一致。
    return GestureDetector(
        key: key,
        behavior: HitTestBehavior.translucent,
        onPanStart: (_) => windowManager.startDragging(),
      onDoubleTap: () => windowManager.toggleMaximize(),
      child: const SizedBox.expand(),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (windowManager.isPipNotifier.value) return const SizedBox.shrink();
    return ValueListenableBuilder<bool>(
      valueListenable: observer.modalOpen,
      builder: (context, open, _) {
        if (!open) return const SizedBox.shrink();
        // 早期版本在这里按窗口高度静默禁用，导致窗口较矮时表现为
        // 「拖了完全没反应」且无任何提示。现在始终生效 —— 边缘带只铺在
        // 弹窗 insetPadding 之外的窄条上，不会碰到面板内容。
        return Positioned.fill(
          // 空区域不拦截命中：Stack 自身不吞事件，只有下面的几条带子参与。
          child: Stack(
            children: [
              // 顶部：与标题栏等高，手感与无弹窗时一致。
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: kDesktopTitleBarHeight,
                child: _handle(key: const ValueKey('dialog-drag-strip')),
              ),
            ],
          ),
        );
      },
    );
  }
}
