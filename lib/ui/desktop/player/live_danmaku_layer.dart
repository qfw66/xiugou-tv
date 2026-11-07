import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../../core/danmaku/danmaku_settings.dart';
import '../../../core/danmaku/live_danmaku_models.dart';

/// Realtime scrolling comments, timed independently of the media position.
///
/// Pausing freezes flights and discards incoming comments. Remove this layer or
/// disable its [TickerMode] when hidden to release the stream subscription.
/// The stream must support listening again after a hidden layer becomes visible.
class LiveDanmakuLayer extends StatefulWidget {
  const LiveDanmakuLayer({
    super.key,
    required this.messages,
    required this.playing,
    this.settings = DanmakuSettings.defaults,
    this.fontSize,
    this.area,
    this.maxPerSecond = 12,
  });

  final Stream<List<LiveDanmakuMessage>> messages;
  final bool playing;
  final DanmakuSettings settings;
  final double? fontSize;
  final double? area;
  final int maxPerSecond;

  @override
  State<LiveDanmakuLayer> createState() => _LiveDanmakuLayerState();
}

class _LiveDanmakuLayerState extends State<LiveDanmakuLayer> with SingleTickerProviderStateMixin {
  final _layout = _LiveDanmakuLayout();
  late final Ticker _ticker;
  StreamSubscription<List<LiveDanmakuMessage>>? _subscription;
  Duration _lastTick = Duration.zero;
  int _generation = 0;
  bool _visible = false;
  bool _hasSurface = false;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visible = TickerMode.valuesOf(context).enabled;
    _syncLifecycle();
  }

  @override
  void didUpdateWidget(LiveDanmakuLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.messages != widget.messages) {
      _unsubscribe();
      _layout.clear();
      _stopTicker();
    }
    _syncLifecycle();
  }

  void _unsubscribe() {
    _generation++;
    _subscription?.cancel();
    _subscription = null;
  }

  void _stopTicker() {
    _ticker.stop();
    _lastTick = Duration.zero;
  }

  void _syncLifecycle() {
    if (!_visible || !_hasSurface) {
      _unsubscribe();
      _stopTicker();
      _layout.clear();
      return;
    }
    if (_subscription == null) {
      final generation = ++_generation;
      _subscription = widget.messages.listen((messages) {
        if (!mounted || generation != _generation || !widget.playing || !_visible || !_hasSurface) return;
        _layout.append(messages);
      });
    }
    if (widget.playing) {
      if (!_ticker.isActive) _ticker.start();
    } else {
      _stopTicker();
    }
  }

  void _onTick(Duration elapsed) {
    final delta = (elapsed - _lastTick).inMicroseconds / Duration.microsecondsPerSecond;
    _lastTick = elapsed;
    if (widget.playing && delta >= 0) _layout.advance(delta);
  }

  @override
  void dispose() {
    _unsubscribe();
    _ticker.dispose();
    _layout.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: LayoutBuilder(builder: (context, constraints) {
          final size = constraints.biggest;
          _hasSurface = size.isFinite && size.width > 0 && size.height > 0;
          if (!_hasSurface) {
            _syncLifecycle();
            return const SizedBox.shrink();
          }
          _layout.configure(
            size: size,
            settings: widget.settings,
            fontSize: widget.fontSize ?? widget.settings.fontSize,
            area: widget.area ?? widget.settings.area,
            maxPerSecond: widget.maxPerSecond,
          );
          _syncLifecycle();
          return RepaintBoundary(
            child: CustomPaint(size: size, painter: _LiveDanmakuPainter(_layout)),
          );
        }),
      );
}

class _LiveEntry {
  _LiveEntry(this.message, this.arrivedAt);

  final LiveDanmakuMessage message;
  final double arrivedAt;
  int count = 1;
  bool admitted = false;

  String get text => count == 1 ? message.text : '${message.text}\u200Ax\u200A${count > 999 ? '999+' : count}';
}

class _LiveFlight {
  _LiveFlight(this.entry, this.painter, this.width, this.startedAt, this.lane);

  final _LiveEntry entry;
  TextPainter painter;
  double width;
  double startedAt;
  int lane;
}

class _LiveDanmakuLayout extends ChangeNotifier {
  static const _capacity = 256;
  static const _gap = 24.0;
  static const _maxTextRunes = 512;
  final _active = <_LiveFlight>[];
  final _pending = Queue<_LiveEntry>();
  final _recent = <(String, int, String), _LiveEntry>{};
  final _admitted = Queue<double>();
  List<_LiveFlight?> _tails = [];
  Size _size = Size.zero;
  DanmakuSettings _settings = DanmakuSettings.defaults;
  double _fontSize = DanmakuSettings.defaults.fontSize;
  double _area = DanmakuSettings.defaults.area;
  int _maxPerSecond = 12;
  double _time = 0;

  double get _lineHeight => _fontSize * _settings.lineHeight;
  int get _limit => math.min(_capacity, (math.max(0, _maxPerSecond) / math.max(1, _settings.density)).ceil());
  double _speed(double width) => (_size.width + width) / _settings.scrollDuration;
  double _x(_LiveFlight flight) => _size.width - (_time - flight.startedAt) * _speed(flight.width);

  void configure({
    required Size size,
    required DanmakuSettings settings,
    required double fontSize,
    required double area,
    required int maxPerSecond,
  }) {
    if (size == _size &&
        settings == _settings &&
        fontSize == _fontSize &&
        area == _area &&
        maxPerSecond == _maxPerSecond) {
      return;
    }
    final oldDuration = _settings.scrollDuration;
    final styleChanged = fontSize != _fontSize ||
        settings.fontWeight != _settings.fontWeight ||
        settings.strokeWidth != _settings.strokeWidth;
    if (settings.mergeDuplicates != _settings.mergeDuplicates) _recent.clear();
    _size = size;
    _settings = settings;
    _fontSize = fontSize;
    _area = area.clamp(0.0, 1.0);
    _maxPerSecond = maxPerSecond;
    final lanes = (_size.height * _area / _lineHeight).floor().clamp(0, _capacity);
    _tails = List.filled(lanes, null);
    _active.removeWhere((flight) {
      final progress = (_time - flight.startedAt) / oldDuration;
      flight.startedAt = _time - progress * settings.scrollDuration;
      if (styleChanged) {
        flight.painter.dispose();
        flight.painter = _textPainter(flight.entry.text, flight.entry.message);
        flight.width = _reservedWidth(flight.entry, flight.painter.width);
      }
      final x = _x(flight);
      final lane = _accepted(flight.entry.message) && x + flight.width > 0 ? _laneFor(flight.width, x) : null;
      if (lane == null) {
        flight.painter.dispose();
        return true;
      }
      flight.lane = lane;
      _tails[lane] = flight;
      return false;
    });
    notifyListeners();
  }

  bool _accepted(LiveDanmakuMessage message) {
    if (_settings.blockScroll) return false;
    if (_settings.blockColorful &&
        ((message.color & 0xFFFFFF) != 0xFFFFFF ||
            message.colors.take(8).any((color) => (color & 0xFFFFFF) != 0xFFFFFF))) {
      return false;
    }
    return _settings.density <= 1 || message.seq % _settings.density == 0;
  }

  void append(List<LiveDanmakuMessage> messages) {
    if (_settings.blockScroll || _limit == 0 || _tails.isEmpty) return;
    _pruneHistory();
    // invariant: retained flights + pending entries never exceed 256; a flood
    // also has bounded per-callback work, including batches of filtered text.
    for (final incoming in messages.take(_capacity * 4)) {
      if (!_accepted(incoming)) continue;
      final text = String.fromCharCodes(incoming.text.runes.take(_maxTextRunes)).replaceAll(RegExp(r'\s+'), ' ').trim();
      if (text.isEmpty) continue;
      final colors = incoming.colors.length >= 2 ? List<int>.unmodifiable(incoming.colors.take(8)) : const <int>[];
      final message = LiveDanmakuMessage(seq: incoming.seq, text: text, color: incoming.color, colors: colors);
      final key = (text, message.color & 0xFFFFFF, colors.join(','));
      final existing = _settings.mergeDuplicates ? _recent[key] : null;
      if (existing != null) {
        existing.count = math.min(1000, existing.count + 1);
        for (final flight in _active) {
          if (identical(flight.entry, existing)) {
            flight.painter.dispose();
            flight.painter = _textPainter(existing.text, existing.message);
            break;
          }
        }
        continue;
      }
      if (_active.length + _pending.length >= _capacity) break;
      final entry = _LiveEntry(message, _time);
      _pending.add(entry);
      if (_settings.mergeDuplicates) {
        if (_recent.length >= _capacity) _recent.remove(_recent.keys.first);
        _recent[key] = entry;
      }
    }
    while (_pending.isNotEmpty && _admitted.length < _limit) {
      final entry = _pending.removeFirst();
      final painter = _textPainter(entry.text, entry.message);
      final width = _reservedWidth(entry, painter.width);
      final lane = _laneFor(width, _size.width);
      if (lane == null) {
        painter.dispose();
        continue;
      }
      final flight = _LiveFlight(entry, painter, width, _time, lane);
      _active.add(flight);
      entry.admitted = true;
      _tails[lane] = flight;
      _admitted.add(_time);
    }
    _pending.clear();
    // A dropped candidate must not suppress a later, displayable repetition.
    _recent.removeWhere((_, entry) => !entry.admitted);
    notifyListeners();
  }

  double _reservedWidth(_LiveEntry entry, double width) {
    if (!_settings.mergeDuplicates) return width;
    final reserve = _textPainter('${entry.message.text}\u200Ax\u200A999+', entry.message);
    final result = math.max(width, reserve.width);
    reserve.dispose();
    return result;
  }

  int? _laneFor(double width, double x) {
    for (var lane = 0; lane < _tails.length; lane++) {
      final previous = _tails[lane];
      if (previous == null) return lane;
      final previousRight = _x(previous) + previous.width;
      if (previousRight + _gap > x) continue;
      final previousSpeed = _speed(previous.width);
      final speed = _speed(width);
      if (speed > previousSpeed && x - speed * (previousRight / previousSpeed) < _gap) continue;
      return lane;
    }
    return null;
  }

  void _pruneHistory() {
    while (_admitted.isNotEmpty && _admitted.first <= _time - 1) {
      _admitted.removeFirst();
    }
    _recent.removeWhere((_, entry) => _time - entry.arrivedAt > DanmakuSettings.mergeWindow);
  }

  void advance(double delta) {
    _time += delta;
    _pruneHistory();
    if (_active.isEmpty) return;
    _active.removeWhere((flight) {
      if (_x(flight) + flight.width > 0) return false;
      if (identical(_tails[flight.lane], flight)) _tails[flight.lane] = null;
      flight.painter.dispose();
      return true;
    });
    notifyListeners();
  }

  TextPainter _textPainter(String text, LiveDanmakuMessage message) {
    final stroke = _settings.strokeWidth;
    final style = TextStyle(
      color: Color(0xFF000000 | (message.color & 0xFFFFFF)),
      fontSize: _fontSize,
      fontWeight: FontWeight.values[((_settings.fontWeight ~/ 100) - 1).clamp(0, 8)],
      height: 1.2,
      shadows: [
        if (stroke > 0)
          for (final offset in const [
            Offset(1, 0),
            Offset(-1, 0),
            Offset(0, 1),
            Offset(0, -1),
            Offset(0.7, 0.7),
            Offset(-0.7, 0.7),
            Offset(0.7, -0.7),
            Offset(-0.7, -0.7),
          ])
            Shadow(color: const Color(0xE6000000), offset: offset * stroke),
      ],
    );
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    if (message.colors.length >= 2 && painter.width > 0) {
      painter.text = TextSpan(
        text: text,
        style: style.copyWith(
          foreground: Paint()
            ..shader = LinearGradient(
              colors: [for (final color in message.colors) Color(0xFF000000 | (color & 0xFFFFFF))],
            ).createShader(Rect.fromLTWH(0, 0, painter.width, painter.height)),
        ),
      );
      painter.layout();
    }
    return painter;
  }

  void clear() {
    for (final flight in _active) {
      flight.painter.dispose();
    }
    _active.clear();
    _pending.clear();
    _recent.clear();
    _admitted.clear();
    _tails.fillRange(0, _tails.length, null);
    _time = 0;
    notifyListeners();
  }

  @override
  void dispose() {
    clear();
    super.dispose();
  }
}

class _LiveDanmakuPainter extends CustomPainter {
  _LiveDanmakuPainter(this.layout) : super(repaint: layout);

  final _LiveDanmakuLayout layout;

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Rect.fromLTWH(0, 0, size.width, size.height * layout._area);
    canvas.save();
    canvas.clipRect(bounds);
    final opacity = layout._settings.opacity.clamp(0.0, 1.0);
    if (opacity < 1) canvas.saveLayer(bounds, Paint()..color = Color.fromRGBO(0, 0, 0, opacity));
    for (final flight in layout._active) {
      final y = flight.lane * layout._lineHeight + (layout._lineHeight - flight.painter.height) / 2;
      canvas.save();
      canvas.translate(layout._x(flight), y);
      flight.painter.paint(canvas, Offset.zero);
      canvas.restore();
    }
    if (opacity < 1) canvas.restore();
    canvas.restore();
  }

  @override
  bool shouldRepaint(_LiveDanmakuPainter oldDelegate) => oldDelegate.layout != layout;
}
