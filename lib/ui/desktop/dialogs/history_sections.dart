import '../../../core/config/models/history_record.dart';

/// 历史记录按日期分组后的一个区块
class HistorySection {
  final String title;
  final List<HistoryRecord> records;

  const HistorySection({required this.title, required this.records});
}

/// 将历史记录按「今天 / 昨天 / 本周 / 更早」分组（保持每组内部原有顺序，空组不输出）。
///
/// [now] 可注入以便测试；「本周」指最近 7 天内、且不属于今天 / 昨天的记录。
List<HistorySection> groupHistoryRecords(List<HistoryRecord> records, {DateTime? now}) {
  final current = now ?? DateTime.now();
  final todayStart = DateTime(current.year, current.month, current.day);
  final yesterdayStart = todayStart.subtract(const Duration(days: 1));
  final weekStart = todayStart.subtract(const Duration(days: 6));

  final today = <HistoryRecord>[];
  final yesterday = <HistoryRecord>[];
  final thisWeek = <HistoryRecord>[];
  final earlier = <HistoryRecord>[];

  for (final record in records) {
    final time = DateTime.fromMillisecondsSinceEpoch(record.timestamp);
    if (!time.isBefore(todayStart)) {
      today.add(record);
    } else if (!time.isBefore(yesterdayStart)) {
      yesterday.add(record);
    } else if (!time.isBefore(weekStart)) {
      thisWeek.add(record);
    } else {
      earlier.add(record);
    }
  }

  return [
    if (today.isNotEmpty) HistorySection(title: '今天', records: today),
    if (yesterday.isNotEmpty) HistorySection(title: '昨天', records: yesterday),
    if (thisWeek.isNotEmpty) HistorySection(title: '本周', records: thisWeek),
    if (earlier.isNotEmpty) HistorySection(title: '更早', records: earlier),
  ];
}

/// 将毫秒时长格式化为 `H:MM:SS` 或 `MM:SS`
String formatPlaybackTime(int milliseconds) {
  final totalSeconds = milliseconds <= 0 ? 0 : milliseconds ~/ 1000;
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  final mm = minutes.toString().padLeft(2, '0');
  final ss = seconds.toString().padLeft(2, '0');
  return hours > 0 ? '$hours:$mm:$ss' : '$mm:$ss';
}
