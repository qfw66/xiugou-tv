import 'package:flutter/material.dart';
import '../../../core/api/models/vod_models.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';
import '../widgets/focus_ring.dart';

/// 详情页选集的完整选择上下文（SET-12：把同站全部线路带进播放会话）。
class EpisodeSelection {
  final VodEpisode episode;
  final String sourceName;
  final List<VodEpisode> episodes;
  final int index;
  final List<PlayFrom> sources;
  final int sourceIndex;

  const EpisodeSelection({
    required this.episode,
    required this.sourceName,
    required this.episodes,
    required this.index,
    required this.sources,
    required this.sourceIndex,
  });
}

/// 选集播放回调：携带当前播放源的剧集列表与索引，以及全部线路（供自动换线）。
typedef PlayEpisodeCallback = void Function(EpisodeSelection selection);

/// 桌面端影视详情与多源选集弹窗
class VodDetailDialog extends StatefulWidget {
  final VodDetail detail;
  final PlayEpisodeCallback onPlayEpisode;
  final bool isFavorite;
  final Future<String?> Function()? onToggleFavorite;

  const VodDetailDialog({
    super.key,
    required this.detail,
    required this.onPlayEpisode,
    this.isFavorite = false,
    this.onToggleFavorite,
  });

  @override
  State<VodDetailDialog> createState() => _VodDetailDialogState();
}

class _VodDetailDialogState extends State<VodDetailDialog> {
  int _selectedSourceIndex = 0;
  late bool _favorited;
  bool _favoriteBusy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _favorited = widget.isFavorite;
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final item = widget.detail.item;
    final sources = widget.detail.sources;
    final currentEpisodes =
        (sources.isNotEmpty && _selectedSourceIndex < sources.length)
            ? sources[_selectedSourceIndex].episodes
            : <VodEpisode>[];

    return Dialog(
      backgroundColor: palette.panel,
      // 与收藏 / 历史弹窗统一：lg 圆角 + borderStrong 描边（B4）
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.lg),
        side: BorderSide(color: palette.borderStrong, width: 1),
      ),
      child: Container(
        width: 820,
        height: 520,
        padding: const EdgeInsets.all(20),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 左侧：海报与影片详情说明
            SizedBox(
              width: 260,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(AppRadii.sm),
                        child: Image.network(
                          item.pic,
                          // ⑥ 内存批：100px 海报 ×2 DPR，避免原图全尺寸解码。
                          cacheWidth: 200,
                          width: 100,
                          height: 140,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => Container(
                            width: 100,
                            height: 140,
                            color: palette.raised,
                            child: Icon(Icons.movie_outlined,
                                color: palette.textDim),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item.name,
                              style: TextStyle(
                                fontSize: AppType.heading,
                                fontWeight: FontWeight.bold,
                                color: palette.textTitle,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 6),
                            if (item.year != null || item.area != null)
                              Text(
                                '${item.year ?? ''}  ${item.area ?? ''}',
                                style: TextStyle(
                                    fontSize: AppType.body,
                                    color: palette.textSub),
                              ),
                            if (item.typeName != null) ...[
                              const SizedBox(height: 4),
                              Text(
                                item.typeName!,
                                style: TextStyle(
                                    fontSize: AppType.body,
                                    color: palette.accentInk),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  if (item.actor != null && item.actor!.isNotEmpty)
                    Text(
                      '主演: ${item.actor}',
                      style: TextStyle(
                          fontSize: AppType.caption, color: palette.textSub),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  const SizedBox(height: 8),
                  Text('剧情简介:',
                      style: TextStyle(
                          fontSize: AppType.body,
                          fontWeight: FontWeight.bold,
                          color: palette.textTitle)),
                  const SizedBox(height: 4),
                  Expanded(
                    child: SingleChildScrollView(
                      child: Text(
                        (item.content?.isNotEmpty ?? false)
                            ? item.content!
                            : '暂无详细简介。',
                        style: TextStyle(
                            fontSize: AppType.caption,
                            color: palette.textBody,
                            height: 1.4),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(width: 20),
            VerticalDivider(color: palette.divider, width: 1),
            const SizedBox(width: 20),

            // 右侧：播放源切换与选集网格
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 顶部：图标块 + 标题 +（收藏 / 关闭）（与收藏 / 历史同一头部语言；B4）
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: palette.raised,
                          borderRadius: BorderRadius.circular(AppRadii.md),
                        ),
                        child: Icon(Icons.play_circle_outline_rounded,
                            color: palette.accentInk, size: 20),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        '选集播放',
                        style: TextStyle(
                            fontSize: AppType.heading,
                            fontWeight: FontWeight.bold,
                            color: palette.textTitle),
                      ),
                      const Spacer(),
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
                            // 异步期间禁用防连点（skill: loading-buttons；B4）
                            onPressed: _favoriteBusy
                                ? null
                                : () async {
                                    final previous = _favorited;
                                    setState(() {
                                      _favoriteBusy = true;
                                      _favorited = !previous;
                                      _error = null;
                                    });
                                    final message =
                                        await widget.onToggleFavorite!();
                                    if (!mounted) return;
                                    setState(() {
                                      _favoriteBusy = false;
                                      if (message != null) {
                                        // 保存失败：星标回退并在弹窗内提示，避免被遮挡。
                                        _favorited = previous;
                                        _error = message;
                                      }
                                    });
                                  },
                          ),
                        ),
                      FocusOutline(
                        radius: AppRadii.pill,
                        child: IconButton(
                          icon: Icon(Icons.close_rounded,
                              color: palette.textSub, size: 20),
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                      ),
                    ],
                  ),
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
                  const SizedBox(height: 8),

                  // 播放源切换标签（自绘胶囊：与左侧导航 / 搜索站点胶囊同一语言；B4）
                  if (sources.length > 1)
                    SizedBox(
                      height: 34,
                      child: ListView.separated(
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
                  const SizedBox(height: 12),

                  // 选集按钮网格
                  Expanded(
                    child: currentEpisodes.isEmpty
                        ? Center(
                            child: Text('该播放源暂无选集',
                                style: TextStyle(color: palette.textDim)),
                          )
                        : GridView.builder(
                            gridDelegate:
                                const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 5,
                              childAspectRatio: 2.2,
                              crossAxisSpacing: 8,
                              mainAxisSpacing: 8,
                            ),
                            itemCount: currentEpisodes.length,
                            itemBuilder: (context, epIdx) {
                              final ep = currentEpisodes[epIdx];
                              return OutlinedButton(
                                style: OutlinedButton.styleFrom(
                                  backgroundColor: palette.raised,
                                  foregroundColor: palette.textTitle,
                                  side: BorderSide(color: palette.borderStrong),
                                  shape: RoundedRectangleBorder(
                                      borderRadius:
                                          BorderRadius.circular(AppRadii.sm)),
                                  padding: EdgeInsets.zero,
                                ).copyWith(
                                  // 悬停 / 聚焦描边 accentInk（与网格卡同一语言；B4）
                                  side:
                                      WidgetStateProperty.resolveWith((states) {
                                    final active = states
                                            .contains(WidgetState.hovered) ||
                                        states.contains(WidgetState.focused);
                                    return BorderSide(
                                      color: active
                                          ? palette.accentInk
                                          : palette.borderStrong,
                                      width: active ? 1.5 : 1,
                                    );
                                  }),
                                ),
                                onPressed: () {
                                  Navigator.of(context).pop();
                                  final sourceName = sources.isNotEmpty
                                      ? sources[_selectedSourceIndex].name
                                      : '';
                                  // 携带当前源剧集列表与索引：播放内切集与选集共用同一链路
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
                                child: Text(
                                  ep.name,
                                  style:
                                      const TextStyle(fontSize: AppType.body),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
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

/// 播放源切换胶囊：视觉与左侧导航 / 搜索站点胶囊同一语言（B4）。
///
/// 选中态用品牌底 + onPrimary 保证对比与可辨（判据：选集选中态可辨）；
/// 悬停 / 聚焦时描 accentInk 边框，进 200 / 出 140。
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
    final palette = AppPalette.of(context);
    final isSelected = widget.isSelected;
    final onAccent = Theme.of(context).colorScheme.onPrimary;

    return FocusRing(
      onTap: widget.onTap,
      semanticLabel: widget.label,
      borderRadius: const BorderRadius.all(Radius.circular(AppRadii.md)),
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: _isHovered ? AppMotion.enter : AppMotion.exit,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: isSelected
                  ? palette.accent
                  : _isHovered
                      ? palette.borderStrong
                      : palette.raised,
              borderRadius: BorderRadius.circular(AppRadii.md),
              border: Border.all(
                color: isSelected
                    ? palette.accent
                    : _isHovered
                        ? palette.accentInk
                        : palette.border,
                width: 1,
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
