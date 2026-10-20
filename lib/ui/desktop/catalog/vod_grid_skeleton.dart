import 'package:flutter/material.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';
import 'vod_grid_view.dart' show VodGridMetrics;

/// 首页 / 分类海报网格的首屏加载骨架（backlog §1 · B2）。
///
/// 设计取舍（已批准）：
/// - 与真实网格共用 [VodGridMetrics]：同列数、同间距、同宽高比，加载完成时
///   不发生布局跳变（skill: `content-jumping` / `progressive-loading`）；
/// - **静态灰块 + 单次淡入 200ms**，不做循环 shimmer：保证 `pumpAndSettle`
///   类测试稳定，也对动效敏感人群友好（skill: `reduced-motion` 精神）。
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
    final palette = AppPalette.of(context);
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
            itemBuilder: (context, index) => _SkeletonCard(palette: palette),
          );
        },
      ),
    );
  }
}

/// 单张占位卡：结构对齐真实卡片（海报区 + 标题区），仅用色块占位。
class _SkeletonCard extends StatelessWidget {
  final AppPalette palette;

  const _SkeletonCard({required this.palette});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: palette.card,
        borderRadius: BorderRadius.circular(AppRadii.md),
        border: Border.all(color: palette.borderStrong, width: 1.0),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 海报占位色块
          Expanded(child: ColoredBox(color: palette.raised)),
          // 标题占位条（标题区高度对齐真实卡片：8+17+8）
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            color: palette.panel,
            child: SizedBox(
              height: 17,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Container(
                  width: 84,
                  height: 10,
                  decoration: BoxDecoration(
                    color: palette.raised,
                    borderRadius: BorderRadius.circular(AppRadii.xs),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
