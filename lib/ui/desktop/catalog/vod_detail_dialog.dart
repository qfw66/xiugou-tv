import 'package:flutter/material.dart';
import '../../../core/api/models/vod_models.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';
import '../widgets/focus_ring.dart';

/// 详情页选集的完整选择上下文（把同站全部线路带进播放会话）。
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

/// 桌面端影视详情与多源选集弹窗（Infuse × Netflix 沉浸大画幅风格）。
class VodDetailDialog extends StatefulWidget {
  final VodDetail detail;
  final PlayEpisodeCallback onPlayEpisode;
  final bool isFavorite;
  final Future<String?> Function()? onToggleFavorite;

  /// 当前播放集；为 `null` 时与改动前完全一致（普通浏览零高亮）。
  final CurrentEpisode? currentEpisode;

  const VodDetailDialog({
    super.key,
    required this.detail,
    required this.onPlayEpisode,
    this.isFavorite = false,
    this.onToggleFavorite,
    this.currentEpisode,
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
    _selectedSourceIndex = _initialSourceIndex();
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

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
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
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 大画幅景深海报
                      Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(AppRadii.md),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.35),
                              blurRadius: 14,
                              offset: const Offset(0, 5),
                            ),
                          ],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(AppRadii.md),
                          child: Image.network(
                            item.pic,
                            cacheWidth: 320,
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

                      // 右侧标题与元数据胶囊
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
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 10),

                            // 年份与地区磨砂标签
                            if (item.year != null || item.area != null) ...[
                              Wrap(
                                spacing: 6,
                                runSpacing: 4,
                                children: [
                                  if (item.year != null &&
                                      item.year!.isNotEmpty)
                                    _MetaBadge(text: item.year!),
                                  if (item.area != null &&
                                      item.area!.isNotEmpty)
                                    _MetaBadge(text: item.area!),
                                ],
                              ),
                              const SizedBox(height: 8),
                            ],

                            // 分类标签
                            if (item.typeName != null &&
                                item.typeName!.isNotEmpty)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: palette.accentWash,
                                  borderRadius:
                                      BorderRadius.circular(AppRadii.xs),
                                  border: Border.all(
                                    color: palette.accentInk
                                        .withValues(alpha: 0.3),
                                    width: 0.8,
                                  ),
                                ),
                                child: Text(
                                  item.typeName!,
                                  style: TextStyle(
                                    fontSize: AppType.caption,
                                    fontWeight: FontWeight.w600,
                                    color: palette.accentInk,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // 主演信息
                  if (item.actor != null && item.actor!.isNotEmpty) ...[
                    Text(
                      '主演: ${item.actor}',
                      style: TextStyle(
                        fontSize: AppType.caption,
                        color: palette.textSub,
                        height: 1.3,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 10),
                  ],

                  // 剧情简介
                  Text(
                    '剧情简介',
                    style: TextStyle(
                      fontSize: AppType.body,
                      fontWeight: FontWeight.bold,
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
                          fontSize: AppType.caption,
                          color: palette.textBody,
                          height: 1.5,
                        ),
                      ),
                    ),
                  ),
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
                    children: [
                      Container(
                        padding: const EdgeInsets.all(7),
                        decoration: BoxDecoration(
                          color: palette.accentWash,
                          borderRadius: BorderRadius.circular(AppRadii.sm),
                          border: Border.all(
                            color: palette.accentInk.withValues(alpha: 0.3),
                            width: 0.8,
                          ),
                        ),
                        child: Icon(Icons.play_circle_fill_rounded,
                            color: palette.accentInk, size: 18),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        '选集播放',
                        style: TextStyle(
                          fontSize: AppType.heading,
                          fontWeight: FontWeight.bold,
                          color: palette.textTitle,
                        ),
                      ),
                      const Spacer(),

                      // 收藏按钮
                      if (widget.onToggleFavorite != null)
                        FocusRing(
                          onTap: () {},
                          semanticLabel: '收藏',
                          borderRadius: const BorderRadius.all(
                              Radius.circular(AppRadii.pill)),
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
                                        _favorited = previous;
                                        _error = message;
                                      }
                                    });
                                  },
                          ),
                        ),
                      const SizedBox(width: 4),

                      // 关闭按钮
                      FocusRing(
                        onTap: () => Navigator.of(context).pop(),
                        semanticLabel: '关闭',
                        borderRadius: const BorderRadius.all(
                            Radius.circular(AppRadii.pill)),
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
                  ],

                  // 选集方糖微网格（Square Pill Grid）
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
                              childAspectRatio: 2.3,
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

/// 元数据磨砂小标签（如年份、地区）
class _MetaBadge extends StatelessWidget {
  final String text;

  const _MetaBadge({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
      decoration: BoxDecoration(
        color: context.palette.raised,
        borderRadius: BorderRadius.circular(AppRadii.xs),
        border: Border.all(color: context.glassBorder, width: 0.8),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: AppType.caption,
          color: context.palette.textSub,
          fontWeight: FontWeight.w500,
        ),
      ),
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
              boxShadow: isSelected
                  ? [
                      BoxShadow(
                        color: palette.accentInk.withValues(alpha: 0.20),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ]
                  : null,
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
              Icon(Icons.play_arrow_rounded, size: 12, color: onAccent),
              const SizedBox(width: 2),
              Flexible(
                child: Text(
                  label,
                  style: const TextStyle(
                    fontSize: AppType.body,
                    fontWeight: FontWeight.bold,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
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
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
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

    if (!isCurrent) return button;
    // 合并成一个语义节点：按钮 + 集名 + selected 一起播报（否则 selected 只落在文本子节点）。
    return MergeSemantics(child: Tooltip(message: '当前播放集', child: button));
  }
}
