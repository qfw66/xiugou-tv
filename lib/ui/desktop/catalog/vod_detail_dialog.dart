import 'dart:async';
import 'dart:math' as math;
import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../core/api/douban_repository.dart';
import '../../../core/api/models/vod_models.dart';
import '../../../core/api/tmdb_repository.dart';
import '../../../core/config/models/history_record.dart';
import '../../../core/api/netdisk_share_links.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';
import '../widgets/app_message.dart';
import '../widgets/desktop_window_frame.dart';
import '../widgets/media_title_bar.dart';
import '../widgets/focus_ring.dart';
import '../dialogs/history_sections.dart';
import '../widgets/horizontal_scroll_area.dart';
import 'poster_image.dart';
import 'douban_poster_image.dart';

part 'cinematic_vod_detail.dart';
part 'cinematic_detail_rail.dart';
part 'cinematic_detail_comments.dart';
part 'cinematic_detail_metadata.dart';

/// 详情页选集的完整选择上下文（把同站全部线路带进播放会话）。
class EpisodeSelection {
  final VodEpisode episode;
  final String sourceName;
  final List<VodEpisode> episodes;
  final int index;
  final List<PlayFrom> sources;
  final int sourceIndex;

  /// 从历史记录定位到这一集时保留所选断点；普通选集仍按片名和集名查找进度。
  final HistoryRecord? resumeRecord;

  const EpisodeSelection({
    required this.episode,
    required this.sourceName,
    required this.episodes,
    required this.index,
    required this.sources,
    required this.sourceIndex,
    this.resumeRecord,
  });
}

/// 选集播放回调：携带当前播放源的剧集列表与索引，以及全部线路。
typedef PlayEpisodeCallback = void Function(EpisodeSelection selection);

/// 「当前集」快照（backlog §15）：由调用方从播放会话组装。
///
/// 组件不依赖 Riverpod；同站同片的判断在 `app.dart` 的
/// `currentEpisodeForDetail(...)` 里完成，不匹配时传 `null`（零高亮）。
///
/// 只看会话、不看播放规格：关闭播放器时 `activePlaySpec` 会先被清空，
/// 随后才恢复详情弹窗——用规格会把「返回选集」这条主路径判成没在播。
class CurrentEpisode {
  /// 播放源名（用于打开弹窗时自动落到该线路）。
  final String sourceName;

  /// 集在播放源列表里的下标。
  final int index;

  /// 集名：与 [index] 同时匹配才算同一集（防详情重拉后错标）。
  final String episodeName;

  const CurrentEpisode({
    required this.sourceName,
    required this.index,
    required this.episodeName,
  });

  bool matches({
    required String sourceName,
    required int index,
    required String episodeName,
  }) =>
      this.sourceName == sourceName &&
      this.index == index &&
      this.episodeName == episodeName;
}

final _localConfigCenterUrl =
    RegExp(r'http://127\.0\.0\.1:\d{2,5}/(?:proxy\?do=pan&action=config|config\b)');

/// 简介里的本机配置中心地址；没有返回 null。
///
/// 网盘配置站（如 newwex 的 Wexconfig）在简介里写「请打开网页版配置中心：局域网 IP:19988/config」，
/// 那个入口会跳到只绑本机的代理端口，桌面上打不开；companion 已把它换成本机代理地址（issue #6）。
String? localConfigCenterUrlOf(String? content) =>
    content == null ? null : _localConfigCenterUrl.firstMatch(content)?.group(0);

/// 详情左栏「上次播放」文案：集名 · 线路 · 进度（播完显示「已看完」）。
String lastWatchedLabel(HistoryRecord record) {
  final progress = record.isFinished
      ? '已看完'
      : record.hasResumePosition
          ? formatPlaybackTime(record.positionMs)
          : '未开始';
  return '上次播放：${record.episodeName} · ${record.sourceName} · $progress';
}

/// 桌面端影视详情与多源选集弹窗（Infuse × Netflix 沉浸大画幅风格）。
class VodDetailDialog extends StatefulWidget {
  final VodDetail detail;
  final PlayEpisodeCallback onPlayEpisode;
  final bool isFavorite;
  final Future<String?> Function()? onToggleFavorite;

  /// 当前播放集；为 `null` 时与改动前完全一致（普通浏览零高亮）。
  final CurrentEpisode? currentEpisode;

  /// 用系统浏览器打开地址；简介里有本机配置中心地址时据此显示「在本机打开配置页」。
  final Future<bool> Function(String url)? onOpenUrl;

  /// 本片在当前站最近一条播放历史；为 `null` 时不显示「上次播放」。
  final HistoryRecord? lastWatched;

  final Future<TmdbMovie?> Function(CancelToken)? loadCinematicMetadata;
  final Future<DoubanDetailMetadata?> Function(CancelToken)? loadDoubanMetadata;
  final Future<List<String>> Function(DoubanDetailMetadata, CancelToken)? loadDoubanBackdrops;
  final Future<List<DoubanComment>> Function(CancelToken)? loadHotComments;
  final ValueChanged<String>? onSearchRecommendation;
  final EpisodeSelection? historySelection;

  const VodDetailDialog({
    super.key,
    required this.detail,
    required this.onPlayEpisode,
    this.isFavorite = false,
    this.onToggleFavorite,
    this.currentEpisode,
    this.onOpenUrl,
    this.lastWatched,
    this.loadCinematicMetadata,
    this.loadDoubanMetadata,
    this.loadDoubanBackdrops,
    this.loadHotComments,
    this.onSearchRecommendation,
    this.historySelection,
  });

  @override
  State<VodDetailDialog> createState() => _VodDetailDialogState();
}

class _VodDetailDialogState extends State<VodDetailDialog> {
  int _selectedSourceIndex = 0;
  late bool _favorited;
  bool _favoriteBusy = false;
  String? _error;

  /// 播放源横栏的横向滚动控制器（滚轮 / 拖拽共用）。
  final ScrollController _sourceScrollController = ScrollController();

  /// §49：详情里出现的网盘分享链接；为空时不显示「复制分享链接」
  late final List<NetdiskShareLink> _shareLinks =
      extractNetdiskShareLinks(widget.detail);

  Future<void> _openConfigCenter(String url) async {
    final opened = await widget.onOpenUrl!(url);
    if (opened || !mounted) return;
    await Clipboard.setData(ClipboardData(text: url));
    showAppMessage('无法打开浏览器，配置页地址已复制：$url',
        type: AppMessageType.warning);
  }

  Future<void> _copyShareLinks(List<NetdiskShareLink> links) async {
    await Clipboard.setData(
        ClipboardData(text: links.map((link) => link.url).join('\n')));
    if (!mounted) return;
    showAppMessage(
        links.length == 1
            ? '已复制${links.single.provider}分享链接'
            : '已复制 ${links.length} 条分享链接',
        type: AppMessageType.success);
  }

  /// 单条直接复制；多条弹菜单逐条选或全部复制
  Widget _buildShareLinkButton(AppPalette palette) {
    final icon = Icon(Icons.link_rounded, color: palette.textSub, size: 22);
    if (_shareLinks.length == 1) {
      return IconButton(
        key: const ValueKey('detail-copy-share-link'),
        icon: icon,
        tooltip: '复制分享链接',
        onPressed: () => _copyShareLinks(_shareLinks),
      );
    }
    return PopupMenuButton<int>(
      key: const ValueKey('detail-copy-share-link'),
      icon: icon,
      tooltip: '复制分享链接',
      color: palette.raised,
      onSelected: (index) =>
          _copyShareLinks(index < 0 ? _shareLinks : [_shareLinks[index]]),
      itemBuilder: (_) => [
        PopupMenuItem<int>(
          value: -1,
          child: Text('全部复制（${_shareLinks.length} 条）',
              style: TextStyle(
                  fontSize: AppType.label,
                  fontWeight: FontWeight.w600,
                  color: palette.textMain)),
        ),
        const PopupMenuDivider(),
        for (var i = 0; i < _shareLinks.length; i++)
          PopupMenuItem<int>(
            value: i,
            child: SizedBox(
              width: 360,
              child: Text('${_shareLinks[i].provider}  ${_shareLinks[i].url}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: AppType.label, color: palette.textBody)),
            ),
          ),
      ],
    );
  }

  @override
  void initState() {
    super.initState();
    _favorited = widget.isFavorite;
    _selectedSourceIndex = _initialSourceIndex();
  }

  @override
  void dispose() {
    _sourceScrollController.dispose();
    super.dispose();
  }

  /// §15：打开弹窗时落到当前集所在线路；找不到就保持默认（第一条）。
  int _initialSourceIndex() {
    final current = widget.currentEpisode;
    if (current == null) return 0;
    final sources = widget.detail.sources;
    final index = sources.indexWhere((s) => s.name == current.sourceName);
    return index >= 0 ? index : 0;
  }

  /// §15：只在「同一线路 + 同一下标 + 同一集名」时认为当前集。
  bool _isCurrent(int epIdx, VodEpisode episode, String sourceName) {
    final current = widget.currentEpisode;
    if (current == null) return false;
    return current.matches(
      sourceName: sourceName,
      index: epIdx,
      episodeName: episode.name,
    );
  }

  Future<void> _toggleFavorite() async {
    if (_favoriteBusy || widget.onToggleFavorite == null) return;
    final previous = _favorited;
    setState(() {
      _favoriteBusy = true;
      _favorited = !previous;
      _error = null;
    });
    String? message;
    try {
      message = await widget.onToggleFavorite!();
    } catch (_) {
      message = '收藏保存失败，请稍后重试';
    }
    if (!mounted) return;
    setState(() {
      _favoriteBusy = false;
      if (message != null) {
        _favorited = previous;
        _error = message;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final item = widget.detail.item;
    final sources = widget.detail.sources;
    if (widget.loadCinematicMetadata case final load?) {
      return _CinematicVodPage(
        key: ValueKey((item.siteKey, item.id, item.name, item.year, item.typeName, item.doubanId)),
        detail: widget.detail,
        load: load,
        loadDoubanMetadata: widget.loadDoubanMetadata,
        loadDoubanBackdrops: widget.loadDoubanBackdrops,
        loadHotComments: widget.loadHotComments,
        current: widget.currentEpisode,
        history: widget.historySelection,
        onPlay: widget.onPlayEpisode,
        onSearchRecommendation: widget.onSearchRecommendation,
        favorite: widget.onToggleFavorite == null
            ? null
            : IconButton.filledTonal(
                tooltip: _favorited ? '取消收藏' : '收藏影片',
                icon: Icon(_favorited ? Icons.star_rounded : Icons.star_outline_rounded),
                onPressed: _favoriteBusy ? null : _toggleFavorite,
              ),
        share: _shareLinks.isEmpty ? null : _buildShareLinkButton(palette),
        error: _error,
      );
    }
    final currentEpisodes =
        (sources.isNotEmpty && _selectedSourceIndex < sources.length)
            ? sources[_selectedSourceIndex].episodes
            : <VodEpisode>[];
    final metaLine = [item.year, item.area, item.typeName]
        .whereType<String>()
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .join(' · ');

    return Dialog(
      backgroundColor: palette.panel,
      // 与收藏 / 历史弹窗统一：lg 圆角 + borderStrong 描边（B4）
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.lg),
        side: BorderSide(color: palette.borderStrong, width: 1),
      ),
      child: Container(
        width: 860,
        height: 540,
        decoration: BoxDecoration(
          color: palette.panel,
          borderRadius: BorderRadius.circular(AppRadii.lg),
          boxShadow: AppShadows.subtleDepth(),
        ),
        padding: const EdgeInsets.all(22),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ==================== 左侧：大画幅海报与影片详情 ====================
            SizedBox(
              width: 280,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 第一层：看的是什么（海报 + 片名 + 元数据 + 更新状态）
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(AppRadii.md),
                          border: Border.all(color: palette.borderStrong),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(AppRadii.md - 1),
                          child: Image(
                            image: posterImageProvider(item.pic,
                                    targetWidth: 320) ??
                                ResizeImage(NetworkImage(item.pic), width: 320),
                            width: 110,
                            height: 156,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Container(
                              width: 110,
                              height: 156,
                              color: palette.raised,
                              child: Icon(Icons.movie_outlined,
                                  size: 36, color: palette.textDim),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item.name,
                              style: TextStyle(
                                fontSize: AppType.h2,
                                fontWeight: FontWeight.bold,
                                color: palette.textTitle,
                                height: 1.25,
                              ),
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (metaLine.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Text(
                                metaLine,
                                key: const ValueKey('detail-meta'),
                                style: TextStyle(
                                  fontSize: AppType.body,
                                  color: palette.textSub,
                                  height: 1.35,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                            // 更新状态（站源 vod_remarks，如「更新至12集」）
                            if (item.remarks?.trim().isNotEmpty ?? false) ...[
                              const SizedBox(height: 8),
                              Text(
                                item.remarks!.trim(),
                                key: const ValueKey('detail-remarks'),
                                style: TextStyle(
                                  fontSize: AppType.body,
                                  fontWeight: FontWeight.w600,
                                  color: palette.accentInk,
                                  height: 1.3,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),

                  // 第二层：我看到哪了——信息用一块平面托起，只做提示，不伪装成正在播放
                  if (widget.lastWatched case final last?) ...[
                    const SizedBox(height: 14),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 8),
                      decoration: BoxDecoration(
                        color: palette.raised,
                        borderRadius: BorderRadius.circular(AppRadii.sm),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(top: 1),
                            child: Icon(Icons.history_rounded,
                                size: 14, color: palette.textSub),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              lastWatchedLabel(last),
                              key: const ValueKey('detail-last-watched'),
                              style: TextStyle(
                                fontSize: AppType.body,
                                color: palette.textMain,
                                height: 1.35,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 14),

                  // 第三层：演职员与简介
                  if (item.director?.trim().isNotEmpty ?? false) ...[
                    _CreditLine(label: '导演', value: item.director!.trim()),
                    const SizedBox(height: 6),
                  ],
                  if (item.actor?.trim().isNotEmpty ?? false) ...[
                    _CreditLine(label: '主演', value: item.actor!.trim()),
                    const SizedBox(height: 12),
                  ],
                  Text(
                    '剧情简介',
                    style: TextStyle(
                      fontSize: AppType.label,
                      fontWeight: FontWeight.w600,
                      color: palette.textTitle,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Expanded(
                    child: SingleChildScrollView(
                      child: Text(
                        (item.content?.isNotEmpty ?? false)
                            ? item.content!
                            : '暂无详细简介。',
                        style: TextStyle(
                          fontSize: AppType.body,
                          color: palette.textBody,
                          height: 1.6,
                        ),
                      ),
                    ),
                  ),
                  if (widget.onOpenUrl != null &&
                      localConfigCenterUrlOf(item.content) != null) ...[
                    const SizedBox(height: 10),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        key: const ValueKey('vod-open-config-center'),
                        onPressed: () => _openConfigCenter(
                            localConfigCenterUrlOf(item.content)!),
                        icon: const Icon(Icons.open_in_browser_rounded,
                            size: 18),
                        label: const Text('在本机打开配置页'),
                      ),
                    ),
                  ],
                ],
              ),
            ),

            const SizedBox(width: 20),
            VerticalDivider(color: palette.divider, width: 1),
            const SizedBox(width: 20),

            // ==================== 右侧：播放源与选集网格 ====================
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 顶部导航栏：图标 + 标题 + 收藏 + 关闭
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Text(
                        '选集播放',
                        style: TextStyle(
                          fontSize: AppType.heading,
                          fontWeight: FontWeight.bold,
                          color: palette.textTitle,
                        ),
                      ),
                      if (currentEpisodes.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        Text(
                          '共 ${currentEpisodes.length} 集',
                          key: const ValueKey('detail-episode-count'),
                          style: TextStyle(
                            fontSize: AppType.body,
                            color: palette.textSub,
                          ),
                        ),
                      ],
                      const Spacer(),

                      // §49 复制网盘分享链接（详情里有链接才显示）
                      if (_shareLinks.isNotEmpty)
                        _buildShareLinkButton(palette),

                      // 收藏按钮
                      if (widget.onToggleFavorite != null)
                        FocusOutline(
                          radius: AppRadii.pill,
                          child: IconButton(
                            icon: Icon(
                              _favorited
                                  ? Icons.star_rounded
                                  : Icons.star_outline_rounded,
                              color: _favorited
                                  ? palette.warning
                                  : palette.textSub,
                              size: 22,
                            ),
                            tooltip: _favorited ? '已收藏 (点击取消)' : '收藏影片',
                            onPressed: _favoriteBusy ? null : _toggleFavorite,
                          ),
                        ),
                      const SizedBox(width: 4),

                      // 关闭按钮
                      FocusOutline(
                        radius: AppRadii.pill,
                        child: IconButton(
                          icon: Icon(Icons.close_rounded,
                              color: palette.textSub, size: 20),
                          tooltip: '关闭',
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                      ),
                    ],
                  ),

                  // 错误提示条
                  if (_error != null)
                    Container(
                      key: const ValueKey('detail-favorite-error'),
                      width: double.infinity,
                      margin: const EdgeInsets.only(top: 8),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: palette.danger.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(AppRadii.sm),
                        border: Border.all(
                            color: palette.danger.withValues(alpha: 0.4)),
                      ),
                      child: Text(
                        _error!,
                        style: TextStyle(
                            color: palette.danger, fontSize: AppType.label),
                      ),
                    ),
                  const SizedBox(height: 10),

                  // 播放源切换横栏（Infuse 药丸胶囊）
                  if (sources.length > 1) ...[
                    SizedBox(
                      height: 34,
                      child: HorizontalScrollArea(
                        controller: _sourceScrollController,
                        child: ListView.separated(
                          controller: _sourceScrollController,
                          // 胶囊自带 onTap，与拖拽同处一个手势竞技场：
                          // 默认 DragStartBehavior.start 会丢掉接受前的位移。
                          dragStartBehavior: DragStartBehavior.down,
                          scrollDirection: Axis.horizontal,
                          itemCount: sources.length,
                          separatorBuilder: (_, __) => const SizedBox(width: 8),
                          itemBuilder: (context, index) {
                            return _SourcePill(
                              label: sources[index].name,
                              isSelected: index == _selectedSourceIndex,
                              onTap: () =>
                                  setState(() => _selectedSourceIndex = index),
                            );
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],

                  // 选集方糖微网格（Square Pill Grid）
                  Expanded(
                    child: currentEpisodes.isEmpty
                        ? Center(
                            child: Text('该播放源暂无选集',
                                style: TextStyle(color: palette.textDim)),
                          )
                        : GridView.builder(
                            key: const ValueKey('detail-episode-grid'),
                            gridDelegate:
                                const SliverGridDelegateWithMaxCrossAxisExtent(
                              // 右侧内容区约 495px：最多三列，让长集名保留两行，
                              // 也能随更窄的测试/未来布局自动降为两列。
                              maxCrossAxisExtent: 165,
                              mainAxisExtent: 58,
                              crossAxisSpacing: 8,
                              mainAxisSpacing: 8,
                            ),
                            itemCount: currentEpisodes.length,
                            itemBuilder: (context, epIdx) {
                              final ep = currentEpisodes[epIdx];
                              final sourceName = sources.isNotEmpty
                                  ? sources[_selectedSourceIndex].name
                                  : '';
                              return _EpisodeButton(
                                key: ValueKey('detail-episode-$epIdx'),
                                label: ep.name,
                                isCurrent: _isCurrent(epIdx, ep, sourceName),
                                onTap: () {
                                  Navigator.of(context).pop();
                                  widget.onPlayEpisode(
                                    EpisodeSelection(
                                      episode: ep,
                                      sourceName: sourceName,
                                      episodes: currentEpisodes,
                                      index: epIdx,
                                      sources: sources,
                                      sourceIndex: _selectedSourceIndex,
                                    ),
                                  );
                                },
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 演职员一行：弱化的栏目名 + 正文色内容。
class _CreditLine extends StatelessWidget {
  final String label;
  final String value;

  const _CreditLine({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Text.rich(
      TextSpan(children: [
        TextSpan(text: '$label  ', style: TextStyle(color: palette.textSub)),
        TextSpan(text: value, style: TextStyle(color: palette.textBody)),
      ]),
      style: const TextStyle(fontSize: AppType.body, height: 1.4),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// 播放源切换胶囊（Infuse 药丸微光）
class _SourcePill extends StatefulWidget {
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _SourcePill({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  State<_SourcePill> createState() => _SourcePillState();
}

class _SourcePillState extends State<_SourcePill> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final isSelected = widget.isSelected;
    final onAccent = Theme.of(context).colorScheme.onPrimary;

    return FocusRing(
      onTap: widget.onTap,
      semanticLabel: widget.label,
      borderRadius: const BorderRadius.all(Radius.circular(AppRadii.pill)),
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: _isHovered ? AppMotion.enter : AppMotion.exit,
            curve: AppMotion.ease,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: isSelected
                  ? palette.accent
                  : _isHovered
                      ? palette.accentWash
                      : palette.raised,
              borderRadius: BorderRadius.circular(AppRadii.pill),
              border: Border.all(
                color: isSelected
                    ? palette.accentInk.withValues(alpha: 0.6)
                    : _isHovered
                        ? palette.accentInk.withValues(alpha: 0.35)
                        : context.glassBorder,
                width: 1.0,
              ),
            ),
            alignment: Alignment.center,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 160),
              child: Text(
                widget.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: AppType.body,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                  color: isSelected
                      ? onAccent
                      : _isHovered
                          ? palette.textTitle
                          : palette.textSub,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 选集方糖微网格按钮（B4：OutlinedButton，悬停 / 聚焦统一 accentInk 1.5 描边）
///
/// §15：`isCurrent` 为真时叠加「当前集」选中态——实心 accent 底 + 播放图标 +
/// `Semantics(selected)`，不靠颜色单独表意（ui-ux-pro-max：compact control semantics）。
class _EpisodeButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final bool isCurrent;

  const _EpisodeButton({
    super.key,
    required this.label,
    required this.onTap,
    this.isCurrent = false,
  });

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final onAccent = Theme.of(context).colorScheme.onPrimary;

    // 用按钮而不是自绘容器：Tab 顺序、Enter / Space 与状态动画由 Material 负责，
    // 悬停 / 聚焦只是同一套状态解析（skill: focus-states / keyboard-nav）。
    final content = isCurrent
        ? Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.play_arrow_rounded, size: 14, color: onAccent),
              const SizedBox(width: 2),
              Flexible(
                child: Text(
                  label,
                  style: const TextStyle(
                    fontSize: AppType.body,
                    fontWeight: FontWeight.bold,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          )
        : Text(
            label,
            style: const TextStyle(
              fontSize: AppType.body,
              fontWeight: FontWeight.w500,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          );

    final button = OutlinedButton(
      style: OutlinedButton.styleFrom(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.sm),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 4),
      ).copyWith(
        side: WidgetStateProperty.resolveWith((states) {
          if (isCurrent) {
            return BorderSide(color: palette.accentInk, width: 1.5);
          }
          final active = states.contains(WidgetState.hovered) ||
              states.contains(WidgetState.focused);
          return active
              ? BorderSide(color: palette.accentInk, width: 1.5)
              : BorderSide(color: palette.borderStrong);
        }),
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (isCurrent) return palette.accent; // 选中态优先于悬停 / 聚焦
          return states.contains(WidgetState.hovered)
              ? palette.accentWash
              : palette.raised;
        }),
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          if (isCurrent) return onAccent;
          return states.contains(WidgetState.hovered)
              ? palette.textTitle
              : palette.textMain;
        }),
      ),
      onPressed: onTap,
      // 语义放在按钮内容里：OutlinedButton 会把子节点语义合并进自己的按钮节点，
      // 这样 selected 与可见的播放图标同源，读屏读到的是按钮本身。
      child: Semantics(selected: isCurrent, child: content),
    );

    final withFullLabel = Tooltip(message: label, child: button);
    if (!isCurrent) return withFullLabel;
    // 合并成一个语义节点：按钮 + 集名 + selected 一起播报（否则 selected 只落在文本子节点）。
    return MergeSemantics(
      child: Tooltip(message: '当前播放集：$label', child: button),
    );
  }
}
