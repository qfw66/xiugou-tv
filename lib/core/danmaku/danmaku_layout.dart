import 'dart:math' as math;

import 'danmaku_models.dart';

/// 一条已排好位置的弹幕（布局结果，只读）。
class PlacedDanmaku {
  const PlacedDanmaku(this.item, this.lane, this.width);

  final DanmakuItem item;

  /// 所在轨道（0 起，自上而下；底部弹幕自下而上）
  final int lane;

  /// 文本像素宽度（由测量函数给出）
  final double width;
}

/// 弹幕布局参数（与画布尺寸、字号相关；变化时需重新 [DanmakuLayout.reset]）。
class DanmakuLayoutConfig {
  const DanmakuLayoutConfig({
    required this.width,
    required this.height,
    this.lineHeight = 30,
    this.areaFraction = 0.75,
    this.scrollDuration = 8.0,
    this.fixedDuration = 4.0,
    this.maxPerSecond = 12,
    this.gap = 24,
    this.accept,
  });

  /// 画布尺寸（逻辑像素）
  final double width;
  final double height;

  /// 一条轨道的高度
  final double lineHeight;

  /// 弹幕可占用的画面比例（自上而下），默认上 3/4
  final double areaFraction;

  /// 滚动弹幕从右边进到完全离开左边所用时间（秒，按 1x 播放计）
  final double scrollDuration;

  /// 顶部 / 底部弹幕停留时间（秒）
  final double fixedDuration;

  /// 每秒最多上屏条数（密度上限，超出丢弃；防止 4 万条把画面糊满、拖垮帧率）
  final int maxPerSecond;

  /// 同轨两条滚动弹幕之间至少留的像素间距
  final double gap;

  /// 过滤（屏蔽规则）：返回 false 的弹幕不上屏、不占轨道与配额
  final bool Function(DanmakuItem item)? accept;

  int get lanes => math.max(1, (height * areaFraction / lineHeight).floor());

  /// 滚动速度（像素 / 秒）：屏宽 + 一个典型文本宽度在 [scrollDuration] 内走完
  double speedFor(double textWidth) => (width + textWidth) / scrollDuration;
}

/// 弹幕排布器：按播放时间增量地把弹幕分配到轨道，计算每一帧的可见列表。
///
/// 纯逻辑、与 Flutter 绘制解耦（文本宽度由 [measure] 注入），便于测试。
///
/// - 只处理「已到时间」的弹幕：游标随时间前进，回退 / 跳转超过 1 s 时 [seek] 重排；
/// - 滚动弹幕找「前车已完全进入画面且不会被追尾」的轨道，顶部 / 底部弹幕找空闲轨道；
/// - 找不到轨道或超出每秒配额时丢弃（弹幕少丢一些远比叠成一坨好）。
class DanmakuLayout {
  DanmakuLayout(this.track, this.config, {required this.measure});

  final DanmakuTrack track;
  DanmakuLayoutConfig config;
  final double Function(DanmakuItem item) measure;

  int _cursor = 0;
  double _lastTime = -1;
  final List<PlacedDanmaku> _active = [];

  /// 每条轨道上最后一条滚动弹幕（用来判断追尾）
  late List<PlacedDanmaku?> _scrollTail = List.filled(config.lanes, null);
  late List<double> _topUntil = List.filled(config.lanes, -1);
  late List<double> _bottomUntil = List.filled(config.lanes, -1);

  int _bucketSecond = -1;
  int _bucketCount = 0;

  /// 当前屏上的弹幕（含尚在动画中的）
  List<PlacedDanmaku> get active => List.unmodifiable(_active);

  /// 画布尺寸 / 字号变化：保留配置，清空排布从当前时间重排。
  void reset(DanmakuLayoutConfig next, double time) {
    config = next;
    seek(time);
  }

  /// 跳转：清屏，游标移到 [time] 处（不回补已过去的弹幕）。
  void seek(double time) {
    _active.clear();
    _scrollTail = List.filled(config.lanes, null);
    _topUntil = List.filled(config.lanes, -1);
    _bottomUntil = List.filled(config.lanes, -1);
    _bucketSecond = -1;
    _bucketCount = 0;
    _cursor = track.lowerBound(time);
    _lastTime = time;
  }

  /// 推进到播放时间 [time]（秒），返回需要绘制的弹幕。
  List<PlacedDanmaku> advance(double time) {
    if (_lastTime < 0 || time < _lastTime - 0.05 || time - _lastTime > 1.5) {
      seek(time);
    }
    _lastTime = time;

    while (_cursor < track.length && track.items[_cursor].time <= time) {
      _place(track.items[_cursor]);
      _cursor++;
    }
    _active.removeWhere((d) => !_visibleAt(d, time));
    return _active;
  }

  bool _visibleAt(PlacedDanmaku d, double time) {
    final age = time - d.item.time;
    if (_scrolls(d.item)) {
      return age <= (config.width + d.width) / config.speedFor(d.width);
    }
    return age <= config.fixedDuration;
  }

  /// 滚动弹幕在 [time] 时左边缘的 x 坐标
  double scrollX(PlacedDanmaku d, double time) =>
      config.width - (time - d.item.time) * config.speedFor(d.width);

  /// 高级弹幕（定位 / 代码）桌面端不解析其脚本，开启显示时按滚动处理。
  static bool _scrolls(DanmakuItem item) =>
      item.mode == DanmakuMode.scroll || item.mode == DanmakuMode.advanced;

  void _place(DanmakuItem item) {
    if (config.accept != null && !config.accept!(item)) return;
    final second = item.time.floor();
    if (second != _bucketSecond) {
      _bucketSecond = second;
      _bucketCount = 0;
    }
    if (_bucketCount >= config.maxPerSecond) return;

    final width = measure(item);
    final lane = switch (item.mode) {
      DanmakuMode.scroll || DanmakuMode.advanced => _scrollLane(item, width),
      DanmakuMode.top => _fixedLane(_topUntil, item),
      DanmakuMode.bottom => _fixedLane(_bottomUntil, item),
    };
    if (lane == null) return;
    final placed = PlacedDanmaku(item, lane, width);
    if (_scrolls(item)) _scrollTail[lane] = placed;
    _active.add(placed);
    _bucketCount++;
  }

  int? _scrollLane(DanmakuItem item, double width) {
    final t = item.time;
    for (var lane = 0; lane < _scrollTail.length; lane++) {
      final prev = _scrollTail[lane];
      if (prev == null) return lane;
      // 前车尾部必须已进入画面并留出间距
      final prevRight = scrollX(prev, t) + prev.width;
      if (prevRight + config.gap > config.width) continue;
      // 新车更快时不能在前车离开前追上它
      final vPrev = config.speedFor(prev.width);
      final vNew = config.speedFor(width);
      if (vNew > vPrev) {
        final prevExit = (scrollX(prev, t) + prev.width) / vPrev; // 前车尾部到达左边缘的剩余时间
        final newHeadAtExit = config.width - vNew * prevExit;
        if (newHeadAtExit < config.gap) continue;
      }
      return lane;
    }
    return null;
  }

  int? _fixedLane(List<double> until, DanmakuItem item) {
    for (var lane = 0; lane < until.length; lane++) {
      if (until[lane] <= item.time) {
        until[lane] = item.time + config.fixedDuration;
        return lane;
      }
    }
    return null;
  }
}
