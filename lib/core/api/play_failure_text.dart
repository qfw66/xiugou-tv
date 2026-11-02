import 'dart:async';

import '../companion/companion_process_manager.dart' show CompanionStatus;
import '../companion/companion_spider_api.dart' show SpiderCallException;

/// 解析播放地址失败时给用户看的提示。选集起播、切集、自动换线、刷新、历史续播共用一套口径。
///
/// 以前有两种问题：一是一律提示「播放解析失败」并让用户去检查解析配置，站源根本没给地址时
/// 也让用户去改解析；二是直接把异常原文（如 `FormatException: Spider 未返回播放地址`）显示出来。
/// 现在按原因分开说：
/// - 站源服务明确给了原因（[SpiderCallException]，如「源方可能已关闭网盘在线模式」）：原样展示；
/// - 站源没有返回地址：说明是站源这一侧没给，建议换线；
/// - 解析超时：超时提示；
/// - 爬虫服务没起来：说明服务未就绪；
/// - 其余（解析规则失败等）：沿用「请检查站源或解析配置」。
///
/// [allLines] 为 true 表示同一集的所有备用线路都试过了。
String playResolveFailureText(Object? error, {bool allLines = false}) {
  if (error is SpiderCallException && error.message.trim().isNotEmpty) {
    final reason = error.message.trim();
    return allLines ? '所有线路都无法播放：$reason' : reason;
  }
  if (error is TimeoutException) {
    return allLines ? '所有线路解析超时，请稍后重试' : '解析播放地址超时，请稍后重试或换一条线路';
  }
  final text = error is FormatException ? error.message : '${error ?? ''}';
  if (text.contains('Companion 服务不可用')) {
    return '站源爬虫服务未就绪，请稍后重试；多次失败可在「设置 → 关于 → 错误日志」查看原因';
  }
  if (text.contains('未返回播放地址') ||
      text.contains('未返回有效媒体地址') ||
      text.contains('Spider 播放响应格式无效')) {
    return allLines
        ? '所有线路都没有返回可播放的地址，请稍后重试或换个站源'
        : '站源没有返回这一集的播放地址，请换一条线路或稍后重试';
  }
  return allLines ? '所有备用线路均不可用，请稍后重试' : '播放解析失败，请检查站源或解析配置';
}

/// 爬虫类站源（csp_ / JS / Python / type 3）在爬虫服务没就绪时，首页与详情的提示。
///
/// 旧文案是「属于 Android Dex 爬虫插件，桌面端暂不支持」。现在桌面端已经能运行安卓 Dex
/// 插件（companion），这句话不再成立，用户看了会误以为这个站永远用不了。
String companionUnavailableText(String siteName, CompanionStatus status) {
  final name = siteName.trim().isEmpty ? '该站源' : '站源「${siteName.trim()}」';
  if (status == CompanionStatus.unsupported) {
    return '$name需要内置的 Java 运行环境，但没有找到，请重新安装修狗TV 后再试';
  }
  return '$name的爬虫服务没有启动成功，请点「重试」；仍然失败可在「设置 → 关于 → 错误日志」查看原因';
}
