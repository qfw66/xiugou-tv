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

/// 默认桌面播放器键位绑定字典
final Map<ShortcutActivator, Intent> defaultPlayerShortcuts = {
  // 播放 / 暂停
  const SingleActivator(LogicalKeyboardKey.space): const PlayPauseIntent(),
  const SingleActivator(LogicalKeyboardKey.keyK): const PlayPauseIntent(),

  // 快退 / 快进 (小步进 10 秒)
  const SingleActivator(LogicalKeyboardKey.arrowLeft): const SeekIntent(Duration(seconds: -10)),
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
};
