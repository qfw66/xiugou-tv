/// 水平滚动条容器：让桌面鼠标也能左右滚动。
///
/// 问题（2026-10-26 实机反馈）：「影片分类太多的情况下没办法左右滚动」。
/// 原因有两层：
/// 1. Flutter 桌面默认 [ScrollBehavior] 的 `dragDevices` **不含鼠标** —— 按住拖不动；
/// 2. 水平 `ListView` 只消费 `scrollDelta.dx`，而普通鼠标滚轮只有 `dy` —— 滚轮也无效。
///
/// 所以这里两件事一起做：把鼠标加进拖拽设备，并把竖向滚轮增量映射到横向滚动。
/// 与搜索站点栏（`_handleSearchSiteBarPointerSignal`）的口径保持一致：
/// 只映射 dy，横滑（dx）留给 Scrollable 自己处理，避免双倍滚动。
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
    if (event is! PointerScrollEvent) return;
    final delta = event.scrollDelta.dy;
    if (delta == 0 || !controller.hasClients) return;
    final position = controller.position;
    final target = (position.pixels + delta)
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    if (target != position.pixels) controller.jumpTo(target);
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
