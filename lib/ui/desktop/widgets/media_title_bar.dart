import 'package:flutter/material.dart';

import '../../theme/app_tokens.dart';
import '../window/desktop_window_manager.dart';
import 'focus_ring.dart';

/// 播放和影片详情共用的顶栏；有窗口管理器时才接管拖动和窗口三键。
class MediaTitleBar extends StatelessWidget {
  const MediaTitleBar({
    super.key,
    required this.scope,
    this.title = '',
    this.onBack,
    this.backTooltip = '返回',
    this.backKey,
    this.leadingAccessory,
    this.actions = const [],
    this.windowManager,
    this.onTitleDoubleTap,
  });

  static const height = 54.0;
  final String scope, title, backTooltip;
  final Key? backKey;
  final VoidCallback? onBack, onTitleDoubleTap;
  final Widget? leadingAccessory;
  final List<Widget> actions;
  final DesktopWindowManager? windowManager;

  @override
  Widget build(BuildContext context) => Container(
    height: height,
    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
    decoration: const BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xCC000000), Colors.transparent],
      ),
    ),
    child: Row(
      children: [
        if (onBack != null)
          FocusOutline(
            radius: AppRadii.pill,
            child: IconButton(
              key: backKey,
              icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
              tooltip: backTooltip,
              onPressed: onBack,
            ),
          ),
        const SizedBox(width: AppSpacing.sm),
        if (leadingAccessory case final accessory?) ...[
          accessory,
          const SizedBox(width: AppSpacing.sm),
        ],
        Expanded(
          child: GestureDetector(
            key: ValueKey('$scope-drag-region'),
            behavior: HitTestBehavior.opaque,
            onPanStart: windowManager == null
                ? null
                : (_) => windowManager!.startDragging(),
            onDoubleTap: onTitleDoubleTap,
            child: Align(
              alignment: Alignment.centerLeft,
              child: title.isEmpty
                  ? null
                  : Text(
                      title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: AppType.title,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
            ),
          ),
        ),
        ...actions,
        if (windowManager case final window?) ...[
          const SizedBox(width: AppSpacing.xs),
          _windowButton(
            'minimize',
            '最小化窗口',
            Icons.remove_rounded,
            window.minimize,
          ),
          ValueListenableBuilder<bool>(
            valueListenable: window.isMaximizedNotifier,
            builder: (_, maximized, _) => _windowButton(
              'maximize',
              maximized ? '还原窗口' : '最大化窗口',
              maximized ? Icons.filter_none_rounded : Icons.crop_square_rounded,
              window.toggleMaximize,
            ),
          ),
          _windowButton(
            'close',
            '关闭窗口',
            Icons.close_rounded,
            window.onWindowClose,
          ),
        ],
      ],
    ),
  );

  Widget _windowButton(
    String name,
    String tooltip,
    IconData icon,
    VoidCallback action,
  ) => IconButton(
    key: ValueKey('$scope-window-$name'),
    iconSize: 17,
    visualDensity: VisualDensity.compact,
    tooltip: tooltip,
    icon: Icon(icon, color: Colors.white),
    onPressed: action,
  );
}
