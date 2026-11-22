import 'package:flutter/material.dart';

import '../../../core/danmaku/danmaku_api.dart';
import '../../../core/danmaku/danmaku_source.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';

/// 设置中心与播放弹窗共用的内置接口选择器，只展示名称，不展示私有地址。
class DanmakuSourceDropdown extends StatelessWidget {
  const DanmakuSourceDropdown({
    super.key,
    required this.source,
    required this.onChanged,
  });

  final DanmakuSource source;
  final ValueChanged<DanmakuSource> onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final configured = configuredDanmakuSources;
    final sources = configured.isEmpty ? [DanmakuSource.primary] : configured;
    final selected = sources.contains(source) ? source : sources.first;
    return DropdownButtonHideUnderline(
      child: DropdownButton<DanmakuSource>(
        value: selected,
        isExpanded: true,
        dropdownColor: palette.panel,
        borderRadius: BorderRadius.circular(AppRadii.md),
        iconEnabledColor: palette.textSub,
        style: TextStyle(color: palette.textMain, fontSize: AppType.label),
        items: [
          for (final source in sources)
            DropdownMenuItem(
              value: source,
              child: Text(
                source.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        onChanged: sources.length < 2
            ? null
            : (value) {
                if (value != null && value != selected) onChanged(value);
              },
      ),
    );
  }
}
