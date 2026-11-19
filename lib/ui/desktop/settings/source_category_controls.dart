import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/settings/models/source_categories.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';
import '../dialogs/escape_closable.dart';
import '../dialogs/app_dialog.dart';

/// null 表示全部，空串表示未分类；空分类来自独立保存的目录。
class SourceCategoryRail extends StatefulWidget {
  final Iterable<String> categories;
  final Iterable<String> directory;
  final String? selected;
  final ValueChanged<String?> onSelected;
  final SourceCategoryController controller;
  final ValueChanged<String>? onRename;
  final ValueChanged<String>? onDelete;

  const SourceCategoryRail({
    super.key,
    required this.categories,
    required this.directory,
    required this.selected,
    required this.onSelected,
    required this.controller,
    this.onRename,
    this.onDelete,
  });

  @override
  State<SourceCategoryRail> createState() => _SourceCategoryRailState();
}

class _SourceCategoryRailState extends State<SourceCategoryRail> {
  final _scroll = ScrollController();
  bool _collapsed = false;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final counts = <String, int>{};
    var total = 0;
    for (final category in widget.categories) {
      counts.update(category, (count) => count + 1, ifAbsent: () => 1);
      total++;
    }
    final names = {...widget.directory, ...counts.keys}
        .where((name) => name.isNotEmpty)
        .toList()
      ..sort();
    Widget row(String? name, String label, int count) => _CategoryRailRow(
          // 系统行与名为 all / uncategorized 的用户分类仍是不同的行。
          key: ValueKey((name, name == null)),
          category: name,
          label: label,
          count: count,
          selected: widget.selected == name,
          controller: widget.controller,
          onSelected: () => widget.onSelected(name),
          onRename: widget.onRename == null || name == null
              ? null
              : () => widget.onRename!(name),
          onDelete: widget.onDelete == null || name == null
              ? null
              : () => widget.onDelete!(name),
        );
    if (_collapsed) {
      return SizedBox(
        key: const ValueKey('source-category-rail'),
        width: 44,
        child: Material(
          color: context.palette.card,
          child: Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: const EdgeInsets.only(top: AppSpacing.md),
              child: IconButton(
                key: const ValueKey('source-category-rail-expand'),
                tooltip: '展开分类栏',
                onPressed: () => setState(() => _collapsed = false),
                icon: const Icon(Icons.chevron_right_rounded),
                color: context.palette.textBody,
              ),
            ),
          ),
        ),
      );
    }
    return SizedBox(
      key: const ValueKey('source-category-rail'),
      width: 220,
      child: Material(
        color: context.palette.card,
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg, AppSpacing.md, AppSpacing.sm, AppSpacing.md),
            child: Row(children: [
              Expanded(
                  child: Text('分类',
                      style: TextStyle(
                          fontSize: AppType.title,
                          fontWeight: FontWeight.w600,
                          color: context.palette.textMain))),
              IconButton(
                key: const ValueKey('source-category-rail-collapse'),
                tooltip: '收起分类栏',
                onPressed: () => setState(() => _collapsed = true),
                icon: const Icon(Icons.chevron_left_rounded, size: 20),
                color: context.palette.textSub,
                visualDensity: VisualDensity.compact,
              ),
            ]),
          ),
          Expanded(
              child: Scrollbar(
            controller: _scroll,
            child: ListView(
              controller: _scroll,
              primary: false,
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
              children: [
                row(null, '全部', total),
                row('', '未分类', counts[''] ?? 0),
                for (final name in names)
                  row(
                      name,
                      SourceCategories.reserved.contains(name)
                          ? '$name（旧分类）'
                          : name,
                      counts[name] ?? 0),
              ],
            ),
          )),
          Divider(height: 1, color: context.palette.border),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.sm),
            child: TextButton.icon(
              key: const ValueKey('source-category-create'),
              onPressed: widget.controller.busy
                  ? null
                  : () => widget.controller.edit(context, create: true),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('新建分类'),
              style: TextButton.styleFrom(
                  foregroundColor: context.palette.accentInk),
            ),
          ),
        ]),
      ),
    );
  }
}

class _CategoryRailRow extends StatefulWidget {
  final String? category;
  final String label;
  final int count;
  final bool selected;
  final SourceCategoryController controller;
  final VoidCallback onSelected;
  final VoidCallback? onRename;
  final VoidCallback? onDelete;

  const _CategoryRailRow(
      {super.key,
      required this.category,
      required this.label,
      required this.count,
      required this.selected,
      required this.controller,
      required this.onSelected,
      this.onRename,
      this.onDelete});

  @override
  State<_CategoryRailRow> createState() => _CategoryRailRowState();
}

class _CategoryRailRowState extends State<_CategoryRailRow> {
  bool _hover = false;
  bool _focus = false;

  @override
  Widget build(BuildContext context) {
    final name = widget.category;
    final editable = name != null && name.isNotEmpty;
    final label = '${widget.label}（${widget.count}）';
    final keyName = name == null
        ? 'all'
        : name.isEmpty
            ? 'uncategorized'
            : const {'all', 'uncategorized'}.contains(name) ||
                    name.startsWith('name:')
                ? 'name:$name'
                : name;
    return DragTarget<SourceCategoryDrag>(
      // “全部”仅用于查看，不代表一个可写入的分类。
      onWillAcceptWithDetails: (details) =>
          name != null &&
          !widget.controller.busy &&
          identical(details.data.owner, widget.controller) &&
          details.data.locations.isNotEmpty,
      onAcceptWithDetails: (details) => unawaited(
          _moveToCategory(widget.controller, details.data.locations, name!)),
      builder: (context, candidates, rejected) => Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.xs),
        child: MouseRegion(
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: Focus(
            canRequestFocus: false,
            onFocusChange: (value) => setState(() => _focus = value),
            child: Material(
              color: candidates.isNotEmpty || widget.selected
                  ? context.palette.selectionFill
                  : Colors.transparent,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadii.sm),
                side: BorderSide(
                  color: candidates.isNotEmpty || _focus || widget.selected
                      ? context.palette.selectionInk
                      : Colors.transparent,
                  width: candidates.isNotEmpty || widget.selected ? 3 : 1,
                ),
              ),
              child: Row(children: [
                Expanded(
                    child: Tooltip(
                  message: label,
                  child: Semantics(
                    selected: widget.selected,
                    child: InkWell(
                      key: ValueKey('source-category-rail:$keyName'),
                      borderRadius: BorderRadius.circular(AppRadii.sm),
                      onTap: widget.controller.busy ? null : widget.onSelected,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.md, vertical: AppSpacing.md),
                        child: Row(children: [
                          SizedBox(
                            width: 20,
                            child: widget.selected
                                ? Icon(Icons.check_rounded,
                                    size: 16,
                                    color: context.palette.selectionInk)
                                : null,
                          ),
                          Expanded(
                              child: Text(widget.label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: AppType.label,
                                      fontWeight: widget.selected
                                          ? FontWeight.w600
                                          : FontWeight.normal,
                                      color: context.palette.textMain))),
                          Text('（${widget.count}）',
                              style: TextStyle(
                                  fontSize: AppType.body,
                                  color: context.palette.textBody)),
                        ]),
                      ),
                    ),
                  ),
                )),
                if (editable)
                  Opacity(
                    opacity: _hover || _focus ? 1 : 0,
                    child: PopupMenuButton<String>(
                      key: ValueKey('source-category-menu:$name'),
                      tooltip: '${widget.label}：分类操作',
                      enabled: !widget.controller.busy,
                      icon: Icon(Icons.more_horiz_rounded,
                          color: context.palette.textBody),
                      color: context.palette.raised,
                      onSelected: (action) => action == 'rename'
                          ? widget.onRename?.call()
                          : widget.onDelete?.call(),
                      itemBuilder: (_) => [
                        PopupMenuItem(
                            value: 'rename',
                            enabled: widget.onRename != null,
                            child: const Text('重命名')),
                        PopupMenuItem(
                            value: 'delete',
                            enabled: widget.onDelete != null,
                            child: const Text('删除分类')),
                      ],
                    ),
                  ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> _moveToCategory(SourceCategoryController controller,
    Iterable<String> locations, String category) async {
  await controller.assign(locations, category);
  if (!controller.failed) controller.clear();
}

class SourceCategoryBadge extends StatelessWidget {
  final String category;

  const SourceCategoryBadge({super.key, required this.category});

  @override
  Widget build(BuildContext context) {
    final label = category.isEmpty ? '未分类' : category;
    return Tooltip(
      message: '分类：$label',
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
        decoration: BoxDecoration(
          color: context.palette.accentWash,
          borderRadius: BorderRadius.circular(AppRadii.xs),
        ),
        child: Text(label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: AppType.caption, color: context.palette.textBody)),
      ),
    );
  }
}

class SourceCategoryDialog extends StatefulWidget {
  final String initialCategory;
  final Iterable<String> categories;
  final Future<void> Function(String category) onSave;
  final bool createOnly;
  final int? selectionCount;
  final String? title;
  final String? originalName;

  const SourceCategoryDialog({
    super.key,
    required this.initialCategory,
    required this.categories,
    required this.onSave,
    this.createOnly = false,
    this.selectionCount,
    this.title,
    this.originalName,
  });

  @override
  State<SourceCategoryDialog> createState() => _SourceCategoryDialogState();
}

class _SourceCategoryDialogState extends State<SourceCategoryDialog> {
  static const _maxLength = 24;
  late final _controller = TextEditingController(text: widget.initialCategory);
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save(String category) async {
    if (_saving) return;
    final String value;
    try {
      value =
          SourceCategories.validate(category, allowEmpty: !widget.createOnly);
      if (widget.createOnly &&
          value != widget.originalName &&
          widget.categories.contains(value)) {
        throw const FormatException('这个分类已存在');
      }
    } on FormatException catch (error) {
      setState(() => _error = error.message);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSave(value);
      if (!mounted) return;
      setState(() => _saving = false);
      Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = '分类保存失败，请重试：$error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final names = widget.categories
        .where((name) => name.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    return EscapeClosable(
      autofocus: false,
      child: PopScope(
        canPop: !_saving,
        child: AlertDialog(
          backgroundColor: context.palette.raised,
          scrollable: true,
          title: Text(
              widget.title ??
                  (widget.createOnly
                      ? widget.selectionCount == null
                          ? '新建分类'
                          : '新建并移入 ${widget.selectionCount} 项'
                      : widget.selectionCount == null
                          ? '设置分类'
                          : '分配 ${widget.selectionCount} 条源'),
              style: TextStyle(
                  fontSize: AppType.heading, color: context.palette.textTitle)),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  key: const ValueKey('source-category-input'),
                  controller: _controller,
                  autofocus: true,
                  enabled: !_saving,
                  maxLength: _maxLength,
                  maxLengthEnforcement: MaxLengthEnforcement.none,
                  style: TextStyle(
                      fontSize: AppType.label, color: context.palette.textMain),
                  decoration: InputDecoration(
                    labelText: '分类名称',
                    labelStyle: TextStyle(color: context.palette.textBody),
                    floatingLabelStyle:
                        TextStyle(color: context.palette.accentInk),
                    focusedBorder: UnderlineInputBorder(
                      borderSide: BorderSide(
                          color: context.palette.accentInk, width: 2),
                    ),
                    helperText: widget.originalName != null
                        ? '输入新的分类名称，该分类下的源会一起移动。“全部”和“未分类”为系统保留名称。'
                        : widget.createOnly
                            ? '空分类也会保留。“全部”用于查看所有源，“未分类”用于没有分类的源，两者为系统保留名称。'
                            : '输入新分类或选择已有分类；留空为未分类。“全部”和“未分类”为系统保留名称。',
                    helperMaxLines: 5,
                    errorText: _error,
                    errorMaxLines: 4,
                  ),
                  onChanged: (_) => setState(() => _error = null),
                  onSubmitted: _save,
                ),
                if (!widget.createOnly && names.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.md),
                  Text('已有分类',
                      style: TextStyle(
                          fontSize: AppType.body,
                          color: context.palette.textSub)),
                  const SizedBox(height: AppSpacing.sm),
                  Wrap(
                    spacing: AppSpacing.sm,
                    runSpacing: AppSpacing.sm,
                    children: [
                      for (final name in names)
                        ChoiceChip(
                          key: ValueKey('source-category-option:$name'),
                          label: Text(name,
                              maxLines: 2, overflow: TextOverflow.ellipsis),
                          tooltip: name,
                          selected: _controller.text.trim() == name,
                          selectedColor: context.palette.accentWash,
                          backgroundColor: context.palette.card,
                          labelStyle: TextStyle(
                              fontSize: AppType.body,
                              color: context.palette.textMain),
                          onSelected: _saving
                              ? null
                              : (_) => setState(() {
                                    _controller.text = name;
                                    _error = null;
                                  }),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          actions: [
            if (!widget.createOnly)
              TextButton(
                onPressed: _saving ? null : () => _save(''),
                child: const Text('清空分类'),
              ),
            TextButton(
              onPressed: _saving ? null : () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: _saving ? null : () => _save(_controller.text),
              child: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 两个管理面板共用选择状态；地址是稳定标识，筛选改变时清空选择。
class SourceCategoryController extends ChangeNotifier {
  final Future<void> Function(Iterable<String>, String) saveAssignment;
  final Future<void> Function(String) saveCategory;
  final Iterable<String> Function() categories;
  final Set<String> selected = {};
  bool busy = false;
  bool failed = false;
  bool _closed = false;
  String? status;

  SourceCategoryController(
      {required this.saveAssignment,
      required this.saveCategory,
      required this.categories});

  void _changed() {
    if (!_closed) notifyListeners();
  }

  void toggle(String location) {
    if (busy) return;
    if (!selected.remove(location)) selected.add(location);
    _changed();
  }

  void clear() {
    selected.clear();
    _changed();
  }

  void selectVisible(Iterable<String> locations, bool value) {
    if (busy) return;
    value ? selected.addAll(locations) : selected.removeAll(locations);
    _changed();
  }

  Future<void> _save(Future<void> Function() task, String success,
      {bool rethrowError = false}) async {
    if (busy) return;
    busy = true;
    failed = false;
    status = '正在保存分类…';
    _changed();
    try {
      await task();
      status = success;
    } catch (error) {
      failed = true;
      status = '分类未保存，原分类保持不变。请重试：$error';
      if (rethrowError) rethrow;
    } finally {
      busy = false;
      _changed();
    }
  }

  Future<void> assign(Iterable<String> locations, String category,
      {bool rethrowError = false}) {
    final ids = Set<String>.of(locations);
    return _save(() async {
      await saveAssignment(ids, category);
      selected.removeAll(ids);
    }, '已保存：${ids.length} 条源已分配到「${category.isEmpty ? '未分类' : category.trim()}」',
        rethrowError: rethrowError);
  }

  Future<void> edit(BuildContext context,
      {String? location, String initial = '', bool create = false}) async {
    if (busy) return;
    final ids = location == null ? Set<String>.of(selected) : {location};
    if (!create && ids.isEmpty) return;
    await showAppDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => SourceCategoryDialog(
        initialCategory: initial,
        categories: categories().toList(),
        createOnly: create,
        selectionCount: create ? null : ids.length,
        onSave: (category) => create
            ? _save(() => saveCategory(category), '已保存分类「$category」',
                rethrowError: true)
            : assign(ids, category, rethrowError: true),
      ),
    );
  }

  @override
  void dispose() {
    _closed = true;
    super.dispose();
  }
}

class SourceCategoryToolbar extends StatelessWidget {
  final SourceCategoryController controller;
  final Iterable<String> visibleLocations;
  const SourceCategoryToolbar(
      {super.key, required this.controller, required this.visibleLocations});

  Future<void> _createAndMove(BuildContext context) async {
    final ids = Set<String>.of(controller.selected);
    if (controller.busy || ids.isEmpty) return;
    await showAppDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => SourceCategoryDialog(
        initialCategory: '',
        categories: controller.categories().toList(),
        createOnly: true,
        selectionCount: ids.length,
        onSave: (name) async {
          // 分配接口会在同一次提交中创建目录，不先写入空分类。
          await controller.assign(ids, name, rethrowError: true);
          controller.clear();
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ids = visibleLocations.toSet();
    final enabled = !controller.busy && controller.selected.isNotEmpty;
    final names = controller
        .categories()
        .where((name) => name.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(
        spacing: AppSpacing.sm,
        runSpacing: AppSpacing.sm,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text('已选 ${controller.selected.length} 项',
              key: const ValueKey('source-category-batch-count'),
              style: TextStyle(
                  fontSize: AppType.label, color: context.palette.textMain)),
          TextButton(
            key: const ValueKey('source-category-select-all'),
            onPressed: controller.busy || ids.isEmpty
                ? null
                : () => controller.selectVisible(ids, true),
            child: const Text('全选'),
          ),
          TextButton(
            key: const ValueKey('source-category-clear-selection'),
            onPressed: enabled ? controller.clear : null,
            child: const Text('清除'),
          ),
          PopupMenuButton<String>(
            key: const ValueKey('source-category-move'),
            tooltip: '移动已选源到分类',
            enabled: enabled,
            color: context.palette.raised,
            onSelected: (name) => unawaited(_moveToCategory(
                controller, Set<String>.of(controller.selected), name)),
            itemBuilder: (_) => [
              for (final name in ['', ...names])
                PopupMenuItem(
                  key: ValueKey('source-category-destination:$name'),
                  value: name,
                  child: Tooltip(
                      message: name.isEmpty ? '未分类' : name,
                      child: Text(name.isEmpty ? '未分类' : name,
                          maxLines: 1, overflow: TextOverflow.ellipsis)),
                ),
            ],
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md, vertical: AppSpacing.sm),
              decoration: BoxDecoration(
                border: Border.all(color: context.palette.borderStrong),
                borderRadius: BorderRadius.circular(AppRadii.sm),
              ),
              child: Text('移动到 ▾',
                  style: TextStyle(
                      fontSize: AppType.label,
                      color: enabled
                          ? context.palette.textMain
                          : context.palette.textSub)),
            ),
          ),
          OutlinedButton(
            key: const ValueKey('source-category-create-and-move'),
            onPressed: enabled ? () => _createAndMove(context) : null,
            child: const Text('新建并移入…'),
          ),
        ],
      ),
      if (controller.status case final status?) ...[
        const SizedBox(height: AppSpacing.sm),
        if (controller.busy) const LinearProgressIndicator(),
        Semantics(
          liveRegion: true,
          child: Text(status,
              key: const ValueKey('source-category-status'),
              style: TextStyle(
                  fontSize: AppType.body,
                  color: controller.failed
                      ? context.palette.danger
                      : context.palette.success)),
        ),
      ],
    ]);
  }
}

class SourceCategoryDrag {
  final SourceCategoryController owner;
  final Set<String> locations;
  SourceCategoryDrag(this.owner, Iterable<String> locations)
      : locations = Set.unmodifiable(locations);
}

/// 整行可选择、拖动；行内动作仍由各自的按钮处理。
class SourceCategoryRow extends StatefulWidget {
  final SourceCategoryController controller;
  final String location;
  final String label;
  final Widget child;
  final IconData? icon;
  final List<Widget> actions;
  const SourceCategoryRow(
      {super.key,
      required this.controller,
      required this.location,
      required this.label,
      required this.child,
      this.icon,
      this.actions = const []});

  @override
  State<SourceCategoryRow> createState() => _SourceCategoryRowState();
}

class _SourceCategoryRowState extends State<SourceCategoryRow> {
  bool _dragging = false;
  bool _focused = false;

  Widget _buildActions(BuildContext context) {
    final iconStyle =
        (IconButtonTheme.of(context).style ?? const ButtonStyle()).copyWith(
      fixedSize: const WidgetStatePropertyAll(Size.square(36)),
      padding: const WidgetStatePropertyAll(EdgeInsets.zero),
      visualDensity: VisualDensity.standard,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    final textStyle =
        (TextButtonTheme.of(context).style ?? const ButtonStyle()).copyWith(
      minimumSize: const WidgetStatePropertyAll(Size(48, 36)),
      padding:
          const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 10)),
      visualDensity: VisualDensity.standard,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    return IconButtonTheme(
      data: IconButtonThemeData(style: iconStyle),
      child: TextButtonTheme(
        data: TextButtonThemeData(style: textStyle),
        child: Wrap(
          alignment: WrapAlignment.end,
          spacing: AppSpacing.xs,
          runSpacing: AppSpacing.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: widget.actions,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final selected = controller.selected.contains(widget.location);
    final ids = selected ? controller.selected : {widget.location};
    return Draggable<SourceCategoryDrag>(
      data: SourceCategoryDrag(controller, ids),
      affinity: Axis.horizontal,
      maxSimultaneousDrags: controller.busy ? 0 : 1,
      onDragStarted: () => setState(() => _dragging = true),
      onDragEnd: (_) {
        if (mounted) setState(() => _dragging = false);
      },
      feedback: Material(
        color: context.palette.raised,
        borderRadius: BorderRadius.circular(AppRadii.sm),
        elevation: 6,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Text('${ids.length} 项',
              style: TextStyle(
                  fontSize: AppType.label, color: context.palette.textMain)),
        ),
      ),
      child: Semantics(
        key: ValueKey('source-category-selection:${widget.location}'),
        container: true,
        selected: selected,
        child: Material(
          color: selected || _dragging
              ? context.palette.selectionFill
              : context.palette.panel,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.sm),
            side: BorderSide(
              color: selected || _dragging || _focused
                  ? context.palette.selectionInk
                  : Colors.transparent,
              width: selected || _dragging ? 3 : 1,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: controller.busy
                ? null
                : () => controller.toggle(widget.location),
            onFocusChange: (value) => setState(() => _focused = value),
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.sm),
              child: LayoutBuilder(builder: (context, constraints) {
                final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
                final inlineActions = constraints.maxWidth >=
                    320 +
                        widget.actions.length * 40 +
                        (scale - 1) * 160 +
                        64 * scale;
                final actions = _buildActions(context);
                final content = Row(children: [
                  SizedBox(
                    width: 36,
                    height: 36,
                    child: Checkbox(
                      key: ValueKey(
                          'source-category-checkbox:${widget.location}'),
                      semanticLabel: '选择 ${widget.label}',
                      value: selected,
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      activeColor: context.palette.selectionInk,
                      checkColor: context.palette.onSelectionInk,
                      onChanged: controller.busy
                          ? null
                          : (_) => controller.toggle(widget.location),
                    ),
                  ),
                  if (widget.icon case final icon?) ...[
                    const SizedBox(width: AppSpacing.sm),
                    Icon(icon, size: 18, color: context.palette.textSub),
                  ],
                  const SizedBox(width: 12),
                  Expanded(child: widget.child),
                  if (selected) ...[
                    Padding(
                      padding: const EdgeInsets.only(left: AppSpacing.sm),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 3),
                        decoration: BoxDecoration(
                          color: context.palette.selectionInk,
                          borderRadius: BorderRadius.circular(AppRadii.xs),
                        ),
                        child: Text(
                          '已选中',
                          style: TextStyle(
                            fontSize: AppType.caption,
                            fontWeight: FontWeight.w700,
                            color: context.palette.onSelectionInk,
                          ),
                        ),
                      ),
                    ),
                  ] else ...[
                    const SizedBox(width: 56),
                  ],
                  if (inlineActions && widget.actions.isNotEmpty) ...[
                    const SizedBox(width: AppSpacing.md),
                    actions,
                  ],
                  const SizedBox(width: AppSpacing.sm),
                  SizedBox(
                    key: ValueKey('source-drag:${widget.location}'),
                    width: 24,
                    height: 36,
                    child: Tooltip(
                      message: '拖动 ${ids.length} 项到左侧分类',
                      child: Icon(Icons.drag_indicator_rounded,
                          size: 18, color: context.palette.textSub),
                    ),
                  ),
                ]);
                return Column(mainAxisSize: MainAxisSize.min, children: [
                  content,
                  if (!inlineActions && widget.actions.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: AppSpacing.xs),
                      child: Align(
                          alignment: Alignment.centerRight, child: actions),
                    ),
                ]);
              }),
            ),
          ),
        ),
      ),
    );
  }
}
