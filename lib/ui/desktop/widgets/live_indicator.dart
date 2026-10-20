import 'package:flutter/material.dart';

import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';

/// 直播热标（B6）：6px 圆点 + 短标，统一取 `danger`（直播的「热」信号）。
///
/// 频道卡的「LIVE」与 EPG 摘要的「正在播出」共用本组件——判别用例
/// 「LIVE 徽章与『正在播出』一致」的实现落点。
/// 短标单行、不换行（skill `compact-label-overflow`）；颜色不作唯一语义，
/// 文字本身已表达状态（`color-not-only`）。
class LiveIndicator extends StatelessWidget {
  const LiveIndicator({
    super.key,
    required this.label,
    this.fontSize = AppType.caption,
  });

  /// 短标文本（'LIVE' / '正在播出'）。
  final String label;

  /// 字号档位；缺省为角标档（频道卡），EPG 摘要用 [AppType.label]。
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.circle, size: 6, color: palette.danger),
        const SizedBox(width: 5),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.fade,
            softWrap: false,
            style: TextStyle(
              color: palette.danger,
              fontSize: fontSize,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
    );
  }
}
