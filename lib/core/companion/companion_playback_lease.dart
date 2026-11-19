import 'dart:async';

import '../player/models/player_state.dart';
import 'companion_process_manager.dart';

/// 播放期间的 companion 使用租约。
///
/// 背景（.do-it/verification/netdisk-idle-20261114/REPORT.md）：网盘直链由
/// companion 的本地代理持续传流，播放中段没有 spider RPC，旧实现只看
/// `notifyActivity()` 计时，于是「起播解析后再无 RPC」约 30 分钟就被判空闲停用，
/// 代理端口消失、流被截断——用户侧表现就是「看着看着掉授权 / 断流」。
///
/// 本控制器把播放器状态映射成租约：播放 / 缓冲 / 暂停时持有，停止、播放完成或
/// 出错时释放；释放后仍要等满完整 idleTimeout 才允许回收，真实空闲不会被饿死。
class CompanionPlaybackLease {
  CompanionPlaybackLease({
    required Stream<PlaybackStatus> statusStream,
    required CompanionProcessManager manager,
  }) : _manager = manager {
    _subscription = statusStream.listen(_onStatus);
  }

  final CompanionProcessManager _manager;
  StreamSubscription<PlaybackStatus>? _subscription;
  CompanionLease? _lease;

  /// 租约是否正被持有（诊断与单测用）。
  bool get isHeld => _lease != null && !_lease!.isReleased;

  void _onStatus(PlaybackStatus status) {
    switch (status) {
      case PlaybackStatus.buffering:
      case PlaybackStatus.playing:
      case PlaybackStatus.paused:
        _hold();
      case PlaybackStatus.idle:
      case PlaybackStatus.completed:
      case PlaybackStatus.error:
        _release();
    }
  }

  void _hold() {
    if (isHeld) return;
    _lease?.release(); // 防御：上一份未释放的租约不会叠加
    _lease = _manager.acquireLease('playback');
  }

  void _release() {
    final lease = _lease;
    _lease = null;
    lease?.release();
  }

  /// 播放器销毁 / 应用退出时调用：释放租约并停止监听。
  Future<void> dispose() async {
    _release();
    await _subscription?.cancel();
    _subscription = null;
  }
}
