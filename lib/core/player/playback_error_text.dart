/// 播放失败类型：决定「要不要自动换线、等不等防抖」。
///
/// - [permanent]：重试也没有意义（域名不解析、HTTP 4xx/5xx、格式不支持）→ 立即换线。
/// - [transient]：可能是抖动（超时、连接重置 / 拒绝、网络不可达）→ 保留防抖，
///   期间位置前进就取消换线。
/// - [unknown]：无法归类 → 按瞬时处理（保守），避免把可恢复的错误当成永久错误。
enum PlaybackFailureKind { permanent, transient, unknown }

/// 一次失败的「用户文案 + 类型」：两者由同一判定产出，避免规则漂移。
class PlaybackFailure {
  final String message;
  final PlaybackFailureKind kind;

  const PlaybackFailure(this.message, this.kind);
}

/// 把播放器底层错误（libmpv / 网络栈）归类。
///
/// 原始错误只用于排查，不直接展示给用户。
PlaybackFailure classifyPlaybackFailure(String? raw) {
  final text = (raw ?? '').toLowerCase();
  if (text.trim().isEmpty) {
    return const PlaybackFailure(
        '播放遇到错误，请稍后重试或换线', PlaybackFailureKind.unknown);
  }
  if (text.contains('resolve hostname') ||
      text.contains('does not resolve') ||
      text.contains('could not resolve') ||
      text.contains('name or service not known') ||
      text.contains('nodename nor servname')) {
    return const PlaybackFailure(
        '无法解析播放地址的域名，请检查网络或换一条线路', PlaybackFailureKind.permanent);
  }
  if (text.contains('http error') ||
      RegExp(r'\b(?:403|404|410|500|502|503|504)\b').hasMatch(text)) {
    return const PlaybackFailure(
        '播放地址不可用（服务器返回错误），请换一条线路', PlaybackFailureKind.permanent);
  }
  if (text.contains('format not supported') ||
      text.contains('unsupported format') ||
      text.contains('could not open codec')) {
    return const PlaybackFailure(
        '播放地址不可用（格式不受支持），请换一条线路', PlaybackFailureKind.permanent);
  }
  // ④ 直播报错诊断：流已打开但没有任何音视频数据（直播源失效 / 维护中高发）。
  if (text.contains('no audio or video data') ||
      text.contains('no video or audio data') ||
      text.contains('did not contain any playable streams') ||
      text.contains('no video or audio streams')) {
    return const PlaybackFailure(
        '播放源没有返回可播放的音视频数据（源可能已失效或在维护），请换线或稍后重试', PlaybackFailureKind.transient);
  }
  // 地址级打不开（通用兜底；格式 / 编码类已在前面分支处理）。
  if (text.contains('failed to open') || text.contains('could not open')) {
    return const PlaybackFailure(
        '播放地址无法打开，请换一条线路或稍后重试', PlaybackFailureKind.permanent);
  }
  // 清单/分段只读到一半就被对端关闭（ffmpeg: "Stream ends prematurely" / "ffurl_read returned ..."）。
  // 典型是源站按 UA 截断或中转抖动，属于**可重试**的瞬时错误，不是地址失效。
  if (text.contains('stream ends prematurely') || text.contains('ffurl_read')) {
    return const PlaybackFailure(
        '该线路传输中断（播放清单没读全），请重试或换一条线路', PlaybackFailureKind.transient);
  }
  if (text.contains('connection refused') ||
      text.contains('connection timed out') ||
      text.contains('timed out') ||
      text.contains('network is unreachable') ||
      text.contains('connection reset')) {
    return const PlaybackFailure(
        '连接播放服务器失败，请稍后重试或换线', PlaybackFailureKind.transient);
  }
  return const PlaybackFailure('播放遇到错误，请稍后重试或换线', PlaybackFailureKind.unknown);
}

/// mpv 的「降级告警」：硬件解码初始化失败（AVHWDeviceContext）、缓存目录建不起来等。
///
/// 实测：`Failed to allocate AVHWDeviceContext.` 之后 mpv 会自动退回软解继续播放，
/// 视频是正常的；如果把它当致命错误，就会出现「弹播放错误，但画面照常播放」。
/// 这类告警只进诊断日志，不弹面板、不触发自动换线。
bool isBenignPlaybackError(String? raw) {
  final text = (raw ?? '').toLowerCase();
  if (text.isEmpty) return false;
  if (text.contains('avhwdevicecontext')) return true;
  if (text.contains('failed to allocate hwdevice')) return true;
  if (text.contains('failed to create file cache')) return true;
  if (text.contains('failed to initialize hardware decoding')) return true;
  if (text.contains('hwdec') && text.contains('failed')) return true;
  return false;
}

/// 只要文案（兼容既有调用点 / 既有用例）。
String friendlyPlaybackError(String? raw) =>
    classifyPlaybackFailure(raw).message;
