import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import '../../../core/config/models/vod_config.dart';
import '../../../core/live/live_playlist_parser.dart';
import '../../../core/live/live_repository.dart';
import '../../../core/live/live_source.dart';
import '../../../core/live/live_text_loader.dart';
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

class LiveDirectDialog extends StatefulWidget {
  const LiveDirectDialog({super.key});

  @override
  State<LiveDirectDialog> createState() => _LiveDirectDialogState();
}

class _LiveDirectDialogState extends State<LiveDirectDialog> {
  final _name = TextEditingController();
  final _url = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    super.dispose();
  }

  void _play() {
    final url = _url.text.trim();
    if (!LivePlaylistParser.isStreamUrl(url)) {
      setState(() => _error = '请输入有效的 HTTP、RTMP、RTSP 或 UDP 直播地址');
      return;
    }
    Navigator.of(context).pop(Live(
      name: _name.text.trim().isEmpty ? '自定义直播流' : _name.text.trim(),
      url: url,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return AlertDialog(
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
          children: [
            TextField(
              controller: _name,
              style: TextStyle(color: palette.textMain),
              decoration: _inputDecoration('频道名称（可选）', palette),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _url,
              style: TextStyle(color: palette.textMain),
              decoration: _inputDecoration('直播流 URL', palette,
                  hint: 'https://example.com/live.m3u8'),
              onSubmitted: (_) => _play(),
            ),
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
          child: FilledButton(onPressed: _play, child: const Text('开始播放')),
        ),
      ],
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
