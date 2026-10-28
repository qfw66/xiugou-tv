import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../../core/danmaku/danmaku_layout.dart';
import '../../../core/danmaku/danmaku_models.dart';
import '../../../core/danmaku/danmaku_settings.dart';

/// 弹幕层（§43）：叠在视频之上、控制条之下，不接收指针事件。
///
/// 时间来源：播放引擎的位置流只有约 4–10 Hz，直接用会一顿一顿；
/// 这里用 [Ticker] 每帧按「上次位置 + 实际流逝 × 倍速」插值，收到新位置时校正。
/// 暂停时冻结（不插值），拖动 / 回退由 [DanmakuLayout] 自行检测并重排。
///
/// 外观与屏蔽来自 [settings]；[fontSize] / [area] 由宿主按「窗口 / 全屏 / 画中画」选好再传入。
class DanmakuLayer extends StatefulWidget {
  const DanmakuLayer({
    super.key,
    required this.track,
    required this.positionStream,
    required this.initialPosition,
    required this.playing,
    this.rate = 1.0,
    this.settings = DanmakuSettings.defaults,
    this.fontSize,
    this.area,
    this.maxPerSecond = 12,
  });

  final DanmakuTrack track;
  final Stream<Duration> positionStream;
  final Duration initialPosition;

  /// 是否在播放（暂停 / 缓冲时冻结弹幕）
  final bool playing;
  final double rate;
  final DanmakuSettings settings;

  /// 实际字号（null = settings.fontSize）
  final double? fontSize;

  /// 实际显示区域（null = settings.area）
  final double? area;
  final int maxPerSecond;

  @override
  State<DanmakuLayer> createState() => _DanmakuLayerState();
}

/// 画中画字号（§43 二期验收反馈：小窗拉大时字也要适度变大）。
///
/// 以默认小窗高 225 为基准取窗口字号 [base] 的 0.65 倍；小窗变高时按**高度的平方根**放大
/// （高 450 ≈ 0.92 倍），即「适度」跟随而非线性翻倍；上限为窗口字号，下限保证可读。
double pipDanmakuFontSize(double base, double height) {
  const baseHeight = 225.0, baseScale = 0.65;
  if (height <= 0) return base * baseScale;
  final scale = (baseScale * math.sqrt(height / baseHeight)).clamp(0.5, 1.0);
  return (base * scale).clamp(DanmakuSettings.minFontSize * 0.75, base).toDouble();
}

/// 按设置判断某条弹幕是否被屏蔽（纯函数，供排布器与测试复用）。
bool danmakuAccepted(DanmakuSettings s, DanmakuItem item) {
  switch (item.mode) {
    case DanmakuMode.scroll:
      if (s.blockScroll) return false;
    case DanmakuMode.top:
      if (s.blockTop) return false;
    case DanmakuMode.bottom:
      if (s.blockBottom) return false;
    case DanmakuMode.advanced:
      if (s.blockAdvanced) return false;
  }
  if (s.blockColorful && (item.color & 0xFFFFFF) != 0xFFFFFF) return false;
  return true;
}

class _DanmakuLayerState extends State<DanmakuLayer> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  StreamSubscription<Duration>? _sub;
  DanmakuLayout? _layout;
  Size _size = Size.zero;

  /// 最近一次引擎位置（秒）与收到它时的 ticker 时间
  double _anchorPos = 0;
  Duration _anchorTick = Duration.zero;
  Duration _lastTick = Duration.zero;
  final ValueNotifier<double> _time = ValueNotifier(0);

  /// 文本排版缓存（同一条弹幕只排版一次；离屏即释放）
  final Map<DanmakuItem, TextPainter> _painters = {};

  double get _fontSize => widget.fontSize ?? widget.settings.fontSize;
  double get _area => widget.area ?? widget.settings.area;
  double get _lineHeight => _fontSize * widget.settings.lineHeight;

  @override
  void initState() {
    super.initState();
    _anchorPos = widget.initialPosition.inMilliseconds / 1000;
    _time.value = _anchorPos;
    _ticker = createTicker(_onTick)..start();
    _subscribe();
  }

  void _subscribe() {
    _sub?.cancel();
    _sub = widget.positionStream.listen((pos) {
      _anchorPos = pos.inMilliseconds / 1000;
      _anchorTick = _lastTick;
      if (!widget.playing) _time.value = _anchorPos;
    });
  }

  @override
  void didUpdateWidget(DanmakuLayer old) {
    super.didUpdateWidget(old);
    if (old.positionStream != widget.positionStream) _subscribe();
    final styleChanged = old.settings.fontWeight != widget.settings.fontWeight ||
        old.settings.strokeWidth != widget.settings.strokeWidth ||
        (old.fontSize ?? old.settings.fontSize) != _fontSize;
    final layoutChanged = styleChanged ||
        old.settings != widget.settings ||
        (old.area ?? old.settings.area) != _area ||
        old.maxPerSecond != widget.maxPerSecond;
    if (old.track != widget.track) {
      _disposePainters();
      _layout = null;
    } else if (layoutChanged) {
      if (styleChanged) _disposePainters();
      _layout?.reset(_config(_size), _time.value);
    }
    if (old.playing != widget.playing) {
      // 暂停 → 播放：以当前显示时间为锚点继续，避免跳一下
      _anchorPos = _time.value;
      _anchorTick = _lastTick;
    }
  }

  void _onTick(Duration elapsed) {
    _lastTick = elapsed;
    if (!widget.playing) return;
    final dt = (elapsed - _anchorTick).inMicroseconds / 1e6;
    // 引擎位置流偶尔停发（缓冲）时不要无限外推：最多外推 1.5 s
    _time.value = _anchorPos + (dt.clamp(0, 1.5)) * widget.rate;
  }

  DanmakuLayoutConfig _config(Size size) {
    final s = widget.settings;
    return DanmakuLayoutConfig(
      width: size.width,
      height: size.height,
      lineHeight: _lineHeight,
      areaFraction: _area,
      scrollDuration: s.scrollDuration,
      fixedDuration: s.fixedDuration,
      maxPerSecond: widget.maxPerSecond,
      accept: (item) => danmakuAccepted(s, item),
    );
  }

  TextPainter _painterFor(DanmakuItem item) => _painters.putIfAbsent(item, () {
        final s = widget.settings;
        final color = Color(0xFF000000 | item.color);
        final weight = FontWeight.values[((s.fontWeight ~/ 100) - 1).clamp(0, 8)];
        final stroke = s.strokeWidth;
        // 描边：用 4 向 + 4 角的零模糊阴影近似（Flutter 文本描边需双层绘制，阴影更省）
        final shadows = <Shadow>[
          if (stroke > 0)
            for (final o in const [
              Offset(1, 0), Offset(-1, 0), Offset(0, 1), Offset(0, -1),
              Offset(0.7, 0.7), Offset(-0.7, 0.7), Offset(0.7, -0.7), Offset(-0.7, -0.7),
            ])
              Shadow(color: const Color(0xE6000000), offset: o * stroke),
        ];
        return TextPainter(
          text: TextSpan(
            text: item.text,
            style: TextStyle(
              color: color,
              fontSize: _fontSize,
              fontWeight: weight,
              height: 1.2,
              shadows: shadows,
            ),
          ),
          textDirection: TextDirection.ltr,
          maxLines: 1,
        )..layout();
      });

  void _disposePainters() {
    for (final p in _painters.values) {
      p.dispose();
    }
    _painters.clear();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _sub?.cancel();
    _disposePainters();
    _time.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: LayoutBuilder(builder: (context, constraints) {
        final size = constraints.biggest;
        if (size.width <= 0 || size.height <= 0) return const SizedBox.shrink();
        if (_layout == null) {
          _layout = DanmakuLayout(widget.track, _config(size), measure: (i) => _painterFor(i).width);
          _layout!.seek(_time.value);
        } else if (size != _size) {
          _layout!.reset(_config(size), _time.value);
        }
        _size = size;
        return RepaintBoundary(
          child: CustomPaint(
            size: size,
            painter: _DanmakuPainter(
              layout: _layout!,
              time: _time,
              painterFor: _painterFor,
              opacity: widget.settings.opacity,
              lineHeight: _lineHeight,
              onRetire: (items) {
                for (final i in items) {
                  _painters.remove(i)?.dispose();
                }
              },
            ),
          ),
        );
      }),
    );
  }
}

class _DanmakuPainter extends CustomPainter {
  _DanmakuPainter({
    required this.layout,
    required this.time,
    required this.painterFor,
    required this.opacity,
    required this.lineHeight,
    required this.onRetire,
  }) : super(repaint: time);

  final DanmakuLayout layout;
  final ValueNotifier<double> time;
  final TextPainter Function(DanmakuItem) painterFor;
  final double opacity;
  final double lineHeight;
  final void Function(Iterable<DanmakuItem>) onRetire;

  Set<DanmakuItem> _prev = {};

  @override
  void paint(Canvas canvas, Size size) {
    final t = time.value;
    final visible = layout.advance(t);
    final now = <DanmakuItem>{};
    final useLayer = opacity < 0.999;
    if (useLayer) {
      canvas.saveLayer(Offset.zero & size, Paint()..color = Color.fromRGBO(0, 0, 0, opacity));
    }
    // 底部弹幕从显示区域的下沿往上排（区域 < 全屏时不贴到画面最底下）
    final areaBottom = size.height * layout.config.areaFraction;
    for (final d in visible) {
      now.add(d.item);
      final tp = painterFor(d.item);
      final double x;
      final double y;
      switch (d.item.mode) {
        case DanmakuMode.scroll:
        case DanmakuMode.advanced:
          x = layout.scrollX(d, t);
          y = d.lane * lineHeight;
        case DanmakuMode.top:
          x = (size.width - tp.width) / 2;
          y = d.lane * lineHeight;
        case DanmakuMode.bottom:
          x = (size.width - tp.width) / 2;
          y = areaBottom - (d.lane + 1) * lineHeight - (areaBottom >= size.height ? 8 : 0);
      }
      tp.paint(canvas, Offset(x, y + (lineHeight - tp.height) / 2));
    }
    if (useLayer) canvas.restore();
    // 离屏的弹幕释放排版缓存，避免 4 万条全堆在内存里
    final gone = _prev.difference(now);
    if (gone.isNotEmpty) onRetire(gone);
    _prev = now;
  }

  @override
  bool shouldRepaint(_DanmakuPainter old) =>
      old.layout != layout || old.opacity != opacity || old.lineHeight != lineHeight;
}
