import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// --- 快捷键意图 (Intents) ---

class PlayPauseIntent extends Intent {
  const PlayPauseIntent();
}

class SeekIntent extends Intent {
  final Duration delta;
  const SeekIntent(this.delta);
}

class VolumeIntent extends Intent {
  final double delta;
  const VolumeIntent(this.delta);
}

class ToggleMuteIntent extends Intent {
  const ToggleMuteIntent();
}

class ToggleFullscreenIntent extends Intent {
  const ToggleFullscreenIntent();
}

class ExitFullscreenIntent extends Intent {
  const ExitFullscreenIntent();
}

class RateAdjustIntent extends Intent {
  final double delta;
  final bool reset;
  const RateAdjustIntent(this.delta, {this.reset = false});
}

class PrevEpisodeIntent extends Intent {
  const PrevEpisodeIntent();
}

class NextEpisodeIntent extends Intent {
  const NextEpisodeIntent();
}

/// §43 弹幕开 / 关
class ToggleDanmakuIntent extends Intent {
  const ToggleDanmakuIntent();
}

/// 默认桌面播放器键位绑定字典
final Map<ShortcutActivator, Intent> defaultPlayerShortcuts = {
  // 播放 / 暂停
  const SingleActivator(LogicalKeyboardKey.space): const PlayPauseIntent(),
  const SingleActivator(LogicalKeyboardKey.keyK): const PlayPauseIntent(),

  // 快退 / 快进 (小步进 10 秒)
  const SingleActivator(LogicalKeyboardKey.arrowLeft): const SeekIntent(Duration(seconds: -10)),
  // → 单击快进由 [HoldToSpeedGesture] 判定（长按改为临时倍速），这里保留同一意图作兜底：
  // 宿主未接管（如直播切台）时仍经此触发。
  const SingleActivator(LogicalKeyboardKey.arrowRight): const SeekIntent(Duration(seconds: 10)),
  const SingleActivator(LogicalKeyboardKey.keyJ): const SeekIntent(Duration(seconds: -10)),
  const SingleActivator(LogicalKeyboardKey.keyL): const SeekIntent(Duration(seconds: 10)),

  // 快退 / 快进 (大步进 30 秒)
  const SingleActivator(LogicalKeyboardKey.arrowLeft, shift: true):
      const SeekIntent(Duration(seconds: -30)),
  const SingleActivator(LogicalKeyboardKey.arrowRight, shift: true):
      const SeekIntent(Duration(seconds: 30)),
  const SingleActivator(LogicalKeyboardKey.arrowLeft, control: true):
      const SeekIntent(Duration(seconds: -30)),
  const SingleActivator(LogicalKeyboardKey.arrowRight, control: true):
      const SeekIntent(Duration(seconds: 30)),

  // 音量微调 (步进 5%)
  const SingleActivator(LogicalKeyboardKey.arrowUp): const VolumeIntent(5.0),
  const SingleActivator(LogicalKeyboardKey.arrowDown): const VolumeIntent(-5.0),

  // 一键静音
  const SingleActivator(LogicalKeyboardKey.keyM): const ToggleMuteIntent(),

  // 全屏切换
  const SingleActivator(LogicalKeyboardKey.keyF): const ToggleFullscreenIntent(),
  const SingleActivator(LogicalKeyboardKey.f11): const ToggleFullscreenIntent(),

  // 退出全屏 / 返回
  const SingleActivator(LogicalKeyboardKey.escape): const ExitFullscreenIntent(),

  // 倍速控制 (C 加速, X 减速, Z 恢复 1.0x)
  const SingleActivator(LogicalKeyboardKey.keyC): const RateAdjustIntent(0.25),
  const SingleActivator(LogicalKeyboardKey.keyX): const RateAdjustIntent(-0.25),
  const SingleActivator(LogicalKeyboardKey.keyZ): const RateAdjustIntent(0.0, reset: true),

  // 上一集 / 下一集 (PAGE UP / PAGE DOWN)
  const SingleActivator(LogicalKeyboardKey.pageUp): const PrevEpisodeIntent(),
  const SingleActivator(LogicalKeyboardKey.pageDown): const NextEpisodeIntent(),

  // 弹幕开 / 关
  const SingleActivator(LogicalKeyboardKey.keyD): const ToggleDanmakuIntent(),
};

/// §14 播放页 → 键「短按快进 / 长按临时倍速」判定。
///
/// → 不再走 [defaultPlayerShortcuts] 的 SingleActivator（那条会随系统按键重复连续快进），
/// 由宿主在 Focus.onKeyEvent 里先交给 [handleKeyEvent]：
/// - 按下：开始计时；重复事件一律吞掉；
/// - 未到 [holdThreshold] 松开：触发 [onTap]（宿主按原逻辑快进 10 秒）；
/// - 到点：触发 [onHoldStart]（宿主切到长按倍率），松开时 [onHoldEnd] 恢复原倍速。
/// 窗口失焦 / 播放器失去焦点 / 销毁时宿主调用 [cancel]，避免倍速卡住。
/// 带修饰键的 →（Shift / Ctrl 大步进）不在此处理，仍由快捷键表负责。
class HoldToSpeedGesture {
  static const Duration defaultHoldThreshold = Duration(milliseconds: 400);

  final Duration holdThreshold;
  final VoidCallback onTap;
  final VoidCallback onHoldStart;
  final VoidCallback onHoldEnd;

  /// 返回 false 时（如直播）不接管，事件继续交给快捷键表。
  final bool Function() isEnabled;

  Timer? _timer;
  bool _pressed = false;
  bool _holding = false;

  HoldToSpeedGesture({
    required this.onTap,
    required this.onHoldStart,
    required this.onHoldEnd,
    required this.isEnabled,
    this.holdThreshold = defaultHoldThreshold,
  });

  bool get isHolding => _holding;

  static bool _isPlainArrowRight(KeyEvent event) {
    if (event.logicalKey != LogicalKeyboardKey.arrowRight) return false;
    final keyboard = HardwareKeyboard.instance;
    return !keyboard.isShiftPressed &&
        !keyboard.isControlPressed &&
        !keyboard.isAltPressed &&
        !keyboard.isMetaPressed;
  }

  KeyEventResult handleKeyEvent(KeyEvent event) {
    if (event.logicalKey != LogicalKeyboardKey.arrowRight) {
      return KeyEventResult.ignored;
    }
    if (event is KeyDownEvent) {
      if (!_isPlainArrowRight(event) || !isEnabled()) return KeyEventResult.ignored;
      cancel();
      _pressed = true;
      _timer = Timer(holdThreshold, () {
        _timer = null;
        if (!_pressed) return;
        _holding = true;
        onHoldStart();
      });
      return KeyEventResult.handled;
    }
    if (!_pressed) return KeyEventResult.ignored;
    if (event is KeyRepeatEvent) return KeyEventResult.handled;
    if (event is KeyUpEvent) {
      final wasHolding = _holding;
      _reset();
      if (wasHolding) {
        onHoldEnd();
      } else {
        onTap();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// 放弃本次按压：已进入长按则恢复（触发 [onHoldEnd]），否则静默丢弃（不快进）。
  void cancel() {
    final wasHolding = _holding;
    _reset();
    if (wasHolding) onHoldEnd();
  }

  void _reset() {
    _timer?.cancel();
    _timer = null;
    _pressed = false;
    _holding = false;
  }

  void dispose() => cancel();
}
