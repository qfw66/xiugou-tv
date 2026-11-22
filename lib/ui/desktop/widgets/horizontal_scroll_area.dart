/// 桌面横栏支持鼠标拖动和滚轮；触控板保留原生方向。
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

class HorizontalScrollArea extends StatelessWidget {
  final ScrollController controller;
  final Widget child;

  /// 是否显示滚动条（默认隐藏，胶囊条里出现滚动条很挤）。
  final bool showScrollbar;

  const HorizontalScrollArea({
    super.key,
    required this.controller,
    required this.child,
    this.showScrollbar = false,
  });

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent ||
        event.kind != PointerDeviceKind.mouse ||
        event.scrollDelta.dx != 0 ||
        event.scrollDelta.dy == 0 ||
        !controller.hasClients) {
      return;
    }
    final position = controller.position;
    if (!position.physics.shouldAcceptUserOffset(position)) return;
    final delta = axisDirectionIsReversed(position.axisDirection)
        ? -event.scrollDelta.dy
        : event.scrollDelta.dy;
    if (delta > 0 ? position.extentAfter == 0 : position.extentBefore == 0) {
      return;
    }
    // 与内外层 Scrollable 仲裁同一事件；到边时不登记，由外层接手。
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      position.pointerScroll(delta);
      event.respond(allowPlatformDefault: false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final content = ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(
        // 关键：桌面鼠标默认不在 dragDevices 里，补上才能按住拖动。
        dragDevices: const {
          PointerDeviceKind.touch,
          PointerDeviceKind.mouse,
          PointerDeviceKind.trackpad,
          PointerDeviceKind.stylus,
          PointerDeviceKind.invertedStylus,
        },
        scrollbars: showScrollbar,
      ),
      child: child,
    );
    return Listener(onPointerSignal: _onPointerSignal, child: content);
  }
}
