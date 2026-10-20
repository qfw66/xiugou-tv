import 'package:flutter/material.dart';
import '../../../core/player/models/player_state.dart';
import '../../../core/push/push_input_resolver.dart';
import '../../../core/push/webdav_repository.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';

/// 浏览仅限用户选定根目录；连接和凭据不会写入配置。
class WebDavBrowserDialog extends StatefulWidget {
  final WebDavRepository? repository;
  const WebDavBrowserDialog({super.key, this.repository});

  @override
  State<WebDavBrowserDialog> createState() => _WebDavBrowserDialogState();
}

class _WebDavBrowserDialogState extends State<WebDavBrowserDialog> {
  final _url = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  late final WebDavRepository _repository;
  WebDavConnection? _connection;
  List<Uri> _trail = const [];
  List<WebDavEntry> _entries = const [];
  bool _busy = false;
  String? _error;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _repository = widget.repository ?? WebDavRepository();
  }

  @override
  void dispose() {
    _url.dispose();
    _username.dispose();
    _password.dispose();
    if (widget.repository == null) _repository.dispose();
    super.dispose();
  }

  void _invalidate(String _) => setState(() {
        _connection = null;
        _trail = const [];
        _entries = const [];
        _error = null;
      });

  Future<void> _connect() async {
    if (_busy) return;
    try {
      final connection = WebDavConnection.parse(_url.text,
          username: _username.text, password: _password.text);
      _connection = null;
      _trail = const [];
      _entries = const [];
      await _load(connection, [connection.root]);
    } catch (error) {
      if (mounted) setState(() => _error = pushErrorMessage(error));
    }
  }

  Future<void> _load(WebDavConnection connection, List<Uri> trail) async {
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final entries = await _repository.list(connection, directory: trail.last);
      if (!mounted || generation != _generation) return;
      setState(() {
        _connection = connection;
        _trail = List.unmodifiable(trail);
        _entries = entries;
      });
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = pushErrorMessage(error));
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  void _select(WebDavEntry entry) {
    final connection = _connection;
    if (_busy || connection == null) return;
    if (entry.isDirectory) {
      _load(connection, [..._trail, entry.uri]);
    } else {
      try {
        Navigator.of(context).pop<MediaPlaySpec>(connection.playSpec(entry));
      } catch (error) {
        setState(() => _error = pushErrorMessage(error));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Dialog(
      backgroundColor: palette.panel,
      insetPadding: const EdgeInsets.all(24),
      child: SizedBox(
        width: 760,
        height: 640,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                  child: Text('浏览 WebDAV 媒体库',
                      style: TextStyle(
                          color: palette.textTitle,
                          fontSize: AppType.h2,
                          fontWeight: FontWeight.bold))),
              IconButton(
                tooltip: '关闭 WebDAV',
                onPressed: () => Navigator.of(context).pop(),
                icon: Icon(Icons.close, color: palette.textSub),
              ),
            ]),
            Text('只读浏览 · 凭据仅在本次使用期间保留',
                style:
                    TextStyle(color: palette.textDim, fontSize: AppType.body)),
            const SizedBox(height: 12),
            TextField(
              controller: _url,
              enabled: !_busy,
              onChanged: _invalidate,
              style:
                  TextStyle(color: palette.textMain, fontSize: AppType.label),
              decoration: _decoration('WebDAV 根地址',
                  hint: 'https://nas.example.com/dav/'),
            ),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                  child: TextField(
                controller: _username,
                enabled: !_busy,
                onChanged: _invalidate,
                style:
                    TextStyle(color: palette.textMain, fontSize: AppType.label),
                decoration: _decoration('用户名（可选）'),
              )),
              const SizedBox(width: 10),
              Expanded(
                  child: TextField(
                controller: _password,
                enabled: !_busy,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                onChanged: _invalidate,
                style:
                    TextStyle(color: palette.textMain, fontSize: AppType.label),
                decoration: _decoration('密码'),
              )),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              FilledButton.icon(
                onPressed: _busy ? null : _connect,
                icon: const Icon(Icons.cloud_outlined, size: 18),
                label: const Text('连接并浏览'),
              ),
              const Spacer(),
              IconButton(
                tooltip: '返回上级',
                onPressed: _busy || _trail.length < 2
                    ? null
                    : () => _load(
                        _connection!, _trail.sublist(0, _trail.length - 1)),
                icon: Icon(Icons.arrow_upward, color: palette.textSub),
              ),
              IconButton(
                tooltip: '刷新 WebDAV',
                onPressed: _busy || _connection == null
                    ? null
                    : () => _load(_connection!, _trail),
                icon: Icon(Icons.refresh, color: palette.textSub),
              ),
            ]),
            if (_trail.isNotEmpty)
              Text(_trail.last.path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: palette.textSub, fontSize: AppType.body)),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(_error!,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: palette.danger, fontSize: AppType.body)),
              ),
            const SizedBox(height: 10),
            Divider(height: 1, color: palette.divider),
            Expanded(
              child: _busy
                  ? const Center(child: CircularProgressIndicator())
                  : _connection == null
                      ? Center(
                          child: Text('填写服务地址后连接，账号为空时匿名访问',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: palette.textSub)))
                      : _entries.isEmpty
                          ? Center(
                              child: Text('此目录为空',
                                  style: TextStyle(color: palette.textSub)))
                          : ListView.builder(
                              itemCount: _entries.length,
                              itemBuilder: (_, index) {
                                final entry = _entries[index];
                                final enabled =
                                    entry.isDirectory || entry.isMedia;
                                return ListTile(
                                  enabled: enabled,
                                  leading: Icon(
                                      entry.isDirectory
                                          ? Icons.folder_outlined
                                          : entry.isMedia
                                              ? Icons.play_circle_outline
                                              : Icons
                                                  .insert_drive_file_outlined,
                                      color: enabled
                                          ? palette.textBody
                                          : palette.textDim),
                                  title: Text(entry.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                          color: enabled
                                              ? palette.textMain
                                              : palette.textDim,
                                          fontSize: AppType.title)),
                                  subtitle: Text(
                                      entry.isDirectory
                                          ? '文件夹'
                                          : !entry.isMedia
                                              ? '非媒体文件'
                                              : entry.size == null
                                                  ? '点击播放'
                                                  : '${entry.size} 字节 · 点击播放',
                                      style: TextStyle(
                                          color: palette.textDim,
                                          fontSize: AppType.body)),
                                  trailing: entry.isDirectory
                                      ? Icon(Icons.chevron_right,
                                          color: palette.textDim)
                                      : null,
                                  onTap: enabled ? () => _select(entry) : null,
                                );
                              },
                            ),
            ),
          ]),
        ),
      ),
    );
  }

  InputDecoration _decoration(String label, {String? hint}) {
    final palette = AppPalette.of(context);
    return InputDecoration(
      labelText: label,
      hintText: hint,
      isDense: true,
      filled: true,
      fillColor: palette.raised,
      labelStyle: TextStyle(color: palette.textSub, fontSize: AppType.body),
      hintStyle: TextStyle(color: palette.textDim, fontSize: AppType.body),
      border:
          OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadii.sm)),
    );
  }
}
