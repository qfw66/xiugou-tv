import 'dart:io';
import 'package:flutter/material.dart';
import '../../../core/config/models/vod_config.dart';
import '../../../core/live/epg_repository.dart';
import '../../../core/live/live_playlist_parser.dart';
import '../../../core/live/live_repository.dart';
import '../../../core/live/live_source.dart';
import '../../../core/live/live_text_loader.dart';
import 'live_epg_dialog.dart';
import 'live_import_dialog.dart';

/// 频道浏览与直播源管理；仓库由应用注入，播放沿用主窗口入口。
class LiveChannelsDialog extends StatefulWidget {
  final List<Live> lives;
  final ValueChanged<Live> onPlayLive;
  final LiveRepository? repository;
  final EpgRepository? epgRepository;
  final Uri? baseUri;
  final Future<String?> Function()? pickPlaylistFile;

  const LiveChannelsDialog({
    super.key,
    required this.lives,
    required this.onPlayLive,
    this.repository,
    this.epgRepository,
    this.baseUri,
    this.pickPlaylistFile,
  });

  @override
  State<LiveChannelsDialog> createState() => _LiveChannelsDialogState();
}

class _LiveChannelsDialogState extends State<LiveChannelsDialog> {
  final _search = TextEditingController();
  late List<Live> _channels;
  List<String> _warnings = const [];
  String? _group;
  String _keyword = '';
  bool _busy = false;
  int _generation = 0;

  List<String> get _groups =>
      _channels.map((channel) => channel.groupName).toSet().toList();

  @override
  void initState() {
    super.initState();
    _channels = widget.lives.where((channel) => !channel.isPlaylist).toList();
    if (widget.repository != null) _reload();
  }

  @override
  void didUpdateWidget(covariant LiveChannelsDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.lives, widget.lives) ||
        oldWidget.baseUri != widget.baseUri ||
        oldWidget.repository != widget.repository) {
      _reload();
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _reload({bool refresh = false}) async {
    final generation = ++_generation;
    final repository = widget.repository;
    if (repository == null) {
      setState(() {
        _channels =
            widget.lives.where((channel) => !channel.isPlaylist).toList();
        if (!_groups.contains(_group)) _group = null;
      });
      return;
    }
    setState(() => _busy = true);
    try {
      final catalog = await repository.load(widget.lives,
          baseUri: widget.baseUri, refresh: refresh);
      if (!mounted || generation != _generation) return;
      setState(() {
        _channels = catalog.channels;
        _warnings = catalog.warnings;
        if (!_groups.contains(_group)) _group = null;
      });
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _warnings = [liveErrorMessage(error)]);
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  void _play(Live channel) {
    if (channel.isPlaylist || !LivePlaylistParser.isStreamUrl(channel.url)) {
      setState(() => _warnings = ['请选择有效频道，清单地址应先导入而不是直接播放']);
      return;
    }
    Navigator.of(context).pop();
    widget.onPlayLive(channel);
  }

  Future<void> _import() async {
    final repository = widget.repository;
    if (repository == null) return;
    final imported = await showDialog<LiveSource>(
      context: context,
      barrierDismissible: false,
      builder: (_) => LiveImportDialog(
        repository: repository,
        pickPlaylistFile: widget.pickPlaylistFile,
      ),
    );
    if (!mounted || imported == null) return;
    _group = null;
    _keyword = '';
    _search.clear();
    await _reload();
  }

  Future<void> _direct() async {
    final channel = await showDialog<Live>(
        context: context, builder: (_) => const LiveDirectDialog());
    if (mounted && channel != null) _play(channel);
  }

  Future<void> _removeSource(LiveSource source) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('移除「${source.name}」？'),
        content: const Text('仅移除此自定义直播源；不删除原文件，也不影响影视配置。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('移除')),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    setState(() => _busy = true);
    try {
      await widget.repository!.removeSource(source.id);
      if (mounted) await _reload();
    } catch (error) {
      if (mounted) setState(() => _warnings = [liveErrorMessage(error)]);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showEpg(Live channel) {
    final repository = widget.epgRepository;
    if (repository == null) return;
    showDialog<void>(
      context: context,
      builder: (_) => LiveEpgDialog(
        channel: channel,
        repository: repository,
        onPlay: () => _play(channel),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final groups = _groups;
    final keyword = _keyword.toLowerCase();
    final filtered = _channels
        .where((channel) =>
            (_group == null || channel.groupName == _group) &&
            (keyword.isEmpty ||
                channel.name.toLowerCase().contains(keyword) ||
                (channel.epgName ?? '').toLowerCase().contains(keyword) ||
                channel.groupName.toLowerCase().contains(keyword)))
        .toList();
    final sources = widget.repository?.sources ?? const <LiveSource>[];

    return Dialog(
      backgroundColor: const Color(0xFF181820),
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Color(0xFF2E2E3C)),
      ),
      child: SizedBox(
        width: 1060,
        height: 680,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF321B23),
                  borderRadius: BorderRadius.circular(10),
                ),
                child:
                    const Icon(Icons.live_tv_rounded, color: Color(0xFFFF626B)),
              ),
              const SizedBox(width: 12),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    const Text('电视直播',
                        style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: Colors.white)),
                    Text('${_channels.length} 个频道 · ${groups.length} 个分组',
                        style: const TextStyle(
                            fontSize: 12, color: Color(0xFF888898))),
                  ])),
              IconButton(
                tooltip: '关闭直播',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close, color: Colors.white70),
              ),
            ]),
            const SizedBox(height: 14),
            Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilledButton.icon(
                    onPressed:
                        _busy || widget.repository == null ? null : _import,
                    style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFE50914),
                        foregroundColor: Colors.white),
                    icon: const Icon(Icons.playlist_add, size: 18),
                    label: const Text('导入直播源'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _direct,
                    icon: const Icon(Icons.link, size: 18),
                    label: const Text('播放直链'),
                  ),
                  IconButton(
                    tooltip: '刷新直播源',
                    onPressed: _busy || widget.repository == null
                        ? null
                        : () => _reload(refresh: true),
                    icon: const Icon(Icons.refresh, color: Colors.white70),
                  ),
                  if (sources.isNotEmpty)
                    PopupMenuButton<LiveSource>(
                      tooltip: '管理自定义源',
                      enabled: !_busy,
                      onSelected: _removeSource,
                      itemBuilder: (_) => [
                        for (final source in sources)
                          PopupMenuItem(
                            value: source,
                            child: Text(
                                '移除：${source.name}（${source.channels.length} 个频道）'),
                          ),
                      ],
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 10),
                        child: Text('自定义源 ${sources.length} ▾',
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 13)),
                      ),
                    ),
                ]),
            const SizedBox(height: 10),
            SizedBox(
                height: 2,
                child: _busy ? const LinearProgressIndicator() : null),
            const SizedBox(height: 10),
            TextField(
              controller: _search,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              onChanged: (value) => setState(() => _keyword = value.trim()),
              decoration: InputDecoration(
                hintText: '搜索频道或分组...',
                hintStyle: const TextStyle(color: Color(0xFF888898)),
                prefixIcon: const Icon(Icons.search,
                    color: Color(0xFF888898), size: 20),
                suffixIcon: _keyword.isEmpty
                    ? null
                    : IconButton(
                        tooltip: '清除搜索',
                        icon: const Icon(Icons.clear, color: Colors.white54),
                        onPressed: () {
                          _search.clear();
                          setState(() => _keyword = '');
                        },
                      ),
                isDense: true,
                filled: true,
                fillColor: const Color(0xFF20202A),
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
            if (groups.isNotEmpty) ...[
              const SizedBox(height: 10),
              SizedBox(
                height: 40,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (final group in <String?>[null, ...groups])
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(group ?? '全部'),
                          labelStyle: const TextStyle(
                              color: Colors.white70, fontSize: 12),
                          backgroundColor: const Color(0xFF24242E),
                          selectedColor: const Color(0xFF5D2029),
                          selected: _group == group,
                          onSelected: (_) => setState(() => _group = group),
                        ),
                      ),
                  ],
                ),
              ),
            ],
            if (_warnings.isNotEmpty) ...[
              const SizedBox(height: 8),
              Tooltip(
                message: _warnings.join('\n'),
                child: Text(_warnings.take(2).join('\n'),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.orangeAccent, fontSize: 12)),
              ),
            ],
            const SizedBox(height: 12),
            Expanded(
              child: filtered.isEmpty
                  ? Center(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.tv_off_outlined,
                          size: 42, color: Color(0xFF626276)),
                      const SizedBox(height: 12),
                      Text(_channels.isEmpty ? '暂无直播频道' : '未找到匹配的直播频道',
                          style: const TextStyle(color: Colors.white70)),
                      const SizedBox(height: 6),
                      const Text('可导入 M3U / TXT 清单，或直接播放直播流',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: Color(0xFF888898), fontSize: 12)),
                    ]))
                  : GridView.builder(
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 340,
                        mainAxisExtent: 126,
                        crossAxisSpacing: 10,
                        mainAxisSpacing: 10,
                      ),
                      itemCount: filtered.length,
                      itemBuilder: (_, index) {
                        final channel = filtered[index];
                        return _LiveChannelCard(
                          key: ValueKey(channel.key),
                          channel: channel,
                          onPlay: () => _play(channel),
                          onEpg: widget.epgRepository == null ||
                                  (channel.epg?.isEmpty ?? true)
                              ? null
                              : () => _showEpg(channel),
                        );
                      },
                    ),
            ),
          ]),
        ),
      ),
    );
  }
}

class _LiveChannelCard extends StatelessWidget {
  final Live channel;
  final VoidCallback onPlay;
  final VoidCallback? onEpg;

  const _LiveChannelCard({
    super.key,
    required this.channel,
    required this.onPlay,
    this.onEpg,
  });

  Widget _logo() {
    const fallback =
        Icon(Icons.live_tv_rounded, color: Color(0xFF9E9EB4), size: 24);
    final logo = channel.logoUrl;
    if (logo == null || logo.isEmpty) return fallback;
    final uri = Uri.tryParse(logo);
    if (uri?.scheme == 'file') {
      try {
        return Image.file(File.fromUri(uri!),
            width: 42,
            height: 42,
            fit: BoxFit.contain,
            cacheWidth: 96,
            errorBuilder: (_, __, ___) => fallback);
      } on UnsupportedError {
        return fallback;
      } on ArgumentError {
        return fallback;
      }
    }
    if (uri == null || !const {'http', 'https'}.contains(uri.scheme)) {
      return fallback;
    }
    return Image.network(logo,
        width: 42,
        height: 42,
        fit: BoxFit.contain,
        cacheWidth: 96,
        errorBuilder: (_, __, ___) => fallback);
  }

  @override
  Widget build(BuildContext context) => Material(
        color: const Color(0xFF22222E),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: const BorderSide(color: Color(0xFF323240))),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPlay,
          hoverColor: const Color(0xFF35232D),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                SizedBox(width: 42, height: 42, child: _logo()),
                const SizedBox(width: 12),
                Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Text(channel.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w600)),
                      const SizedBox(height: 3),
                      Text(channel.groupName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Color(0xFF888898), fontSize: 12)),
                    ])),
              ]),
              const Spacer(),
              Row(children: [
                const Icon(Icons.circle, size: 6, color: Color(0xFFFF626B)),
                const SizedBox(width: 5),
                const Text('LIVE',
                    style: TextStyle(
                        color: Color(0xFFFF626B),
                        fontSize: 10,
                        fontWeight: FontWeight.bold)),
                const Spacer(),
                if (onEpg != null)
                  TextButton.icon(
                    onPressed: onEpg,
                    icon: const Icon(Icons.event_note, size: 16),
                    label: const Text('节目单', style: TextStyle(fontSize: 12)),
                    style: TextButton.styleFrom(
                        foregroundColor: const Color(0xFFC2C4DA),
                        minimumSize: Size.zero,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 6)),
                  )
                else
                  const Text('暂无 EPG',
                      style: TextStyle(fontSize: 11, color: Colors.white38)),
                const SizedBox(width: 8),
                const Icon(Icons.play_circle_outline,
                    size: 20, color: Color(0xFFFF626B)),
              ]),
            ]),
          ),
        ),
      );
}
