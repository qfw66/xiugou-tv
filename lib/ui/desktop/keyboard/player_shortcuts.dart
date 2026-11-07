import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/settings/models/player_shortcut_bindings.dart';
export '../../../core/settings/models/player_shortcut_bindings.dart';

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

class ToggleDanmakuIntent extends Intent {
  const ToggleDanmakuIntent();
}

const _logicalKeys = <String, LogicalKeyboardKey>{
  'space': LogicalKeyboardKey.space,
  'escape': LogicalKeyboardKey.escape,
  'arrowLeft': LogicalKeyboardKey.arrowLeft,
  'arrowRight': LogicalKeyboardKey.arrowRight,
  'arrowUp': LogicalKeyboardKey.arrowUp,
  'arrowDown': LogicalKeyboardKey.arrowDown,
  'pageUp': LogicalKeyboardKey.pageUp,
  'pageDown': LogicalKeyboardKey.pageDown,
  'home': LogicalKeyboardKey.home,
  'end': LogicalKeyboardKey.end,
  'insert': LogicalKeyboardKey.insert,
  'delete': LogicalKeyboardKey.delete,
  'backspace': LogicalKeyboardKey.backspace,
  'minus': LogicalKeyboardKey.minus,
  'equal': LogicalKeyboardKey.equal,
  'bracketLeft': LogicalKeyboardKey.bracketLeft,
  'bracketRight': LogicalKeyboardKey.bracketRight,
  'backslash': LogicalKeyboardKey.backslash,
  'semicolon': LogicalKeyboardKey.semicolon,
  'quote': LogicalKeyboardKey.quote,
  'comma': LogicalKeyboardKey.comma,
  'period': LogicalKeyboardKey.period,
  'slash': LogicalKeyboardKey.slash,
  'backquote': LogicalKeyboardKey.backquote,
  'keyA': LogicalKeyboardKey.keyA,
  'keyB': LogicalKeyboardKey.keyB,
  'keyC': LogicalKeyboardKey.keyC,
  'keyD': LogicalKeyboardKey.keyD,
  'keyE': LogicalKeyboardKey.keyE,
  'keyF': LogicalKeyboardKey.keyF,
  'keyG': LogicalKeyboardKey.keyG,
  'keyH': LogicalKeyboardKey.keyH,
  'keyI': LogicalKeyboardKey.keyI,
  'keyJ': LogicalKeyboardKey.keyJ,
  'keyK': LogicalKeyboardKey.keyK,
  'keyL': LogicalKeyboardKey.keyL,
  'keyM': LogicalKeyboardKey.keyM,
  'keyN': LogicalKeyboardKey.keyN,
  'keyO': LogicalKeyboardKey.keyO,
  'keyP': LogicalKeyboardKey.keyP,
  'keyQ': LogicalKeyboardKey.keyQ,
  'keyR': LogicalKeyboardKey.keyR,
  'keyS': LogicalKeyboardKey.keyS,
  'keyT': LogicalKeyboardKey.keyT,
  'keyU': LogicalKeyboardKey.keyU,
  'keyV': LogicalKeyboardKey.keyV,
  'keyW': LogicalKeyboardKey.keyW,
  'keyX': LogicalKeyboardKey.keyX,
  'keyY': LogicalKeyboardKey.keyY,
  'keyZ': LogicalKeyboardKey.keyZ,
  'digit0': LogicalKeyboardKey.digit0,
  'digit1': LogicalKeyboardKey.digit1,
  'digit2': LogicalKeyboardKey.digit2,
  'digit3': LogicalKeyboardKey.digit3,
  'digit4': LogicalKeyboardKey.digit4,
  'digit5': LogicalKeyboardKey.digit5,
  'digit6': LogicalKeyboardKey.digit6,
  'digit7': LogicalKeyboardKey.digit7,
  'digit8': LogicalKeyboardKey.digit8,
  'digit9': LogicalKeyboardKey.digit9,
  'numpad0': LogicalKeyboardKey.numpad0,
  'numpad1': LogicalKeyboardKey.numpad1,
  'numpad2': LogicalKeyboardKey.numpad2,
  'numpad3': LogicalKeyboardKey.numpad3,
  'numpad4': LogicalKeyboardKey.numpad4,
  'numpad5': LogicalKeyboardKey.numpad5,
  'numpad6': LogicalKeyboardKey.numpad6,
  'numpad7': LogicalKeyboardKey.numpad7,
  'numpad8': LogicalKeyboardKey.numpad8,
  'numpad9': LogicalKeyboardKey.numpad9,
  'numpadAdd': LogicalKeyboardKey.numpadAdd,
  'numpadSubtract': LogicalKeyboardKey.numpadSubtract,
  'numpadMultiply': LogicalKeyboardKey.numpadMultiply,
  'numpadDivide': LogicalKeyboardKey.numpadDivide,
  'numpadDecimal': LogicalKeyboardKey.numpadDecimal,
  'f1': LogicalKeyboardKey.f1,
  'f2': LogicalKeyboardKey.f2,
  'f3': LogicalKeyboardKey.f3,
  'f4': LogicalKeyboardKey.f4,
  'f5': LogicalKeyboardKey.f5,
  'f6': LogicalKeyboardKey.f6,
  'f7': LogicalKeyboardKey.f7,
  'f8': LogicalKeyboardKey.f8,
  'f9': LogicalKeyboardKey.f9,
  'f10': LogicalKeyboardKey.f10,
  'f11': LogicalKeyboardKey.f11,
  'f12': LogicalKeyboardKey.f12,
  'f13': LogicalKeyboardKey.f13,
  'f14': LogicalKeyboardKey.f14,
  'f15': LogicalKeyboardKey.f15,
  'f16': LogicalKeyboardKey.f16,
  'f17': LogicalKeyboardKey.f17,
  'f18': LogicalKeyboardKey.f18,
  'f19': LogicalKeyboardKey.f19,
  'f20': LogicalKeyboardKey.f20,
  'f21': LogicalKeyboardKey.f21,
  'f22': LogicalKeyboardKey.f22,
  'f23': LogicalKeyboardKey.f23,
  'f24': LogicalKeyboardKey.f24,
};

PlayerKeyBinding? playerKeyBindingFromEvent(KeyEvent event) {
  final keyboard = HardwareKeyboard.instance;
  if (keyboard.isMetaPressed) return null;
  for (final entry in _logicalKeys.entries) {
    if (entry.value == event.logicalKey) {
      return PlayerKeyBinding(entry.key,
          control: keyboard.isControlPressed,
          alt: keyboard.isAltPressed,
          shift: keyboard.isShiftPressed);
    }
  }
  return null;
}

Intent _intentFor(PlayerShortcutAction action) => switch (action) {
      PlayerShortcutAction.playPause => const PlayPauseIntent(),
      PlayerShortcutAction.seekBackward =>
        const SeekIntent(Duration(seconds: -10)),
      PlayerShortcutAction.seekForward =>
        const SeekIntent(Duration(seconds: 10)),
      PlayerShortcutAction.seekBackwardLarge =>
        const SeekIntent(Duration(seconds: -30)),
      PlayerShortcutAction.seekForwardLarge =>
        const SeekIntent(Duration(seconds: 30)),
      PlayerShortcutAction.volumeUp => const VolumeIntent(5),
      PlayerShortcutAction.volumeDown => const VolumeIntent(-5),
      PlayerShortcutAction.toggleMute => const ToggleMuteIntent(),
      PlayerShortcutAction.toggleFullscreen => const ToggleFullscreenIntent(),
      PlayerShortcutAction.exitFullscreen => const ExitFullscreenIntent(),
      PlayerShortcutAction.rateUp => const RateAdjustIntent(0.25),
      PlayerShortcutAction.rateDown => const RateAdjustIntent(-0.25),
      PlayerShortcutAction.rateReset => const RateAdjustIntent(0, reset: true),
      PlayerShortcutAction.previousEpisode => const PrevEpisodeIntent(),
      PlayerShortcutAction.nextEpisode => const NextEpisodeIntent(),
      PlayerShortcutAction.toggleDanmaku => const ToggleDanmakuIntent(),
    };

Map<ShortcutActivator, Intent> buildPlayerShortcuts(
        PlayerShortcutBindings bindings) =>
    {
      for (final action in PlayerShortcutAction.values)
        for (final binding in bindings.keysFor(action))
          SingleActivator(_logicalKeys[binding.key]!,
              control: binding.control,
              alt: binding.alt,
              shift: binding.shift): _intentFor(action),
    };

final Map<ShortcutActivator, Intent> defaultPlayerShortcuts =
    buildPlayerShortcuts(PlayerShortcutBindings.defaults);

bool playerShortcutHasEditableFocus() {
  final context = FocusManager.instance.primaryFocus?.context;
  return context != null &&
      (context.widget is EditableText ||
          context.findAncestorStateOfType<EditableTextState>() != null);
}

class _PlayerShortcutManager extends ShortcutManager {
  bool enabled = true;

  @override
  KeyEventResult handleKeypress(BuildContext context, KeyEvent event) {
    if (!enabled || playerShortcutHasEditableFocus()) {
      return KeyEventResult.ignored;
    }
    return super.handleKeypress(context, event);
  }
}

/// Hosts disable the scope while drawers or other player panels own navigation.
class PlayerShortcutScope extends StatefulWidget {
  final PlayerShortcutBindings bindings;
  final bool enabled;
  final Widget child;

  const PlayerShortcutScope({
    super.key,
    this.bindings = PlayerShortcutBindings.defaults,
    this.enabled = true,
    required this.child,
  });

  @override
  State<PlayerShortcutScope> createState() => _PlayerShortcutScopeState();
}

class _PlayerShortcutScopeState extends State<PlayerShortcutScope> {
  late final _PlayerShortcutManager _manager = _PlayerShortcutManager();

  @override
  void initState() {
    super.initState();
    _updateManager();
  }

  @override
  void didUpdateWidget(covariant PlayerShortcutScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bindings != widget.bindings ||
        oldWidget.enabled != widget.enabled) {
      _updateManager();
    }
  }

  void _updateManager() {
    _manager.enabled = widget.enabled;
    _manager.shortcuts = buildPlayerShortcuts(widget.bindings);
  }

  @override
  void dispose() {
    _manager.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      Shortcuts.manager(manager: _manager, child: widget.child);
}

/// Short press seeks, hold temporarily changes rate. The host cancels on focus
/// loss and preference changes; the primary seek-forward binding owns the gesture.
class HoldToSpeedGesture {
  static const Duration defaultHoldThreshold = Duration(milliseconds: 400);

  final Duration holdThreshold;
  final VoidCallback onTap;
  final VoidCallback onHoldStart;
  final VoidCallback onHoldEnd;
  final bool Function() isEnabled;
  final PlayerKeyBinding Function()? getBinding;

  Timer? _timer;
  PlayerKeyBinding? _activeBinding;
  bool _holding = false;

  HoldToSpeedGesture({
    required this.onTap,
    required this.onHoldStart,
    required this.onHoldEnd,
    required this.isEnabled,
    this.getBinding,
    this.holdThreshold = defaultHoldThreshold,
  });

  bool get isHolding => _holding;

  PlayerKeyBinding get _binding =>
      getBinding?.call() ?? const PlayerKeyBinding('arrowRight');

  bool get _canHandle => isEnabled() && !playerShortcutHasEditableFocus();

  KeyEventResult handleKeyEvent(KeyEvent event) {
    final active = _activeBinding;
    if (active != null && (!_canHandle || active != _binding)) cancel();
    if (event is KeyDownEvent) {
      if (!_canHandle || playerKeyBindingFromEvent(event) != _binding) {
        return KeyEventResult.ignored;
      }
      cancel();
      _activeBinding = _binding;
      _timer = Timer(holdThreshold, () {
        _timer = null;
        if (_activeBinding == null) return;
        if (!_canHandle || _activeBinding != _binding) {
          cancel();
          return;
        }
        _holding = true;
        onHoldStart();
      });
      return KeyEventResult.handled;
    }
    if (_activeBinding == null ||
        event.logicalKey != _logicalKeys[_activeBinding!.key]) {
      return KeyEventResult.ignored;
    }
    // The primary key owns release, even if its modifiers were released first.
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

  void cancel() {
    final wasHolding = _holding;
    _reset();
    if (wasHolding) onHoldEnd();
  }

  void _reset() {
    _timer?.cancel();
    _timer = null;
    _activeBinding = null;
    _holding = false;
  }

  void dispose() => cancel();
}
