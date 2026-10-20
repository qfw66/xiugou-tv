import 'package:flutter/material.dart';
import '../../../core/config/models/history_record.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';
import '../widgets/focus_ring.dart';
import 'history_sections.dart';

/// 播放历史记录弹窗
///
/// 纯展示组件：列表按「今天 / 昨天 / 本周 / 更早」分组，每条记录展示观看进度条与续播位置；
/// 数据由调用方注入（通常经 `Consumer` 监听 historyProvider，实现删除 / 进度更新后实时刷新）。
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
    final palette = AppPalette.of(context);
    return Dialog(
      backgroundColor: palette.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.lg),
        side: BorderSide(color: palette.borderStrong, width: 1),
      ),
      child: Container(
        width: 760,
        height: 560,
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 头部标题与操作按钮
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: palette.raised,
                    borderRadius: BorderRadius.circular(AppRadii.md),
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
                          color: palette.textTitle),
                    ),
                    Text(
                      '共 ${records.length} 条观看记录',
                      style: TextStyle(
                          fontSize: AppType.body, color: palette.textSub),
                    ),
                  ],
                ),
                const Spacer(),
                if (records.isNotEmpty)
                  FocusOutline(
                    radius: AppRadii.pill,
                    child: TextButton.icon(
                      style: TextButton.styleFrom(
                        foregroundColor: palette.danger,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                      ),
                      icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                      label: const Text('清空历史',
                          style: TextStyle(fontSize: AppType.label)),
                      onPressed: () {
                        showDialog(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            backgroundColor: palette.card,
                            title: Text('清空播放历史',
                                style: TextStyle(
                                    color: palette.textTitle,
                                    fontSize: AppType.heading)),
                            content: Text('确定要清空所有播放历史记录吗？',
                                style: TextStyle(
                                    color: palette.textBody,
                                    fontSize: AppType.label)),
                            actions: [
                              FocusOutline(
                                radius: AppRadii.pill,
                                child: TextButton(
                                  onPressed: () => Navigator.of(ctx).pop(),
                                  child: Text('取消',
                                      style: TextStyle(color: palette.textSub)),
                                ),
                              ),
                              FocusOutline(
                                radius: AppRadii.pill,
                                child: ElevatedButton(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: palette.accent,
                                    // 品牌底上必须显式前景 onPrimary：M3 默认前景是 primary=品牌色，会同色不可见
                                    foregroundColor:
                                        Theme.of(context).colorScheme.onPrimary,
                                  ),
                                  onPressed: () {
                                    Navigator.of(ctx).pop();
                                    onClearAll();
                                  },
                                  child: const Text('确定清空'),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                const SizedBox(width: 8),
                FocusOutline(
                  radius: AppRadii.pill,
                  child: IconButton(
                    icon: Icon(Icons.close_rounded,
                        color: palette.textBody, size: 22),
                    onPressed: () => Navigator.of(context).pop(),
                    tooltip: '关闭',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // 历史记录列表
            Expanded(
              child: records.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 64,
                            height: 64,
                            decoration: BoxDecoration(
                              color: palette.card,
                              borderRadius:
                                  BorderRadius.circular(AppRadii.pill),
                            ),
                            child: Icon(Icons.history_toggle_off_rounded,
                                size: 36, color: palette.textDim),
                          ),
                          const SizedBox(height: 12),
                          Text('暂无播放历史记录',
                              style: TextStyle(
                                  color: palette.textSub,
                                  fontSize: AppType.title)),
                        ],
                      ),
                    )
                  : _buildGroupedList(context),
            ),
          ],
        ),
      ),
    );
  }

  /// 按日期分组渲染：区块标题 + 该组内的记录卡片，展平到一个 ListView 中
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
    final palette = AppPalette.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 8),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 14,
            decoration: BoxDecoration(
              color: palette.accentInk,
              borderRadius: BorderRadius.circular(AppRadii.hairline),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            title,
            style: TextStyle(
                fontSize: AppType.label,
                fontWeight: FontWeight.bold,
                color: palette.textMain),
          ),
          const SizedBox(width: 6),
          Text(
            '$count',
            style: TextStyle(fontSize: AppType.caption, color: palette.textDim),
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
    final palette = AppPalette.of(context);
    final record = widget.record;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: AnimatedContainer(
        // 进 200 / 出 140（B4 与全站统一）
        duration: _isHovered ? AppMotion.enter : AppMotion.exit,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: _isHovered ? palette.hover : palette.card,
          borderRadius: BorderRadius.circular(AppRadii.md),
          border: Border.all(
            color: _isHovered ? palette.borderStrong : palette.border,
            width: 1,
          ),
        ),
        child: Row(
          children: [
            // 封面海报
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadii.sm),
              child: Image.network(
                record.vodPic,
                // ⑥ 内存批：44px 海报 ×2 DPR（与频道台标同口径 96）。
                cacheWidth: 96,
                width: 44,
                height: 60,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(
                  width: 44,
                  height: 60,
                  color: palette.raised,
                  child: Icon(Icons.movie_outlined,
                      color: palette.textDim, size: 20),
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
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: palette.raised,
                          borderRadius: BorderRadius.circular(AppRadii.xs),
                        ),
                        child: Text(
                          record.episodeName,
                          style: TextStyle(
                              fontSize: AppType.caption,
                              color: palette.accentInk,
                              fontWeight: FontWeight.bold),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '线路: ${record.sourceName}',
                        style: TextStyle(
                            fontSize: AppType.caption, color: palette.textSub),
                      ),
                      if (record.siteName != null &&
                          record.siteName!.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            record.siteName!,
                            style: TextStyle(
                                fontSize: AppType.caption,
                                color: palette.textSub),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                      const SizedBox(width: 12),
                      Text(
                        widget.timeText,
                        style: TextStyle(
                            fontSize: AppType.caption, color: palette.textDim),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _ProgressIndicator(record: record),
                ],
              ),
            ),
            const SizedBox(width: 12),

            // 播放与删除操作
            FocusOutline(
              radius: AppRadii.sm,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: palette.accent,
                  // 品牌底上必须显式前景 onPrimary：M3 默认前景是 primary=品牌色，会同色不可见
                  foregroundColor: Theme.of(context).colorScheme.onPrimary,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadii.sm)),
                ),
                icon: const Icon(Icons.play_arrow_rounded, size: 18),
                label: const Text('继续观看',
                    style: TextStyle(
                        fontSize: AppType.body, fontWeight: FontWeight.w600)),
                onPressed: widget.onPlay,
              ),
            ),
            const SizedBox(width: 8),
            FocusOutline(
              radius: AppRadii.pill,
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
    );
  }
}

/// 观看进度条 + 续播位置文案（如「已看 35% · 12:34 / 45:00」）
class _ProgressIndicator extends StatelessWidget {
  final HistoryRecord record;

  const _ProgressIndicator({required this.record});

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
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
        // 时长未知时不渲染进度条（不能用不确定态动画：无法体现比例且会持续重绘）
        if (hasDuration) ...[
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadii.hairline),
            child: LinearProgressIndicator(
              value: record.progress,
              minHeight: 3,
              backgroundColor: palette.raised,
              valueColor: AlwaysStoppedAnimation<Color>(palette.accentInk),
            ),
          ),
          const SizedBox(height: 4),
        ],
        Text(
          label,
          style: TextStyle(fontSize: AppType.caption, color: palette.textSub),
        ),
      ],
    );
  }
}
