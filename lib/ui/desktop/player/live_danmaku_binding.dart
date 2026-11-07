import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../../core/danmaku/danmaku_settings.dart';
import '../../../core/danmaku/live_danmaku_client.dart';
import '../../../core/danmaku/live_danmaku_models.dart';
import 'desktop_video_player.dart';

/// Binds a caller-owned client to one playback context and its player controls.
class LiveDanmakuBinding extends StatefulWidget {
  const LiveDanmakuBinding({
    super.key,
    required this.client,
    required this.sourceUrl,
    required this.contextKey,
    required this.enabled,
    required this.settings,
    required this.preparing,
    required this.onToggle,
    required this.onSettingsChanged,
    required this.builder,
  });

  final LiveDanmakuClient client;
  final String? sourceUrl;
  final Object contextKey;
  final bool enabled;
  final DanmakuSettings settings;
  final bool preparing;
  final VoidCallback onToggle;
  final ValueChanged<DanmakuSettings> onSettingsChanged;
  final Widget Function(BuildContext, PlayerLiveDanmakuNav?) builder;

  @override
  State<LiveDanmakuBinding> createState() => _LiveDanmakuBindingState();
}

class _LiveDanmakuBindingState extends State<LiveDanmakuBinding> {
  late final ValueNotifier<bool> _enabled;
  late final ValueNotifier<DanmakuSettings> _settings;
  StreamController<List<LiveDanmakuMessage>> _messages =
      StreamController<List<LiveDanmakuMessage>>.broadcast(sync: true);
  // invariant: one published stream identity per playback generation.
  late Stream<List<LiveDanmakuMessage>> _messageStream = _messages.stream;
  StreamSubscription<List<LiveDanmakuMessage>>? _subscription;
  final Set<LiveDanmakuClient> _clientsToStop = {};
  LiveDanmakuClient? _appliedClient;
  String? _appliedSource;
  String? _source;
  String? _blockedSource;
  int _generation = 0;
  bool _syncScheduled = false;

  static String? _normalizeSource(String? source) {
    final value = source?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  String? get _desiredSource =>
      widget.enabled && !widget.preparing && _source != _blockedSource
          ? _source
          : null;

  @override
  void initState() {
    super.initState();
    _enabled = ValueNotifier(widget.enabled);
    _settings = ValueNotifier(widget.settings);
    _source = _normalizeSource(widget.sourceUrl);
    _scheduleSync();
  }

  @override
  void didUpdateWidget(LiveDanmakuBinding oldWidget) {
    super.didUpdateWidget(oldWidget);
    final source = _normalizeSource(widget.sourceUrl);
    final sourceChanged = source != _source;
    final contextChanged = oldWidget.contextKey != widget.contextKey;
    final clientChanged = !identical(oldWidget.client, widget.client);

    // A context may change before its source arrives. Never reopen that stale
    // source through a toggle, preparation change, or a temporary null source.
    if (contextChanged && source != null && source == _source) {
      _blockedSource = source;
    } else if (source != null && source != _blockedSource) {
      _blockedSource = null;
    }
    _source = source;
    if (clientChanged) _clientsToStop.add(oldWidget.client);

    if (sourceChanged ||
        contextChanged ||
        clientChanged ||
        oldWidget.enabled != widget.enabled ||
        oldWidget.preparing != widget.preparing) {
      _replaceMessages();
    }
    _scheduleSync();
  }

  void _cancelMessages() {
    _generation++;
    final subscription = _subscription;
    _subscription = null;
    if (subscription != null) unawaited(subscription.cancel());
  }

  void _replaceMessages() {
    _cancelMessages();
    final previous = _messages;
    _messages =
        StreamController<List<LiveDanmakuMessage>>.broadcast(sync: true);
    _messageStream = _messages.stream;
    // A synchronous stream's onDone may rebuild an ancestor too.
    scheduleMicrotask(() => unawaited(previous.close()));
  }

  void _listen(LiveDanmakuClient client) {
    if (_subscription != null) return;
    final generation = _generation;
    final messages = _messages;
    _subscription = client.messages.listen((batch) {
      if (!mounted || generation != _generation || _desiredSource == null) {
        return;
      }
      messages.add(batch);
    });
  }

  void _scheduleSync() {
    if (_syncScheduled) return;
    _syncScheduled = true;
    // These listeners can belong to ancestors of the binding. Publish only
    // after synchronous build/update/dispose has returned.
    scheduleMicrotask(_synchronize);
  }

  void _synchronize() {
    _syncScheduled = false;
    final stopped = Set<LiveDanmakuClient>.of(_clientsToStop);
    _clientsToStop.clear();
    for (final client in stopped) {
      if (identical(client, _appliedClient)) {
        _appliedClient = null;
        _appliedSource = null;
      }
      unawaited(client.stop());
    }
    if (!mounted) return;

    _enabled.value = widget.enabled;
    _settings.value = widget.settings;
    final client = widget.client;
    final source = _desiredSource;
    if (identical(client, _appliedClient) && source == _appliedSource) {
      if (source != null) _listen(client);
      return;
    }

    _appliedClient = client;
    _appliedSource = source;
    if (source == null) {
      if (!stopped.contains(client)) unawaited(client.stop());
    } else {
      _listen(client);
      // The client versions starts/stops and closes superseded remote handles.
      unawaited(client.start(source));
    }
  }

  @override
  void dispose() {
    _cancelMessages();
    final messages = _messages;
    scheduleMicrotask(() => unawaited(messages.close()));
    _clientsToStop.add(widget.client);
    final appliedClient = _appliedClient;
    if (appliedClient != null) _clientsToStop.add(appliedClient);
    _scheduleSync();
    _enabled.dispose();
    _settings.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final client = widget.client;
    return widget.builder(
      context,
      _source == null
          ? null
          : PlayerLiveDanmakuNav(
              messages: _messageStream,
              enabled: _enabled,
              settings: _settings,
              onToggle: widget.onToggle,
              onSettingsChanged: widget.onSettingsChanged,
              state: client,
              status: () => client.status,
              error: () => client.error,
            ),
    );
  }
}
