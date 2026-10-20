import 'package:flutter/material.dart';
import '../../../core/api/models/vod_models.dart';
import '../../theme/app_palette.dart';
import '../widgets/focus_ring.dart';
import '../../theme/app_tokens.dart';

/// 网格布局参数（真实网格与骨架屏共用：同列数、同间距、同宽高比，
/// 保证加载完成时布局不跳变——skill 规则 `content-jumping`）。
abstract final class VodGridMetrics {
  /// 卡片最小宽度，用于计算自适应列数（约 160~200px 的中间值）
  static const double cardMinWidth = 175;

  /// 标准影视海报比例（宽 / 高）
  static const double cardAspectRatio = 0.65;

  /// 网格间距（横向 / 纵向）
  static const double spacing = 14;

  /// 网格内边距
  static const EdgeInsets padding =
      EdgeInsets.symmetric(horizontal: 16, vertical: 12);

  /// 按可用宽度计算列数（3–8 列）
  static int crossAxisCount(double maxWidth) =>
      (maxWidth / cardMinWidth).floor().clamp(3, 8);
}

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
    final palette = AppPalette.of(context);
    if (items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: palette.raised,
                borderRadius: BorderRadius.circular(AppRadii.pill),
              ),
              child:
                  Icon(Icons.movie_outlined, size: 32, color: palette.textDim),
            ),
            const SizedBox(height: 12),
            Text(
              '当前分类暂无影视内容',
              style: TextStyle(color: palette.textSub, fontSize: AppType.label),
            ),
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        return GridView.builder(
          padding: VodGridMetrics.padding,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: VodGridMetrics.crossAxisCount(constraints.maxWidth),
            childAspectRatio: VodGridMetrics.cardAspectRatio,
            crossAxisSpacing: VodGridMetrics.spacing,
            mainAxisSpacing: VodGridMetrics.spacing,
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

  /// 悬停动效节奏（D2）：进入 200ms / 离开 140ms——离开更快才「跟手」。
  Duration get _hoverMotion => _isHovered ? AppMotion.enter : AppMotion.exit;

  /// 计算顶部左侧标签（如：「豆瓣热播」「4K」「1080P」「更新至xx集」）。
  ///
  /// B2 角标真实性：只在有真实信息时渲染——已移除「豆瓣热播」等假数据兜底，
  /// 无信息返回 null（角标不渲染）。
  String? _resolveTopBadge() {
    if (widget.item.tag != null && widget.item.tag!.isNotEmpty) {
      return widget.item.tag!;
    }
    if (widget.item.remarks != null && widget.item.remarks!.isNotEmpty) {
      final r = widget.item.remarks!;
      if (r.contains('4K') ||
          r.contains('1080P') ||
          r.contains('HD') ||
          r.contains('更新至') ||
          r.contains('完结') ||
          r.contains('超清')) {
        return r;
      }
    }
    return null;
  }

  /// 评分文本；只在有真实评分时返回（B2：不再用备注/年份/「评分 8.5」兜底）。
  String? _resolveScoreText() {
    final score = widget.item.score;
    if (score == null || score.isEmpty) return null;
    return score;
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final topBadge = _resolveTopBadge();
    final scoreText = _resolveScoreText();

    return FocusRing(
        onTap: widget.onTap,
        semanticLabel: widget.item.name,
        borderRadius: const BorderRadius.all(Radius.circular(AppRadii.md)),
        child: MouseRegion(
          onEnter: (_) => setState(() => _isHovered = true),
          onExit: (_) => setState(() => _isHovered = false),
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: widget.onTap,
            child: AnimatedScale(
              scale: _isHovered ? 1.035 : 1.0,
              duration: _hoverMotion,
              curve: AppMotion.ease,
              child: AnimatedContainer(
                duration: _hoverMotion,
                curve: AppMotion.ease,
                decoration: BoxDecoration(
                  color: palette.card,
                  borderRadius: BorderRadius.circular(AppRadii.md),
                  border: Border.all(
                    color:
                        _isHovered ? palette.accentInk : palette.borderStrong,
                    width: _isHovered ? 1.5 : 1.0,
                  ),
                  boxShadow: _isHovered
                      ? [
                          BoxShadow(
                            color: palette.accentInk.withValues(alpha: 0.16),
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
                            // ⑥ 内存批：卡片最宽约 310px，512 覆盖 1.5x DPR 内清晰度，
                            // 避免按原图（常见 500~1000px 宽）全尺寸解码。
                            cacheWidth: 512,
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stackTrace) =>
                                Container(
                              color: palette.raised,
                              child: Center(
                                child: Icon(
                                  Icons.movie_creation_outlined,
                                  size: 38,
                                  color: palette.textDim,
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
                                    // 海报底部固定压暗（与主题无关），保证任何海报上文字可读
                                    Colors.black.withAlpha(200),
                                  ],
                                ),
                              ),
                            ),
                          ),

                          // 1. 左上角信息角标（仅真实信息时渲染；B2 已去除假兜底）
                          if (topBadge != null)
                            Positioned(
                              left: 8,
                              top: 8,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 3),
                                decoration: BoxDecoration(
                                  // 海报左上角标签固定半透深底 + 浅字：标签信息在文字里，
                                  // 颜色只是装饰（skill: Color Only），压在任何海报上都要可读 → 与主题无关
                                  color: const Color(0xCC000000),
                                  borderRadius:
                                      BorderRadius.circular(AppRadii.xs),
                                  boxShadow: [
                                    BoxShadow(
                                      // 海报投影固定黑色，与主题无关
                                      color: Colors.black.withAlpha(120),
                                      blurRadius: 4,
                                    ),
                                  ],
                                ),
                                child: Text(
                                  topBadge,
                                  style: const TextStyle(
                                    color: Color(0xFFF2F4F8),
                                    fontSize: AppType.caption,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 0.2,
                                  ),
                                  maxLines: 1,
                                ),
                              ),
                            ),

                          // 2. 左下角评分角标（图标 + 数字；仅真实评分时渲染）
                          if (scoreText != null)
                            Positioned(
                              left: 8,
                              bottom: 8,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 2.5),
                                decoration: BoxDecoration(
                                  // 海报上的角标固定深底亮黄：与主题无关，保证任意海报上都可读
                                  color: const Color(0xE616161E),
                                  borderRadius:
                                      BorderRadius.circular(AppRadii.xs),
                                  border: Border.all(
                                      color: const Color(0x66FFB300),
                                      width: 0.8),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    // 星形图标替代 emoji「⭐」（skill: no-emoji-icons）；
                                    // 固定暖黄与深底配套，跨主题可读
                                    const Icon(
                                      Icons.star_rounded,
                                      size: 12,
                                      color: Color(0xFFFFC107),
                                    ),
                                    const SizedBox(width: 3),
                                    Text(
                                      scoreText,
                                      style: const TextStyle(
                                        color: Color(0xFFFFC107),
                                        fontSize: AppType.caption,
                                        fontWeight: FontWeight.bold,
                                        // 数字等宽，多卡对齐不抖动（skill: number-tabular）
                                        fontFeatures: [
                                          FontFeature.tabularFigures()
                                        ],
                                      ),
                                      maxLines: 1,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),

                    // 底部影视标题名称
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 8),
                      color: palette.panel,
                      child: Text(
                        widget.item.name,
                        style: TextStyle(
                          color:
                              _isHovered ? palette.textTitle : palette.textBody,
                          fontSize: AppType.body,
                          fontWeight:
                              _isHovered ? FontWeight.bold : FontWeight.w500,
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
        ));
  }
}
