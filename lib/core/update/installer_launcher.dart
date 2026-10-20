import 'dart:io';

import 'package:path/path.dart' as p;

typedef ProcessStarter = Future<Process> Function(
    String executable, List<String> arguments);

/// 安装版识别与外部程序启动。
///
/// 安装版判定：可执行文件同目录存在 Inno Setup 生成的 `unins000.exe`。
/// 便携版（解压 zip）没有该文件，因此只提示、不自动替换。
class InstallerLauncher {
  final ProcessStarter _start;
  final String? Function() _executablePath;

  InstallerLauncher({
    ProcessStarter? start,
    String? Function()? executablePath,
  })  : _start = start ??
            ((executable, arguments) => Process.start(executable, arguments,
                mode: ProcessStartMode.detached)),
        _executablePath = executablePath ?? (() => Platform.resolvedExecutable);

  bool get isInstalledBuild => isInstalledExecutable(_executablePath() ?? '');

  /// 纯函数版本的判定，便于测试直接给路径。
  static bool isInstalledExecutable(String executablePath) {
    if (executablePath.trim().isEmpty) return false;
    final uninstaller = File(p.join(p.dirname(executablePath), 'unins000.exe'));
    return uninstaller.existsSync();
  }

  /// 启动安装程序。`/CLOSEAPPLICATIONS` 让安装器能替换正在运行的文件，
  /// `/NORESTART` 避免安装器自行重启系统。
  Future<bool> launch(String setupPath) async {
    try {
      if (!File(setupPath).existsSync()) return false;
      await _start(setupPath, const ['/CLOSEAPPLICATIONS', '/NORESTART']);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 用系统默认浏览器打开链接（不经 shell 拼接命令）。
  Future<bool> openUrl(String url) async {
    try {
      await _start('rundll32.exe', ['url.dll,FileProtocolHandler', url]);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 打开所在文件夹。
  Future<bool> openFolder(String path) async {
    try {
      await _start('explorer.exe', [path]);
      return true;
    } catch (_) {
      return false;
    }
  }
}
