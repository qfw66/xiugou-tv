import 'dart:io';

import 'package:flutter/services.dart';

/// 把子进程交给原生侧的 Job Object（见 `windows/runner/process_job.h`）。
///
/// 被收养的进程及其之后派生的全部子孙，会在主程序以**任何方式**退出时（正常关闭、崩溃、
/// 被任务管理器结束）由系统一并终止——这是 companion 自身看门狗之外的最后一道兜底。
/// 只收养 companion：重启、更新安装器、打开链接这类本就该脱离主程序存活的进程绝不能收养。
class ProcessJob {
  const ProcessJob._();

  static const MethodChannel _channel = MethodChannel('xiugou/process_job');

  /// 收养成功返回 true；非 Windows、原生侧未注册（如测试环境）或调用失败返回 false。
  static Future<bool> adopt(int pid) async {
    if (!Platform.isWindows) return false;
    try {
      return await _channel.invokeMethod<bool>('adopt', pid) ?? false;
    } catch (_) {
      return false;
    }
  }
}
