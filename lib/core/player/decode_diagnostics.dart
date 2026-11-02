/// 播放中的实际解码状态（§50），从 mpv 只读属性回读，用于播放设置面板展示。
///
/// 设置里选的是「期望」的解码方式，mpv 在片源格式或显卡不支持时会静默回落软解；
/// 这里把真实结果摆出来，用户和排障都能直接看到是否在硬解。
class DecodeDiagnostics {
  /// 设置中的解码方式（`hwdec`）
  final String requested;

  /// mpv `hwdec-current`；软解为 `no`，未解码视频（纯音频 / 未起播）时为空
  final String current;

  /// mpv `video-codec`，例如 `h264`、`hevc`
  final String codec;

  final int width;
  final int height;

  const DecodeDiagnostics({
    required this.requested,
    required this.current,
    this.codec = '',
    this.width = 0,
    this.height = 0,
  });

  bool get hasVideo => current.isNotEmpty;

  bool get isHardware => hasVideo && current != 'no';

  /// 期望硬解但实际在软解：片源格式（如老核显遇到 HEVC 10bit / AV1）或驱动不支持。
  bool get fellBackToSoftware => hasVideo && requested != 'no' && current == 'no';

  /// 面板一行展示的文字，例如「硬件解码 · d3d11va-copy · h264 1920×1080」。
  String get summary {
    if (!hasVideo) return '未在解码视频';
    final mode = isHardware ? '硬件解码 · $current' : '软件解码';
    final codecName = codec.split(' ').first;
    final size = width > 0 && height > 0 ? ' $width×$height' : '';
    final media = codecName.isEmpty && size.isEmpty ? '' : ' · $codecName$size';
    return '$mode$media'.trim();
  }
}
