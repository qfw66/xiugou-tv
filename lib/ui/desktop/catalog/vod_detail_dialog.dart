import 'package:flutter/material.dart';
import '../../../core/api/models/vod_models.dart';

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
  String? _error;

  @override
  void initState() {
    super.initState();
    _favorited = widget.isFavorite;
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.detail.item;
    final sources = widget.detail.sources;
    final currentEpisodes = (sources.isNotEmpty && _selectedSourceIndex < sources.length)
        ? sources[_selectedSourceIndex].episodes
        : <VodEpisode>[];

    return Dialog(
      backgroundColor: const Color(0xFF1C1C24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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
                        borderRadius: BorderRadius.circular(8),
                        child: Image.network(
                          item.pic,
                          width: 100,
                          height: 140,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => Container(
                            width: 100,
                            height: 140,
                            color: const Color(0xFF282834),
                            child: const Icon(Icons.movie_outlined, color: Colors.grey),
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
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 6),
                            if (item.year != null || item.area != null)
                              Text(
                                '${item.year ?? ''}  ${item.area ?? ''}',
                                style: const TextStyle(fontSize: 12, color: Color(0xFFA0A0B0)),
                              ),
                            if (item.typeName != null) ...[
                              const SizedBox(height: 4),
                              Text(
                                item.typeName!,
                                style: const TextStyle(fontSize: 12, color: Color(0xFFE50914)),
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
                      style: const TextStyle(fontSize: 11, color: Color(0xFF9090A0)),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  const SizedBox(height: 8),
                  const Text('剧情简介:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white)),
                  const SizedBox(height: 4),
                  Expanded(
                    child: SingleChildScrollView(
                      child: Text(
                        (item.content?.isNotEmpty ?? false) ? item.content! : '暂无详细简介。',
                        style: const TextStyle(fontSize: 11, color: Color(0xFFB0B0C0), height: 1.4),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(width: 20),
            const VerticalDivider(color: Color(0xFF2E2E3C), width: 1),
            const SizedBox(width: 20),

            // 右侧：播放源切换与选集网格
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 顶部关闭按钮与标题
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        '选集播放',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                      ),
                      Row(
                        children: [
                          if (widget.onToggleFavorite != null)
                            IconButton(
                              icon: Icon(
                                _favorited ? Icons.star_rounded : Icons.star_outline_rounded,
                                color: _favorited ? const Color(0xFFFFB300) : const Color(0xFFA0A0B0),
                                size: 22,
                              ),
                              tooltip: _favorited ? '已收藏 (点击取消)' : '收藏影片',
                              onPressed: () async {
                                final previous = _favorited;
                                setState(() {
                                  _favorited = !previous;
                                  _error = null;
                                });
                                final message =
                                    await widget.onToggleFavorite!();
                                if (!mounted) return;
                                if (message != null) {
                                  // 保存失败：星标回退并在弹窗内提示，避免被遮挡。
                                  setState(() {
                                    _favorited = previous;
                                    _error = message;
                                  });
                                }
                              },
                            ),
                          IconButton(
                            icon: const Icon(Icons.close_rounded, color: Color(0xFFA0A0B0), size: 20),
                            onPressed: () => Navigator.of(context).pop(),
                          ),
                        ],
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
                        color: const Color(0xFF3A1F22),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFF7A2E34)),
                      ),
                      child: Text(
                        _error!,
                        style: const TextStyle(
                            color: Colors.orangeAccent, fontSize: 12.5),
                      ),
                    ),
                  const SizedBox(height: 8),

                  // 播放源切换标签
                  if (sources.length > 1)
                    SizedBox(
                      height: 34,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: sources.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 8),
                        itemBuilder: (context, index) {
                          final isSelected = index == _selectedSourceIndex;
                          return ChoiceChip(
                            label: Text(sources[index].name, style: const TextStyle(fontSize: 12)),
                            selected: isSelected,
                            selectedColor: const Color(0xFFE50914),
                            backgroundColor: const Color(0xFF282834),
                            labelStyle: TextStyle(
                              color: isSelected ? Colors.white : const Color(0xFFA0A0B0),
                              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                            ),
                            onSelected: (_) => setState(() => _selectedSourceIndex = index),
                          );
                        },
                      ),
                    ),
                  const SizedBox(height: 12),

                  // 选集按钮网格
                  Expanded(
                    child: currentEpisodes.isEmpty
                        ? const Center(
                            child: Text('该播放源暂无选集', style: TextStyle(color: Color(0xFF707080))),
                          )
                        : GridView.builder(
                            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
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
                                  backgroundColor: const Color(0xFF252530),
                                  foregroundColor: Colors.white,
                                  side: const BorderSide(color: Color(0xFF383848)),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                                  padding: EdgeInsets.zero,
                                ),
                                onPressed: () {
                                  Navigator.of(context).pop();
                                  final sourceName = sources.isNotEmpty ? sources[_selectedSourceIndex].name : '';
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
                                  style: const TextStyle(fontSize: 12),
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
