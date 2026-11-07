import 'package:flutter/foundation.dart';

/// 解析出的清晰度选项；选择意图由宿主提交，UI 不提前改变当前档位。
@immutable
class PlayerQualityNav {
  const PlayerQualityNav({
    required this.names,
    required this.selectedIndex,
    required this.onSelect,
    this.busy = false,
    this.label = '清晰度',
  });

  final String label;
  final List<String> names;
  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final bool busy;

  String get currentName => selectedIndex >= 0 && selectedIndex < names.length
      ? names[selectedIndex]
      : label;
}

/// 外部播放器仅由显式操作启动；资格、进程与忙态都由宿主管理。
@immutable
class PlayerExternalNav {
  const PlayerExternalNav({
    required this.onLaunch,
    this.busy = false,
    this.enabled = true,
    this.statusText,
  });

  final VoidCallback onLaunch;
  final bool busy;
  final bool enabled;
  final String? statusText;
}

/// 跨站查找由用户显式发起；宿主控制资格、进度、取消和最终播放事务。
@immutable
class PlayerSourceSwitchNav {
  const PlayerSourceSwitchNav({
    required this.onSearch,
    this.onCancel,
    this.busy = false,
    this.enabled = true,
    this.statusText,
  });

  final VoidCallback onSearch;
  final VoidCallback? onCancel;
  final bool busy;
  final bool enabled;
  final String? statusText;
}
