import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/player/mpv_player_engine.dart';
import '../../../core/segments/segment_models.dart';
import '../../theme/app_tokens.dart';
import '../widgets/focus_ring.dart';
import 'segment_panel.dart';

/// 播放到共享片段时该做什么（纯函数，便于测试）。
class SegmentHit {
  const SegmentHit(this.segment, {required this.auto});
  final SharedSegment segment;

  /// true = 自动执行（随后出 3 秒「撤销」提醒）；false = 只显示提示胶囊，让用户自己点
  final bool auto;
}

/// 当前位置落在哪条共享片段里。
///
/// - 只看与本地时长一致的剪辑版本（±15 秒）；精彩时刻只做标记不执行；
/// - 本地已设片头时，共享「片头」让位（本地优先，两功能互不干扰）；
/// - 片段最后 0.5 秒不再触发（刚跳到结束点时不会被再次命中）；
/// - 已执行 / 已处理过的片段（[handled]）不再触发：用户主动拖回来重看不会被反复跳走；
/// - 2026-10-27 拍板：**第一个人提交后就自动执行**（不再要求 2 票），错了靠「撤销」反馈纠正；
///   用户关掉「自动应用」时才退回提示胶囊。
SegmentHit? findSegmentHit({
  required List<SharedSegment> segments,
  required int positionMs,
  required int durationMs,
  required bool autoApply,
  required int localOpeningMs,
  required Set<String> handled,
}) {
  for (final s in segments) {
    if (s.action == SegmentAction.highlight) continue;
    if (!s.matchesDuration(durationMs)) continue;
    if (s.category == SegmentCategory.intro && localOpeningMs > 0) continue;
    if (handled.contains(s.id)) continue;
    if (positionMs >= s.startMs && positionMs < s.endMs - 500) {
      return SegmentHit(s, auto: autoApply);
    }
  }
  return null;
}

/// 共享片段执行器（§44）：叠在播放器右下角。
///
/// - 自动执行后出「已为你跳过片头 · 撤销」提醒，[undoWindow]（5 秒）后自动消失，指针停在上面时不消失；
/// - 点「撤销」= 回到片段开头 / 恢复音量，并上报**异议**；
/// - 提醒自然消失 = 上报**认可**（相当于投了一票）；
/// - 反馈交给 [PlayerSegmentsNav.onFeedback]，每人每集每分类一条（服务端覆盖旧结论）。
class SegmentPlaybackRunner extends StatefulWidget {
  const SegmentPlaybackRunner({
    super.key,
    required this.nav,
    required this.engine,
    required this.onNotice,
  });

  final PlayerSegmentsNav nav;
  final MpvPlayerEngine engine;

  /// OSD 提示（图标 + 文案）
  final void Function(IconData icon, String text) onNotice;

  /// 撤销提醒停留时长（2026-10-27 用户：由 3 秒改为 5 秒；指针停在提醒上时暂停计时）。
  static const Duration undoWindow = Duration(seconds: 5);

  @override
  State<SegmentPlaybackRunner> createState() => _SegmentPlaybackRunnerState();
}

class _SegmentPlaybackRunnerState extends State<SegmentPlaybackRunner> {
  StreamSubscription<Duration>? _sub;
  final Set<String> _handled = {};
  String? _episodeKey;

  /// 未自动执行（关闭了自动应用）时的手动提示胶囊
  SharedSegment? _prompt;

  /// 刚自动执行、等待「撤销」的片段，及执行时那一集的键（反馈必须带它）
  SharedSegment? _undoable;
  String? _undoableKey;
  Timer? _undoTimer;

  /// 正在静音的片段及静音前音量（离开片段时恢复）
  SharedSegment? _muting;
  double _volumeBeforeMute = 100;

  @override
  void initState() {
    super.initState();
    _sub = widget.engine.positionStream.listen(_onPosition);
  }

  @override
  void dispose() {
    _sub?.cancel();
    // 退出时提醒还在：按「没撤销」结算（用户没有表示异议）
    _settleUndo(disputed: false);
    _restoreMute();
    super.dispose();
  }

  void _onPosition(Duration position) {
    if (!mounted) return;
    final state = widget.nav.state.value;
    final key = state.episode?.key;
    if (key != _episodeKey) {
      _episodeKey = key;
      _handled.clear();
      _settleUndo(disputed: false);
      _restoreMute();
    }
    final pos = position.inMilliseconds;
    final muting = _muting;
    if (muting != null && (pos < muting.startMs || pos >= muting.endMs)) _restoreMute();

    final hit = findSegmentHit(
      segments: state.phase == SegmentsPhase.ready ? state.segments : const [],
      positionMs: pos,
      durationMs: widget.engine.duration.inMilliseconds,
      autoApply: widget.nav.autoApply,
      localOpeningMs: widget.nav.localOpeningMs,
      handled: _handled,
    );
    if (hit != null && hit.auto) {
      _apply(hit.segment, auto: true);
      return;
    }
    final prompt = hit?.segment;
    if (prompt?.id != _prompt?.id) setState(() => _prompt = prompt);
  }

  void _apply(SharedSegment s, {required bool auto}) {
    _handled.add(s.id);
    switch (s.action) {
      case SegmentAction.skip:
        unawaited(widget.engine.seek(Duration(milliseconds: s.endMs)));
        if (!auto) widget.onNotice(Icons.fast_forward_rounded, '已跳过${s.category.label}');
      case SegmentAction.mute:
        _volumeBeforeMute = widget.engine.volume;
        _muting = s;
        unawaited(widget.engine.setVolume(0));
        if (!auto) widget.onNotice(Icons.volume_off_rounded, '${s.category.label}已静音');
      case SegmentAction.highlight:
        break;
    }
    _prompt = null;
    if (auto) {
      // 上一条提醒还没结束：先按认可结算，再换成新的
      _settleUndo(disputed: false);
      _undoable = s;
      _undoableKey = widget.nav.state.value.episode?.key;
      _undoTimer = Timer(SegmentPlaybackRunner.undoWindow, () => _settleUndo(disputed: false));
    }
    setState(() {});
  }

  /// 「撤销」：回到片段开头 / 恢复音量，记异议。
  void _undo() {
    final s = _undoable;
    if (s == null) return;
    switch (s.action) {
      case SegmentAction.skip:
        unawaited(widget.engine.seek(Duration(milliseconds: s.startMs)));
      case SegmentAction.mute:
        _restoreMute();
      case SegmentAction.highlight:
        break;
    }
    widget.onNotice(Icons.undo_rounded, '已撤销，感谢反馈');
    _settleUndo(disputed: true);
  }

  /// 结束当前提醒并上报结论（每个片段只上报一次）。
  void _settleUndo({required bool disputed}) {
    _undoTimer?.cancel();
    _undoTimer = null;
    final s = _undoable;
    if (s == null) return;
    _undoable = null;
    final key = _undoableKey;
    _undoableKey = null;
    final report = widget.nav.onFeedback;
    if (report != null) unawaited(report(s, disputed: disputed, episodeKey: key));
    if (mounted) setState(() {});
  }

  void _restoreMute() {
    if (_muting == null) return;
    _muting = null;
    // 用户在静音期间自己调过音量就不动它
    if (widget.engine.volume <= 0) unawaited(widget.engine.setVolume(_volumeBeforeMute));
  }

  // 与「跳过片头」胶囊同一套固定浅底深字：压在任意画面上都醒目，与主题无关
  static const Color _ink = Color(0xFF101014);
  static const TextStyle _strong = TextStyle(color: _ink, fontSize: AppType.body, fontWeight: FontWeight.w600);
  static const TextStyle _weak = TextStyle(color: Color(0xFF55555F), fontSize: AppType.caption);

  IconData _iconOf(SharedSegment s) =>
      s.action == SegmentAction.mute ? Icons.volume_off_rounded : Icons.fast_forward_rounded;

  @override
  Widget build(BuildContext context) {
    final undoable = _undoable;
    if (undoable != null) {
      final done = undoable.action == SegmentAction.mute ? '已为你静音' : '已为你跳过';
      // 整条可点：点击即撤销（目标大，3 秒内好点中）
      return _pill(
        key: const ValueKey('segment-undo'),
        onTap: _undo,
        children: [
          Icon(_iconOf(undoable), size: 16, color: _ink),
          const SizedBox(width: 6),
          Text('$done${undoable.category.label}', style: _strong),
          const SizedBox(width: 10),
          Container(width: 1, height: 14, color: const Color(0x33101014)),
          const SizedBox(width: 10),
          const Text('撤销',
              style: TextStyle(color: Color(0xFF2563EB), fontSize: AppType.body, fontWeight: FontWeight.w700)),
          const SizedBox(width: 4),
          const Text('（有误请点）', style: _weak),
        ],
      );
    }
    final s = _prompt;
    if (s == null) return const SizedBox.shrink();
    final verb = s.action == SegmentAction.mute ? '静音' : '跳过';
    return _pill(
      key: const ValueKey('segment-prompt'),
      onTap: () => _apply(s, auto: false),
      children: [
        Text('$verb${s.category.label}', style: _strong),
        const SizedBox(width: 6),
        Text('${formatSegmentTime(s.startMs)}–${formatSegmentTime(s.endMs)}', style: _weak),
        const SizedBox(width: 4),
        Icon(_iconOf(s), size: 16, color: _ink),
      ],
    );
  }

  /// 指针进入撤销提醒：暂停倒计时；离开后重新给满一个窗口。
  void _holdUndo(bool hovering) {
    if (_undoable == null) return;
    _undoTimer?.cancel();
    _undoTimer = hovering ? null : Timer(SegmentPlaybackRunner.undoWindow, () => _settleUndo(disputed: false));
  }

  Widget _pill({required Key key, required VoidCallback onTap, required List<Widget> children}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: MouseRegion(
        onEnter: (_) => _holdUndo(true),
        onExit: (_) => _holdUndo(false),
        child: FocusOutline(
        radius: AppRadii.pill,
        color: _ink,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            key: key,
            borderRadius: BorderRadius.circular(AppRadii.pill),
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.sm),
              decoration: BoxDecoration(
                color: const Color(0xE6FFFFFF),
                borderRadius: BorderRadius.circular(AppRadii.pill),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: children),
            ),
          ),
        ),
      ),
      ),
    );
  }
}
