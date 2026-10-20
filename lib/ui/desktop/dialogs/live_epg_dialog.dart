import 'dart:async';
import 'package:flutter/material.dart';
import '../../../core/config/models/vod_config.dart';
import '../../../core/live/epg_program.dart';
import '../../../core/live/epg_repository.dart';
import '../../../core/live/live_text_loader.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';
import '../widgets/focus_ring.dart';
import '../widgets/live_indicator.dart';

/// 节目单独立加载，失败或无数据时仍可直接播放频道。
class LiveEpgDialog extends StatefulWidget {
  final Live channel;
  final EpgRepository repository;
  final VoidCallback? onPlay;
  final DateTime Function()? clock;

  const LiveEpgDialog({
    super.key,
    required this.channel,
    required this.repository,
    this.onPlay,
    this.clock,
  });

  @override
  State<LiveEpgDialog> createState() => _LiveEpgDialogState();
}

class _LiveEpgDialogState extends State<LiveEpgDialog> {
  EpgSchedule? _schedule;
  String? _error;
  bool _busy = false;
  int _day = 0;
  int _generation = 0;
  Timer? _timer;
  late String _calendarDay;

  DateTime get _now => (widget.clock ?? DateTime.now)();
  String _dateKey(DateTime value) => value
      .toUtc()
      .add(const Duration(hours: 8))
      .toIso8601String()
      .substring(0, 10);

  @override
  void initState() {
    super.initState();
    _calendarDay = _dateKey(_now);
    _load();
    _timer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (!mounted) return;
      final day = _dateKey(_now);
      if (day != _calendarDay) {
        _calendarDay = day;
        _load();
      } else {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool forceRefresh = false}) async {
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final schedule = await widget.repository.load(
        widget.channel,
        date: _now.add(Duration(days: _day)),
        forceRefresh: forceRefresh,
      );
      if (mounted && generation == _generation) {
        setState(() => _schedule = schedule);
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _error = liveErrorMessage(error);
          _schedule = null;
        });
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  String _time(DateTime value) {
    final local = value.toUtc().add(const Duration(hours: 8));
    return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }

  /// 「正在播出 / 接下来」摘要块。
  ///
  /// `live` 为真时使用与频道卡 LIVE 相同的 `LiveIndicator` 热标（B6 统一）。
  Widget _summary(String label, EpgProgram program, Color color,
          {bool live = false}) =>
      Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(AppRadii.md),
          border: Border.all(color: color.withValues(alpha: 0.35)),
        ),
        child: Row(children: [
          if (live)
            // 与频道卡 LIVE 共用同一组件/规格（B6 判别用例）。
            LiveIndicator(label: label, fontSize: AppType.label)
          else
            Text(label,
                style: TextStyle(color: color, fontSize: AppType.label)),
          const SizedBox(width: 8),
          Expanded(
              child: Text('${_time(program.start)}  ${program.title}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: color, fontSize: AppType.label))),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final now = _now;
    final current = _schedule?.currentAt(now);
    final next = _schedule?.nextAt(now);
    final programs = _schedule?.programs ?? const <EpgProgram>[];
    return Dialog(
      backgroundColor: palette.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.lg),
        side: BorderSide(color: palette.borderStrong),
      ),
      insetPadding: const EdgeInsets.all(24),
      child: SizedBox(
        width: 680,
        height: 630,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: palette.accentWash,
                  borderRadius: BorderRadius.circular(AppRadii.md),
                ),
                child: Icon(Icons.event_note_rounded, color: palette.accentInk),
              ),
              const SizedBox(width: 12),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(widget.channel.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: palette.textTitle,
                            fontSize: AppType.h2,
                            fontWeight: FontWeight.bold)),
                    Text('节目单 · 北京时间 UTC+8',
                        style: TextStyle(
                            color: palette.textSub, fontSize: AppType.body)),
                  ])),
              FocusOutline(
                radius: AppRadii.pill,
                child: IconButton(
                    tooltip: '关闭节目单',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(Icons.close, color: palette.textSub)),
              ),
            ]),
            const SizedBox(height: 6),
            Row(children: [
              for (var day = 0; day < 2; day++) ...[
                ChoiceChip(
                  label: Text(day == 0 ? '今天' : '明天'),
                  selected: _day == day,
                  onSelected: (_) {
                    if (_day == day) return;
                    _day = day;
                    _load();
                  },
                ),
                const SizedBox(width: 8),
              ],
              const Spacer(),
              FocusOutline(
                radius: AppRadii.pill,
                child: IconButton(
                  tooltip: '刷新节目单',
                  onPressed: _busy ? null : () => _load(forceRefresh: true),
                  icon: Icon(Icons.refresh, color: palette.textSub),
                ),
              ),
            ]),
            const SizedBox(height: 12),
            if (!_busy && current != null)
              // 「正在播出」复用 danger 红（直播的「热」信号），
              // 热标与频道卡 LIVE 共用同一组件（B6）。
              _summary('正在播出', current, palette.danger, live: true),
            if (!_busy && next != null) _summary('接下来', next, palette.textBody),
            Expanded(
              child: _busy
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                      ? Center(
                          child:
                              Column(mainAxisSize: MainAxisSize.min, children: [
                          Text(_error!,
                              textAlign: TextAlign.center,
                              style: TextStyle(color: palette.danger)),
                          const SizedBox(height: 8),
                          Text('节目单不可用不影响频道播放',
                              style: TextStyle(
                                  color: palette.textSub,
                                  fontSize: AppType.body)),
                          TextButton(
                              onPressed: () => _load(forceRefresh: true),
                              child: const Text('重试')),
                        ]))
                      : programs.isEmpty
                          ? Center(
                              child: Text('暂无节目单，频道仍可正常播放',
                                  style: TextStyle(color: palette.textSub)))
                          : ListView.separated(
                              itemCount: programs.length,
                              separatorBuilder: (_, __) =>
                                  Divider(height: 1, color: palette.divider),
                              itemBuilder: (_, index) {
                                final program = programs[index];
                                final playing = program.isCurrent(now);
                                final future = program.start.isAfter(now);
                                return Container(
                                  // 「正在播出」行强调：danger 左条 + 6% 底。
                                  // 同时保留文字标签「正在播出」，颜色仅作辅助
                                  // （skill `state-clarity` / `color-not-only`）。
                                  decoration: BoxDecoration(
                                    color: playing
                                        ? palette.danger.withValues(alpha: 0.06)
                                        : null,
                                    border: Border(
                                      left: BorderSide(
                                        color: playing
                                            ? palette.danger
                                            : Colors.transparent,
                                        width: 3,
                                      ),
                                    ),
                                  ),
                                  child: ListTile(
                                    contentPadding: const EdgeInsets.symmetric(
                                        horizontal: 10, vertical: 4),
                                    title: Text(program.title,
                                        style: TextStyle(
                                          color: playing
                                              ? palette.danger
                                              : palette.textMain,
                                          fontSize: AppType.title,
                                        )),
                                    subtitle: Text(
                                      '${_time(program.start)} – ${_time(program.end)}'
                                      '${program.description == null ? '' : '\n${program.description}'}',
                                      maxLines: 3,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                          color: palette.textSub,
                                          fontSize: AppType.body),
                                    ),
                                    trailing: Text(
                                        playing
                                            ? '正在播出'
                                            : future
                                                ? '预告'
                                                : '已结束',
                                        style: TextStyle(
                                            color: playing
                                                ? palette.danger
                                                : palette.textSub,
                                            fontSize: AppType.body)),
                                  ),
                                );
                              },
                            ),
            ),
            if (widget.onPlay != null) ...[
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: FocusOutline(
                  radius: AppRadii.pill,
                  child: FilledButton.icon(
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('播放频道'),
                    onPressed: () {
                      Navigator.of(context).pop();
                      widget.onPlay!();
                    },
                  ),
                ),
              ),
            ],
          ]),
        ),
      ),
    );
  }
}
