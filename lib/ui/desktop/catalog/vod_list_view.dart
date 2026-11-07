import 'package:flutter/material.dart';
import '../../../core/api/models/vod_models.dart';
import '../../theme/app_palette.dart';
import '../widgets/focus_ring.dart';
import '../../theme/app_tokens.dart';

/// 桌面端搜索结果文字列表视图（搜索显示 = 文字列表时使用）。
///
/// 仅负责渲染非空结果行；空态（含聚合开 / 关文案）由搜索结果区统一呈现。
class VodListView extends StatelessWidget {
  final List<VodItem> items;
  final ValueChanged<VodItem> onItemTap;

  const VodListView({
    super.key,
    required this.items,
    required this.onItemTap,
  });

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
      itemCount: items.length,
      separatorBuilder: (_, __) =>
          Divider(height: 1, thickness: 0.6, color: palette.divider),
      itemBuilder: (context, index) {
        final item = items[index];
        return _VodListRow(item: item, onTap: () => onItemTap(item));
      },
    );
  }
}

class _VodListRow extends StatefulWidget {
  final VodItem item;
  final VoidCallback onTap;

  const _VodListRow({required this.item, required this.onTap});

  @override
  State<_VodListRow> createState() => _VodListRowState();
}

class _VodListRowState extends State<_VodListRow> {
  bool _isHovered = false;

  /// 悬停节奏（D2）：进 200ms / 出 140ms。
  Duration get _hoverMotion => _isHovered ? AppMotion.enter : AppMotion.exit;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final item = widget.item;
    final siteName = item.siteName?.trim() ?? '';
    final source = siteName.isNotEmpty
        ? siteName
        : (item.tag?.trim().isNotEmpty ?? false ? item.tag! : '未知来源');
    final score = item.score?.trim() ?? '';
    final hasScore = score.isNotEmpty;
    final remarks = item.remarks?.trim() ?? '';
    final year = item.year?.trim() ?? '';
    final hasMetas = hasScore || remarks.isNotEmpty || year.isNotEmpty;

    final metadata = <Widget>[
      Tooltip(
        message: source,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: palette.card,
            borderRadius: BorderRadius.circular(AppRadii.sm),
            border: Border.all(color: palette.borderStrong, width: 1),
          ),
          child: Text(
            source,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: AppType.caption, color: palette.textSub),
          ),
        ),
      ),
      if (hasMetas)
        Wrap(
          spacing: 8,
          runSpacing: 4,
          alignment: WrapAlignment.end,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (hasScore)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.star_rounded, size: 12, color: palette.warning),
                  const SizedBox(width: 3),
                  Flexible(
                    child: Text(
                      score,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppType.body,
                        color: palette.textBody,
                        fontWeight: FontWeight.w600,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ],
              ),
            if (remarks.isNotEmpty)
              Tooltip(
                message: remarks,
                child: Text(
                  remarks,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: AppType.body, color: palette.textDim),
                ),
              ),
            if (year.isNotEmpty)
              Text(
                '$year年',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: AppType.body, color: palette.textDim),
              ),
          ],
        ),
    ];

    return FocusRing(
      onTap: widget.onTap,
      semanticLabel: item.name,
      borderRadius: const BorderRadius.all(Radius.circular(AppRadii.md)),
      child: InkWell(
        onTap: widget.onTap,
        hoverColor: palette.hover,
        onHover: (hovering) => setState(() => _isHovered = hovering),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: LayoutBuilder(
            builder: (context, constraints) => Row(
              children: [
                Expanded(
                  child: AnimatedDefaultTextStyle(
                    duration: _hoverMotion,
                    curve: AppMotion.ease,
                    style: TextStyle(
                      fontSize: AppType.title,
                      color: _isHovered ? palette.textTitle : palette.textMain,
                      fontWeight: FontWeight.w500,
                    ),
                    child: Tooltip(
                      message: item.name,
                      excludeFromSemantics: true,
                      child: Text(
                        item.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: constraints.maxWidth / 2,
                  ),
                  child: Wrap(
                    spacing: 10,
                    runSpacing: 4,
                    alignment: WrapAlignment.end,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: metadata,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
