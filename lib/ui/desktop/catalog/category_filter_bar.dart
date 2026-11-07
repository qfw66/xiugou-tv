/// 分类页筛选条：站源 `homeContent` 声明了 `filters` 时，在分类条下方按「每个 key 一行」
/// 列出胶囊选项（待办第 20 条，方案见 docs/SOURCE_FILTERS_PLAN.md）。
///
/// 选择语义对齐 FongMi：单 key 单选，再点取消；未选的 key 不进 extend。
/// 进入分类时一律未选——站源首项的 `v` 绝大多数非空（样本 535 / 575），
/// 若默认选中首项并下发，一进页面就会被隐性过滤。为此每行都有一个「默认项」：
/// 站源自带的「全部 / 不限」或空值项直接充当；没有时在行首补一个本地项，
/// 排序类叫「默认」，其余叫「全部」。默认项高亮即表示该 key 不下发。
///
/// 组件本身无业务状态：选择与折叠由调用方持有，这里只负责呈现与回调。
/// 筛选行默认收起，进入时是否展开由设置「分类页筛选条默认展开」决定。
library;

import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../core/api/models/vod_models.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';
import '../widgets/filter_pill.dart';
import '../widgets/focus_ring.dart';
import '../widgets/horizontal_scroll_area.dart';

/// 一行筛选的展示模型：[options] 已含默认项，[defaultIndex] 指向它。
class FilterRowModel {
  final VodFilter filter;
  final List<VodFilterOption> options;
  final int defaultIndex;

  const FilterRowModel._(this.filter, this.options, this.defaultIndex);

  /// 按默认项规则构建一行（见库注释）。
  factory FilterRowModel.of(VodFilter filter) {
    final first = filter.options.first;
    if (isDefaultFilterOption(first)) {
      return FilterRowModel._(filter, filter.options, 0);
    }
    final label = isSortFilter(filter) ? '默认' : '全部';
    return FilterRowModel._(
      filter,
      List.unmodifiable(
          [VodFilterOption(name: label, value: ''), ...filter.options]),
      0,
    );
  }

  /// 当前选择下高亮的选项下标：未选（或选值已不在选项里）时落在默认项。
  int selectedIndex(Map<String, String> selection) {
    final value = selection[filter.key];
    if (value == null) return defaultIndex;
    for (var i = 0; i < options.length; i++) {
      if (i != defaultIndex && options[i].value == value) return i;
    }
    return defaultIndex;
  }
}

/// 站源自带的默认项：值为空，或名称就是「全部 / 不限」。
bool isDefaultFilterOption(VodFilterOption option) {
  if (option.value.trim().isEmpty) return true;
  final name = option.name.trim();
  return name == '全部' || name == '不限';
}

/// 排序类筛选（补的默认项叫「默认」而不是「全部」）。
bool isSortFilter(VodFilter filter) {
  final key = filter.key.toLowerCase();
  return key == 'order' ||
      key == 'sort' ||
      key == 'by' ||
      filter.name.contains('排序');
}

/// 点选一个选项后的新选择：点默认项、空值项或已选项都回到未选（该 key 移除）。
Map<String, String> applyFilterSelection(
  Map<String, String> selection,
  FilterRowModel row,
  int index,
) {
  final next = Map<String, String>.of(selection);
  final option = row.options[index];
  final alreadySelected =
      index != row.defaultIndex && row.selectedIndex(selection) == index;
  if (index == row.defaultIndex ||
      option.value.isEmpty ||
      alreadySelected) {
    next.remove(row.filter.key);
  } else {
    next[row.filter.key] = option.value;
  }
  return next;
}

/// 只保留当前分类筛选组里存在的 key：站源改了选项后，旧值不该变成看不见的隐性过滤。
Map<String, String> sanitizeFilterSelection(
  Map<String, String> selection,
  List<VodFilter> filters,
) {
  if (selection.isEmpty) return const {};
  final result = <String, String>{};
  for (final filter in filters) {
    final row = FilterRowModel.of(filter);
    final value = selection[filter.key];
    if (value == null) continue;
    if (row.selectedIndex(selection) != row.defaultIndex) {
      result[filter.key] = value;
    }
  }
  return result;
}

/// 筛选条件指纹：按 key 排序后的 JSON，key 顺序不同结果相同；无条件时为空串。
String filterSelectionFingerprint(Map<String, String> selection) {
  if (selection.isEmpty) return '';
  final keys = selection.keys.toList()..sort();
  return jsonEncode({for (final key in keys) key: selection[key]});
}

/// 已选条件的摘要（按筛选组顺序，如「动作片 · 2024」）；未选时为空串。
String filterSelectionSummary(
  List<VodFilter> filters,
  Map<String, String> selection,
) {
  final names = <String>[];
  for (final filter in filters) {
    final row = FilterRowModel.of(filter);
    final index = row.selectedIndex(selection);
    if (index != row.defaultIndex) names.add(row.options[index].name);
  }
  return names.join(' · ');
}

/// 分类条右侧的折叠开关：展开时显示「筛选 N ▴」，折叠时附已选摘要。
class CategoryFilterToggle extends StatelessWidget {
  final List<VodFilter> filters;
  final Map<String, String> selection;
  final bool expanded;
  final VoidCallback onToggle;

  const CategoryFilterToggle({
    super.key,
    required this.filters,
    required this.selection,
    required this.expanded,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final count = sanitizeFilterSelection(selection, filters).length;
    final summary = filterSelectionSummary(filters, selection);
    final label = StringBuffer('筛选');
    if (count > 0) label.write(' $count');
    if (!expanded && summary.isNotEmpty) label.write('：$summary');
    final active = count > 0;
    return FocusRing(
      onTap: onToggle,
      semanticLabel: expanded ? '收起筛选' : '展开筛选',
      borderRadius: const BorderRadius.all(Radius.circular(AppRadii.pill)),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          key: const ValueKey('category-filter-toggle'),
          onTap: onToggle,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: active ? palette.accentWash : palette.card,
              borderRadius: BorderRadius.circular(AppRadii.pill),
              border: Border.all(
                color: active
                    ? palette.accentInk.withValues(alpha: 0.45)
                    : context.glassBorder,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.tune_rounded,
                    size: 14,
                    color: active ? palette.accentInk : palette.textSub),
                const SizedBox(width: 6),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 260),
                  child: Text(
                    label.toString(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppType.body,
                      fontWeight: FontWeight.w600,
                      color: active ? palette.accentInk : palette.textBody,
                    ),
                  ),
                ),
                const SizedBox(width: 2),
                Icon(
                  expanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  size: 16,
                  color: palette.textSub,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 展开态的筛选行：每个 key 一行，行内横向滚动（选项懒构建，198 项也只建可见部分）。
class CategoryFilterBar extends StatelessWidget {
  final List<VodFilter> filters;
  final Map<String, String> selection;

  /// 用户点了某行的某个选项；参数为点选后的完整新选择。
  final ValueChanged<Map<String, String>> onChanged;

  const CategoryFilterBar({
    super.key,
    required this.filters,
    required this.selection,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    if (filters.isEmpty) return const SizedBox.shrink();
    return Column(
      key: const ValueKey('category-filter-bar'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final filter in filters)
          _FilterRow(
            key: ValueKey('category-filter-row-${filter.key}'),
            row: FilterRowModel.of(filter),
            selection: selection,
            onChanged: onChanged,
          ),
      ],
    );
  }
}

class _FilterRow extends StatefulWidget {
  final FilterRowModel row;
  final Map<String, String> selection;
  final ValueChanged<Map<String, String>> onChanged;

  const _FilterRow({
    super.key,
    required this.row,
    required this.selection,
    required this.onChanged,
  });

  @override
  State<_FilterRow> createState() => _FilterRowState();
}

class _FilterRowState extends State<_FilterRow> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    final selected = row.selectedIndex(widget.selection);
    return SizedBox(
      height: 36,
      child: Row(
        children: [
          SizedBox(
            width: 52,
            child: Text(
              row.filter.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: AppType.body,
                fontWeight: FontWeight.w600,
                color: context.palette.textSub,
              ),
            ),
          ),
          Expanded(
            child: HorizontalScrollArea(
              controller: _controller,
              child: ListView.separated(
                controller: _controller,
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(vertical: 3),
                itemCount: row.options.length,
                separatorBuilder: (_, __) => const SizedBox(width: 6),
                itemBuilder: (context, index) => FilterPill(
                  key: ValueKey('category-filter-${row.filter.key}-$index'),
                  label: row.options[index].name,
                  isSelected: index == selected,
                  onTap: () => widget.onChanged(
                      applyFilterSelection(widget.selection, row, index)),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
