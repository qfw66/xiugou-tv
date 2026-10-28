/// 聚合搜索的取消令牌。
///
/// 为什么需要：`StreamSubscription.cancel()` 只能停止**接收**批次，底层站源请求
/// 仍会继续跑——用户点了搜索框的叉，几十个站源还在后台检索、继续打日志、继续占
/// 带宽与 CPU。令牌把「取消」一路传到底层：
///
/// - `SearchEngine` 在发出下一批前检查，取消后立即结束并丢弃在途结果；
/// - CMS 站源把它桥接成 Dio `CancelToken`，**在途 HTTP 请求会被真正中止**；
/// - 伴随（Spider）站源除了断掉本地 RPC 连接，还会按 `rpcId` 通知 companion
///   调 `Call.cancel()`，把 jar 内部正在阻塞的那次网络请求一起中止，
///   以免 worker 继续占着线程池槽位（见 `CallRegistry`）。
class SearchCancelToken {
  bool _cancelled = false;
  final List<void Function()> _listeners = <void Function()>[];

  bool get isCancelled => _cancelled;

  /// 取消（幂等）：监听者只触发一次，之后注册的回调会立即执行。
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    final listeners = List<void Function()>.of(_listeners);
    _listeners.clear();
    for (final listener in listeners) {
      listener();
    }
  }

  /// 注册取消回调；若已取消则立即执行一次。
  void onCancel(void Function() listener) {
    if (_cancelled) {
      listener();
      return;
    }
    _listeners.add(listener);
  }
}
