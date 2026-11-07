enum PlayerShortcutAction {
  playPause('播放 / 暂停'),
  seekBackward('快退 10 秒'),
  seekForward('快进 10 秒'),
  seekBackwardLarge('快退 30 秒'),
  seekForwardLarge('快进 30 秒'),
  volumeUp('增加音量'),
  volumeDown('降低音量'),
  toggleMute('静音 / 恢复音量'),
  toggleFullscreen('切换全屏'),
  exitFullscreen('退出全屏 / 返回'),
  rateUp('加快播放速度'),
  rateDown('减慢播放速度'),
  rateReset('恢复 1 倍速'),
  previousEpisode('上一集'),
  nextEpisode('下一集'),
  toggleDanmaku('显示 / 隐藏弹幕');

  final String label;
  const PlayerShortcutAction(this.label);
}

/// Stable logical key names keep persisted preferences independent of Flutter.
class PlayerKeyBinding {
  final String key;
  final bool control;
  final bool alt;
  final bool shift;

  const PlayerKeyBinding(
    this.key, {
    this.control = false,
    this.alt = false,
    this.shift = false,
  });

  static const keyLabels = <String, String>{
    'space': '空格',
    'escape': 'Esc',
    'arrowLeft': '←',
    'arrowRight': '→',
    'arrowUp': '↑',
    'arrowDown': '↓',
    'pageUp': 'Page Up',
    'pageDown': 'Page Down',
    'home': 'Home',
    'end': 'End',
    'insert': 'Insert',
    'delete': 'Delete',
    'backspace': 'Backspace',
    'minus': '-',
    'equal': '=',
    'bracketLeft': '[',
    'bracketRight': ']',
    'backslash': r'\',
    'semicolon': ';',
    'quote': "'",
    'comma': ',',
    'period': '.',
    'slash': '/',
    'backquote': '`',
    'numpadAdd': '数字键盘 +',
    'numpadSubtract': '数字键盘 -',
    'numpadMultiply': '数字键盘 *',
    'numpadDivide': '数字键盘 /',
    'numpadDecimal': '数字键盘 .',
  };

  static bool isSupportedKey(String key) =>
      keyLabels.containsKey(key) ||
      RegExp(r'^key[A-Z]$').hasMatch(key) ||
      RegExp(r'^digit[0-9]$').hasMatch(key) ||
      RegExp(r'^numpad[0-9]$').hasMatch(key) ||
      RegExp(r'^f([1-9]|1[0-9]|2[0-4])$').hasMatch(key);

  String get label {
    final keyLabel = keyLabels[key] ??
        (key.startsWith('key')
            ? key.substring(3)
            : key.startsWith('digit')
                ? key.substring(5)
                : key.startsWith('numpad')
                    ? '数字键盘 ${key.substring(6)}'
                    : key.toUpperCase());
    return [if (control) 'Ctrl', if (alt) 'Alt', if (shift) 'Shift', keyLabel]
        .join(' + ');
  }

  static PlayerKeyBinding? _fromJson(Object? raw) {
    if (raw is! Map || raw['key'] is! String) return null;
    for (final name in ['control', 'alt', 'shift']) {
      if (raw.containsKey(name) && raw[name] is! bool) return null;
    }
    return PlayerKeyBinding(raw['key'] as String,
        control: raw['control'] == true,
        alt: raw['alt'] == true,
        shift: raw['shift'] == true);
  }

  Map<String, Object> toJson() => {
        'key': key,
        if (control) 'control': true,
        if (alt) 'alt': true,
        if (shift) 'shift': true,
      };

  @override
  bool operator ==(Object other) =>
      other is PlayerKeyBinding &&
      other.key == key &&
      other.control == control &&
      other.alt == alt &&
      other.shift == shift;

  @override
  int get hashCode => Object.hash(key, control, alt, shift);
}

/// An immutable, conflict-free set; replacing an action removes all old aliases.
class PlayerShortcutBindings {
  final Map<PlayerShortcutAction, List<PlayerKeyBinding>> _bindings;

  const PlayerShortcutBindings._(this._bindings);

  static const defaults = PlayerShortcutBindings._({
    PlayerShortcutAction.playPause: [
      PlayerKeyBinding('space'),
      PlayerKeyBinding('keyK')
    ],
    PlayerShortcutAction.seekBackward: [
      PlayerKeyBinding('arrowLeft'),
      PlayerKeyBinding('keyJ')
    ],
    PlayerShortcutAction.seekForward: [
      PlayerKeyBinding('arrowRight'),
      PlayerKeyBinding('keyL')
    ],
    PlayerShortcutAction.seekBackwardLarge: [
      PlayerKeyBinding('arrowLeft', shift: true),
      PlayerKeyBinding('arrowLeft', control: true),
    ],
    PlayerShortcutAction.seekForwardLarge: [
      PlayerKeyBinding('arrowRight', shift: true),
      PlayerKeyBinding('arrowRight', control: true),
    ],
    PlayerShortcutAction.volumeUp: [PlayerKeyBinding('arrowUp')],
    PlayerShortcutAction.volumeDown: [PlayerKeyBinding('arrowDown')],
    PlayerShortcutAction.toggleMute: [PlayerKeyBinding('keyM')],
    PlayerShortcutAction.toggleFullscreen: [
      PlayerKeyBinding('keyF'),
      PlayerKeyBinding('f11')
    ],
    PlayerShortcutAction.exitFullscreen: [PlayerKeyBinding('escape')],
    PlayerShortcutAction.rateUp: [PlayerKeyBinding('keyC')],
    PlayerShortcutAction.rateDown: [PlayerKeyBinding('keyX')],
    PlayerShortcutAction.rateReset: [PlayerKeyBinding('keyZ')],
    PlayerShortcutAction.previousEpisode: [PlayerKeyBinding('pageUp')],
    PlayerShortcutAction.nextEpisode: [PlayerKeyBinding('pageDown')],
    PlayerShortcutAction.toggleDanmaku: [PlayerKeyBinding('keyD')],
  });

  List<PlayerKeyBinding> keysFor(PlayerShortcutAction action) =>
      _bindings[action]!;

  PlayerKeyBinding get primarySeekForward =>
      keysFor(PlayerShortcutAction.seekForward).first;

  static String? _reservedReason(
      PlayerShortcutAction action, PlayerKeyBinding binding) {
    if (binding.key == 'tab' ||
        binding.key == 'enter' ||
        binding.key == 'numpadEnter') {
      return 'Tab 和 Enter 用于界面导航，不能设为播放快捷键。';
    }
    if (!PlayerKeyBinding.isSupportedKey(binding.key)) {
      return '不支持这个按键，请使用字母、数字、方向键或功能键。';
    }
    if (binding.key == 'escape' &&
        (action != PlayerShortcutAction.exitFullscreen ||
            binding.control ||
            binding.alt ||
            binding.shift)) {
      return 'Esc 保留给退出全屏 / 返回及关闭对话框。';
    }
    if ((binding.alt && (binding.key == 'f4' || binding.key == 'space')) ||
        (binding.control && binding.alt && binding.key == 'delete') ||
        (binding.control && (binding.key == 'keyW' || binding.key == 'keyQ'))) {
      return '${binding.label} 是系统保留快捷键，请选择其他组合。';
    }
    return null;
  }

  String? validationError(
      PlayerShortcutAction action, PlayerKeyBinding binding) {
    final reserved = _reservedReason(action, binding);
    if (reserved != null) return reserved;
    for (final other in PlayerShortcutAction.values) {
      if (other != action && keysFor(other).contains(binding)) {
        return '${binding.label} 已用于“${other.label}”，请先更改该动作。';
      }
    }
    return null;
  }

  PlayerShortcutBindings replace(
      PlayerShortcutAction action, PlayerKeyBinding binding) {
    final error = validationError(action, binding);
    if (error != null) throw FormatException(error);
    return PlayerShortcutBindings._(Map.unmodifiable({
      ..._bindings,
      action: List<PlayerKeyBinding>.unmodifiable([binding]),
    }));
  }

  /// Restores every default alias for one action without stealing other keys.
  PlayerShortcutBindings restoreDefaultsFor(PlayerShortcutAction action) {
    final keys = defaults.keysFor(action);
    for (final binding in keys) {
      final error = validationError(action, binding);
      if (error != null) throw FormatException(error);
    }
    return PlayerShortcutBindings._(Map.unmodifiable({
      ..._bindings,
      action: List<PlayerKeyBinding>.unmodifiable(keys),
    }));
  }

  /// Invalid maps fall back as a whole so no silent default creates a conflict.
  factory PlayerShortcutBindings.fromJson(Object? raw) {
    if (raw is! Map || raw['version'] != 1 || raw['bindings'] is! Map) {
      return defaults;
    }
    final stored = raw['bindings'] as Map;
    final parsed = <PlayerShortcutAction, List<PlayerKeyBinding>>{};
    final seen = <PlayerKeyBinding>{};
    for (final action in PlayerShortcutAction.values) {
      List<PlayerKeyBinding> keys;
      if (!stored.containsKey(action.name)) {
        keys = defaults.keysFor(action);
      } else {
        final values = stored[action.name];
        if (values is! List || values.isEmpty || values.length > 4) {
          return defaults;
        }
        keys = [];
        for (final value in values) {
          final binding = PlayerKeyBinding._fromJson(value);
          if (binding == null) return defaults;
          keys.add(binding);
        }
      }
      for (final binding in keys) {
        if (_reservedReason(action, binding) != null || !seen.add(binding)) {
          return defaults;
        }
      }
      parsed[action] = List.unmodifiable(keys);
    }
    return PlayerShortcutBindings._(Map.unmodifiable(parsed));
  }

  Map<String, Object> toJson() => {
        'version': 1,
        'bindings': {
          for (final action in PlayerShortcutAction.values)
            action.name:
                keysFor(action).map((binding) => binding.toJson()).toList(),
        },
      };

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! PlayerShortcutBindings) return false;
    for (final action in PlayerShortcutAction.values) {
      final a = keysFor(action);
      final b = other.keysFor(action);
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (a[i] != b[i]) return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll([
        for (final action in PlayerShortcutAction.values)
          Object.hashAll(keysFor(action)),
      ]);
}
