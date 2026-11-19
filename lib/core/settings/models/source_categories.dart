/// 源分类目录：独立于源条目存在，迁移时保留旧名称（包括旧版特殊名称）。
class SourceCategories {
  static const reserved = {'全部', '未分类'};
  static const maxLength = 24;

  final List<String> names;

  SourceCategories([Iterable<String> names = const []])
      : names =
            List.unmodifiable(names.where((name) => name.isNotEmpty).toSet());

  static String validate(String input, {bool allowEmpty = false}) {
    final value = input.trim();
    if (value.isEmpty && !allowEmpty) {
      throw const FormatException('请输入分类名称');
    }
    if (value.runes.length > maxLength) {
      throw const FormatException('分类名称最多 24 个字符');
    }
    if (RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
      throw const FormatException('分类名称不能包含换行或控制字符');
    }
    if (reserved.contains(value)) {
      throw const FormatException('“全部”和“未分类”是保留名称：分别用于查看所有源和没有分类的源');
    }
    return value;
  }

  SourceCategories include(Iterable<String> values) =>
      SourceCategories([...names, ...values]);

  SourceCategories create(String input) {
    final value = validate(input);
    if (names.contains(value)) throw const FormatException('这个分类已存在');
    return include([value]);
  }

  /// 重命名一个已存在分类；与创建共用同一套名称规则。
  SourceCategories rename(String from, String input) {
    if (!names.contains(from)) {
      throw StateError('分类已不存在，请刷新后重试');
    }
    final value = validate(input);
    if (value == from) return this;
    if (names.contains(value)) throw const FormatException('这个分类已存在');
    return SourceCategories(names.map((name) => name == from ? value : name));
  }

  /// 删除分类目录项；条目归属由调用方在同一事务内迁移。
  SourceCategories remove(String name) =>
      SourceCategories(names.where((item) => item != name));

  factory SourceCategories.fromJson(Object? raw) {
    if (raw == null) return SourceCategories();
    if (raw is! List || raw.any((item) => item is! String)) {
      throw const FormatException('源分类目录格式无效');
    }
    return SourceCategories(raw.cast<String>());
  }
}
