import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import '../../../core/config/models/vod_config.dart';
import '../../../core/live/live_direct_mode_memory.dart';
import '../../../core/live/live_playlist_parser.dart';
import '../../../core/live/live_repository.dart';
import '../../../core/live/live_source.dart';
import '../../../core/live/live_text_loader.dart';
import '../../../core/player/hls_playlist_probe.dart';
import '../../../core/player/models/player_state.dart';
import '../../../core/player/playback_http_headers.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';
import '../widgets/focus_ring.dart';

/// 导入只影响直播仓库，取消文件选择不会提交任何变更。
class LiveImportDialog extends StatefulWidget {
  final LiveRepository repository;
  final Future<String?> Function()? pickPlaylistFile;

  const LiveImportDialog({
    super.key,
    required this.repository,
    this.pickPlaylistFile,
  });

  @override
  State<LiveImportDialog> createState() => _LiveImportDialogState();
}

class _LiveImportDialogState extends State<LiveImportDialog> {
  final _input = TextEditingController();
  final _name = TextEditingController();
  final _epg = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _input.dispose();
    _name.dispose();
    _epg.dispose();
    super.dispose();
  }

  String? _epgUrl() {
    final value = _epg.text.trim();
    if (value.isEmpty) return null;
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !const {'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty) {
      throw const FormatException('EPG 地址必须是 HTTP / HTTPS 地址');
    }
    return value;
  }

  Future<void> _run(Future<LiveSource?> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final source = await action();
      if (mounted && source != null) Navigator.of(context).pop(source);
    } catch (error) {
      if (mounted) setState(() => _error = liveErrorMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _importFile() => _run(() async {
        final path = await (widget.pickPlaylistFile ?? _pickFile)();
        if (!mounted || path == null || path.isEmpty) return null;
        return widget.repository
            .importFile(path, name: _name.text, epg: _epgUrl());
      });

  Future<String?> _pickFile() async {
    final file = await openFile(acceptedTypeGroups: [
      const XTypeGroup(label: '直播清单', extensions: ['m3u', 'm3u8', 'txt']),
    ]);
    return file?.path;
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        backgroundColor: palette.panel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.lg),
          side: BorderSide(color: palette.borderStrong),
        ),
        title: Row(children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: palette.accentWash,
              borderRadius: BorderRadius.circular(AppRadii.md),
            ),
            child: Icon(Icons.playlist_add, color: palette.accentInk, size: 20),
          ),
          const SizedBox(width: 10),
          Text('导入直播源', style: TextStyle(color: palette.textTitle)),
        ]),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('支持 M3U / TXT 地址、粘贴清单或本地文件。不会覆盖影视配置。',
                    style: TextStyle(
                        color: palette.textBody, fontSize: AppType.label)),
                const SizedBox(height: 16),
                TextField(
                  controller: _name,
                  enabled: !_busy,
                  style: TextStyle(color: palette.textMain),
                  decoration: _inputDecoration('直播源名称（可选）', palette),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _input,
                  enabled: !_busy,
                  minLines: 3,
                  maxLines: 6,
                  style: TextStyle(
                      color: palette.textMain, fontSize: AppType.label),
                  decoration: _inputDecoration('M3U / TXT 地址或内容', palette,
                      hint: 'https://example.com/live.m3u'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _epg,
                  enabled: !_busy,
                  style: TextStyle(
                      color: palette.textMain, fontSize: AppType.label),
                  decoration: _inputDecoration('EPG 地址（可选）', palette,
                      hint: 'XMLTV / XMLTV.gz，或包含 {name}、{date} 的 JSON 接口'),
                ),
                const SizedBox(height: 8),
                Text('留空时使用清单声明的节目单。远程源与本地文件可在直播页刷新。',
                    style: TextStyle(
                        color: palette.textSub, fontSize: AppType.body)),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, style: TextStyle(color: palette.danger)),
                ],
                if (_busy) ...[
                  const SizedBox(height: 16),
                  const LinearProgressIndicator(),
                ],
              ],
            ),
          ),
        ),
        actions: [
          FocusOutline(
            radius: AppRadii.pill,
            child: TextButton(
                onPressed: _busy ? null : () => Navigator.of(context).pop(),
                child: const Text('取消')),
          ),
          FocusOutline(
            radius: AppRadii.pill,
            child: OutlinedButton.icon(
              onPressed: _busy ? null : _importFile,
              icon: const Icon(Icons.folder_open, size: 18),
              label: const Text('选择本地文件'),
            ),
          ),
          FocusOutline(
            radius: AppRadii.pill,
            child: FilledButton(
              onPressed: _busy
                  ? null
                  : () => _run(() => widget.repository.importInput(_input.text,
                      name: _name.text, epg: _epgUrl())),
              child: const Text('导入清单'),
            ),
          ),
        ],
      ),
    );
  }
}

/// 直链弹窗的播放方式三态（P1/D1）：自动识别 / 按点播 / 按直播。
enum DirectPlaybackChoice { auto, vod, live }

/// 「播放直链」：地址 + 频道名 + 播放方式三态。
///
/// - **自动**（默认）：先查主机记忆；没有记忆且设置开启时只读清单探测（≤1.2 s），
///   识别失败静默回退直播；
/// - **按点播 / 按直播**：用户显式选择，比记忆与探测都优先（`.mp4` 等容器除外），
///   并把选择写入主机记忆（下次直链直接命中，不再探测）。
class LiveDirectDialog extends StatefulWidget {
  const LiveDirectDialog({
    super.key,
    this.playbackMode,
    this.repository,
    this.autoDetect = true,
    this.browserHeaderFallbacks = true,
    this.probe,
  });

  /// 预置的播放方式（null = 自动识别）；用于从既有直链重新打开。
  final PlaybackMode? playbackMode;

  /// 主机记忆读写；null 时不记忆（测试 / 无仓库场景）。
  final LiveRepository? repository;

  /// 设置项「直链自动识别播放方式」（关闭后不探测）。
  final bool autoDetect;

  /// 设置项「播放时补浏览器请求头」：探测与起播用同一份头。
  final bool browserHeaderFallbacks;

  /// 注入探针（测试用 fake）；null 用共享实例（进程内缓存）。
  final HlsPlaylistProbe? probe;

  @override
  State<LiveDirectDialog> createState() => _LiveDirectDialogState();
}

class _LiveDirectDialogState extends State<LiveDirectDialog> {
  final _name = TextEditingController();
  final _url = TextEditingController();
  String? _error;
  late DirectPlaybackChoice _choice;
  /// 用户是否主动点了「自动识别」（= 忘掉该主机记忆，下次重新识别）。
  bool _autoPickedByUser = false;
  bool _busy = false;
  bool _identifying = false;

  HlsPlaylistProbe get _probe => widget.probe ?? sharedHlsPlaylistProbe;

  @override
  void initState() {
    super.initState();
    _choice = switch (widget.playbackMode) {
      PlaybackMode.vod => DirectPlaybackChoice.vod,
      PlaybackMode.live => DirectPlaybackChoice.live,
      null => DirectPlaybackChoice.auto,
    };
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    super.dispose();
  }

  void _pick(DirectPlaybackChoice choice) {
    setState(() {
      _choice = choice;
      _autoPickedByUser = choice == DirectPlaybackChoice.auto;
      _error = null;
    });
  }

  /// 探测请求头：与 mpv 起播用同一份浏览器头回退（探测与播放的出口一致）。
  Map<String, String>? _probeHeaders(String url) =>
      withBrowserHeaderFallbacks(null, url,
          enabled: widget.browserHeaderFallbacks);

  Future<void> _play() async {
    if (_busy) return;
    final url = _url.text.trim();
    if (!LivePlaylistParser.isStreamUrl(url)) {
      setState(() => _error = '请输入有效的 HTTP、RTMP、RTSP 或 UDP 直播地址');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final repo = widget.repository;
      final host = LiveDirectModeMemory.hostOfUrl(url);
      final manual = switch (_choice) {
        DirectPlaybackChoice.vod => PlaybackMode.vod,
        DirectPlaybackChoice.live => PlaybackMode.live,
        DirectPlaybackChoice.auto => null,
      };
      final containerHint = containerHintForUrl(url);

      PlaybackMode? remembered;
      if (repo != null && host.isNotEmpty) {
        try {
          remembered = await repo.loadDirectPlaybackMode(host);
        } catch (_) {
          remembered = null; // 记忆读失败按无记忆处理，不影响起播
        }
        if (!mounted) return;
      }
      // 主动选「自动」= 删除该主机条目，让下次重新识别。
      if (_choice == DirectPlaybackChoice.auto &&
          _autoPickedByUser &&
          repo != null &&
          host.isNotEmpty) {
        unawaited(repo
            .rememberDirectPlaybackMode(host, null)
            .catchError((Object _) {}));
        remembered = null;
      }

      HlsProbeResult? probe;
      if (shouldProbeDirectPlayback(
        url: url,
        manual: manual,
        containerHint: containerHint,
        remembered: remembered,
        autoDetect: widget.autoDetect,
      )) {
        setState(() => _identifying = true);
        // 探测永不抛异常：失败静默回退直播（原因只进诊断）。
        probe = await _probe.probe(url, headers: _probeHeaders(url));
        if (!mounted) return;
        setState(() => _identifying = false);
      }

      final decision = resolveDirectPlaybackMode(
        url: url,
        manual: manual,
        containerHint: containerHint,
        remembered: remembered,
        probe: probe,
      );

      // 记忆：只记用户显式选择或探测有结论的模式；失败不记（避免一次抖动钉死主机）。
      if (repo != null && host.isNotEmpty) {
        final store = manual ??
            (probe != null && !probe.failed ? decision.mode : null);
        if (store != null) {
          unawaited(
              repo.rememberDirectPlaybackMode(host, store).catchError((_) {}));
        }
      }

      if (!mounted) return;
      Navigator.of(context).pop(Live(
        name: _name.text.trim().isEmpty ? '自定义直播流' : _name.text.trim(),
        url: url,
        playbackMode: decision.mode,
        playbackModeSource: decision.source,
        playbackModeReason: decision.reason,
      ));
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _identifying = false;
        });
      }
    }
  }

  String get _hint {
    if (_choice == DirectPlaybackChoice.vod) {
      return '按点播播放：显示进度条，可拖动定位；断流不会从头自动重播。';
    }
    if (_choice == DirectPlaybackChoice.live) {
      return '按直播播放：不显示进度条（不可拖动），←/→ 用于切台。';
    }
    return widget.autoDetect
        ? '自动：起播前只读清单（最多 4 秒），识别为点播就启用进度条；识别失败按直播播放。'
        : '自动：设置里已关闭「直链自动识别播放方式」，将按主机记忆 / 直播播放。';
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        backgroundColor: palette.panel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.lg),
          side: BorderSide(color: palette.borderStrong),
        ),
        title: Row(children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: palette.accentWash,
              borderRadius: BorderRadius.circular(AppRadii.md),
            ),
            child: Icon(Icons.link, color: palette.accentInk, size: 20),
          ),
          const SizedBox(width: 10),
          Text('播放直播直链', style: TextStyle(color: palette.textTitle)),
        ]),
        content: SizedBox(
          width: 500,
          child: SingleChildScrollView(
              child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _name,
                enabled: !_busy,
                style: TextStyle(color: palette.textMain),
                decoration: _inputDecoration('频道名称（可选）', palette),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _url,
                enabled: !_busy,
                style: TextStyle(color: palette.textMain),
                decoration: _inputDecoration('直播流 URL', palette,
                    hint: 'https://example.com/live.m3u8'),
                onSubmitted: (_) => _play(),
              ),
              const SizedBox(height: 14),
              Text('播放方式',
                  style:
                      TextStyle(color: palette.textSub, fontSize: AppType.label)),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (final option in const [
                    (DirectPlaybackChoice.auto, 'auto', '自动识别'),
                    (DirectPlaybackChoice.vod, 'vod', '按点播播放'),
                    (DirectPlaybackChoice.live, 'live', '按直播播放'),
                  ])
                    ChoiceChip(
                      key: ValueKey('direct-mode-${option.$2}'),
                      label: Text(option.$3),
                      selected: _choice == option.$1,
                      onSelected: _busy ? null : (_) => _pick(option.$1),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(_hint,
                  style: TextStyle(color: palette.textSub, fontSize: AppType.body)),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: TextStyle(color: palette.danger)),
              ],
            ],
          )),
        ),
        actions: [
          FocusOutline(
            radius: AppRadii.pill,
            child: TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('取消')),
          ),
          FocusOutline(
            radius: AppRadii.pill,
            child: FilledButton(
              onPressed: _busy ? null : _play,
              child: Text(_identifying ? '正在识别播放方式…' : '开始播放'),
            ),
          ),
        ],
      ),
    );
  }
}

InputDecoration _inputDecoration(String label, AppPalette palette,
        {String? hint}) =>
    InputDecoration(
      labelText: label,
      hintText: hint,
      labelStyle: TextStyle(color: palette.textSub, fontSize: AppType.label),
      hintStyle: TextStyle(color: palette.textDim, fontSize: AppType.body),
      filled: true,
      fillColor: palette.raised,
      border:
          OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadii.sm)),
    );
