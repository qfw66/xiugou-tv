import 'package:flutter/material.dart';

import '../../../core/danmaku/danmaku_settings.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';
import 'player_side_drawer.dart';

/// 播放页「弹幕设置」抽屉内容（§43 二期验收反馈：播放中直接调，不用退到设置中心）。
///
/// 与设置中心「弹幕」分组是同一份 [DanmakuSettings]：这里改了会落盘，设置中心也同步。
/// - 选项类（屏蔽 / 区域 / 字重）点了立即生效；
/// - 滑块拖动时只更新抽屉内数值，**松手**才提交（避免拖动中每帧都落盘）。
///
/// 抽屉是独立路由，宿主重建不会刷新这里，所以面板自己持有一份当前值。
class DanmakuSettingsPanel extends StatefulWidget {
  const DanmakuSettingsPanel({
    super.key,
    required this.initial,
    required this.onChanged,
    required this.enabled,
    required this.onToggle,
  });

  final DanmakuSettings initial;
  final ValueChanged<DanmakuSettings> onChanged;

  /// 本次播放是否显示弹幕（与控制条「弹幕」按钮 / D 键同一个开关）
  final bool enabled;
  final VoidCallback onToggle;

  @override
  State<DanmakuSettingsPanel> createState() => _DanmakuSettingsPanelState();
}

class _DanmakuSettingsPanelState extends State<DanmakuSettingsPanel> {
  late DanmakuSettings _value = widget.initial;
  late bool _enabled = widget.enabled;

  /// 正在拖动的滑块：键 → 临时值（松手前不提交）
  final Map<String, double> _dragging = {};

  void _commit(DanmakuSettings next) {
    if (next == _value) return;
    setState(() => _value = next);
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final d = _value;
    return PlayerSideDrawerFrame(
      key: const ValueKey('danmaku-settings-drawer'),
      icon: Icons.tune_rounded,
      title: '弹幕设置',
      closeTooltip: '关闭弹幕设置',
      footer: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            key: const ValueKey('danmaku-drawer-reset'),
            onPressed: d == DanmakuSettings.defaults
                ? null
                : () => _commit(DanmakuSettings.defaults),
            child: const Text('恢复默认'),
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _switchRow(),
          // 2026-10-27 验收反馈：与下方滑块统一成「左标签 / 中控件 / 右数值」一行一项。
          // 屏蔽是开关量，不适合滑块，同样一行一项，控件用开关。
          _section('屏蔽类型'),
          _toggleRow('block-scroll', '滚动弹幕', d.blockScroll, (v) => d.copyWith(blockScroll: v)),
          _toggleRow('block-top', '顶部弹幕', d.blockTop, (v) => d.copyWith(blockTop: v)),
          _toggleRow('block-bottom', '底部弹幕', d.blockBottom, (v) => d.copyWith(blockBottom: v)),
          _toggleRow('block-colorful', '彩色弹幕', d.blockColorful, (v) => d.copyWith(blockColorful: v)),
          _toggleRow('block-advanced', '高级弹幕', d.blockAdvanced, (v) => d.copyWith(blockAdvanced: v)),
          _section('显示'),
          _optionSlider<double>('area', '显示区域', DanmakuSettings.areaOptions,
              (v) => (v - d.area).abs() < 0.01, (v) => d.copyWith(area: v)),
          _optionSlider<double>('pip-area', '画中画区域', DanmakuSettings.areaOptions,
              (v) => (v - d.pipArea).abs() < 0.01, (v) => d.copyWith(pipArea: v)),
          _optionSlider<int>('weight', '字体粗细', DanmakuSettings.fontWeightOptions,
              (v) => v == d.fontWeight, (v) => d.copyWith(fontWeight: v)),
          _section('外观'),
          _slider('opacity', '不透明度', d.opacity, DanmakuSettings.minOpacity,
              DanmakuSettings.maxOpacity, 18, (v) => '${(v * 100).round()}%',
              (v) => d.copyWith(opacity: v)),
          _slider('stroke', '描边粗细', d.strokeWidth, DanmakuSettings.minStroke,
              DanmakuSettings.maxStroke, 8, (v) => v == 0 ? '无' : v.toStringAsFixed(1),
              (v) => d.copyWith(strokeWidth: v)),
          _slider('font-size', '字体大小', d.fontSize, DanmakuSettings.minFontSize,
              DanmakuSettings.maxFontSize, 36, (v) => '${v.round()}',
              (v) => d.copyWith(fontSize: v.roundToDouble())),
          _slider('fullscreen-font-size', '全屏字体大小', d.fullscreenFontSize,
              DanmakuSettings.minFontSize, DanmakuSettings.maxFontSize, 36,
              (v) => '${v.round()}', (v) => d.copyWith(fullscreenFontSize: v.roundToDouble())),
          _slider('line-height', '行高', d.lineHeight, DanmakuSettings.minLineHeight,
              DanmakuSettings.maxLineHeight, 15, (v) => '${v.toStringAsFixed(1)}×',
              (v) => d.copyWith(lineHeight: v)),
          _section('速度'),
          _slider('scroll-duration', '滚动弹幕时长', d.scrollDuration, DanmakuSettings.minScroll,
              DanmakuSettings.maxScroll, 34, _sec, (v) => d.copyWith(scrollDuration: v)),
          _slider('fixed-duration', '静态弹幕时长', d.fixedDuration, DanmakuSettings.minFixed,
              DanmakuSettings.maxFixed, 18, _sec, (v) => d.copyWith(fixedDuration: v)),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  static String _sec(double v) => '${v.toStringAsFixed(v % 1 == 0 ? 0 : 1)} 秒';

  Widget _switchRow() {
    final palette = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 10, 0),
      child: Row(
        children: [
          Expanded(
            child: Text('本次播放显示弹幕',
                style: TextStyle(color: palette.playerText, fontSize: AppType.label)),
          ),
          Switch(
            key: const ValueKey('danmaku-drawer-enabled'),
            value: _enabled,
            onChanged: (_) {
              widget.onToggle();
              setState(() => _enabled = !_enabled);
            },
          ),
        ],
      ),
    );
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
        child: Text(
          title,
          style: TextStyle(
            color: context.palette.textDim,
            fontSize: AppType.caption,
            letterSpacing: 0.5,
            fontWeight: FontWeight.w600,
          ),
        ),
      );

  /// 一行一项的统一骨架：左标签（固定宽）· 中控件 · 右数值（固定宽，开关行为空）。
  Widget _row(String label, Widget control, {String? value}) {
    final palette = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 8, 0),
      child: SizedBox(
        height: 40,
        child: Row(
          children: [
            SizedBox(
              width: _labelWidth,
              child: Text(label, style: TextStyle(color: palette.playerText, fontSize: AppType.body)),
            ),
            Expanded(child: control),
            SizedBox(
              width: _valueWidth,
              child: value == null
                  ? null
                  : Text(
                      value,
                      textAlign: TextAlign.right,
                      maxLines: 1,
                      style: TextStyle(color: palette.textSub, fontSize: AppType.body),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  static const double _labelWidth = 84;
  static const double _valueWidth = 52;

  /// 屏蔽开关行：开关靠右贴着数值列，与滑块行的末端对齐。
  Widget _toggleRow(String key, String label, bool value, DanmakuSettings Function(bool) apply) => _row(
        label,
        Align(
          alignment: Alignment.centerRight,
          child: Transform.scale(
            scale: 0.8,
            alignment: Alignment.centerRight,
            child: Switch(
              key: ValueKey('danmaku-drawer-$key'),
              value: value,
              onChanged: (v) => _commit(apply(v)),
            ),
          ),
        ),
        value: value ? '屏蔽' : '显示',
      );

  /// 档位滑块：选项按顺序排成离散刻度，右侧显示档位名；松手提交（与数值滑块同一节奏）。
  Widget _optionSlider<T>(
    String key,
    String label,
    List<(T, String)> options,
    bool Function(T) isCurrent,
    DanmakuSettings Function(T) apply,
  ) {
    var index = options.indexWhere((o) => isCurrent(o.$1));
    if (index < 0) index = 0;
    final shown = (_dragging[key] ?? index.toDouble()).round().clamp(0, options.length - 1);
    return _row(
      label,
      Slider(
        key: ValueKey('danmaku-drawer-$key'),
        value: shown.toDouble(),
        min: 0,
        max: (options.length - 1).toDouble(),
        divisions: options.length - 1,
        onChanged: (v) => setState(() => _dragging[key] = v),
        onChangeEnd: (v) {
          _dragging.remove(key);
          _commit(apply(options[v.round().clamp(0, options.length - 1)].$1));
        },
      ),
      value: options[shown].$2,
    );
  }

  Widget _slider(
    String key,
    String label,
    double current,
    double min,
    double max,
    int divisions,
    String Function(double) format,
    DanmakuSettings Function(double) apply,
  ) {
    final shown = (_dragging[key] ?? current).clamp(min, max).toDouble();
    return _row(
      label,
      Slider(
        key: ValueKey('danmaku-drawer-$key'),
        value: shown,
        min: min,
        max: max,
        divisions: divisions,
        onChanged: (v) => setState(() => _dragging[key] = v),
        onChangeEnd: (v) {
          _dragging.remove(key);
          _commit(apply(v));
        },
      ),
      value: format(shown),
    );
  }
}
