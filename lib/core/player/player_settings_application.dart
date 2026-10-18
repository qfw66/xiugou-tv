import 'dart:async';
import 'models/player_settings.dart';

/// 方法成功返回意味着已完成回读确认，而不只是发出了写入请求。
abstract interface class PlayerSettingsTarget {
  Future<void> setProperty(String name, String value);
  Future<void> setStartupVolume(double value);
  Future<void> setStartupRate(double value);
}

enum SettingsApplicationPhase { waiting, applying, confirmed, failed, closed }

class SettingsApplicationState {
  final SettingsApplicationPhase phase;
  final Map<String, String> failures;
  final bool defaultsPending;
  final bool canRetry;

  const SettingsApplicationState({
    this.phase = SettingsApplicationPhase.waiting,
    this.failures = const {},
    this.defaultsPending = false,
    this.canRetry = false,
  });
}

/// 管理首选项与播放器之间的确认状态，不承担磁盘保存职责。
class PlayerSettingsApplication {
  PlayerSettings _settings = PlayerSettings.defaults;
  PlayerSettings? _startupSettings;
  PlayerSettingsTarget? _target;
  final _confirmed = <String, String>{};
  final _startupConfirmed = <String>{};
  Map<String, String> _failures = {};
  final _states = StreamController<SettingsApplicationState>.broadcast();
  Future<void> _chain = Future<void>.value();
  int _generation = 0;
  int _pending = 0;
  bool _closed = false;

  PlayerSettings get settings => _settings;
  SettingsApplicationState get state => SettingsApplicationState(
        phase: _closed
            ? SettingsApplicationPhase.closed
            : _pending > 0
                ? SettingsApplicationPhase.applying
                : _failures.isNotEmpty
                    ? SettingsApplicationPhase.failed
                    : _target == null
                        ? SettingsApplicationPhase.waiting
                        : SettingsApplicationPhase.confirmed,
        failures: Map.unmodifiable(_failures),
        defaultsPending: _startupSettings != null &&
            (_settings.defaultVolume != _startupSettings!.defaultVolume ||
                _settings.defaultRate != _startupSettings!.defaultRate),
        canRetry: !_closed &&
            _target != null &&
            _pending == 0 &&
            _failures.isNotEmpty,
      );

  Stream<SettingsApplicationState> get states => _states.stream;

  Future<void> update(PlayerSettings settings) {
    if (_closed) throw StateError('播放器设置应用已关闭');
    _settings = settings.normalized();
    _generation++;
    if (_target == null) {
      _publish();
      return Future<void>.value();
    }
    return _enqueue();
  }

  Future<void> attach(PlayerSettingsTarget target) {
    if (_closed || _target != null) throw StateError('播放器设置目标不可重复连接');
    _target = target;
    _startupSettings = _settings;
    return _enqueue();
  }

  void initializationFailed() {
    if (_closed) return;
    _failures = {'初始化': '播放器初始化失败，请重新启动应用后重试'};
    _publish();
  }

  Future<void> retry() {
    if (!state.canRetry) return _chain;
    return _enqueue();
  }

  Future<void> _enqueue() {
    final settings = _settings;
    final generation = _generation;
    _pending++;
    _publish();
    final next = _chain.then((_) async {
      try {
        if (_closed || generation != _generation) return;
        final failures = <String, String>{};
        for (final entry in settings.toMpvProperties().entries) {
          if (_closed) return;
          if (_confirmed[entry.key] == entry.value) continue;
          try {
            await _target!.setProperty(entry.key, entry.value);
            _confirmed[entry.key] = entry.value;
          } catch (error) {
            _confirmed.remove(entry.key);
            failures[entry.key] = '${entry.value}：$error';
          }
        }
        final startup = _startupSettings!;
        for (final name in ['默认音量', '默认倍速']) {
          if (_closed) return;
          if (_startupConfirmed.contains(name)) continue;
          try {
            if (name == '默认音量') {
              await _target!.setStartupVolume(startup.defaultVolume);
            } else {
              await _target!.setStartupRate(startup.defaultRate);
            }
            _startupConfirmed.add(name);
          } catch (error) {
            failures[name] = '$error';
          }
        }
        _failures = failures;
      } finally {
        _pending--;
        _publish();
      }
    });
    _chain =
        next.then<void>((_) {}, onError: (Object error, StackTrace stack) {});
    return next;
  }

  void _publish() {
    if (!_closed) _states.add(state);
  }

  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    _states.add(state);
    await _chain;
    await _states.close();
  }
}
