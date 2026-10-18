import 'package:flutter/material.dart';
import '../../../core/api/models/vod_models.dart';

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
    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
      itemCount: items.length,
      separatorBuilder: (_, __) => const Divider(height: 1, thickness: 0.6, color: Color(0xFF242430)),
      itemBuilder: (context, index) {
        final item = items[index];
        return _VodListRow(item: item, onTap: () => onItemTap(item));
      },
    );
  }
}

class _VodListRow extends StatelessWidget {
  final VodItem item;
  final VoidCallback onTap;

  const _VodListRow({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final siteName = item.siteName?.trim() ?? '';
    final source = siteName.isNotEmpty ? siteName : (item.tag?.trim().isNotEmpty ?? false ? item.tag! : '未知来源');
    final metas = [
      if (item.score != null && item.score!.isNotEmpty) '⭐ ${item.score}',
      if (item.remarks != null && item.remarks!.isNotEmpty) item.remarks!,
      if (item.year != null && item.year!.isNotEmpty) '${item.year}年',
    ];

    return InkWell(
      onTap: onTap,
      hoverColor: const Color(0xFF20202C),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Text(
                item.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13.5,
                  color: Color(0xFFE6E6F0),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Text(
              source,
              style: const TextStyle(fontSize: 12, color: Color(0xFF8C8CA0)),
            ),
            if (metas.isNotEmpty) ...[
              const SizedBox(width: 12),
              Text(
                metas.join(' · '),
                style: const TextStyle(fontSize: 12, color: Color(0xFF66667A)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
