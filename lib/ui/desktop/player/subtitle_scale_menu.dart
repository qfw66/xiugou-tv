import 'package:flutter/material.dart';

import '../../theme/app_tokens.dart';

List<PopupMenuEntry<String>> subtitleScaleMenuItems({
  required double? current,
  required ValueChanged<double> onSelected,
}) => [
  const PopupMenuDivider(),
  PopupMenuItem<String>(
    enabled: false,
    height: 32,
    child: Text(
      current == null ? '字号仅适用于文本字幕' : '字幕字号',
      style: const TextStyle(fontSize: AppType.caption),
    ),
  ),
  if (current != null)
    for (final factor in const [0.75, 1.0, 1.25, 1.5, 2.0])
      CheckedPopupMenuItem<String>(
        height: 40,
        checked: (factor - current).abs() < 0.001,
        onTap: () => onSelected(factor),
        child: Text(
          factor == 1 ? '100%（默认）' : '${(factor * 100).round()}%',
          style: const TextStyle(fontSize: AppType.body),
        ),
      ),
];
