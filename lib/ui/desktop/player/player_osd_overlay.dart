import 'dart:async';
import 'dart:ui';
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

/// 播放器屏幕实时交互浮层提示组件 (On-Screen Display - Infuse 微透磨砂风格)
class PlayerOsdOverlay extends StatefulWidget {
  final OsdController controller;

  const PlayerOsdOverlay({super.key, required this.controller});

  @override
  State<PlayerOsdOverlay> createState() => _PlayerOsdOverlayState();
}

class _PlayerOsdOverlayState extends State<PlayerOsdOverlay> {
  /// 淡出期间保留的最后一条内容（离场不提前清空内容，避免闪烁）。
  OsdMessage? _lastMessage;

  /// 进 200ms / 出 140ms（D2 动效节奏，离开更快更跟手）。
  Duration _motion({required bool visible}) =>
      visible ? AppMotion.enter : AppMotion.exit;

  /// 淡出动画结束后清空内容（子树回到空，不驻留旧文案与语义）。
  void _clearWhenHidden() {
    if (!mounted) return;
    if (widget.controller.currentMessage == null && _lastMessage != null) {
      setState(() => _lastMessage = null);
    }
  }

  /// 尝试从文本中解析百分比（如 "音量: 75%" -> 0.75）以展示进度微光条
  double? _tryParsePercent(String text) {
    if (!text.contains('%')) return null;
    final match = RegExp(r'(\d+)%').firstMatch(text);
    if (match != null) {
      final value = int.tryParse(match.group(1) ?? '');
      if (value != null) {
        return (value / 100.0).clamp(0.0, 1.0);
      }
    }
    return null;
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
    final percent = _tryParsePercent(msg.text);

    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadii.lg),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          constraints: const BoxConstraints(minWidth: 140, maxWidth: 360),
          decoration: BoxDecoration(
            color: const Color(0xCC101014),
            borderRadius: BorderRadius.circular(AppRadii.lg),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.16),
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.45),
                blurRadius: 28,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.lg,
                  vertical: AppSpacing.md,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 图标微光徽章底座
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(AppRadii.sm),
                        border: Border.all(
                          color: palette.accentInk.withValues(alpha: 0.28),
                          width: 1,
                        ),
                      ),
                      child: Center(
                        child: Icon(
                          msg.icon,
                          color: palette.accentInk,
                          size: 22,
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    // 状态说明文本
                    Flexible(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            msg.text,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: AppType.heading,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.2,
                              fontFeatures: [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (msg.subText != null) ...[
                            const SizedBox(height: 3),
                            Text(
                              msg.subText!,
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.72),
                                fontSize: AppType.body,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              // 如果包含百分比，展示底部细线微发光进度条（3px）
              if (percent != null)
                Container(
                  height: 3,
                  width: double.infinity,
                  color: Colors.white.withValues(alpha: 0.10),
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor: percent,
                    child: Container(
                      decoration: BoxDecoration(
                        color: palette.accentInk,
                        boxShadow: [
                          BoxShadow(
                            color: palette.accentInk.withValues(alpha: 0.6),
                            blurRadius: 4,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
