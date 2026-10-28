import 'package:flutter/material.dart';
import '../../../core/api/models/vod_models.dart';
import '../../theme/app_palette.dart';
import '../widgets/focus_ring.dart';
import '../../theme/app_tokens.dart';
import 'poster_image.dart';

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

  /// 海报解码目标宽度（与卡片实际显示宽度同量级，避免整张 4000px 原图进内存）
  static const int posterCacheWidth = 512;
}

/// 桌面端影视海报流瀑布网格组件（精准复现线框图视觉规范）
class VodGridView extends StatelessWidget {
  final List<VodItem> items;
  final ValueChanged<VodItem> onItemTap;

  /// 逐条决定海报解码器（可选）。
  ///
  /// 返回 null 时用默认的 `ResizeImage(NetworkImage(...))`。豆瓣图床必须走
  /// [DoubanPosterImage]：`NetworkImage` 加头用 `headers.add`，会和 `dart:io`
  /// 默认 UA 叠成两条，豆瓣直接 403（§17 实测）。
  final ImageProvider? Function(VodItem item)? imageProviderFor;

  /// 外部滚动控制器（首页无限滚动要读 `maxScrollExtent` 判断是否需要续页）
  final ScrollController? controller;

  const VodGridView({
    super.key,
    required this.items,
    required this.onItemTap,
    this.imageProviderFor,
    this.controller,
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
          controller: controller,
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
              poster: imageProviderFor?.call(item) ??
                  posterImageProvider(item.pic,
                      targetWidth: VodGridMetrics.posterCacheWidth) ??
                  ResizeImage(NetworkImage(item.pic),
                      width: VodGridMetrics.posterCacheWidth),
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

  /// 海报解码器（默认 `ResizeImage(NetworkImage(...))`；豆瓣图床由外部注入）
  final ImageProvider poster;

  const _VodCard({
    required this.item,
    required this.index,
    required this.onTap,
    required this.poster,
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

    return MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        cursor: SystemMouseCursors.click,
        // 先缩放再套焦点环：否则缩放只作用于卡片，焦点环停在 100% 尺寸，
        // 放大 4% 之后环就比卡片小一圈（描边与影片大小对不上）。
        child: AnimatedScale(
          scale: _isHovered ? 1.04 : 1.0,
          duration: _hoverMotion,
          curve: AppMotion.ease,
          child: FocusRing(
            onTap: widget.onTap,
            semanticLabel: widget.item.name,
            borderRadius: const BorderRadius.all(Radius.circular(AppRadii.lg)),
            child: GestureDetector(
              onTap: widget.onTap,
              child: AnimatedContainer(
                duration: _hoverMotion,
                curve: AppMotion.ease,
                decoration: BoxDecoration(
                  color: palette.card,
                  borderRadius: BorderRadius.circular(AppRadii.lg),
                  // 边框不再画在 decoration 上：`Border.all` 在圆角矩形上是
                  // 居中描边，一半落在盒子外会被圆角裁剪吃掉，四角几乎看不见。
                  // 描边改由 Stack 最上层的 [_CardRingPainter] 负责。
                  boxShadow: _isHovered
                      ? AppShadows.cardHover(palette.accentInk)
                      : null,
                ),
                clipBehavior: Clip.antiAlias,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // 1. 全景海报封面（Netflix 式画报铺满）
                    //
                    // 直播频道常见「无台标」（pic 为空）。此前仍会构造
                    // NetworkImage('') 并真的发起请求，加载失败后再走 errorBuilder：
                    // 上千个频道滚动时就是上千次无效请求 + 异常上报，直接拖垮滚动。
                    // 空 URL 直接渲染占位，不发请求。
                    if (widget.item.pic.trim().isEmpty)
                      Container(
                        color: palette.raised,
                        child: Center(
                          child: Icon(
                            Icons.movie_creation_outlined,
                            size: 40,
                            color: palette.textDim,
                          ),
                        ),
                      )
                    else
                      Image(
                        image: widget.poster,
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) => Container(
                          color: palette.raised,
                          child: Center(
                            child: Icon(
                              Icons.movie_creation_outlined,
                              size: 40,
                              color: palette.textDim,
                            ),
                          ),
                        ),
                      ),

                    // 2. 底部电影级平滑黑场渐变（从透明平滑过渡至浓郁深黑，保证标题绝对可读）
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            stops: const [0.0, 0.45, 0.72, 1.0],
                            colors: [
                              Colors.transparent,
                              Colors.transparent,
                              Colors.black.withValues(alpha: 0.65),
                              Colors.black.withValues(alpha: 0.92),
                            ],
                          ),
                        ),
                      ),
                    ),

                    // 3. 悬停微光：底部再压一层极轻的通透流光，不参与描边
                    if (_isHovered)
                      Positioned.fill(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                palette.accentInk.withValues(alpha: 0.10),
                                Colors.transparent,
                              ],
                            ),
                            borderRadius:
                                BorderRadius.circular(AppRadii.lg),
                          ),
                        ),
                      ),

                    // 4. 左上角信息角标（Infuse 磨砂玻璃胶囊：仅真实信息时渲染）
                    if (topBadge != null)
                      Positioned(
                        left: 8,
                        top: 8,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 7, vertical: 3.5),
                          decoration: BoxDecoration(
                            color: const Color(0xB3121218),
                            borderRadius: BorderRadius.circular(AppRadii.xs),
                            border: Border.all(
                              color: const Color(0x33FFFFFF),
                              width: 0.8,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.35),
                                blurRadius: 4,
                                offset: const Offset(0, 1),
                              ),
                            ],
                          ),
                          child: Text(
                            topBadge,
                            style: const TextStyle(
                              color: Color(0xFFF2F4F8),
                              fontSize: AppType.caption,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.2,
                            ),
                            maxLines: 1,
                          ),
                        ),
                      ),

                    // 5. 底部信息区：标题 + 评分/备注（悬浮式融合，告别生硬色块拼接）
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // 标题
                            Text(
                              widget.item.name,
                              style: TextStyle(
                                color: _isHovered
                                    ? Colors.white
                                    : const Color(0xFFF0F1F5),
                                fontSize: AppType.label,
                                fontWeight: _isHovered
                                    ? FontWeight.bold
                                    : FontWeight.w600,
                                letterSpacing: 0.2,
                                shadows: const [
                                  Shadow(
                                    color: Color(0xCC000000),
                                    blurRadius: 4,
                                    offset: Offset(0, 1),
                                  ),
                                ],
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),

                            // 评分角标（有真实评分时显示在标题下方）
                            if (scoreText != null) ...[
                              const SizedBox(height: 4),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(
                                    Icons.star_rounded,
                                    size: 13,
                                    color: Color(0xFFFFC107),
                                  ),
                                  const SizedBox(width: 3),
                                  Text(
                                    scoreText,
                                    style: const TextStyle(
                                      color: Color(0xFFFFC107),
                                      fontSize: AppType.caption,
                                      fontWeight: FontWeight.bold,
                                      fontFeatures: [
                                        FontFeature.tabularFigures()
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),

                    // 6. 描边（最上层）：必须压在内容之上——画在 decoration 上会被
                    //    不透明海报盖住，且居中描边被圆角裁掉一半，四个角就"消失"了。
                    Positioned.fill(
                      child: IgnorePointer(
                        child: TweenAnimationBuilder<double>(
                          tween: Tween<double>(end: _isHovered ? 1 : 0),
                          duration: _hoverMotion,
                          curve: AppMotion.ease,
                          builder: (context, t, _) => CustomPaint(
                            painter: _CardRingPainter(
                              color: Color.lerp(context.glassBorder,
                                  palette.accentInk, t)!,
                              width: 1 + 0.6 * t,
                              radius: AppRadii.lg,
                            ),
                          ),
                        ),
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

/// 卡片描边：[width] 的中心线整体内缩半个线宽，整条线都落在卡片内侧。
///
/// 为什么不用 `Border.all`：它在圆角矩形上是**居中**描边（`deflate(width / 2)`），
/// 一半落在盒子外；卡片又被 `Clip.antiAlias` 按同一圆角裁剪，外半被吃掉，角落只剩
/// 亚像素混合，视觉上"四角没有描边"（2026-10-22 像素实测：四角 12×12 区域内
/// accent 命中数为 0）。改成内缩描边后，四个角是完整圆弧。
class _CardRingPainter extends CustomPainter {
  const _CardRingPainter({
    required this.color,
    required this.width,
    required this.radius,
  });

  final Color color;
  final double width;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    if (width <= 0 || size.isEmpty) return;
    final inset = width / 2;
    final rect = Rect.fromLTWH(
      inset,
      inset,
      size.width - width,
      size.height - width,
    );
    if (rect.isEmpty) return;
    final rrect = RRect.fromRectAndRadius(
      rect,
      Radius.circular((radius - inset).clamp(0.0, radius)),
    );
    canvas.drawRRect(
      rrect,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..isAntiAlias = true,
    );
  }

  @override
  bool shouldRepaint(_CardRingPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.width != width ||
      oldDelegate.radius != radius;
}
