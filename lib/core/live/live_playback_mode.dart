import '../config/models/vod_config.dart';
import '../player/hls_playlist_probe.dart';
import '../player/models/player_state.dart';

/// 直播页左上角「播放方式」菜单的选项。
///
/// 只在本次运行内按频道地址生效，不落盘；持久的「按主机记忆」仍归直链弹窗。
enum LivePlaybackChoice { auto, vod, live }

/// 起播前是否要先只读一次清单判定点播 / 直播（联网，最多等探测预算）。
///
/// - 菜单选「自动」：凡是 HLS 地址都探测（用户主动要求，不受设置开关限制）；
/// - 菜单选「按点播 / 按直播」：不探测；
/// - 没选过：只探测「手动添加」里尚无结论的单个地址（受设置开关控制）——
///   导入的频道清单照旧按直播起播，换台不多等。
///
/// 扩展名已能定论（`.mp4` / `.flv` 等）时都不联网。
bool shouldProbeLiveChannel({
  required Live live,
  LivePlaybackChoice? choice,
  required bool isManualChannel,
  required bool autoDetect,
}) {
  if (containerHintForUrl(live.url) != null) return false;
  if (!isHlsProbeCandidate(live.url)) return false;
  return switch (choice) {
    LivePlaybackChoice.auto => true,
    LivePlaybackChoice.vod || LivePlaybackChoice.live => false,
    null => isManualChannel && autoDetect && live.playbackMode == null,
  };
}

/// 频道 → 播放参数（纯函数，播放方式的唯一决策点见 [resolveDirectPlaybackMode]）。
///
/// 优先级：菜单手动选择 > 本次探测结果 > 频道自带结论（直链弹窗）> 默认直播。
/// 菜单选「自动」时不沿用频道自带结论，按探测 / 扩展名重新判定。
MediaPlaySpec livePlaySpec(
  Live live, {
  LivePlaybackChoice? choice,
  HlsProbeResult? probe,
  int lineIndex = 0,
}) {
  final selected = lineIndex >= 0 && lineIndex < live.lines.length ? lineIndex : 0;
  final url = live.lines.isEmpty ? live.url : live.lines[selected].url;
  final manual = switch (choice) {
    LivePlaybackChoice.vod => PlaybackMode.vod,
    LivePlaybackChoice.live => PlaybackMode.live,
    _ => null,
  };
  final decide = manual != null || probe != null || choice == LivePlaybackChoice.auto;
  final decision = decide
      ? resolveDirectPlaybackMode(url: url, manual: manual, probe: probe)
      : null;
  return MediaPlaySpec(
    url: url,
    headers: live.headers.isEmpty ? null : live.headers,
    title: live.name,
    qualities: live.lines.length < 2 ? const [] : [
      for (final line in live.lines)
        PlaybackQuality(name: line.name, url: line.url, headers: live.headers),
    ],
    qualityIndex: live.lines.length < 2 ? 0 : selected,
    // 导入频道 / 收藏 / 上次频道的旧数据没有模式 → 沿用旧行为按直播（D7）。
    mode: decision?.mode ?? live.playbackMode ?? PlaybackMode.live,
    modeSource: decision?.source ??
        live.playbackModeSource ??
        (live.playbackMode == null
            ? PlaybackModeSource.defaultLive
            : PlaybackModeSource.directDialog),
    modeDetail: decision?.reason ?? live.playbackModeReason,
  );
}

/// 菜单里打勾的一项：本次运行选过的优先；其余手动结论按模式，其它都算「自动」。
LivePlaybackChoice checkedLivePlaybackChoice(
  MediaPlaySpec spec, {
  required LivePlaybackChoice? override,
}) {
  if (override != null) return override;
  if (spec.modeSource != PlaybackModeSource.manual) return LivePlaybackChoice.auto;
  return spec.isLive ? LivePlaybackChoice.live : LivePlaybackChoice.vod;
}
