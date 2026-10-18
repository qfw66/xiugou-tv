import 'package:media_kit/media_kit.dart';
import 'player_settings_application.dart';

/// 数值化解析 mpv 宽高比取值：支持浮点（`1.777778`）与 `W:H`（`16:9`）。
///
/// 无法构成正比例时（`no` / `auto` / 空串 / 非法格式）返回 null；
/// 实测 mpv v0.36 的回读为 6 位小数字符串（如 `1.777778`）。
double? mpvAspectRatioOf(String raw) {
  final value = raw.trim();
  if (value.isEmpty) return null;
  final direct = double.tryParse(value);
  if (direct != null) return direct.isFinite && direct > 0 ? direct : null;
  final parts = value.split(':');
  if (parts.length != 2) return null;
  final width = double.tryParse(parts[0].trim());
  final height = double.tryParse(parts[1].trim());
  if (width == null || height == null || width <= 0 || height <= 0) return null;
  return width / height;
}

/// media_kit 的原生写入会忽略返回码，必须以回读结果作为确认依据。
class MpvSettingsTarget implements PlayerSettingsTarget {
  final Player _player;
  final NativePlayer _native;

  MpvSettingsTarget(Player player)
      : _player = player,
        _native = _nativePlayer(player);

  static NativePlayer _nativePlayer(Player player) {
    final platform = player.platform;
    if (platform is! NativePlayer) throw UnsupportedError('当前播放器不支持 mpv 参数');
    return platform;
  }

  @override
  Future<void> setProperty(String name, String value) async {
    await _native.setProperty(name, value);
    final actual = await _native.getProperty(name);
    // mpv 将旧 audio-channels=auto 规范化为 auto-safe。
    if (name == 'audio-channels' && value == 'auto' && actual == 'auto-safe') {
      return;
    }
    // mpv 将宽高比取值规范化为浮点（16:9 → 1.777778）：按数值容差确认。
    if (name == 'video-aspect-override' && value != actual) {
      final expected = mpvAspectRatioOf(value);
      final readBack = mpvAspectRatioOf(actual);
      if (expected != null && readBack != null && (expected - readBack).abs() < 0.001) {
        return;
      }
    }
    _verify(name, value, actual);
  }

  @override
  Future<void> setStartupVolume(double value) async {
    await _player.setVolume(value);
    _verify('volume', '$value', await _native.getProperty('volume'));
  }

  @override
  Future<void> setStartupRate(double value) async {
    await _player.setRate(value);
    if (!_native.configuration.pitch) {
      _verify('speed', '$value', await _native.getProperty('speed'));
      return;
    }
    _verify('audio-pitch-correction', 'no',
        await _native.getProperty('audio-pitch-correction'));
    final filters = await _native.getProperty('af');
    // mpv 过滤器字符串会用 %长度% 转义 scale 数值；pitch 模式不通过 speed 控制倍速。
    final scale = RegExp(r'^scaletempo=scale=(?:%\d+%)?([0-9.eE+-]+)$')
        .firstMatch(filters)
        ?.group(1);
    _verify(
        'scaletempo:scale', '${value / _player.state.pitch}', scale ?? filters);
  }

  void _verify(String name, String expected, String actual) {
    if (expected == actual) return;
    final left = double.tryParse(expected);
    final right = double.tryParse(actual);
    if (left != null &&
        right != null &&
        left.isFinite &&
        right.isFinite &&
        (left - right).abs() < 0.000001) {
      return;
    }
    throw StateError(
        '$name 未确认（期望 $expected，回读 ${actual.isEmpty ? '不可用' : actual}）');
  }
}
