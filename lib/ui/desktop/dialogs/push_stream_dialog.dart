import 'dart:async';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../core/player/models/player_state.dart';
import '../../../core/push/push_input_resolver.dart';
import '../../../core/push/webdav_repository.dart';
import 'webdav_browser_dialog.dart';

/// 所有输入共享解析与播放入口；系统剪贴板只在用户点击时读取。
class PushStreamDialog extends StatefulWidget {
  final FutureOr<void> Function(MediaPlaySpec spec) onPlayPush;
  final PushInputResolver? resolver;
  final Future<String?> Function()? readClipboard;
  final Future<List<String>> Function()? pickMediaFiles;
  final WebDavRepository? webDavRepository;

  const PushStreamDialog({
    super.key,
    required this.onPlayPush,
    this.resolver,
    this.readClipboard,
    this.pickMediaFiles,
    this.webDavRepository,
  });

  @override
  State<PushStreamDialog> createState() => _PushStreamDialogState();
}

class _PushStreamDialogState extends State<PushStreamDialog> {
  final _url = TextEditingController();
  final _title = TextEditingController();
  late final PushInputResolver _resolver;
  bool _busy = false;
  bool _dragging = false;
  bool _closing = false;
  MediaPlaySpec? _webDavSelection;
  String? _error;
  String? _notice;

  @override
  void initState() {
    super.initState();
    _resolver = widget.resolver ?? PushInputResolver();
  }

  @override
  void dispose() {
    _url.dispose();
    _title.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (!mounted || _busy || _closing) return;
    setState(() {
      _busy = true;
      _dragging = false;
      _error = null;
      _notice = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted && !_closing) {
        setState(() => _error = pushErrorMessage(error));
      }
    } finally {
      if (mounted && !_closing) setState(() => _busy = false);
    }
  }

  Future<void> _playInput(String input) async {
    final source = input == _webDavSelection?.url ? _webDavSelection : null;
    final title = _title.text.trim();
    final spec = await _resolver.resolve(
      input,
      title: title.isEmpty ? source?.title : title,
      headers: source?.headers ?? const {},
    );
    if (!mounted || _closing) return;
    await widget.onPlayPush(spec);
    if (!mounted || _closing) return;
    _closing = true;
    Navigator.of(context).pop();
  }

  void _close() {
    _closing = true;
    Navigator.of(context).pop();
  }

  Future<String?> _choose(List<String> rawCandidates) async {
    final candidates = rawCandidates
        .where((value) => value.trim().isNotEmpty)
        .toSet()
        .toList();
    if (candidates.isEmpty) return null;
    if (candidates.length > 200) {
      throw const FormatException('一次最多选择 200 个候选，请缩小选择范围');
    }
    if (candidates.length == 1) return candidates.single;
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('选择要播放的媒体'),
        content: SizedBox(
          width: 540,
          height: 330,
          child: ListView.separated(
            itemCount: candidates.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, index) => ListTile(
              leading: Text('${index + 1}'),
              title: Text(_candidateLabel(candidates[index]),
                  maxLines: 2, overflow: TextOverflow.ellipsis),
              onTap: () => Navigator.of(dialogContext).pop(candidates[index]),
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消')),
        ],
      ),
    );
  }

  Future<void> _chooseAndPlay(List<String> candidates) async {
    final selected = await _choose(candidates);
    if (!mounted || _closing || selected == null) return;
    _webDavSelection = null;
    _url.text = selected;
    await _playInput(selected);
  }

  Future<void> _fromClipboard() => _run(() async {
        final text = await (widget.readClipboard ?? _readClipboard)();
        if (!mounted || _closing) return;
        final candidates = _resolver.extractCandidates(text ?? '');
        if (candidates.isEmpty) {
          throw const FormatException('剪贴板中未找到媒体地址或文件路径');
        }
        final selected = await _choose(candidates);
        if (!mounted || _closing || selected == null) return;
        _webDavSelection = null;
        _url.text = selected;
        setState(() => _notice = '已识别地址，请确认后点击立即播放');
      });

  Future<void> _fromFiles() => _run(() async {
        final files = await (widget.pickMediaFiles ?? _pickFiles)();
        if (!mounted || _closing) return;
        await _chooseAndPlay(files);
      });

  Future<void> _fromWebDav() => _run(() async {
        final spec = await showDialog<MediaPlaySpec>(
          context: context,
          builder: (_) =>
              WebDavBrowserDialog(repository: widget.webDavRepository),
        );
        if (!mounted || _closing || spec == null) return;
        _webDavSelection = spec;
        _url.text = spec.url;
        await _playInput(spec.url);
      });

  static Future<String?> _readClipboard() async =>
      (await Clipboard.getData(Clipboard.kTextPlain))?.text;

  static Future<List<String>> _pickFiles() async {
    final files = await openFiles(acceptedTypeGroups: [
      XTypeGroup(
          label: '视频与音频',
          extensions: PushInputResolver.mediaExtensions.toList()),
    ]);
    return files.map((file) => file.path).toList();
  }

  static String _candidateLabel(String value) {
    final uri = Uri.tryParse(value.split('|').first);
    if (uri != null && uri.hasAuthority) {
      return uri.replace(userInfo: '').toString().split(RegExp(r'[?#]')).first;
    }
    return value;
  }

  @override
  Widget build(BuildContext context) => PopScope<void>(
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) _closing = true;
        },
        child: Dialog(
          backgroundColor: const Color(0xFF181820),
          insetPadding: const EdgeInsets.all(24),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Color(0xFF2E2E3C)),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    const Icon(Icons.send_rounded,
                        color: Color(0xFFE50914), size: 26),
                    const SizedBox(width: 12),
                    const Expanded(
                        child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('链接推送与直接播放',
                            style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: Colors.white)),
                        Text('媒体直链 · 本地文件 · WebDAV · 已挂载 SMB',
                            style: TextStyle(
                                fontSize: 12, color: Color(0xFF888898))),
                      ],
                    )),
                    IconButton(
                      tooltip: '关闭推送',
                      onPressed: _close,
                      icon: const Icon(Icons.close, color: Colors.white70),
                    ),
                  ]),
                  const SizedBox(height: 18),
                  TextField(
                    controller: _title,
                    enabled: !_busy,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    decoration: _decoration('视频标题 (可选)'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _url,
                    enabled: !_busy,
                    minLines: 2,
                    maxLines: 4,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    decoration: _decoration('媒体地址或文件路径',
                        hint: r'https://example.com/movie.mp4 或 C:\视频\电影.mkv'),
                    onChanged: (_) => setState(() {
                      _webDavSelection = null;
                      _error = null;
                      _notice = null;
                    }),
                  ),
                  const SizedBox(height: 12),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _fromClipboard,
                      icon: const Icon(Icons.content_paste, size: 17),
                      label: const Text('识别剪贴板'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _fromFiles,
                      icon: const Icon(Icons.folder_open, size: 17),
                      label: const Text('选择媒体文件'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _fromWebDav,
                      icon: const Icon(Icons.cloud_outlined, size: 17),
                      label: const Text('浏览 WebDAV'),
                    ),
                  ]),
                  const SizedBox(height: 14),
                  DropTarget(
                    enable: !_busy &&
                        !_closing &&
                        (ModalRoute.of(context)?.isCurrent ?? true),
                    onDragEntered: (_) {
                      if (!_busy && !_dragging) {
                        setState(() => _dragging = true);
                      }
                    },
                    onDragExited: (_) {
                      if (_dragging && mounted) {
                        setState(() => _dragging = false);
                      }
                    },
                    onDragDone: (details) => _run(() => _chooseAndPlay(
                        details.files.map((file) => file.path).toList())),
                    child: Container(
                      key: const ValueKey('push-drop-zone'),
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 18),
                      decoration: BoxDecoration(
                        color: _dragging
                            ? const Color(0xFF44212A)
                            : const Color(0xFF20202A),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                            color: _dragging
                                ? const Color(0xFFFF626B)
                                : const Color(0xFF3B3B4C)),
                      ),
                      child: Column(children: [
                        Icon(Icons.file_download_outlined,
                            color: _dragging
                                ? const Color(0xFFFF626B)
                                : Colors.white54),
                        const SizedBox(height: 6),
                        const Text('将媒体文件拖到这里即可播放',
                            textAlign: TextAlign.center,
                            style:
                                TextStyle(color: Colors.white70, fontSize: 13)),
                        const Text('多个文件会先选择，不会自动加入播放队列',
                            textAlign: TextAlign.center,
                            style:
                                TextStyle(color: Colors.white38, fontSize: 11)),
                      ]),
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text(r'SMB：先在 Windows 中登录共享，再选择映射盘文件或输入 \\服务器\共享\文件。',
                      style: TextStyle(color: Color(0xFF888898), fontSize: 12)),
                  const SizedBox(height: 4),
                  const Text('暂不支持磁力链，请使用媒体直链或已下载文件；本页不会写入点播历史。',
                      style: TextStyle(color: Color(0xFF888898), fontSize: 12)),
                  if (_error != null) ...[
                    const SizedBox(height: 10),
                    Text(_error!,
                        style: const TextStyle(
                            color: Colors.redAccent, fontSize: 13)),
                  ],
                  if (_notice != null) ...[
                    const SizedBox(height: 10),
                    Text(_notice!,
                        style: const TextStyle(
                            color: Colors.lightBlueAccent, fontSize: 12)),
                  ],
                  const SizedBox(height: 10),
                  SizedBox(
                      height: 2,
                      child: _busy ? const LinearProgressIndicator() : null),
                  const SizedBox(height: 12),
                  Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                    TextButton(onPressed: _close, child: const Text('取消')),
                    const SizedBox(width: 12),
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFFE50914)),
                      onPressed: _busy
                          ? null
                          : () => _run(() => _playInput(_url.text)),
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: const Text('立即播放'),
                    ),
                  ]),
                ],
              ),
            ),
          ),
        ),
      );

  InputDecoration _decoration(String label, {String? hint}) => InputDecoration(
        labelText: label,
        hintText: hint,
        labelStyle: const TextStyle(color: Color(0xFF888898), fontSize: 12),
        hintStyle: const TextStyle(color: Color(0xFF626276), fontSize: 12),
        filled: true,
        fillColor: const Color(0xFF20202A),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
      );
}
