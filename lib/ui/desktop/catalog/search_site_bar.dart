import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';
import '../widgets/filter_pill.dart';
import '../widgets/focus_ring.dart';
import '../widgets/horizontal_scroll_area.dart';
import 'search_site_groups.dart';

/// 搜索站点筛选栏；同一搜索的增量结果保留展开状态，新搜索可用新 key 复位。
class SearchSiteBar extends StatefulWidget {
  final List<SearchSiteGroup> groups;
  final int totalCount;
  final String? selectedKey;
  final ValueChanged<String?> onSelected;
  final Widget? progress;

  const SearchSiteBar({
    super.key,
    required this.groups,
    required this.totalCount,
    required this.selectedKey,
    required this.onSelected,
    this.progress,
  });

  @override
  State<SearchSiteBar> createState() => _SearchSiteBarState();
}

class _SearchSiteBarState extends State<SearchSiteBar> {
  final _horizontal = ScrollController();
  final _vertical = ScrollController();
  bool _expanded = false;

  @override
  void dispose() {
    _horizontal.dispose();
    _vertical.dispose();
    super.dispose();
  }

  void _toggleExpanded() => setState(() => _expanded = !_expanded);

  @override
  Widget build(BuildContext context) {
    final rowHeight = math.max(
      38.0,
      MediaQuery.textScalerOf(context).scale(AppType.body) * 1.5 + 16,
    );
    final expandedHeight = math.max(
      rowHeight,
      math.min(192.0, MediaQuery.sizeOf(context).height * 0.35),
    );
    final label = _expanded ? '收起站点' : '展开站点';
    return SizedBox(
      key: const ValueKey('search-site-bar'),
      child: AnimatedSize(
        alignment: Alignment.topCenter,
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : _expanded ? AppMotion.enter : AppMotion.exit,
        curve: AppMotion.ease,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _expanded
                  ? _buildExpanded(expandedHeight)
                  : _buildCollapsed(rowHeight),
            ),
            const SizedBox(width: AppSpacing.sm),
            Semantics(
              key: const ValueKey('search-site-toggle'),
              expanded: _expanded,
              child: FocusOutline(
                child: SizedBox.square(
                  dimension: rowHeight,
                  child: IconButton(
                    tooltip: label,
                    onPressed: _toggleExpanded,
                    color: context.palette.textBody,
                    style: IconButton.styleFrom(
                      backgroundColor: context.palette.card,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppRadii.sm),
                      ),
                    ),
                    icon: Icon(_expanded ? Icons.expand_less : Icons.expand_more),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCollapsed(double height) {
    final children = _items(context);
    return SizedBox(
      height: height,
      child: HorizontalScrollArea(
        controller: _horizontal,
        child: SingleChildScrollView(
          controller: _horizontal,
          primary: false,
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var index = 0; index < children.length; index++) ...[
                if (index > 0) const SizedBox(width: AppSpacing.sm),
                children[index],
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildExpanded(double maxHeight) {
    return LayoutBuilder(builder: (context, constraints) {
      final width = math.max(0.0, constraints.maxWidth - AppSpacing.sm);
      return ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
          child: Scrollbar(
            controller: _vertical,
            thumbVisibility: true,
            child: SingleChildScrollView(
              controller: _vertical,
              primary: false,
              padding: const EdgeInsets.only(right: AppSpacing.sm, top: 2, bottom: 2),
              child: Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: _items(context, maxWidth: width),
              ),
            ),
          ),
        ),
      );
    });
  }

  List<Widget> _items(BuildContext context, {double? maxWidth}) => [
        if (widget.groups.length >= 2)
          _pill(
            context,
            key: const ValueKey('search-site-pill-all'),
            label: '全部',
            count: widget.totalCount,
            selected: widget.selectedKey == null,
            onTap: () => widget.onSelected(null),
            maxWidth: maxWidth,
          ),
        for (final group in widget.groups)
          _pill(
            context,
            key: ValueKey('search-site-pill-${group.key}'),
            label: group.name,
            count: group.count,
            selected: widget.selectedKey == group.key,
            onTap: () => widget.onSelected(
              widget.selectedKey == group.key ? null : group.key,
            ),
            maxWidth: maxWidth,
          ),
        if (widget.progress != null)
          maxWidth == null
              ? widget.progress!
              : IntrinsicWidth(child: widget.progress!),
      ];

  Widget _pill(
    BuildContext context, {
    required Key key,
    required String label,
    required int count,
    required bool selected,
    required VoidCallback onTap,
    double? maxWidth,
  }) {
    final displayLabel = maxWidth == null
        ? label
        : _fitLabel(context, label, count, selected, maxWidth);
    final pill = Tooltip(
      message: label,
      excludeFromSemantics: true,
      child: Semantics(
        container: true,
        button: true,
        label: label,
        value: '$count 个结果',
        selected: selected,
        onTap: onTap,
        child: FocusRing(
          key: key,
          onTap: onTap,
          // FilterPill couples its semantic label to the displayed text. Keep
          // its visuals and pointer handling, with one full-name focus target.
          child: ExcludeSemantics(
            child: ExcludeFocus(
              child: FilterPill(
                label: displayLabel,
                count: count,
                isSelected: selected,
                onTap: onTap,
              ),
            ),
          ),
        ),
      ),
    );
    return maxWidth == null ? pill : IntrinsicWidth(child: pill);
  }

  /// FilterPill 的标签上限为 220；更窄的多行栏须为数量、内边距和边框留位。
  /// 仅截短展示文字，完整名称由 Tooltip 与语义保留，字号保持原样。
  String _fitLabel(
    BuildContext context,
    String label,
    int count,
    bool selected,
    double maxWidth,
  ) {
    final base = DefaultTextStyle.of(context).style;
    final painter = TextPainter(
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    );
    double measure(String text, TextStyle style) {
      painter.text = TextSpan(text: text, style: style);
      painter.layout();
      return painter.width;
    }

    try {
      final badgeWidth = measure('$count', base.copyWith(
        fontSize: AppType.caption,
        fontWeight: FontWeight.bold,
        fontFeatures: const [FontFeature.tabularFigures()],
      ));
      final available = math.max(0.0, math.min(220.0, maxWidth - badgeWidth - 52));
      final style = base.copyWith(
        fontSize: AppType.body,
        fontWeight: selected ? FontWeight.bold : FontWeight.w500,
      );
      if (measure(label, style) <= available) return label;
      final characters = label.characters.toList(growable: false);
      var low = 0;
      var high = characters.length;
      while (low < high) {
        final middle = (low + high + 1) ~/ 2;
        final candidate = '${characters.take(middle).join()}…';
        if (measure(candidate, style) <= available) {
          low = middle;
        } else {
          high = middle - 1;
        }
      }
      return '${characters.take(low).join()}…';
    } finally {
      painter.dispose();
    }
  }
}
