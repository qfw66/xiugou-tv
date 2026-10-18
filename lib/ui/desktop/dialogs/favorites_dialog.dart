import 'package:flutter/material.dart';
import '../../../core/api/models/vod_models.dart';

/// 收藏夹弹窗。
///
/// [onRemoveItem] 返回 null 表示删除成功；返回字符串表示失败原因，会在弹窗内
/// 显示（不使用 SnackBar，避免被弹窗自身遮挡）。
class FavoritesDialog extends StatefulWidget {
  final List<VodItem> items;
  final ValueChanged<VodItem> onItemTap;
  final Future<String?> Function(String id) onRemoveItem;

  const FavoritesDialog({
    super.key,
    required this.items,
    required this.onItemTap,
    required this.onRemoveItem,
  });

  @override
  State<FavoritesDialog> createState() => _FavoritesDialogState();
}

class _FavoritesDialogState extends State<FavoritesDialog> {
  late final List<VodItem> _items = List.of(widget.items);
  String? _error;
  bool _removing = false;

  Future<void> _remove(String id) async {
    if (_removing) return;
    _removing = true;
    final message = await widget.onRemoveItem(id);
    _removing = false;
    if (!mounted) return;
    if (message != null) {
      setState(() => _error = message);
      return;
    }
    setState(() {
      _error = null;
      _items.removeWhere((e) => e.id == id);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF181820),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Color(0xFF2E2E3C), width: 1),
      ),
      child: Container(
        width: 860,
        height: 600,
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 头部标题与操作按钮
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF282834),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.star_rounded, color: Color(0xFFE50914), size: 20),
                ),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '我的收藏',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                    Text(
                      '共收藏 ${_items.length} 部影片',
                      style: const TextStyle(fontSize: 12, color: Color(0xFF888898)),
                    ),
                  ],
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close_rounded, color: Color(0xFFA0A0B0), size: 22),
                  onPressed: () => Navigator.of(context).pop(),
                  tooltip: '关闭',
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (_error != null)
              Container(
                key: const ValueKey('favorites-error'),
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 12),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: const Color(0xFF3A1F22),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFF7A2E34)),
                ),
                child: Text(
                  _error!,
                  style: const TextStyle(
                      color: Colors.orangeAccent, fontSize: 12.5),
                ),
              ),

            // 收藏网格
            Expanded(
              child: _items.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 64,
                            height: 64,
                            decoration: BoxDecoration(
                              color: const Color(0xFF22222E),
                              borderRadius: BorderRadius.circular(32),
                            ),
                            child: const Icon(Icons.star_outline_rounded, size: 36, color: Color(0xFF5A5A6E)),
                          ),
                          const SizedBox(height: 12),
                          const Text('暂无收藏影片', style: TextStyle(color: Color(0xFF888898), fontSize: 14)),
                          const SizedBox(height: 4),
                          const Text('在影片详情中点击「收藏」即可保存在这里', style: TextStyle(color: Color(0xFF666678), fontSize: 12)),
                        ],
                      ),
                    )
                  : GridView.builder(
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 4,
                        childAspectRatio: 0.68,
                        crossAxisSpacing: 14,
                        mainAxisSpacing: 14,
                      ),
                      itemCount: _items.length,
                      itemBuilder: (context, index) {
                        final item = _items[index];
                        return _FavoriteItemCard(
                          item: item,
                          onTap: () {
                            Navigator.of(context).pop();
                            widget.onItemTap(item);
                          },
                          onRemove: () => _remove(item.id),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FavoriteItemCard extends StatefulWidget {
  final VodItem item;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  const _FavoriteItemCard({
    required this.item,
    required this.onTap,
    required this.onRemove,
  });

  @override
  State<_FavoriteItemCard> createState() => _FavoriteItemCardState();
}

class _FavoriteItemCardState extends State<_FavoriteItemCard> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _isHovered ? 1.03 : 1.0,
          duration: const Duration(milliseconds: 140),
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFF1E1E28),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: _isHovered ? const Color(0xFFE50914) : const Color(0xFF2C2C3C),
                width: _isHovered ? 1.5 : 1,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 封面
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ClipRRect(
                        borderRadius: const BorderRadius.vertical(top: Radius.circular(9)),
                        child: Image.network(
                          item.pic,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => Container(
                            color: const Color(0xFF282836),
                            child: const Icon(Icons.movie_creation_outlined, size: 36, color: Color(0xFF48485C)),
                          ),
                        ),
                      ),
                      // 删除收藏按钮
                      Positioned(
                        top: 6,
                        right: 6,
                        child: GestureDetector(
                          key: ValueKey('favorite-remove-${item.id}'),
                          onTap: widget.onRemove,
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              color: const Color(0xCC000000),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: const Icon(Icons.close_rounded, size: 14, color: Colors.white70),
                          ),
                        ),
                      ),
                      // 备注
                      if (item.remarks != null && item.remarks!.isNotEmpty)
                        Positioned(
                          left: 6,
                          bottom: 6,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: const Color(0xCC000000),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              item.remarks!,
                              style: const TextStyle(fontSize: 10, color: Color(0xFFFFA500), fontWeight: FontWeight.bold),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                // 标题
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  child: Text(
                    item.name,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: _isHovered ? Colors.white : const Color(0xFFDCDCE8),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
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
