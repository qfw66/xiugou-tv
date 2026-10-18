import 'dart:async';
import 'package:flutter/material.dart';

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
class PlayerOsdOverlay extends StatelessWidget {
  final OsdController controller;

  const PlayerOsdOverlay({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final msg = controller.currentMessage;
        return IgnorePointer(
          child: AnimatedOpacity(
            opacity: controller.isVisible ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 180),
            child: Align(
              alignment: const Alignment(0.0, -0.65),
              child: msg == null
                  ? const SizedBox.shrink()
                  : Container(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                      decoration: BoxDecoration(
                        color: const Color(0xCC181820),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0x33FFFFFF), width: 1),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x66000000),
                            blurRadius: 16,
                            offset: Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(msg.icon, color: const Color(0xFFE50914), size: 28),
                          const SizedBox(width: 12),
                          Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                msg.text,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 15,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              if (msg.subText != null) ...[
                                const SizedBox(height: 2),
                                Text(
                                  msg.subText!,
                                  style: const TextStyle(
                                    color: Color(0xFFA0A0B0),
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
            ),
          ),
        );
      },
    );
  }
}
