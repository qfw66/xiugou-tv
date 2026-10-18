import 'models/track_info.dart';

/// 可选能力：视频轨选择。
///
/// 仅支持的播放引擎实现（当前为 mpv 引擎）。未实现的引擎不显示
/// 「视轨」入口，避免把视频轨能力强加给所有 `PlayerEngine` 实现与测试替身。
abstract class VideoTrackCapable {
  List<TrackInfo> get videoTracks;

  Stream<List<TrackInfo>> get videoTracksStream;

  /// 选择视频轨；`id == 'auto'` / `'no'` 分别映射为自动 / 关闭。
  Future<void> selectVideoTrack(TrackInfo track);
}

/// 可选能力：关闭字幕（不选择具体字幕轨）。
abstract class SubtitleTrackCapable {
  Future<void> disableSubtitle();
}
