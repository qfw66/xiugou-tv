import 'dart:io';
import 'package:flutter/material.dart';
import '../../../core/config/models/vod_config.dart';
import '../../../core/live/epg_repository.dart';
import '../../../core/live/live_playlist_parser.dart';
import '../../../core/live/live_repository.dart';
import '../../../core/live/live_source.dart';
import '../../../core/live/live_text_loader.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';
import '../widgets/focus_ring.dart';
import '../widgets/live_indicator.dart';
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

  /// 已收藏的频道键集合（§33）；为 null 时卡片不展示收藏入口。
  final Set<String>? favoritedKeys;

  /// 切换收藏；失败时应抛错，弹窗据此回退星标。
  final Future<void> Function(Live channel)? onToggleFavorite;

  const LiveChannelsDialog({
    super.key,
    required this.lives,
    required this.onPlayLive,
    this.repository,
    this.epgRepository,
    this.baseUri,
    this.pickPlaylistFile,
    this.favoritedKeys,
    this.onToggleFavorite,
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

  /// 收藏态的本地视图（§33）：点星标立刻反馈，落盘失败再回退。
  late final Set<String> _favorited = {...?widget.favoritedKeys};

  /// 置顶「收藏频道」分类的哨兵值（§34）。真实分组来自数据，不会等于它。
  static const String _favoriteGroup = '\u0000favorites';

  String get _favoriteGroupLabel => '收藏频道 ${_favorited.length}';

  bool _matchesGroup(Live channel) {
    if (_group == null) return true;
    if (_group == _favoriteGroup) return _favorited.contains(channel.key);
    return channel.groupName == _group;
  }

  Future<void> _toggleFavorite(Live channel) async {
    final toggle = widget.onToggleFavorite;
    if (toggle == null) return;
    final wasFavorited = _favorited.contains(channel.key);
    setState(() {
      if (wasFavorited) {
        _favorited.remove(channel.key);
      } else {
        _favorited.add(channel.key);
      }
    });
    try {
      await toggle(channel);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        if (wasFavorited) {
          _favorited.add(channel.key);
        } else {
          _favorited.remove(channel.key);
        }
      });
    }
  }

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
        if (_group != _favoriteGroup && !_groups.contains(_group)) _group = null;
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
        if (_group != _favoriteGroup && !_groups.contains(_group)) {
          _group = null;
        }
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

  String _emptyTitle() {
    if (_channels.isEmpty) return '暂无直播频道';
    if (_group == _favoriteGroup) return '收藏频道还是空的';
    return '未找到匹配的直播频道';
  }

  String _emptyHint() {
    if (_channels.isEmpty) return '可导入 M3U / TXT 清单，或直接播放直播流';
    if (_group == _favoriteGroup) return '在频道卡片上点右下角星标即可收藏';
    return '换个分组或清空搜索词试试';
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final groups = _groups;
    final keyword = _keyword.toLowerCase();
    final filtered = _channels
        .where((channel) =>
            _matchesGroup(channel) &&
            (keyword.isEmpty ||
                channel.name.toLowerCase().contains(keyword) ||
                (channel.epgName ?? '').toLowerCase().contains(keyword) ||
                channel.groupName.toLowerCase().contains(keyword)))
        .toList();
    final sources = widget.repository?.sources ?? const <LiveSource>[];

    return Dialog(
      backgroundColor: palette.panel,
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.lg),
        side: BorderSide(color: palette.borderStrong),
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
                  color: palette.accentWash,
                  borderRadius: BorderRadius.circular(AppRadii.md),
                ),
                child: Icon(Icons.live_tv_rounded, color: palette.accentInk),
              ),
              const SizedBox(width: 12),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text('电视直播',
                        style: TextStyle(
                            fontSize: AppType.h1,
                            fontWeight: FontWeight.bold,
                            color: palette.textTitle)),
                    Text('${_channels.length} 个频道 · ${groups.length} 个分组',
                        style: TextStyle(
                            fontSize: AppType.body, color: palette.textSub)),
                  ])),
              FocusOutline(
                radius: AppRadii.pill,
                child: IconButton(
                  tooltip: '关闭直播',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: Icon(Icons.close, color: palette.textBody),
                ),
              ),
            ]),
            const SizedBox(height: 14),
            Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FocusOutline(
                    radius: AppRadii.pill,
                    child: FilledButton.icon(
                      onPressed:
                          _busy || widget.repository == null ? null : _import,
                      style: FilledButton.styleFrom(
                          backgroundColor: palette.accent),
                      icon: const Icon(Icons.playlist_add, size: 18),
                      label: const Text('导入直播源'),
                    ),
                  ),
                  FocusOutline(
                    radius: AppRadii.pill,
                    child: OutlinedButton.icon(
                      onPressed: _direct,
                      icon: const Icon(Icons.link, size: 18),
                      label: const Text('播放直链'),
                    ),
                  ),
                  IconButton(
                    tooltip: '刷新直播源',
                    onPressed: _busy || widget.repository == null
                        ? null
                        : () => _reload(refresh: true),
                    icon: Icon(Icons.refresh, color: palette.textBody),
                  ),
                  if (sources.isNotEmpty)
                    FocusOutline(
                      radius: AppRadii.sm,
                      child: PopupMenuButton<LiveSource>(
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
                        child: _HoverHighlight(
                          borderRadius: BorderRadius.circular(AppRadii.sm),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 10),
                            child: Text('自定义源 ${sources.length} ▾',
                                style: TextStyle(
                                    color: palette.textBody,
                                    fontSize: AppType.label)),
                          ),
                        ),
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
              style:
                  TextStyle(color: palette.textMain, fontSize: AppType.label),
              onChanged: (value) => setState(() => _keyword = value.trim()),
              decoration: InputDecoration(
                hintText: '搜索频道或分组...',
                hintStyle: TextStyle(color: palette.textSub),
                prefixIcon:
                    Icon(Icons.search, color: palette.textSub, size: 20),
                suffixIcon: _keyword.isEmpty
                    ? null
                    : IconButton(
                        tooltip: '清除搜索',
                        icon: Icon(Icons.clear, color: palette.textDim),
                        onPressed: () {
                          _search.clear();
                          setState(() => _keyword = '');
                        },
                      ),
                isDense: true,
                filled: true,
                fillColor: palette.raised,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadii.md)),
              ),
            ),
            if (groups.isNotEmpty) ...[
              const SizedBox(height: 10),
              SizedBox(
                height: 40,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    // §34：置顶「收藏频道」分类（一直显示，空时给空态引导）。
                    if (widget.onToggleFavorite != null)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          key: const ValueKey('live-group-favorites'),
                          label: Text(_favoriteGroupLabel),
                          labelStyle: TextStyle(
                              color: palette.textBody, fontSize: AppType.body),
                          backgroundColor: palette.raised,
                          selectedColor: palette.accent.withValues(alpha: 0.22),
                          selected: _group == _favoriteGroup,
                          onSelected: (_) =>
                              setState(() => _group = _favoriteGroup),
                        ),
                      ),
                    for (final group in <String?>[null, ...groups])
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          key: ValueKey('live-group-${group ?? 'all'}'),
                          label: Text(group ?? '全部'),
                          labelStyle: TextStyle(
                              color: palette.textBody, fontSize: AppType.body),
                          backgroundColor: palette.raised,
                          selectedColor: palette.accent.withValues(alpha: 0.22),
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
                    style: TextStyle(
                        color: palette.warning, fontSize: AppType.body)),
              ),
            ],
            const SizedBox(height: 12),
            Expanded(
              child: filtered.isEmpty
                  ? Center(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.tv_off_outlined,
                          size: 42, color: palette.textDim),
                      const SizedBox(height: 12),
                      Text(_emptyTitle(),
                          style: TextStyle(color: palette.textBody)),
                      const SizedBox(height: 6),
                      Text(_emptyHint(),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: palette.textSub, fontSize: AppType.body)),
                      if (_channels.isEmpty && widget.repository != null) ...[
                        const SizedBox(height: 14),
                        FocusOutline(
                          radius: AppRadii.pill,
                          child: FilledButton.icon(
                            key: const ValueKey('live-empty-import'),
                            onPressed: _busy ? null : _import,
                            style: FilledButton.styleFrom(
                                backgroundColor: palette.accent),
                            icon: const Icon(Icons.playlist_add, size: 18),
                            label: const Text('导入直播源'),
                          ),
                        ),
                      ],
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
                          favorited: _favorited.contains(channel.key),
                          onToggleFavorite: widget.onToggleFavorite == null
                              ? null
                              : () => _toggleFavorite(channel),
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

class _LiveChannelCard extends StatefulWidget {
  final Live channel;
  final VoidCallback onPlay;
  final VoidCallback? onEpg;

  /// 已收藏态（§33）。收藏键用 [Live.key]。
  final bool favorited;

  /// 为 null 时不展示收藏入口（例如收藏夹内部复用该卡片时不需要再收藏）。
  final VoidCallback? onToggleFavorite;

  const _LiveChannelCard({
    super.key,
    required this.channel,
    required this.onPlay,
    this.onEpg,
    this.favorited = false,
    this.onToggleFavorite,
  });

  @override
  State<_LiveChannelCard> createState() => _LiveChannelCardState();
}

class _LiveChannelCardState extends State<_LiveChannelCard> {
  bool _isHovered = false;

  /// hover 节奏（D2：进 200 / 出 140）。
  Duration get _hoverMotion => _isHovered ? AppMotion.enter : AppMotion.exit;

  Widget _logo(AppPalette palette) {
    final fallback =
        Icon(Icons.live_tv_rounded, color: palette.textSub, size: 24);
    final logo = widget.channel.logoUrl;
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
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final channel = widget.channel;
    return FocusRing(
        onTap: widget.onPlay,
        semanticLabel: channel.name,
        borderRadius: const BorderRadius.all(Radius.circular(AppRadii.md)),
        child: MouseRegion(
          onEnter: (_) => setState(() => _isHovered = true),
          onExit: (_) => setState(() => _isHovered = false),
          cursor: SystemMouseCursors.click,
          child: AnimatedScale(
            // 与海报卡同一「轻放大」范式；频道卡更宽（340 + 10 格距），
            // 取 1.02（1.035 时相邻卡会侵出约 1.9px 造成重叠）。
            scale: _isHovered ? 1.02 : 1.0,
            duration: _hoverMotion,
            curve: AppMotion.ease,
            child: AnimatedContainer(
              duration: _hoverMotion,
              curve: AppMotion.ease,
              decoration: BoxDecoration(
                color: palette.card,
                borderRadius: BorderRadius.circular(AppRadii.md),
                border: Border.all(
                  color: _isHovered ? palette.accentInk : palette.border,
                  width: _isHovered ? 1.5 : 1.0,
                ),
                boxShadow: _isHovered
                    ? [
                        BoxShadow(
                          color: palette.accentInk.withValues(alpha: 0.16),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ]
                    : null,
              ),
              clipBehavior: Clip.antiAlias,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: widget.onPlay,
                  // hover 视觉由外层（缩放 / 描边 / 柔光）承担，避免叠加过重；
                  // 保留按压 splash 反馈。
                  hoverColor: Colors.transparent,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            SizedBox(
                                width: 42, height: 42, child: _logo(palette)),
                            const SizedBox(width: 12),
                            Expanded(
                                child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                  Text(channel.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                          color: palette.textTitle,
                                          fontSize: AppType.title,
                                          fontWeight: FontWeight.w600)),
                                  const SizedBox(height: 3),
                                  Text(channel.groupName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                          color: palette.textSub,
                                          fontSize: AppType.body)),
                                ])),
                          ]),
                          const Spacer(),
                          Row(children: [
                            // 热标与 EPG「正在播出」共用同一组件（B6）。
                            const LiveIndicator(label: 'LIVE'),
                            const Spacer(),
                            if (widget.onToggleFavorite != null)
                              Tooltip(
                                message: widget.favorited ? '取消收藏' : '收藏频道',
                                child: IconButton(
                                  key: ValueKey('live-fav-${channel.key}'),
                                  onPressed: widget.onToggleFavorite,
                                  icon: Icon(
                                    widget.favorited
                                        ? Icons.star_rounded
                                        : Icons.star_border_rounded,
                                    size: 20,
                                  ),
                                  color: widget.favorited
                                      ? palette.warning
                                      : palette.textSub,
                                  visualDensity: VisualDensity.compact,
                                  constraints: const BoxConstraints(
                                      minWidth: 32, minHeight: 32),
                                  padding: EdgeInsets.zero,
                                ),
                              ),
                            if (widget.onEpg != null)
                              TextButton.icon(
                                onPressed: widget.onEpg,
                                icon: const Icon(Icons.event_note, size: 16),
                                label: const Text('节目单',
                                    style: TextStyle(fontSize: AppType.body)),
                                style: TextButton.styleFrom(
                                    foregroundColor: palette.textBody,
                                    minimumSize: Size.zero,
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 6, vertical: 6)),
                              )
                            else
                              Text('暂无 EPG',
                                  style: TextStyle(
                                      fontSize: AppType.caption,
                                      color: palette.textSub)),
                            const SizedBox(width: 8),
                            Icon(Icons.play_circle_outline,
                                size: 20, color: palette.accentInk),
                          ]),
                        ]),
                  ),
                ),
              ),
            ),
          ),
        ));
  }
}

/// hover 高亮容器（B6）：`PopupMenuButton` 的 child 模式没有内置底色反馈，
/// 补一层 `palette.hover` 底（skill `hover-states`；进 200 / 出 140）。
class _HoverHighlight extends StatefulWidget {
  const _HoverHighlight({required this.borderRadius, required this.child});

  final BorderRadius borderRadius;
  final Widget child;

  @override
  State<_HoverHighlight> createState() => _HoverHighlightState();
}

class _HoverHighlightState extends State<_HoverHighlight> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: AnimatedContainer(
        duration: _hovered ? AppMotion.enter : AppMotion.exit,
        curve: AppMotion.ease,
        decoration: BoxDecoration(
          color: _hovered ? palette.hover : null,
          borderRadius: widget.borderRadius,
        ),
        child: widget.child,
      ),
    );
  }
}
