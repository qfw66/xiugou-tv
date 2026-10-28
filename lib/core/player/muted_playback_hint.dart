/// 静音起播提醒的去重器（§36 / §36-R）。
///
/// 口径（2026-10-26 用户确认）：**每部影片**播放时只要是静音状态都要提醒一次；
/// 同一部影片内切集 / 暂停继续 / 拖动不再重复打扰。
///
/// 因此去重键是「影片身份」而不是播放器实例：
/// - 取播放地址 + 标题（同一部片不同集地址不同，但用户视角仍是同一部片，所以只用
///   地址会在换集时重复弹 —— 这里优先用**标题**，拿不到标题才退回地址）；
/// - 记录保留最近 [capacity] 条，长会话里不会无限增长。
class MutedPlaybackHintRegistry {
  MutedPlaybackHintRegistry({this.capacity = 64});

  final int capacity;
  final List<String> _order = <String>[];
  final Set<String> _seen = <String>{};

  /// 该影片是否已经提醒过。
  bool alreadyHinted(String specKey) => _seen.contains(specKey);

  /// 登记一次提醒；返回 true 表示「本次应该真的弹出来」。
  bool shouldHint(String specKey) {
    if (specKey.isEmpty) return false;
    if (_seen.contains(specKey)) return false;
    if (_order.length >= capacity) {
      final oldest = _order.removeAt(0);
      _seen.remove(oldest);
    }
    _order.add(specKey);
    _seen.add(specKey);
    return true;
  }

  /// 仅供测试：清空记录。
  void clear() {
    _order.clear();
    _seen.clear();
  }

  /// 由播放规格推出「影片身份」。
  ///
  /// 优先标题：换集时地址会变但标题不变，用户会认为还是同一部片。
  static String keyFor({String? title, String? url}) {
    final t = (title ?? '').trim();
    if (t.isNotEmpty) return 't:$t';
    final u = (url ?? '').trim();
    if (u.isNotEmpty) return 'u:$u';
    return '';
  }
}
