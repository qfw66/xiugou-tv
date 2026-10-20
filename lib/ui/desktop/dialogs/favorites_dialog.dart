import 'package:flutter/material.dart';
import '../../../core/api/models/vod_models.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';
import '../widgets/focus_ring.dart';

/// 收藏夹弹窗。
///
/// [onRemoveItem] 返回 null 表示删除成功；返回字符串表示失败原因，会在弹窗内
/// 就地显示（失败反馈贴近操作处，便于直接重试）。
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
    final palette = AppPalette.of(context);
    return Dialog(
      backgroundColor: palette.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.lg),
        side: BorderSide(color: palette.borderStrong, width: 1),
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
                    color: palette.raised,
                    borderRadius: BorderRadius.circular(AppRadii.md),
                  ),
                  child: Icon(Icons.star_rounded,
                      color: palette.accentInk, size: 20),
                ),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '我的收藏',
                      style: TextStyle(
                          fontSize: AppType.h2,
                          fontWeight: FontWeight.bold,
                          color: palette.textTitle),
                    ),
                    Text(
                      '共收藏 ${_items.length} 部影片',
                      style: TextStyle(
                          fontSize: AppType.body, color: palette.textSub),
                    ),
                  ],
                ),
                const Spacer(),
                FocusOutline(
                  radius: AppRadii.pill,
                  child: IconButton(
                    icon: Icon(Icons.close_rounded,
                        color: palette.textSub, size: 22),
                    onPressed: () => Navigator.of(context).pop(),
                    tooltip: '关闭',
                  ),
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
                  color: palette.danger.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppRadii.sm),
                  border:
                      Border.all(color: palette.danger.withValues(alpha: 0.4)),
                ),
                child: Text(
                  _error!,
                  style:
                      TextStyle(color: palette.danger, fontSize: AppType.label),
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
                              color: palette.raised,
                              borderRadius:
                                  BorderRadius.circular(AppRadii.pill),
                            ),
                            child: Icon(Icons.star_outline_rounded,
                                size: 36, color: palette.textDim),
                          ),
                          const SizedBox(height: 12),
                          Text('暂无收藏影片',
                              style: TextStyle(
                                  color: palette.textSub,
                                  fontSize: AppType.title)),
                          const SizedBox(height: 4),
                          Text('在影片详情中点击「收藏」即可保存在这里',
                              style: TextStyle(
                                  color: palette.textDim,
                                  fontSize: AppType.body)),
                        ],
                      ),
                    )
                  : GridView.builder(
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
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
    final palette = AppPalette.of(context);
    final item = widget.item;

    return FocusRing(
      onTap: widget.onTap,
      semanticLabel: item.name,
      borderRadius: const BorderRadius.all(Radius.circular(AppRadii.md)),
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedScale(
            scale: _isHovered ? 1.03 : 1.0,
            duration: _isHovered ? AppMotion.enter : AppMotion.exit,
            child: AnimatedContainer(
              duration: _isHovered ? AppMotion.enter : AppMotion.exit,
              decoration: BoxDecoration(
                color: palette.raised,
                borderRadius: BorderRadius.circular(AppRadii.md),
                border: Border.all(
                  color: _isHovered ? palette.accentInk : palette.pressed,
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
                          borderRadius: const BorderRadius.vertical(
                              top: Radius.circular(AppRadii.sm)),
                          child: Image.network(
                            item.pic,
                            // ⑥ 内存批：4 列卡片宽约 140~160px，320 覆盖 2x DPR。
                            cacheWidth: 320,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Container(
                              color: palette.raised,
                              child: Icon(Icons.movie_creation_outlined,
                                  size: 36, color: palette.textDim),
                            ),
                          ),
                        ),
                        // 删除收藏按钮（悬停反馈 + 键盘焦点；B4）
                        Positioned(
                          top: 6,
                          right: 6,
                          child: _RemoveButton(
                            itemId: item.id,
                            onRemove: widget.onRemove,
                          ),
                        ),
                        // 备注
                        if (item.remarks != null && item.remarks!.isNotEmpty)
                          Positioned(
                            left: 6,
                            bottom: 6,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                // 海报上的备注角标固定深底亮字
                                color: const Color(0xCC000000),
                                borderRadius:
                                    BorderRadius.circular(AppRadii.xs),
                              ),
                              child: Text(
                                item.remarks!,
                                style: const TextStyle(
                                    fontSize: AppType.caption,
                                    // 与海报网格评分角标同一暖黄（固定色，海报上跨主题可读；B4 统一）
                                    color: Color(0xFFFFC107),
                                    fontWeight: FontWeight.bold),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  // 标题
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    child: Text(
                      item.name,
                      style: TextStyle(
                        fontSize: AppType.body,
                        fontWeight: FontWeight.bold,
                        color:
                            _isHovered ? palette.textTitle : palette.textBody,
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
      ),
    );
  }
}

/// 海报角上的删除收藏按钮（B4）。
///
/// 固定深底保证任意海报上可见；悬停转深红提示删除；支持键盘焦点环。
class _RemoveButton extends StatefulWidget {
  final String itemId;
  final VoidCallback onRemove;

  const _RemoveButton({required this.itemId, required this.onRemove});

  @override
  State<_RemoveButton> createState() => _RemoveButtonState();
}

class _RemoveButtonState extends State<_RemoveButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return FocusRing(
      onTap: widget.onRemove,
      semanticLabel: '移除收藏',
      borderRadius: BorderRadius.circular(AppRadii.lg),
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          key: ValueKey('favorite-remove-${widget.itemId}'),
          onTap: widget.onRemove,
          child: AnimatedContainer(
            duration: _isHovered ? AppMotion.enter : AppMotion.exit,
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              // 海报上的悬浮按钮固定色：深底保证任意海报可见，悬停转深红提示删除
              color: _isHovered
                  ? const Color(0xE6C62828)
                  : const Color(0xCC000000),
              borderRadius: BorderRadius.circular(AppRadii.lg),
            ),
            child: const Icon(Icons.close_rounded,
                size: 14, color: Colors.white70),
          ),
        ),
      ),
    );
  }
}
