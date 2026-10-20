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
            child: Row(
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
                    child: Text(
                      item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                // 来源：小圆角标签（B3——层次清楚，与 D2 卡片存在感一致）
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: palette.card,
                    borderRadius: BorderRadius.circular(AppRadii.sm),
                    border: Border.all(color: palette.borderStrong, width: 1),
                  ),
                  child: Text(
                    source,
                    style: TextStyle(
                        fontSize: AppType.caption, color: palette.textSub),
                  ),
                ),
                if (hasMetas) ...[
                  const SizedBox(width: 10),
                  // 评分：星形图标 + tabular 数字（B3——emoji 退役，与网格角标同一语义）
                  if (hasScore) ...[
                    Icon(Icons.star_rounded, size: 12, color: palette.warning),
                    const SizedBox(width: 3),
                    Text(
                      score,
                      style: TextStyle(
                        fontSize: AppType.body,
                        color: palette.textBody,
                        fontWeight: FontWeight.w600,
                        // 数字等宽，多行对齐不抖动（skill: number-tabular）
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                  if (hasScore && (remarks.isNotEmpty || year.isNotEmpty))
                    const SizedBox(width: 8),
                  if (remarks.isNotEmpty)
                    Text(
                      remarks,
                      style: TextStyle(
                          fontSize: AppType.body, color: palette.textDim),
                    ),
                  if (remarks.isNotEmpty && year.isNotEmpty)
                    const SizedBox(width: 8),
                  if (year.isNotEmpty)
                    Text(
                      '$year年',
                      style: TextStyle(
                          fontSize: AppType.body, color: palette.textDim),
                    ),
                ],
              ],
            ),
          ),
        ));
  }
}
