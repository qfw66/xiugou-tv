/// 播放器运行状态枚举
enum PlaybackStatus {
  idle,
  buffering,
  playing,
  paused,
  completed,
  error,
}

/// 媒体播放输入规约模型
class MediaPlaySpec {
  final String url;
  final Map<String, String>? headers;
  final String? title;
  final bool isLive;
  final Duration? startPosition;

  const MediaPlaySpec({
    required this.url,
    this.headers,
    this.title,
    this.isLive = false,
    this.startPosition,
  });

  @override
  String toString() => 'MediaPlaySpec(url: $url, title: $title, isLive: $isLive)';
}

/// 视频画面分辨率尺寸
class VideoDimensions {
  final int width;
  final int height;

  const VideoDimensions({this.width = 0, this.height = 0});

  double get aspectRatio => (width > 0 && height > 0) ? width / height : 16 / 9;

  @override
  String toString() => '${width}x$height';
}
