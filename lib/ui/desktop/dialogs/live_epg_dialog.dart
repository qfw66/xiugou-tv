import 'dart:async';
import 'package:flutter/material.dart';
import '../../../core/config/models/vod_config.dart';
import '../../../core/live/epg_program.dart';
import '../../../core/live/epg_repository.dart';
import '../../../core/live/live_text_loader.dart';

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

  Widget _summary(String label, EpgProgram program, Color color) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: 0.35)),
        ),
        child: Text('$label · ${_time(program.start)}  ${program.title}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: color, fontSize: 13)),
      );

  @override
  Widget build(BuildContext context) {
    final now = _now;
    final current = _schedule?.currentAt(now);
    final next = _schedule?.nextAt(now);
    final programs = _schedule?.programs ?? const <EpgProgram>[];
    return Dialog(
      backgroundColor: const Color(0xFF181820),
      insetPadding: const EdgeInsets.all(24),
      child: SizedBox(
        width: 680,
        height: 630,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                  child: Text('${widget.channel.name} · 节目单',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold))),
              IconButton(
                  tooltip: '关闭节目单',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close, color: Colors.white70)),
            ]),
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
              const Expanded(
                  child: Text('北京时间 UTC+8',
                      textAlign: TextAlign.end,
                      style:
                          TextStyle(color: Color(0xFF888898), fontSize: 12))),
              IconButton(
                tooltip: '刷新节目单',
                onPressed: _busy ? null : () => _load(forceRefresh: true),
                icon: const Icon(Icons.refresh, color: Colors.white70),
              ),
            ]),
            const SizedBox(height: 12),
            if (!_busy && current != null)
              _summary('正在播出', current, const Color(0xFFFF626B)),
            if (!_busy && next != null)
              _summary('接下来', next, const Color(0xFFB1B9D4)),
            Expanded(
              child: _busy
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                      ? Center(
                          child:
                              Column(mainAxisSize: MainAxisSize.min, children: [
                          Text(_error!,
                              textAlign: TextAlign.center,
                              style:
                                  const TextStyle(color: Colors.orangeAccent)),
                          const SizedBox(height: 8),
                          const Text('节目单不可用不影响频道播放',
                              style: TextStyle(
                                  color: Colors.white60, fontSize: 12)),
                          TextButton(
                              onPressed: () => _load(forceRefresh: true),
                              child: const Text('重试')),
                        ]))
                      : programs.isEmpty
                          ? const Center(
                              child: Text('暂无节目单，频道仍可正常播放',
                                  style: TextStyle(color: Colors.white60)))
                          : ListView.separated(
                              itemCount: programs.length,
                              separatorBuilder: (_, __) => const Divider(
                                  height: 1, color: Color(0xFF30303C)),
                              itemBuilder: (_, index) {
                                final program = programs[index];
                                final playing = program.isCurrent(now);
                                final future = program.start.isAfter(now);
                                return ListTile(
                                  contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 4),
                                  title: Text(program.title,
                                      style: TextStyle(
                                        color: playing
                                            ? const Color(0xFFFF626B)
                                            : Colors.white,
                                        fontSize: 14,
                                      )),
                                  subtitle: Text(
                                    '${_time(program.start)} – ${_time(program.end)}'
                                    '${program.description == null ? '' : '\n${program.description}'}',
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        color: Colors.white54, fontSize: 12),
                                  ),
                                  trailing: Text(
                                      playing
                                          ? '正在播出'
                                          : future
                                              ? '预告'
                                              : '已结束',
                                      style: TextStyle(
                                          color: playing
                                              ? const Color(0xFFFF626B)
                                              : Colors.white38,
                                          fontSize: 12)),
                                );
                              },
                            ),
            ),
            if (widget.onPlay != null) ...[
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('播放频道'),
                  onPressed: () {
                    Navigator.of(context).pop();
                    widget.onPlay!();
                  },
                ),
              ),
            ],
          ]),
        ),
      ),
    );
  }
}
