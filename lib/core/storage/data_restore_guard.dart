/// 恢复完成后置为 true，直到应用重启。
///
/// 恢复只改磁盘文件，运行中的仓库仍持有旧内存快照；若此时继续落盘，
/// 会把刚恢复的数据整体覆盖回旧值。置位后所有文件存储写入直接跳过，
/// 由用户重启应用从磁盘重新加载。
///
/// 行为约定（SET-10 / R-2）：
/// - 用户主动操作的写入（设置、收藏、直播源、首页站源）抛出
///   [DataRestorePendingRestartException]，由调用方提示「本次修改未保存」；
/// - 后台写入（播放历史、窗口状态、配置快照 current/cached）保持静默跳过，不打断播放；
///   配置源历史随「设置」路径抛出，因为它是用户在设置页的主动操作。
bool dataRestorePendingRestart = false;

/// 恢复后、重启前的写入被拒绝：消息可直接展示给用户。
class DataRestorePendingRestartException implements Exception {
  static const String messageText = '数据已恢复，请重启应用后再修改；本次修改未保存';

  const DataRestorePendingRestartException();

  String get message => messageText;

  @override
  String toString() => messageText;
}
