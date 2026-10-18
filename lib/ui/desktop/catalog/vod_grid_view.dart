import 'package:flutter/material.dart';
import '../../../core/api/models/vod_models.dart';

/// 桌面端影视海报流瀑布网格组件（精准复现线框图视觉规范）
class VodGridView extends StatelessWidget {
  final List<VodItem> items;
  final ValueChanged<VodItem> onItemTap;

  const VodGridView({
    super.key,
    required this.items,
    required this.onItemTap,
  });

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: const Color(0xFF1E1E28),
                borderRadius: BorderRadius.circular(32),
              ),
              child: const Icon(Icons.movie_outlined, size: 32, color: Color(0xFF68687C)),
            ),
            const SizedBox(height: 12),
            const Text(
              '当前分类暂无影视内容',
              style: TextStyle(color: Color(0xFF78788C), fontSize: 13),
            ),
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // 根据桌面窗口宽度自适应计算列数 (卡片宽度约 160~200px)
        final crossAxisCount = (constraints.maxWidth / 175).floor().clamp(3, 8);

        return GridView.builder(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            childAspectRatio: 0.65, // 标准影视海报比例
            crossAxisSpacing: 14.0,
            mainAxisSpacing: 14.0,
          ),
          itemCount: items.length,
          itemBuilder: (context, index) {
            final item = items[index];
            return _VodCard(
              item: item,
              index: index,
              onTap: () => onItemTap(item),
            );
          },
        );
      },
    );
  }
}

class _VodCard extends StatefulWidget {
  final VodItem item;
  final int index;
  final VoidCallback onTap;

  const _VodCard({
    required this.item,
    required this.index,
    required this.onTap,
  });

  @override
  State<_VodCard> createState() => _VodCardState();
}

class _VodCardState extends State<_VodCard> {
  bool _isHovered = false;

  /// 计算顶部左侧标签 (如: "豆瓣热播", "4K", "1080P", "更新至xx集")
  String _resolveTopBadge() {
    if (widget.item.tag != null && widget.item.tag!.isNotEmpty) {
      return widget.item.tag!;
    }
    if (widget.item.remarks != null && widget.item.remarks!.isNotEmpty) {
      final r = widget.item.remarks!;
      if (r.contains('4K') || r.contains('1080P') || r.contains('HD') || r.contains('更新至') || r.contains('完结') || r.contains('超清')) {
        return r;
      }
    }
    // 默认高光标签
    return '豆瓣热播';
  }

  /// 计算底部评分标签 (如: "8.8", "评分 9.2", "⭐ 8.5")
  String _resolveScoreBadge() {
    if (widget.item.score != null && widget.item.score!.isNotEmpty) {
      return '⭐ ${widget.item.score}';
    }
    if (widget.item.remarks != null && widget.item.remarks!.isNotEmpty) {
      return widget.item.remarks!;
    }
    if (widget.item.year != null && widget.item.year!.isNotEmpty) {
      return widget.item.year!;
    }
    return '评分 8.5';
  }

  @override
  Widget build(BuildContext context) {
    final topBadge = _resolveTopBadge();
    final scoreBadge = _resolveScoreBadge();

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _isHovered ? 1.035 : 1.0,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOutCubic,
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFF181822),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: _isHovered ? const Color(0xFFE50914) : const Color(0xFF282836),
                width: _isHovered ? 1.5 : 1.0,
              ),
              boxShadow: _isHovered
                  ? [
                      BoxShadow(
                        color: const Color(0xFFE50914).withAlpha(40),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ]
                  : null,
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 海报封面容器（含左上角标与左下角评分标签）
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // 封面图片
                      Image.network(
                        widget.item.pic,
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) => Container(
                          color: const Color(0xFF20202C),
                          child: const Center(
                            child: Icon(
                              Icons.movie_creation_outlined,
                              size: 38,
                              color: Color(0xFF505064),
                            ),
                          ),
                        ),
                      ),

                      // 底部暗色渐变，增强文字可视度
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        height: 50,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Colors.transparent,
                                Colors.black.withAlpha(200),
                              ],
                            ),
                          ),
                        ),
                      ),

                      // 1. 左上角高光角标 [ 豆瓣热播 ] (严格对齐线框图)
                      Positioned(
                        left: 8,
                        top: 8,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                          decoration: BoxDecoration(
                            color: const Color(0xFFE50914),
                            borderRadius: BorderRadius.circular(4),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withAlpha(120),
                                blurRadius: 4,
                              ),
                            ],
                          ),
                          child: Text(
                            topBadge,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 0.2,
                            ),
                            maxLines: 1,
                          ),
                        ),
                      ),

                      // 2. 左下角评分角标 [ 评分 ] (严格对齐线框图)
                      Positioned(
                        left: 8,
                        bottom: 8,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2.5),
                          decoration: BoxDecoration(
                            color: const Color(0xE616161E),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: const Color(0x66FFB300), width: 0.8),
                          ),
                          child: Text(
                            scoreBadge,
                            style: const TextStyle(
                              color: Color(0xFFFFC107),
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                            maxLines: 1,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // 底部影视标题名称
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  color: const Color(0xFF14141E),
                  child: Text(
                    widget.item.name,
                    style: TextStyle(
                      color: _isHovered ? Colors.white : const Color(0xFFD8D8E6),
                      fontSize: 12,
                      fontWeight: _isHovered ? FontWeight.bold : FontWeight.w500,
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
