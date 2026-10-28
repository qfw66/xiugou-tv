import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/segments/segment_models.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';
import 'player_side_drawer.dart';

/// 播放页「片段」视图模型（§44；宿主装配，组件保持哑视图）。
///
/// 与「片头片尾」（本地、按影片记忆）是两个独立功能：这里是**按集共享**给所有用户的片段。
class PlayerSegmentsNav {
  const PlayerSegmentsNav({
    required this.state,
    required this.onSubmit,
    required this.autoApply,
    required this.onAutoApplyChanged,
    this.localOpeningMs = 0,
    this.onFeedback,
  });

  /// 自动执行后的反馈（§44 2026-10-27 拍板）：[disputed] = 用户在提醒期间点了「撤销」。
  /// [episodeKey] = 执行时那一集的键（提醒结束时可能已换集，不能读当前状态）。
  final Future<void> Function(SharedSegment segment, {required bool disputed, String? episodeKey})? onFeedback;

  final ValueListenable<SegmentsState> state;
  final Future<SegmentSubmitResult> Function(SegmentDraft draft) onSubmit;

  /// 是否按共享片段自动跳过 / 静音；关闭后只出提示胶囊，由用户自己点。
  final bool autoApply;
  final ValueChanged<bool> onAutoApplyChanged;

  /// 本地已设的片头点（> 0 时本地优先，共享「片头」不再自动跳）。
  final int localOpeningMs;
}

/// 片段在时间轴上的颜色（§44 用户口径：片头片尾绿色、广告黄色……）。
///
/// 固定色、不随主题：时间轴压在视频画面上，和播放器 chrome 同一套思路。
/// 「精彩时刻」是动作而非分类，单独用粉色，不论标在哪个分类上。
abstract final class SegmentColors {
  static const Color introOutro = Color(0xFF22C55E); // 绿：片头 / 片尾
  static const Color ad = Color(0xFFFACC15); // 黄：广告
  static const Color recapPreview = Color(0xFF38BDF8); // 蓝：前情回顾 / 下集预告
  static const Color other = Color(0xFFA78BFA); // 紫：其他
  static const Color highlight = Color(0xFFF472B6); // 粉：精彩时刻

  static Color of(SegmentCategory category, SegmentAction action) {
    if (action == SegmentAction.highlight) return highlight;
    return switch (category) {
      SegmentCategory.intro || SegmentCategory.outro => introOutro,
      SegmentCategory.ad => ad,
      SegmentCategory.recap || SegmentCategory.preview => recapPreview,
      SegmentCategory.other => other,
    };
  }

  /// 1 票（未确认）的片段在时间轴上画淡一些。
  static const double trustedAlpha = 0.9;
  static const double untrustedAlpha = 0.45;
}

/// 时间轴上的一个色块：起止为本集时长的比例（0–1）。
class SegmentMark {
  const SegmentMark({required this.id, required this.start, required this.end, required this.color});
  final String id;
  final double start;
  final double end;
  final Color color;

  @override
  bool operator ==(Object other) =>
      other is SegmentMark && other.id == id && other.start == start && other.end == end && other.color == color;

  @override
  int get hashCode => Object.hash(id, start, end, color);
}

/// 把本集共享片段换算成时间轴色块：只取与本地时长一致的剪辑版本（±15 秒），
/// 未加载完 / 无时长时为空。1 票的片段颜色变淡。
List<SegmentMark> segmentMarksFor(SegmentsState state, int durationMs) {
  if (state.phase != SegmentsPhase.ready || durationMs <= 0) return const [];
  final marks = <SegmentMark>[];
  for (final s in state.segments) {
    if (!s.matchesDuration(durationMs)) continue;
    final start = (s.startMs / durationMs).clamp(0.0, 1.0);
    final end = (s.endMs / durationMs).clamp(0.0, 1.0);
    if (end <= start) continue;
    marks.add(SegmentMark(
      id: s.id,
      start: start,
      end: end,
      color: SegmentColors.of(s.category, s.action)
          .withValues(alpha: s.trusted ? SegmentColors.trustedAlpha : SegmentColors.untrustedAlpha),
      // 1 票只是画淡一点（还没别人认可过），执行上与多票一致
    ));
  }
  return marks;
}

/// 进度条轨道：默认圆角轨道之上叠画片段色块（滑点仍画在最上层）。
class SegmentTrackShape extends RoundedRectSliderTrackShape {
  const SegmentTrackShape(this.marks);
  final List<SegmentMark> marks;

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
    double additionalActiveTrackHeight = 2,
  }) {
    super.paint(context, offset,
        parentBox: parentBox,
        sliderTheme: sliderTheme,
        enableAnimation: enableAnimation,
        textDirection: textDirection,
        thumbCenter: thumbCenter,
        secondaryOffset: secondaryOffset,
        isDiscrete: isDiscrete,
        isEnabled: isEnabled,
        additionalActiveTrackHeight: additionalActiveTrackHeight);
    if (marks.isEmpty) return;
    final rect = getPreferredRect(
        parentBox: parentBox, offset: offset, sliderTheme: sliderTheme, isEnabled: isEnabled, isDiscrete: isDiscrete);
    final canvas = context.canvas;
    for (final m in marks) {
      final left = rect.left + rect.width * m.start;
      final right = rect.left + rect.width * m.end;
      canvas.drawRRect(
        RRect.fromLTRBR(left, rect.top, right < left + 2 ? left + 2 : right, rect.bottom,
            Radius.circular(rect.height / 2)),
        Paint()..color = m.color,
      );
    }
  }

  @override
  bool operator ==(Object other) => other is SegmentTrackShape && listEquals(other.marks, marks);

  @override
  int get hashCode => Object.hashAll(marks);
}

String formatSegmentTime(int ms) {
  final d = Duration(milliseconds: ms < 0 ? 0 : ms);
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

/// `1:02:03` / `02:03` / `123`（秒）→ 毫秒；格式不对返回 null。
int? parseSegmentTime(String text) {
  final t = text.trim();
  if (t.isEmpty) return null;
  final parts = t.split(RegExp(r'[:：]'));
  if (parts.length > 3) return null;
  var total = 0;
  for (final part in parts) {
    final n = int.tryParse(part.trim());
    if (n == null || n < 0) return null;
    total = total * 60 + n;
  }
  if (parts.length > 1 && parts.skip(1).any((x) => (int.tryParse(x.trim()) ?? 0) >= 60)) return null;
  return total * 1000;
}

/// 「片段」抽屉：上半部分提交（开始 / 结束 / 分类 / 动作），下半部分本集已共享的片段。
class SegmentPanel extends StatefulWidget {
  const SegmentPanel({
    super.key,
    required this.nav,
    required this.position,
    required this.duration,
    required this.onSeek,
  });

  final PlayerSegmentsNav nav;

  /// 当前播放位置（「取当前」按钮用；每次取最新值）
  final Duration Function() position;
  final Duration Function() duration;
  final ValueChanged<Duration> onSeek;

  @override
  State<SegmentPanel> createState() => _SegmentPanelState();
}

class _SegmentPanelState extends State<SegmentPanel> {
  final _start = TextEditingController();
  final _end = TextEditingController();
  SegmentCategory _category = SegmentCategory.intro;
  SegmentAction _action = SegmentAction.skip;
  bool _busy = false;
  late bool _autoApply = widget.nav.autoApply;
  (bool, String)? _result;

  @override
  void dispose() {
    _start.dispose();
    _end.dispose();
    super.dispose();
  }

  void _fill(TextEditingController c) {
    c.text = formatSegmentTime(widget.position().inMilliseconds);
    setState(() => _result = null);
  }

  Future<void> _submit() async {
    final st = parseSegmentTime(_start.text);
    final en = parseSegmentTime(_end.text);
    if (st == null || en == null) {
      setState(() => _result = (false, '请填写开始和结束时间（如 01:32）'));
      return;
    }
    final duration = widget.duration().inMilliseconds;
    setState(() {
      _busy = true;
      _result = null;
    });
    final r = await widget.nav.onSubmit(SegmentDraft(
      category: _category,
      action: _action,
      startMs: st,
      endMs: en,
      durationMs: duration,
    ));
    if (!mounted) return;
    setState(() {
      _busy = false;
      _result = (r.ok, r.message);
      if (r.ok) {
        _start.clear();
        _end.clear();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return PlayerSideDrawerFrame(
      key: const ValueKey('segment-drawer'),
      icon: Icons.content_cut_rounded,
      title: '片段',
      closeTooltip: '关闭片段',
      child: ValueListenableBuilder<SegmentsState>(
        valueListenable: widget.nav.state,
        builder: (context, state, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _hint(state),
            if (state.episode != null) ...[
              _section('提交片段'),
              _submitForm(state),
            ],
            _section('本集共享片段'),
            _sharedList(state),
            const SizedBox(height: 8),
            _autoApplyRow(),
          ],
        ),
      ),
    );
  }

  Widget _hint(SegmentsState s) {
    final palette = context.palette;
    final text = switch (s.phase) {
      SegmentsPhase.unavailable => s.message ?? '识别不出集数，无法共享片段',
      SegmentsPhase.failed => '共享片段加载失败：${s.message ?? ''}',
      SegmentsPhase.loading => '正在加载共享片段…',
      _ => s.episode == null ? '' : '《${s.episode!.title}》第 ${s.episode!.episode} 集',
    };
    if (text.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Text(text, style: TextStyle(color: palette.textSub, fontSize: AppType.body)),
    );
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
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

  Widget _submitForm(SegmentsState state) {
    final palette = context.palette;
    final done = state.submitted.contains(_category);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _timeRow('开始', _start, 'segment-start'),
          const SizedBox(height: 6),
          _timeRow('结束', _end, 'segment-end'),
          const SizedBox(height: 10),
          // 2026-10-27 验收反馈：分类与动作改为下拉，并排一行
          Row(
            children: [
              Expanded(
                child: _dropdown<SegmentCategory>(
                  key: 'segment-category',
                  label: '分类',
                  values: SegmentCategory.values,
                  labelOf: (c) => state.submitted.contains(c) ? '${c.label}（已提交）' : c.label,
                  selected: _category,
                  onSelect: (c) => setState(() {
                    _category = c;
                    _result = null;
                  }),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _dropdown<SegmentAction>(
                  key: 'segment-action',
                  label: '动作',
                  values: SegmentAction.values,
                  labelOf: (a) => a.label,
                  selected: _action,
                  onSelect: (a) => setState(() => _action = a),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            key: const ValueKey('segment-submit'),
            onPressed: _busy || done ? null : _submit,
            icon: _busy
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.cloud_upload_rounded, size: 18),
            label: Text(done ? '本集「${_category.label}」已提交过' : '共享给其他用户'),
          ),
          if (_result != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _result!.$2,
                key: const ValueKey('segment-result'),
                style: TextStyle(
                  color: _result!.$1 ? palette.accentInk : palette.danger,
                  fontSize: AppType.body,
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '每集每种分类只能提交一次；时间明显不合理的不会被记录。',
              style: TextStyle(color: palette.textDim, fontSize: AppType.caption),
            ),
          ),
        ],
      ),
    );
  }

  Widget _timeRow(String label, TextEditingController c, String key) {
    final palette = context.palette;
    return Row(
      children: [
        SizedBox(
          width: 40,
          child: Text(label, style: TextStyle(color: palette.playerText, fontSize: AppType.label)),
        ),
        Expanded(
          child: SizedBox(
            height: 36,
            child: TextField(
              key: ValueKey(key),
              controller: c,
              style: TextStyle(color: palette.playerText, fontSize: AppType.label),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9:：]'))],
              decoration: InputDecoration(
                hintText: '00:00',
                hintStyle: TextStyle(color: palette.textDim),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                filled: true,
                fillColor: palette.playerText.withValues(alpha: 0.06),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadii.sm),
                  borderSide: BorderSide(color: palette.playerText.withValues(alpha: 0.16)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadii.sm),
                  borderSide: BorderSide(color: palette.playerText.withValues(alpha: 0.16)),
                ),
              ),
              onChanged: (_) => setState(() => _result = null),
            ),
          ),
        ),
        const SizedBox(width: 6),
        TextButton(
          key: ValueKey('$key-now'),
          onPressed: () => _fill(c),
          child: const Text('取当前'),
        ),
      ],
    );
  }

  /// 带标签的紧凑下拉：标签在左，下拉框外观与时间输入框一致（同一套描边 / 底色）。
  Widget _dropdown<T>({
    required String key,
    required String label,
    required List<T> values,
    required String Function(T) labelOf,
    required T selected,
    required ValueChanged<T> onSelect,
  }) {
    final palette = context.palette;
    return Row(
      children: [
        Text(label, style: TextStyle(color: palette.playerText, fontSize: AppType.label)),
        const SizedBox(width: 6),
        Expanded(
          child: Container(
            height: 36,
            padding: const EdgeInsets.only(left: 10, right: 4),
            decoration: BoxDecoration(
              color: palette.playerText.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(AppRadii.sm),
              border: Border.all(color: palette.playerText.withValues(alpha: 0.16)),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<T>(
                key: ValueKey(key),
                value: selected,
                isExpanded: true,
                isDense: true,
                // 菜单底色跟随主题的「抬起」面，深 / 浅主题下都与抽屉协调
                dropdownColor: palette.raised,
                iconEnabledColor: palette.playerText.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(AppRadii.sm),
                style: TextStyle(color: palette.playerText, fontSize: AppType.label),
                items: [
                  for (final v in values)
                    DropdownMenuItem<T>(
                      key: ValueKey('$key-${v is SegmentCategory ? v.key : (v as SegmentAction).key}'),
                      value: v,
                      child: Text(labelOf(v), maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (v) {
                  if (v != null && v != selected) onSelect(v);
                },
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _sharedList(SegmentsState state) {
    final palette = context.palette;
    final localDuration = widget.duration().inMilliseconds;
    final list = state.segments.where((s) => s.matchesDuration(localDuration)).toList()
      ..sort((a, b) => a.startMs.compareTo(b.startMs));
    if (list.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Text(
          state.phase == SegmentsPhase.ready ? '还没有人共享这一集的片段' : '—',
          style: TextStyle(color: palette.textDim, fontSize: AppType.body),
        ),
      );
    }
    return Column(
      children: [
        for (final s in list)
          InkWell(
            key: ValueKey('segment-shared-${s.id}'),
            onTap: () => widget.onSeek(Duration(milliseconds: s.startMs)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Icon(
                    switch (s.action) {
                      SegmentAction.skip => Icons.fast_forward_rounded,
                      SegmentAction.mute => Icons.volume_off_rounded,
                      SegmentAction.highlight => Icons.star_rounded,
                    },
                    size: 18,
                    // 与时间轴色块同色，一眼对得上
                    color: SegmentColors.of(s.category, s.action),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '${s.category.label} · ${s.action.label}',
                      style: TextStyle(color: palette.playerText, fontSize: AppType.label),
                    ),
                  ),
                  Text(
                    '${formatSegmentTime(s.startMs)}–${formatSegmentTime(s.endMs)}',
                    style: TextStyle(color: palette.textSub, fontSize: AppType.body),
                  ),
                  const SizedBox(width: 8),
                  Tooltip(
                    message: '${s.votes} 人认可（提交者 + 播放时没有撤销的观众）',
                    child: Text(
                      '${s.votes}票',
                      style: TextStyle(
                        color: s.trusted ? palette.accentInk : palette.textDim,
                        fontSize: AppType.caption,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _autoApplyRow() {
    final palette = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 10, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '自动应用共享片段',
              style: TextStyle(color: palette.playerText, fontSize: AppType.body),
            ),
          ),
          Switch(
            key: const ValueKey('segment-auto-apply'),
            value: _autoApply,
            onChanged: (v) {
              setState(() => _autoApply = v);
              widget.nav.onAutoApplyChanged(v);
            },
          ),
        ],
      ),
    );
  }
}
