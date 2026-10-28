import 'package:flutter/material.dart';

/// 输入框专用的「视觉密度」覆盖（§26 / §42）。
///
/// 桌面端 `ThemeData.visualDensity` 默认取 `VisualDensity.adaptivePlatformDensity`，
/// 在 Windows 上等于 `compact`（vertical: -2）。`InputDecorator._layout` 会把这
/// 8 个逻辑像素**整份**减进 `contentHeight`，却只在基线上补回 `dy / 2` ——
/// 当输入框的可用高度被父级**夹住**时（顶栏 30px 胶囊就是），净效果就是把
/// 输入框与提示整体**下压 `|dy| / 2` = 4 逻辑像素**（实测见 §26 第 3 轮：
/// 胶囊 46 物理像素高，提示墨迹比中心低 7.5 物理像素 = 5 逻辑像素）。
///
/// 只包输入框本身，不要连按钮、开关一起包进来：全局 compact 的尺寸与间距是有意的。
///
/// **用在哪**：高度被夹住的输入框（如 30px 搜索胶囊）。
/// **别乱用**：对话框里高度不受限的输入框本来就不偏 —— 真机实测（WebDAV 弹窗，
/// 3 个 dense 描边输入框）compact 与 standard 的文字都在盒心，差别只是盒高
/// 36px vs 44px。给它们加这层覆盖等于把字段撑高 8px，属于可见的尺寸变化而非修正。
class AppInputDensity extends StatelessWidget {
  const AppInputDensity({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(visualDensity: VisualDensity.standard),
      child: child,
    );
  }
}
