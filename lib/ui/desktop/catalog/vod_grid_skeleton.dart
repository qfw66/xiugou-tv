import 'package:flutter/material.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';
import 'vod_grid_view.dart' show VodGridMetrics;

/// 首页 / 分类海报网格的首屏加载骨架（Infuse × Netflix 风格画报级对齐）。
///
/// 设计规范与不可动摇原则：
/// - 与真实海报卡片 [_VodCard] 严格共享 [VodGridMetrics]（同列数、同间距、同 0.65 宽高比）；
/// - 与全新画报卡片严格保持一致的圆角（[AppRadii.lg] 16px）、微透边框（[context.glassBorder]）
///   与全景渐变结构，彻底杜绝数据加载完成时的布局跳动（skill: `content-jumping`）；
/// - 维持单次淡入 200ms（[AppMotion.enter]），不做无限循环 shimmer，保证自动化测试与动效敏感用户友好。
class VodGridSkeleton extends StatefulWidget {
  /// 占位卡片数量
  final int count;

  const VodGridSkeleton({super.key, this.count = 12});

  @override
  State<VodGridSkeleton> createState() => _VodGridSkeletonState();
}

class _VodGridSkeletonState extends State<VodGridSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fade =
      AnimationController(vsync: this, duration: AppMotion.enter)..forward();

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: LayoutBuilder(
        builder: (context, constraints) {
          return GridView.builder(
            padding: VodGridMetrics.padding,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount:
                  VodGridMetrics.crossAxisCount(constraints.maxWidth),
              childAspectRatio: VodGridMetrics.cardAspectRatio,
              crossAxisSpacing: VodGridMetrics.spacing,
              mainAxisSpacing: VodGridMetrics.spacing,
            ),
            itemCount: widget.count,
            itemBuilder: (context, index) => const _SkeletonCard(),
          );
        },
      ),
    );
  }
}

/// 单张全景画报占位卡：与真实 [_VodCard] 像素级结构对齐。
class _SkeletonCard extends StatelessWidget {
  const _SkeletonCard();

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return Container(
      decoration: BoxDecoration(
        color: palette.card,
        borderRadius: BorderRadius.circular(AppRadii.lg),
        border: Border.all(color: context.glassBorder, width: 1.0),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 1. 全景海报铺满色块
          ColoredBox(color: palette.raised),

          // 2. 底部暗色渐变（与真卡片一致，预置视觉重心）
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
                    Colors.black.withValues(alpha: 0.40),
                    Colors.black.withValues(alpha: 0.75),
                  ],
                ),
              ),
            ),
          ),

          // 3. 左上角占位小胶囊（模拟 4K / 完结标签）
          Positioned(
            left: 8,
            top: 8,
            child: Container(
              width: 42,
              height: 16,
              decoration: BoxDecoration(
                color: palette.panel.withValues(alpha: 0.8),
                borderRadius: BorderRadius.circular(AppRadii.xs),
                border: Border.all(
                  color: const Color(0x22FFFFFF),
                  width: 0.8,
                ),
              ),
            ),
          ),

          // 4. 底部占位标题条（模拟文字主条与副条）
          Positioned(
            left: 10,
            right: 10,
            bottom: 12,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // 模拟影视标题
                FractionallySizedBox(
                  widthFactor: 0.75,
                  child: Container(
                    height: 12,
                    decoration: BoxDecoration(
                      color: palette.textDim.withValues(alpha: 0.35),
                      borderRadius: BorderRadius.circular(AppRadii.xs),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                // 模拟评分/年份标签
                Container(
                  width: 38,
                  height: 9,
                  decoration: BoxDecoration(
                    color: palette.textDim.withValues(alpha: 0.22),
                    borderRadius: BorderRadius.circular(AppRadii.xs),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
