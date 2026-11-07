part of 'settings_page.dart';

class _ExternalPlayerSettingsCard extends StatefulWidget {
  final ExternalPlayerSettings value;
  final ValueChanged<ExternalPlayerSettings> onChanged;
  final Future<String?> Function()? pickExecutable;

  const _ExternalPlayerSettingsCard({
    required this.value,
    required this.onChanged,
    this.pickExecutable,
  });

  @override
  State<_ExternalPlayerSettingsCard> createState() =>
      _ExternalPlayerSettingsCardState();
}

class _ExternalPlayerSettingsCardState
    extends State<_ExternalPlayerSettingsCard> {
  bool _selecting = false;
  String? _error;

  Future<void> _pick() async {
    if (_selecting) return;
    setState(() {
      _selecting = true;
      _error = null;
    });
    try {
      final String? selected;
      final picker = widget.pickExecutable;
      if (picker != null) {
        selected = await picker();
      } else {
        final file = await openFile(
          acceptedTypeGroups: const [
            XTypeGroup(label: 'Windows 播放器程序', extensions: ['exe']),
          ],
          confirmButtonText: '选择播放器',
        );
        selected = file?.path;
      }
      if (!mounted || selected == null) return;
      final path = selected.trim();
      if (!RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(path) ||
          !path.toLowerCase().endsWith('.exe')) {
        setState(() => _error = '请选择本机绝对路径下的 .exe 播放器文件。');
        return;
      }
      final name = path.replaceAll('\\', '/').split('/').last.toLowerCase();
      final kind = switch (name) {
        'mpv.exe' => ExternalPlayerKind.mpv,
        'vlc.exe' => ExternalPlayerKind.vlc,
        _ => ExternalPlayerKind.generic,
      };
      widget.onChanged(ExternalPlayerSettings(executablePath: path, kind: kind));
    } catch (_) {
      if (mounted) setState(() => _error = '无法打开文件选择器，请重试。');
    } finally {
      if (mounted) setState(() => _selecting = false);
    }
  }

  void _clear() {
    setState(() => _error = null);
    widget.onChanged(ExternalPlayerSettings.defaults);
  }

  @override
  Widget build(BuildContext context) {
    final value = widget.value;
    final description = switch (value.kind) {
      ExternalPlayerKind.mpv => '传递全部请求头，并从当前点播进度开始播放。',
      ExternalPlayerKind.vlc =>
        '传递 User-Agent、Referer 与当前点播进度；其他请求头不受支持。',
      ExternalPlayerKind.generic => '仅传递播放地址；适用于 PotPlayer 等播放器。',
    };
    final muted = TextStyle(
      fontSize: AppType.body,
      color: context.palette.textSub,
      height: 1.5,
    );
    return _card(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('播放器程序',
              style: TextStyle(
                  fontSize: AppType.body,
                  fontWeight: FontWeight.w600,
                  color: context.palette.textMain)),
          const SizedBox(height: 8),
          SelectableText(
            value.isConfigured ? value.executablePath : '尚未选择播放器',
            key: const ValueKey('external-player-path'),
            style: muted,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton.icon(
                key: const ValueKey('external-player-select'),
                onPressed: _selecting ? null : _pick,
                style: _outlinedStyle(context),
                icon: _selecting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.folder_open_rounded, size: 18),
                label: Text(_selecting ? '正在选择…' : '选择 .exe 程序'),
              ),
              TextButton(
                key: const ValueKey('external-player-clear'),
                onPressed: _selecting || !value.isConfigured ? null : _clear,
                child: const Text('清除'),
              ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Semantics(
              liveRegion: true,
              child: Text(
                _error!,
                key: const ValueKey('external-player-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          ],
          const SizedBox(height: 16),
          Text('播放器模式', style: muted),
          const SizedBox(height: 8),
          _boxedDropdown(
            context,
            width: 240,
            child: DropdownButton<ExternalPlayerKind>(
              key: const ValueKey('external-player-kind'),
              value: value.kind,
              isExpanded: true,
              dropdownColor: context.palette.raised,
              style: TextStyle(
                  fontSize: AppType.label, color: context.palette.textMain),
              items: const [
                DropdownMenuItem(
                  value: ExternalPlayerKind.generic,
                  child: Text('通用（含 PotPlayer）'),
                ),
                DropdownMenuItem(
                  value: ExternalPlayerKind.mpv,
                  child: Text('mpv'),
                ),
                DropdownMenuItem(
                  value: ExternalPlayerKind.vlc,
                  child: Text('VLC'),
                ),
              ],
              onChanged: _selecting || !value.isConfigured
                  ? null
                  : (kind) {
                      if (kind != null && kind != value.kind) {
                        widget.onChanged(value.copyWith(kind: kind));
                      }
                    },
            ),
          ),
          const SizedBox(height: 8),
          Text(description, style: muted),
          const SizedBox(height: 12),
          Text(
            '在播放页打开第三方播放器，启动成功后暂停内置播放器。'
            '外部播放进度不会回传；使用本地代理地址时，请保持本应用运行。',
            style: muted,
          ),
        ],
      ),
    );
  }
}
