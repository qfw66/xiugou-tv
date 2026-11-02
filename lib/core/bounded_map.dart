/// 有上限的 Map 写入：按插入顺序淘汰最早的项（Dart 默认 Map 保持插入顺序）。
///
/// 用于「只增不减」的内存缓存：键空间随用户浏览增长（分页、片单 id、异常首行），
/// 不设上限就会在长时间运行中持续上涨。重复写入同一键会把它移到最新位置。
extension BoundedMapPut<K, V> on Map<K, V> {
  void putBounded(K key, V value, int maxEntries) {
    remove(key);
    while (length >= maxEntries && isNotEmpty) {
      remove(keys.first);
    }
    this[key] = value;
  }
}
