import 'package:flutter/material.dart';
import '../../../core/player/models/player_state.dart';
import '../../../core/push/push_input_resolver.dart';
import '../../../core/push/webdav_profile_store.dart';
import '../../../core/push/webdav_repository.dart';
import '../../../core/storage/data_restore_guard.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';
import 'app_dialog.dart';

class WebDavBrowserDialog extends StatefulWidget {
  final WebDavRepository? repository;
  final WebDavProfileStore? profileStore;
  const WebDavBrowserDialog({super.key, this.repository, this.profileStore});

  @override
  State<WebDavBrowserDialog> createState() => _WebDavBrowserDialogState();
}

class _WebDavBrowserDialogState extends State<WebDavBrowserDialog> {
  final _url = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  late final WebDavRepository _repository;
  late final WebDavProfileStore _store;
  WebDavConnection? _connection;
  List<Uri> _trail = const [];
  List<WebDavEntry> _entries = const [];
  List<WebDavProfile> _profiles = const [];
  bool _busy = false;
  bool _closing = false;
  bool _readingProfiles = true;
  bool _remember = true;
  bool _profilesReadable = true;
  String? _editingId;
  String? _error;
  String? _recordError;
  String? _notice;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _repository = widget.repository ?? WebDavRepository();
    _store = widget.profileStore ?? WebDavProfileStore();
    _readProfiles();
  }

  Future<void> _readProfiles() async {
    try {
      final profiles = await _store.read();
      if (mounted) setState(() => _profiles = profiles);
    } catch (_) {
      if (mounted) {
        setState(() {
          _profilesReadable = false;
          _remember = false;
          _recordError = '已保存的连接无法读取，可继续临时连接';
        });
      }
    } finally {
      if (mounted) setState(() => _readingProfiles = false);
    }
  }

  @override
  void dispose() {
    _url.dispose();
    _username.dispose();
    _password.dispose();
    if (widget.repository == null) _repository.dispose();
    super.dispose();
  }

  void _didClose() {
    _closing = true;
    _generation++;
  }

  void _invalidate(String _) => setState(() {
    _connection = null;
    _trail = const [];
    _entries = const [];
    _error = null;
    _notice = null;
  });

  void _edit(WebDavProfile? profile) {
    if (_busy) return;
    _url.text = profile?.url ?? '';
    _username.text = profile?.username ?? '';
    _password.text = profile?.password ?? '';
    _invalidate('');
    setState(() {
      _editingId = profile?.id;
      _remember = _profilesReadable;
    });
  }

  Future<void> _connectSaved(WebDavProfile profile) async {
    _edit(profile);
    await _connect();
  }

  Future<void> _connect() async {
    if (_busy || _readingProfiles || _closing) return;
    try {
      final profile = WebDavProfile.create(
        _url.text,
        username: _username.text,
        password: _password.text,
      );
      final connection = profile.connect();
      _connection = null;
      _trail = const [];
      _entries = const [];
      await _load(
        connection,
        [connection.root],
        saveProfile: _remember ? profile : null,
        replacingId: _editingId,
      );
    } catch (error) {
      if (mounted) setState(() => _error = pushErrorMessage(error));
    }
  }

  Future<void> _load(
    WebDavConnection connection,
    List<Uri> trail, {
    WebDavProfile? saveProfile,
    String? replacingId,
  }) async {
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      final entries = await _repository.list(connection, directory: trail.last);
      if (!mounted || generation != _generation) return;
      setState(() {
        _connection = connection;
        _trail = List.unmodifiable(trail);
        _entries = entries;
      });
      if (saveProfile != null) {
        try {
          final profiles = await _store.save(
            saveProfile,
            replacingId: replacingId,
          );
          if (!mounted || generation != _generation) return;
          setState(() {
            _profiles = profiles;
            _editingId = saveProfile.id;
            _recordError = null;
            _notice = '连接已保存，下次可直接点击连接';
          });
        } on DataRestorePendingRestartException catch (error) {
          if (mounted && generation == _generation) {
            setState(() => _recordError = error.message);
          }
        } on WebDavProfileStoreException catch (error) {
          if (mounted && generation == _generation) {
            setState(() => _recordError = '已连接，但记录未保存：${error.message}');
          }
        } catch (_) {
          if (mounted && generation == _generation) {
            setState(() => _recordError = '已连接，但记录未保存；请检查数据目录权限或重试');
          }
        }
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = pushErrorMessage(error));
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  Future<void> _remove(WebDavProfile profile) async {
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除已保存的连接？'),
        content: const Text('只删除本机连接记录，不会删除服务器上的文件。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (!mounted || _closing || confirmed != true || _busy) return;
    setState(() => _busy = true);
    try {
      final profiles = await _store.remove(profile.id);
      if (!mounted) return;
      setState(() {
        _profiles = profiles;
        _recordError = null;
        _notice = '连接记录已删除';
        if (_editingId == profile.id) {
          _editingId = null;
          _remember = false;
        }
      });
    } on DataRestorePendingRestartException catch (error) {
      if (mounted) setState(() => _recordError = error.message);
    } catch (_) {
      if (mounted) setState(() => _recordError = '连接记录未删除，请检查数据目录权限或重试');
    } finally {
      if (mounted) setState(() => _busy = false);
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
    return PopScope<MediaPlaySpec>(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _didClose();
      },
      child: Dialog(
        backgroundColor: palette.panel,
        insetPadding: const EdgeInsets.all(24),
        child: SizedBox(
          width: 800,
          height: 720,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '浏览 WebDAV 媒体库',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          color: palette.textTitle,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭 WebDAV',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: CustomScrollView(
                    slivers: [
                      SliverToBoxAdapter(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '只读浏览 · 保存后可在本机一键连接',
                              style: TextStyle(color: palette.textSub),
                            ),
                            if (_readingProfiles)
                              const LinearProgressIndicator(),
                            if (_profiles.isNotEmpty) ...[
                              const SizedBox(height: 12),
                              Text(
                                '已保存的连接',
                                style: Theme.of(context).textTheme.titleSmall,
                              ),
                              const SizedBox(height: 4),
                              for (final profile in _profiles)
                                _savedRow(profile),
                            ],
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    _editingId == null ? '连接信息' : '编辑连接',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleSmall,
                                  ),
                                ),
                                TextButton.icon(
                                  onPressed: _busy ? null : () => _edit(null),
                                  icon: const Icon(Icons.add_rounded, size: 18),
                                  label: const Text('新建连接'),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            TextField(
                              controller: _url,
                              enabled: !_busy,
                              onChanged: _invalidate,
                              keyboardType: TextInputType.url,
                              decoration: _decoration(
                                'WebDAV 根地址',
                                hint: 'https://nas.example.com/dav/',
                              ),
                            ),
                            const SizedBox(height: 10),
                            LayoutBuilder(
                              builder: (context, constraints) {
                                final fields = [
                                  TextField(
                                    controller: _username,
                                    enabled: !_busy,
                                    onChanged: _invalidate,
                                    decoration: _decoration('用户名（可选）'),
                                  ),
                                  TextField(
                                    controller: _password,
                                    enabled: !_busy,
                                    obscureText: true,
                                    enableSuggestions: false,
                                    autocorrect: false,
                                    onChanged: _invalidate,
                                    onSubmitted: (_) => _connect(),
                                    decoration: _decoration('密码'),
                                  ),
                                ];
                                if (constraints.maxWidth < 440) {
                                  return Column(
                                    children: [
                                      fields[0],
                                      const SizedBox(height: 10),
                                      fields[1],
                                    ],
                                  );
                                }
                                return Row(
                                  children: [
                                    Expanded(child: fields[0]),
                                    const SizedBox(width: 10),
                                    Expanded(child: fields[1]),
                                  ],
                                );
                              },
                            ),
                            CheckboxListTile(
                              contentPadding: EdgeInsets.zero,
                              controlAffinity: ListTileControlAffinity.leading,
                              value: _remember,
                              onChanged:
                                  _busy ||
                                      _readingProfiles ||
                                      !_profilesReadable
                                  ? null
                                  : (value) => setState(
                                      () => _remember = value ?? false,
                                    ),
                              title: const Text('保存此连接（含密码）'),
                              subtitle: const Text('账号与密码加密保存在本机，不随备份导出'),
                            ),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                FilledButton.icon(
                                  onPressed: _busy || _readingProfiles
                                      ? null
                                      : _connect,
                                  icon: const Icon(
                                    Icons.cloud_rounded,
                                    size: 18,
                                  ),
                                  label: const Text('连接并浏览'),
                                ),
                                IconButton(
                                  tooltip: '返回上级',
                                  onPressed: _busy || _trail.length < 2
                                      ? null
                                      : () => _load(
                                          _connection!,
                                          _trail.sublist(0, _trail.length - 1),
                                        ),
                                  icon: const Icon(Icons.arrow_upward_rounded),
                                ),
                                IconButton(
                                  tooltip: '刷新 WebDAV',
                                  onPressed: _busy || _connection == null
                                      ? null
                                      : () => _load(_connection!, _trail),
                                  icon: const Icon(Icons.refresh_rounded),
                                ),
                              ],
                            ),
                            if (_trail.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: Text(
                                  _trail.last.path,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(color: palette.textSub),
                                ),
                              ),
                            for (final message in [
                              _error,
                              _recordError,
                              _notice,
                            ])
                              if (message != null)
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 8,
                                  ),
                                  child: Text(
                                    message,
                                    style: TextStyle(
                                      color: message == _notice
                                          ? palette.textSub
                                          : palette.danger,
                                    ),
                                  ),
                                ),
                            const SizedBox(height: 12),
                            Divider(height: 1, color: palette.divider),
                          ],
                        ),
                      ),
                      if (_busy)
                        const SliverToBoxAdapter(
                          child: Padding(
                            padding: EdgeInsets.all(32),
                            child: Center(child: CircularProgressIndicator()),
                          ),
                        )
                      else if (_connection == null || _entries.isEmpty)
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.all(28),
                            child: Text(
                              _connection == null
                                  ? '填写服务地址后连接，账号为空时匿名访问'
                                  : '此目录为空',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: palette.textSub),
                            ),
                          ),
                        )
                      else
                        SliverList.builder(
                          itemCount: _entries.length,
                          itemBuilder: (_, index) {
                            final entry = _entries[index];
                            final enabled = entry.isDirectory || entry.isMedia;
                            return ListTile(
                              enabled: enabled,
                              leading: Icon(
                                entry.isDirectory
                                    ? Icons.folder_rounded
                                    : entry.isMedia
                                    ? Icons.play_circle_outline_rounded
                                    : Icons.insert_drive_file_outlined,
                              ),
                              title: Text(
                                entry.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                entry.isDirectory
                                    ? '文件夹'
                                    : !entry.isMedia
                                    ? '非媒体文件'
                                    : entry.size == null
                                    ? '点击播放'
                                    : '${entry.size} 字节 · 点击播放',
                              ),
                              trailing: entry.isDirectory
                                  ? const Icon(Icons.chevron_right_rounded)
                                  : null,
                              onTap: enabled ? () => _select(entry) : null,
                            );
                          },
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _savedRow(WebDavProfile profile) => ListTile(
    key: ValueKey('webdav-profile-${profile.id}'),
    contentPadding: EdgeInsets.zero,
    title: Text(profile.url, maxLines: 1, overflow: TextOverflow.ellipsis),
    subtitle: Text(
      profile.username.isEmpty ? '匿名访问' : profile.username,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    ),
    onTap: _busy ? null : () => _connectSaved(profile),
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        OutlinedButton(
          onPressed: _busy ? null : () => _connectSaved(profile),
          child: const Text('连接'),
        ),
        PopupMenuButton<String>(
          enabled: !_busy,
          tooltip: '管理连接',
          onSelected: (action) =>
              action == 'edit' ? _edit(profile) : _remove(profile),
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'edit', child: Text('编辑连接')),
            PopupMenuItem(value: 'delete', child: Text('删除连接')),
          ],
        ),
      ],
    ),
  );

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
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadii.sm),
      ),
    );
  }
}
