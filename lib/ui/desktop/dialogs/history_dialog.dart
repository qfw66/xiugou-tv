import 'package:flutter/material.dart';
import '../../../core/config/models/history_record.dart';
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
    return Dialog(
      backgroundColor: const Color(0xFF181820),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Color(0xFF2E2E3C), width: 1),
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
                    color: const Color(0xFF282834),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.history_rounded, color: Color(0xFFE50914), size: 20),
                ),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '播放历史',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                    Text(
                      '共 ${records.length} 条观看记录',
                      style: const TextStyle(fontSize: 12, color: Color(0xFF888898)),
                    ),
                  ],
                ),
                const Spacer(),
                if (records.isNotEmpty)
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      foregroundColor: const Color(0xFFFF6B6B),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    ),
                    icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                    label: const Text('清空历史', style: TextStyle(fontSize: 13)),
                    onPressed: () {
                      showDialog(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          backgroundColor: const Color(0xFF22222C),
                          title: const Text('清空播放历史', style: TextStyle(color: Colors.white, fontSize: 16)),
                          content: const Text('确定要清空所有播放历史记录吗？', style: TextStyle(color: Color(0xFFB0B0C0), fontSize: 13)),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.of(ctx).pop(),
                              child: const Text('取消', style: TextStyle(color: Color(0xFF888898))),
                            ),
                            ElevatedButton(
                              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFE50914)),
                              onPressed: () {
                                Navigator.of(ctx).pop();
                                onClearAll();
                              },
                              child: const Text('确定清空', style: TextStyle(color: Colors.white)),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.close_rounded, color: Color(0xFFA0A0B0), size: 22),
                  onPressed: () => Navigator.of(context).pop(),
                  tooltip: '关闭',
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
                              color: const Color(0xFF22222E),
                              borderRadius: BorderRadius.circular(32),
                            ),
                            child: const Icon(Icons.history_toggle_off_rounded, size: 36, color: Color(0xFF5A5A6E)),
                          ),
                          const SizedBox(height: 12),
                          const Text('暂无播放历史记录', style: TextStyle(color: Color(0xFF888898), fontSize: 14)),
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
      rows.add(_SectionHeader(title: section.title, count: section.records.length));
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
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 8),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 14,
            decoration: BoxDecoration(
              color: const Color(0xFFE50914),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            title,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFFD0D0DC)),
          ),
          const SizedBox(width: 6),
          Text(
            '$count',
            style: const TextStyle(fontSize: 11, color: Color(0xFF6E6E80)),
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
    final record = widget.record;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: _isHovered ? const Color(0xFF22222E) : const Color(0xFF1B1B24),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: _isHovered ? const Color(0xFF3E3E52) : const Color(0xFF262634),
            width: 1,
          ),
        ),
        child: Row(
          children: [
            // 封面海报
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.network(
                record.vodPic,
                width: 44,
                height: 60,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(
                  width: 44,
                  height: 60,
                  color: const Color(0xFF2A2A38),
                  child: const Icon(Icons.movie_outlined, color: Color(0xFF686878), size: 20),
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
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xFF2C2C3C),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          record.episodeName,
                          style: const TextStyle(fontSize: 11, color: Color(0xFFE50914), fontWeight: FontWeight.bold),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '线路: ${record.sourceName}',
                        style: const TextStyle(fontSize: 11, color: Color(0xFF888898)),
                      ),
                      if (record.siteName != null && record.siteName!.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            record.siteName!,
                            style: const TextStyle(fontSize: 11, color: Color(0xFF888898)),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                      const SizedBox(width: 12),
                      Text(
                        widget.timeText,
                        style: const TextStyle(fontSize: 11, color: Color(0xFF6E6E80)),
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
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFE50914),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
              ),
              icon: const Icon(Icons.play_arrow_rounded, size: 18),
              label: const Text('继续观看', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
              onPressed: widget.onPlay,
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: const Icon(Icons.delete_outline_rounded, size: 18, color: Color(0xFF808092)),
              tooltip: '删除此记录',
              onPressed: widget.onDelete,
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
    if (!record.hasResumePosition) {
      return const Text(
        '尚未记录进度 · 从头开始播放',
        style: TextStyle(fontSize: 11, color: Color(0xFF6E6E80)),
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
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: record.progress,
              minHeight: 3,
              backgroundColor: const Color(0xFF2C2C3C),
              valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFFE50914)),
            ),
          ),
          const SizedBox(height: 4),
        ],
        Text(
          label,
          style: const TextStyle(fontSize: 11, color: Color(0xFF9A9AAE)),
        ),
      ],
    );
  }
}
