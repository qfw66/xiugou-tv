import 'package:flutter/material.dart';
import '../window/desktop_window_manager.dart';
import 'desktop_title_bar.dart';

class DesktopWindowFrame extends StatelessWidget {
  final DesktopWindowManager windowManager;
  final Widget child;
  final String? activeSiteName;
  final VoidCallback? onSettingsPressed;
  final VoidCallback? onSiteSelectorPressed;

  const DesktopWindowFrame({
    super.key,
    required this.windowManager,
    required this.child,
    this.activeSiteName,
    this.onSettingsPressed,
    this.onSiteSelectorPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF101014),
      body: Column(
        children: [
          DesktopTitleBar(
            windowManager: windowManager,
            activeSiteName: activeSiteName,
            onSettingsPressed: onSettingsPressed,
            onSiteSelectorPressed: onSiteSelectorPressed,
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}
