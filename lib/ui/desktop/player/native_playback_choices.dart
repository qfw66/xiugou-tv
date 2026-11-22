import 'package:flutter/material.dart';

import '../../../core/player/embedded_playback.dart';
import '../../../core/player/models/player_state.dart';
import '../../../core/player/mpv_player_engine.dart';
import '../../theme/app_palette.dart';

class NativePlaybackChoices extends StatefulWidget {
  const NativePlaybackChoices({
    super.key,
    required this.engine,
    this.onSwitched,
    this.channel = const EmbeddedPlaybackChannel(),
  });
  final MpvPlayerEngine engine;
  final EmbeddedPlaybackChannel channel;
  final VoidCallback? onSwitched;

  @override
  State<NativePlaybackChoices> createState() => _NativePlaybackChoicesState();
}

class _NativePlaybackChoicesState extends State<NativePlaybackChoices> {
  late final _available = widget.channel.available();
  bool _busy = false;
  String? _message;

  String? _reason() {
    final e = widget.engine;
    final spec = e.currentSpec;
    if (spec == null) return '尚无播放中的节目';
    final reason = EmbeddedPlaybackChannel.input(
      spec,
      browserHeaders: e.playbackSettings.browserHeaders,
    ).reason;
    if (reason != null) return reason;
    if (e.rate != 1.0) return '此倍速需要 mpv';
    if (e.status != PlaybackStatus.playing &&
        e.status != PlaybackStatus.paused) {
      return '等待节目起播';
    }
    return null;
  }

  Future<void> _select(NativePlaybackBackend? backend) async {
    if (_busy || (backend != null && _reason() != null)) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final switched = await widget.engine.selectPlaybackBackend(
        backend,
        channel: widget.channel,
      );
      if (!mounted) return;
      if (switched) {
        widget.onSwitched?.call();
      } else {
        _message = '未能切换播放内核';
      }
    } catch (_) {
      _message = '未能切换播放内核';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<EmbeddedPlaybackSession?>(
        valueListenable: widget.engine.embeddedSession,
        builder: (context, session, _) => Material(
          type: MaterialType.transparency,
          child: ExpansionTile(
            textColor: context.palette.playerText,
            collapsedTextColor: context.palette.playerText,
            iconColor: context.palette.playerText,
            collapsedIconColor: context.palette.playerText,
            leading: const Icon(Icons.video_settings_outlined),
            title: const Text('播放内核'),
            subtitle: Text(_busy ? '切换中…' : (session?.backend.label ?? 'mpv')),
            children: [
              FutureBuilder<Set<NativePlaybackBackend>>(
                future: _available,
                builder: (context, available) => StreamBuilder<PlaybackStatus>(
                  stream: widget.engine.statusStream,
                  builder: (context, _) {
                    final reason = _reason();
                    return Column(
                      children: [
                        for (final backend in <NativePlaybackBackend?>[
                          null,
                          ...NativePlaybackBackend.values,
                        ])
                          Builder(
                            builder: (context) {
                              final current = session?.backend == backend;
                              final why = backend == null
                                  ? null
                                  : !available.hasData
                                  ? '正在检查…'
                                  : available.data!.contains(backend)
                                  ? reason
                                  : backend == NativePlaybackBackend.mdk
                                  ? 'MDK 运行库不可用'
                                  : 'Windows 媒体组件不可用';
                              return ListTile(
                                key: ValueKey(
                                  'native-playback-${backend?.name ?? 'mpv'}',
                                ),
                                leading: Icon(
                                  current
                                      ? Icons.radio_button_checked
                                      : Icons.radio_button_unchecked,
                                ),
                                title: Text(backend?.label ?? 'mpv'),
                                textColor: context.palette.playerText,
                                iconColor: context.palette.playerText,
                                selectedColor: context.palette.accentInk,
                                subtitle: why == null || current
                                    ? null
                                    : Text(why),
                                selected: current,
                                enabled: !_busy && (current || why == null),
                                onTap: current || _busy || why != null
                                    ? null
                                    : () => _select(backend),
                              );
                            },
                          ),
                        if (_message != null)
                          Padding(
                            padding: const EdgeInsets.all(8),
                            child: Semantics(
                              liveRegion: true,
                              child: Text(_message!),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      );
}
