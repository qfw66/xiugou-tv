import 'dart:async';

import 'models/player_state.dart';
import 'playback_error_text.dart';

/// 本地 companion 代理播放中断后的有界自恢复。
///
/// 触发条件（三者同时满足）：
/// 1. 播放器已经提交错误（`PlaybackStatus.error`），且错误不是良性告警；
/// 2. 当前播放地址就是本机 companion 代理（`http://127.0.0.1:<port>/...`）；
/// 3. 代理进程已退出 / 端口对不上，或错误是 403/410（直链签名过期）。
///
/// 命中后由 [recover] 按已有剧集上下文重新解析并从原位置续播。只认已提交的错误，
/// 不抢引擎自己对 `stream ends prematurely` 的同地址重试；限流按滑动窗口计
/// （[window] 内最多 [maxAttempts] 次、两次间隔不小于 [cooldown]），不随重载清零，
/// 因此恢复动作自己触发的重播不会把上限刷掉。
class CompanionProxyRecovery {
  CompanionProxyRecovery({
    required Stream<PlaybackStatus> statusStream,
    required String? Function() currentError,
    required bool Function() isProxySpec,
    required bool Function() proxyAlive,
    required Future<void> Function() recover,
    this.cooldown = const Duration(minutes: 1),
    this.window = const Duration(minutes: 15),
    this.maxAttempts = 3,
  })  : _currentError = currentError,
        _isProxySpec = isProxySpec,
        _proxyAlive = proxyAlive,
        _recover = recover {
    _subscription = statusStream.listen(_onStatus);
  }

  final String? Function() _currentError;
  final bool Function() _isProxySpec;
  final bool Function() _proxyAlive;
  final Future<void> Function() _recover;

  /// 两次自动恢复之间的最小间隔。
  final Duration cooldown;

  /// 限流滑动窗口长度。
  final Duration window;

  /// [window] 内允许的最大自动恢复次数。
  final int maxAttempts;

  StreamSubscription<PlaybackStatus>? _subscription;
  final List<DateTime> _attempts = [];
  bool _recovering = false;

  /// 当前窗口内已发生的自动恢复次数（诊断与单测用）。
  int get attempts => _attempts.length;

  void _onStatus(PlaybackStatus status) {
    if (status != PlaybackStatus.error) return;
    if (_recovering) return;
    final raw = _currentError();
    if (raw == null || raw.isEmpty) return;
    if (isBenignPlaybackError(raw)) return;
    if (!_isProxySpec()) return;
    final proxyGone = !_proxyAlive();
    if (!proxyGone && !_looksLikeExpiredLink(raw)) return;
    if (!_withinBudget()) return;

    _attempts.add(DateTime.now());
    _recovering = true;
    Future<void>(() async {
      try {
        await _recover();
      } catch (_) {
        // 恢复失败由播放链路自己报错；这里只保证不阻塞后续错误处理。
      } finally {
        _recovering = false;
      }
    });
  }

  bool _withinBudget() {
    final now = DateTime.now();
    _attempts.removeWhere((at) => now.difference(at) > window);
    if (_attempts.length >= maxAttempts) return false;
    final last = _attempts.isEmpty ? null : _attempts.last;
    return last == null || now.difference(last) >= cooldown;
  }

  static bool _looksLikeExpiredLink(String raw) {
    return RegExp(r'\b(?:403|410)\b').hasMatch(raw.toLowerCase());
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
  }
}

/// 播放地址是否指向本机（companion 代理只监听回环地址）。
bool isLoopbackPlaybackUrl(String? url) {
  if (url == null || url.isEmpty) return false;
  final uri = Uri.tryParse(url);
  if (uri == null) return false;
  final host = uri.host.toLowerCase();
  return host == '127.0.0.1' || host == 'localhost' || host == '::1';
}
