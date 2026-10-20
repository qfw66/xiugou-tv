import 'dart:io';

import 'package:path/path.dart' as p;

/// 应用图标（单版，§12-C 图标统一）：
/// 圆角化浅色版（r = 56/256），不再随主题切换素材；
/// exe / 安装器 / 任务栏使用同源圆角化的 `app_icon.ico`。
const String appIconAsset = 'assets/icons/app_icon.png';

/// 原生窗口 / 任务栏图标需要磁盘路径；Flutter 资源打包在
/// `<exe 目录>/data/flutter_assets/assets/icons/app_icon.png`（debug 与 release 布局一致）。
String appIconFilePath() => p.joinAll([
      p.dirname(Platform.resolvedExecutable),
      'data',
      'flutter_assets',
      ...appIconAsset.split('/'),
    ]);
