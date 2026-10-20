import 'dart:async';
import 'package:flutter/material.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';

/// 屏幕浮动指示消息数据模型
class OsdMessage {
  final IconData icon;
  final String text;
  final String? subText;

  const OsdMessage({
    required this.icon,
    required this.text,
    this.subText,
  });
}

/// 屏幕浮层控制器
class OsdController extends ChangeNotifier {
  OsdMessage? _currentMessage;
  Timer? _dismissTimer;
  static const Duration _displayDuration = Duration(milliseconds: 1200);

  OsdMessage? get currentMessage => _currentMessage;
  bool get isVisible => _currentMessage != null;

  void show(IconData icon, String text, {String? subText}) {
    _dismissTimer?.cancel();
    _currentMessage = OsdMessage(icon: icon, text: text, subText: subText);
    notifyListeners();

    _dismissTimer = Timer(_displayDuration, () {
      _currentMessage = null;
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _dismissTimer?.cancel();
    super.dispose();
  }
}

/// 播放器屏幕实时交互浮层提示组件 (On-Screen Display)
class PlayerOsdOverlay extends StatefulWidget {
  final OsdController controller;

  const PlayerOsdOverlay({super.key, required this.controller});

  @override
  State<PlayerOsdOverlay> createState() => _PlayerOsdOverlayState();
}

class _PlayerOsdOverlayState extends State<PlayerOsdOverlay> {
  /// 淡出期间保留的最后一条内容（B5：离场不再先清空再淡出）。
  OsdMessage? _lastMessage;

  /// 进 200 / 出 140（D2），与播放器控制层同一节奏。
  Duration _motion({required bool visible}) =>
      visible ? AppMotion.enter : AppMotion.exit;

  /// 淡出动画结束后清空内容（子树回到空，不驻留旧文案与语义）。
  void _clearWhenHidden() {
    if (!mounted) return;
    if (widget.controller.currentMessage == null && _lastMessage != null) {
      setState(() => _lastMessage = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final msg = widget.controller.currentMessage;
        if (msg != null) _lastMessage = msg;
        final visible = msg != null;
        final display = msg ?? _lastMessage;
        return IgnorePointer(
          child: AnimatedOpacity(
            opacity: visible ? 1.0 : 0.0,
            duration: _motion(visible: visible),
            onEnd: _clearWhenHidden,
            child: Align(
              alignment: const Alignment(0.0, -0.65),
              child: display == null
                  ? const SizedBox.shrink()
                  : TweenAnimationBuilder<double>(
                      // 进场自下方 8px 上浮；离场回落（与淡出同节奏）。
                      tween: Tween<double>(end: visible ? 0.0 : 8.0),
                      duration: _motion(visible: visible),
                      curve: AppMotion.ease,
                      builder: (context, dy, child) => Transform.translate(
                        offset: Offset(0, dy),
                        child: child,
                      ),
                      child: _buildCard(palette, display),
                    ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildCard(AppPalette palette, OsdMessage msg) {
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg, vertical: AppSpacing.md),
      decoration: BoxDecoration(
        color: palette.playerChrome,
        borderRadius: BorderRadius.circular(AppRadii.md),
        border: Border.all(
            color: palette.playerText.withValues(alpha: 0.2), width: 1),
        boxShadow: const [
          BoxShadow(
            // 浮层阴影固定黑色，与主题无关
            color: Color(0x66000000),
            blurRadius: 16,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(msg.icon, color: palette.accentInk, size: 28),
          const SizedBox(width: AppSpacing.md),
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                msg.text,
                style: TextStyle(
                  color: palette.playerText,
                  fontSize: AppType.heading,
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (msg.subText != null) ...[
                const SizedBox(height: AppSpacing.xs),
                Text(
                  msg.subText!,
                  style: TextStyle(
                    color: palette.playerText.withValues(alpha: 0.7),
                    fontSize: AppType.body,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
