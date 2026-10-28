import 'package:flutter/material.dart';
import '../../../core/config/models/history_record.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';
import '../catalog/poster_image.dart';
import '../widgets/focus_ring.dart';
import 'history_sections.dart';

/// 播放历史记录弹窗（Infuse × Netflix 风格流媒体沉浸质感）。
///
/// 纯展示组件：列表按「今天 / 昨天 / 本周 / 更早」分组，每条记录展示细线发光进度条与续播位置。
class HistoryDialog extends StatelessWidget {
  final List<HistoryRecord> records;
  final ValueChanged<HistoryRecord> onPlayRecord;
  final ValueChanged<String> onDeleteRecord;
  final VoidCallback onClearAll;

  /// 分组所用的当前时间（可注入以便测试）
  final DateTime? now;

  const HistoryDialog({
    super.key,
    required this.records,
    required this.onPlayRecord,
    required this.onDeleteRecord,
    required this.onClearAll,
    this.now,
  });

  String _formatTime(int timestamp) {
    final current = now ?? DateTime.now();
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp);
    final diff = current.difference(date);

    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
    if (diff.inHours < 24) return '${diff.inHours} 小时前';
    if (diff.inDays < 7) return '${diff.inDays} 天前';
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    final dialog = Dialog(
      backgroundColor: palette.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.lg),
        side: BorderSide(color: context.glassBorder, width: 1.0),
      ),
      child: Container(
        width: 780,
        height: 580,
        decoration: BoxDecoration(
          color: palette.panel,
          borderRadius: BorderRadius.circular(AppRadii.lg),
          boxShadow: AppShadows.subtleDepth(),
        ),
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ==================== 头部标题与操作按钮 ====================
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: palette.accentWash,
                    borderRadius: BorderRadius.circular(AppRadii.sm),
                    border: Border.all(
                      color: palette.accentInk.withValues(alpha: 0.3),
                      width: 0.8,
                    ),
                  ),
                  child: Icon(Icons.history_rounded,
                      color: palette.accentInk, size: 20),
                ),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '播放历史',
                      style: TextStyle(
                        fontSize: AppType.h2,
                        fontWeight: FontWeight.bold,
                        color: palette.textTitle,
                      ),
                    ),
                    Text(
                      '共 ${records.length} 条观看记录',
                      style: TextStyle(
                        fontSize: AppType.caption,
                        color: palette.textSub,
                      ),
                    ),
                  ],
                ),
                const Spacer(),

                // 清空历史按钮（B6：TextButton + FocusOutline 叠画描边）
                if (records.isNotEmpty)
                  FocusOutline(
                    radius: AppRadii.pill,
                    child: TextButton(
                      style: TextButton.styleFrom(
                        foregroundColor: palette.danger,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                      ),
                      onPressed: () {
                        showDialog(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            backgroundColor: palette.card,
                            shape: RoundedRectangleBorder(
                              borderRadius:
                                  BorderRadius.circular(AppRadii.lg),
                              side: BorderSide(
                                  color: context.glassBorder, width: 1.0),
                            ),
                            title: Text('清空播放历史',
                                style: TextStyle(
                                    color: palette.textTitle,
                                    fontSize: AppType.heading,
                                    fontWeight: FontWeight.bold)),
                            content: Text('确定要清空所有播放历史记录吗？此操作不可撤销。',
                                style: TextStyle(
                                    color: palette.textBody,
                                    fontSize: AppType.label)),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.of(ctx).pop(),
                                child: Text('取消',
                                    style: TextStyle(color: palette.textSub)),
                              ),
                              ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: palette.danger,
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(
                                          AppRadii.pill)),
                                ),
                                onPressed: () {
                                  Navigator.of(ctx).pop();
                                  onClearAll();
                                },
                                child: const Text('确定清空'),
                              ),
                            ],
                          ),
                        );
                      },
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.delete_sweep_outlined, size: 18),
                          SizedBox(width: 8),
                          Text('清空历史',
                              style: TextStyle(fontSize: AppType.label)),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(width: 8),

                // 关闭按钮
                FocusRing(
                  onTap: () => Navigator.of(context).pop(),
                  semanticLabel: '关闭',
                  borderRadius:
                      const BorderRadius.all(Radius.circular(AppRadii.pill)),
                  child: IconButton(
                    icon: Icon(Icons.close_rounded,
                        color: palette.textSub, size: 20),
                    onPressed: () => Navigator.of(context).pop(),
                    tooltip: '关闭',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // ==================== 历史记录列表 ====================
            Expanded(
              child: records.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 72,
                            height: 72,
                            decoration: BoxDecoration(
                              color: palette.raised,
                              borderRadius:
                                  BorderRadius.circular(AppRadii.pill),
                              border: Border.all(
                                  color: context.glassBorder, width: 1.0),
                              boxShadow: AppShadows.subtleDepth(),
                            ),
                            child: Icon(Icons.history_toggle_off_rounded,
                                size: 36, color: palette.textDim),
                          ),
                          const SizedBox(height: 14),
                          Text('暂无播放历史记录',
                              style: TextStyle(
                                  color: palette.textTitle,
                                  fontSize: AppType.title,
                                  fontWeight: FontWeight.w600)),
                          const SizedBox(height: 6),
                          Text('观看影片后将自动记录播放进度',
                              style: TextStyle(
                                  color: palette.textSub,
                                  fontSize: AppType.caption)),
                        ],
                      ),
                    )
                  : _buildGroupedList(context),
            ),
          ],
        ),
      ),
    );

    // 窗口拖动只保留在窗口顶部那条带（§40-R3），面板内部不再接管拖动。
    return dialog;
  }

  /// 按日期分组渲染：区块标题 + 该组内的记录卡片
  Widget _buildGroupedList(BuildContext context) {
    final sections = groupHistoryRecords(records, now: now);
    final rows = <Widget>[];
    for (final section in sections) {
      rows.add(
          _SectionHeader(title: section.title, count: section.records.length));
      for (final record in section.records) {
        rows.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _HistoryCard(
              record: record,
              timeText: _formatTime(record.timestamp),
              onPlay: () {
                Navigator.of(context).pop();
                onPlayRecord(record);
              },
              onDelete: () => onDeleteRecord(record.id),
            ),
          ),
        );
      }
    }

    return ListView(children: rows);
  }
}

/// 日期分组标题（今天 / 昨天 / 本周 / 更早）
class _SectionHeader extends StatelessWidget {
  final String title;
  final int count;

  const _SectionHeader({required this.title, required this.count});

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 8),
      child: Row(
        children: [
          Container(
            width: 3.5,
            height: 14,
            decoration: BoxDecoration(
              color: palette.accentInk,
              borderRadius: BorderRadius.circular(AppRadii.pill),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            title,
            style: TextStyle(
              fontSize: AppType.label,
              fontWeight: FontWeight.bold,
              color: palette.textTitle,
            ),
          ),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: palette.raised,
              borderRadius: BorderRadius.circular(AppRadii.pill),
              border: Border.all(color: context.glassBorder, width: 0.8),
            ),
            child: Text(
              '$count',
              style: TextStyle(
                fontSize: AppType.caption,
                fontWeight: FontWeight.bold,
                fontFeatures: const [FontFeature.tabularFigures()],
                color: palette.textDim,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HistoryCard extends StatefulWidget {
  final HistoryRecord record;
  final String timeText;
  final VoidCallback onPlay;
  final VoidCallback onDelete;

  const _HistoryCard({
    required this.record,
    required this.timeText,
    required this.onPlay,
    required this.onDelete,
  });

  @override
  State<_HistoryCard> createState() => _HistoryCardState();
}

class _HistoryCardState extends State<_HistoryCard> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final record = widget.record;

    return FocusRing(
      onTap: widget.onPlay,
      semanticLabel: record.vodName,
      borderRadius: const BorderRadius.all(Radius.circular(AppRadii.md)),
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: GestureDetector(
          onTap: widget.onPlay,
          child: AnimatedContainer(
            duration: _isHovered ? AppMotion.enter : AppMotion.exit,
            curve: AppMotion.ease,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: _isHovered ? palette.accentWash : palette.card,
              borderRadius: BorderRadius.circular(AppRadii.md),
              border: Border.all(
                color: _isHovered
                    ? palette.accentInk.withValues(alpha: 0.45)
                    : context.glassBorder,
                width: 1.0,
              ),
              boxShadow: _isHovered
                  ? [
                      BoxShadow(
                        color: palette.accentInk.withValues(alpha: 0.12),
                        blurRadius: 10,
                        offset: const Offset(0, 3),
                      ),
                    ]
                  : null,
            ),
            child: Row(
              children: [
                // 封面海报（Netflix 风格微阴影海报）
                Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(AppRadii.sm),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.25),
                        blurRadius: 6,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(AppRadii.sm),
                    child: Image(
                      image: posterImageProvider(record.vodPic,
                              targetWidth: 120) ??
                          ResizeImage(NetworkImage(record.vodPic), width: 120),
                      width: 46,
                      height: 64,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                        width: 46,
                        height: 64,
                        color: palette.raised,
                        child: Icon(Icons.movie_outlined,
                            color: palette.textDim, size: 22),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 14),

                // 剧名与进度
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        record.vodName,
                        style: TextStyle(
                          fontSize: AppType.title,
                          fontWeight: FontWeight.bold,
                          color: palette.textTitle,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 5),

                      // 标签行（集数 + 线路 + 站点 + 时间）
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 1.5),
                            decoration: BoxDecoration(
                              color: palette.accentWash,
                              borderRadius:
                                  BorderRadius.circular(AppRadii.xs),
                              border: Border.all(
                                color: palette.accentInk.withValues(alpha: 0.3),
                                width: 0.8,
                              ),
                            ),
                            child: Text(
                              record.episodeName,
                              style: TextStyle(
                                fontSize: AppType.caption,
                                color: palette.accentInk,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '线路: ${record.sourceName}',
                            style: TextStyle(
                              fontSize: AppType.caption,
                              color: palette.textSub,
                            ),
                          ),
                          if (record.siteName != null &&
                              record.siteName!.isNotEmpty) ...[
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                record.siteName!,
                                style: TextStyle(
                                  fontSize: AppType.caption,
                                  color: palette.textSub,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                          const SizedBox(width: 10),
                          Text(
                            widget.timeText,
                            style: TextStyle(
                              fontSize: AppType.caption,
                              color: palette.textDim,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),

                      // 观看进度条
                      _ProgressIndicator(record: record),
                    ],
                  ),
                ),
                const SizedBox(width: 12),

                // 操作按钮组（胶囊形态）
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: palette.accent,
                    foregroundColor:
                        Theme.of(context).colorScheme.onPrimary,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 8),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppRadii.pill)),
                    elevation: 1,
                  ),
                  icon: const Icon(Icons.play_arrow_rounded, size: 18),
                  label: const Text('续播',
                      style: TextStyle(
                          fontSize: AppType.caption,
                          fontWeight: FontWeight.bold)),
                  onPressed: widget.onPlay,
                ),
                const SizedBox(width: 6),

                FocusRing(
                  onTap: widget.onDelete,
                  semanticLabel: '删除',
                  borderRadius:
                      const BorderRadius.all(Radius.circular(AppRadii.pill)),
                  child: IconButton(
                    icon: Icon(Icons.delete_outline_rounded,
                        size: 18, color: palette.textSub),
                    tooltip: '删除此记录',
                    onPressed: widget.onDelete,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 观看进度条 + 续播位置文案
class _ProgressIndicator extends StatelessWidget {
  final HistoryRecord record;

  const _ProgressIndicator({required this.record});

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    if (!record.hasResumePosition) {
      return Text(
        '尚未记录进度 · 从头开始播放',
        style: TextStyle(fontSize: AppType.caption, color: palette.textDim),
      );
    }

    final hasDuration = record.durationMs > 0;
    final percent = (record.progress * 100).round();
    final positionText = formatPlaybackTime(record.positionMs);
    final label = record.isFinished
        ? '已看完 · 从头开始播放'
        : hasDuration
            ? '已看 $percent% · $positionText / ${formatPlaybackTime(record.durationMs)}'
            : '上次看到 $positionText';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (hasDuration) ...[
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadii.pill),
            child: LinearProgressIndicator(
              value: record.progress,
              minHeight: 3.5,
              backgroundColor: palette.border,
              valueColor: AlwaysStoppedAnimation<Color>(palette.accentInk),
            ),
          ),
          const SizedBox(height: 5),
        ],
        Text(
          label,
          style: TextStyle(
            fontSize: AppType.caption,
            color: palette.textSub,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}
