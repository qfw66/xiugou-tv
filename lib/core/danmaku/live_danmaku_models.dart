class LiveDanmakuMessage {
  const LiveDanmakuMessage({
    required this.seq,
    required this.text,
    this.color = 0xFFFFFF,
    this.colors = const [],
  });

  final int seq;
  final String text;
  final int color;
  final List<int> colors;
}

enum LiveDanmakuStatus { idle, connecting, ready, retrying, error, closed }
