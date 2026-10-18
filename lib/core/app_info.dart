import 'package:package_info_plus/package_info_plus.dart';

/// 构建注入的应用版本（`package_info_plus` 读取 exe 版本资源），供备份等
/// 非 UI 路径使用；未加载或读取失败时为 null（调用方兜底为「未知版本」）。
String? appVersionLabel;

/// 读取并缓存版本号；失败时保持 null（不写占位版本）。
Future<String?> loadAppVersionLabel() async {
  try {
    final info = await PackageInfo.fromPlatform();
    final build = info.buildNumber.trim();
    appVersionLabel =
        build.isEmpty ? info.version : '${info.version}+$build';
  } catch (_) {
    appVersionLabel = null;
  }
  return appVersionLabel;
}
