import 'dart:io';

import 'package:dio/dio.dart';

import '../config/config_repository.dart';
import '../config/models/vod_config.dart';
import '../live/live_repository.dart';
import '../live/live_source.dart';
import '../live/live_switch_reconcile.dart';
import '../settings/models/config_source_entry.dart';

/// 切换配置源后的处理结果：只描述「发生了什么」，由宿主决定如何提示与打开弹窗。
///
/// 这样核心流程（加载配置 → 加载直播目录 → 按 §4.3 对账）可以在不依赖 Flutter /
/// Riverpod 的情况下测试；app.dart 只负责确认框、忙碌态与弹窗。
class ConfigSwitchResult {
  const ConfigSwitchResult({
    this.configChanged = false,
    this.liveUpdated = false,
    this.channelKept = false,
    this.ignored = false,
    this.action = ConfigSwitchAction.none,
    this.message,
    this.level = ConfigSwitchMessageLevel.info,
  });

  /// 新配置是否已成功应用。
  final bool configChanged;

  /// 是否已更新直播运行态（保留频道 / 起播新频道 / 停止直播）。
  final bool liveUpdated;

  /// 新配置中仍存在切换前的频道，播放未被打断。
  final bool channelKept;

  /// 并发点击时被忽略的调用。
  final bool ignored;

  final ConfigSwitchAction action;
  final String? message;
  final ConfigSwitchMessageLevel level;
}

enum ConfigSwitchAction { none, openChannelManager }

enum ConfigSwitchMessageLevel { info, warning, error }

/// 切换前的直播运行态快照（与 app.dart 的 LivePlaybackRuntime 结构一致）。
typedef LiveSwitchRuntime = ({List<Live> channels, int index});

/// 配置源切换流程（方案 §4.3）。
class ConfigSourceSwitcher {
  ConfigSourceSwitcher({
    required this.configRepository,
    required this.liveRepository,
    required this.onRuntimeUpdated,
    required this.onStartChannel,
    required this.onStopPlayback,
  });

  final ConfigRepository configRepository;
  final LiveRepository liveRepository;

  /// 新配置里仍能找到当前频道：只更新运行态，不重新起播。
  final void Function(List<Live> channels, int index) onRuntimeUpdated;

  /// 新配置里没有当前频道：起播新配置的第一个频道。
  final Future<bool> Function(List<Live> channels, int index) onStartChannel;

  /// 新配置没有任何直播源：停止直播，由宿主清空 activePlaySpec 等状态。
  final Future<void> Function() onStopPlayback;

  bool _running = false;

  bool get running => _running;

  Future<ConfigSwitchResult> switchTo({
    required ConfigSourceEntry entry,
    required LiveSwitchRuntime? previousRuntime,
    Future<int?> Function(List<DepotEntry> entries)? selectDepot,
  }) async {
    if (_running) return const ConfigSwitchResult(ignored: true);
    _running = true;
    try {
      final VodConfig config;
      try {
        config = entry.kind == ConfigSourceKind.file
            ? await configRepository.loadFromFile(entry.location,
                selectDepot: selectDepot)
            : await configRepository.loadFromInput(entry.location,
                selectDepot: selectDepot);
      } on DepotSelectionCancelled {
        return const ConfigSwitchResult(
          message: '已取消切换配置源',
          level: ConfigSwitchMessageLevel.info,
        );
      } on ConfigLoadSuperseded {
        return const ConfigSwitchResult();
      } catch (error) {
        return ConfigSwitchResult(
          message: '切换配置源失败：${configSwitchErrorText(error)}；当前配置未改变',
          level: ConfigSwitchMessageLevel.error,
        );
      }

      final name = entry.displayName;
      if (previousRuntime == null) {
        return ConfigSwitchResult(
          configChanged: true,
          message: '已切换至「$name」',
        );
      }

      final LiveCatalog catalog;
      try {
        final sourceUrl = configRepository.currentWindowConfig.lastConfigUrl;
        catalog = await liveRepository.load(
          config.lives,
          baseUri: sourceUrl == null ? null : Uri.tryParse(sourceUrl),
        );
      } catch (error) {
        return ConfigSwitchResult(
          configChanged: true,
          message: '配置已切换，但直播源加载失败：${configSwitchErrorText(error)}',
          level: ConfigSwitchMessageLevel.error,
        );
      }

      final current = _currentChannel(previousRuntime);
      final reconciled = reconcileLiveAfterConfigSwitch(
        catalog: catalog,
        current: current,
        previousScopeId: null,
      );

      if (reconciled.found && !reconciled.requiresRestart) {
        onRuntimeUpdated(reconciled.channels, reconciled.index);
        return ConfigSwitchResult(
          configChanged: true,
          liveUpdated: true,
          channelKept: true,
          message: '已切换至「$name」，当前频道继续播放',
        );
      }

      if (reconciled.channels.isNotEmpty) {
        final started = await onStartChannel(
          reconciled.channels,
          reconciled.index,
        );
        return ConfigSwitchResult(
          configChanged: true,
          liveUpdated: true,
          message: started ? '已切换至「$name」' : '已切换至「$name」，但直播起播失败',
          level: started
              ? ConfigSwitchMessageLevel.info
              : ConfigSwitchMessageLevel.warning,
        );
      }

      await onStopPlayback();
      return ConfigSwitchResult(
        configChanged: true,
        liveUpdated: true,
        action: ConfigSwitchAction.openChannelManager,
        message: '「$name」没有可用直播源',
        level: ConfigSwitchMessageLevel.warning,
      );
    } finally {
      _running = false;
    }
  }

  Live? _currentChannel(LiveSwitchRuntime runtime) {
    if (runtime.index < 0 || runtime.index >= runtime.channels.length) {
      return null;
    }
    return runtime.channels[runtime.index];
  }
}

/// 切换配置源时展示给用户的错误摘要。
String configSwitchErrorText(Object error) {
  if (error is FormatException) return error.message;
  if (error is StateError) return error.message;
  if (error is FileSystemException) {
    final path = error.path ?? '';
    if (path.isEmpty || error.message.contains(path)) return error.message;
    return '${error.message}：$path';
  }
  if (error is DioException) {
    if (error.type == DioExceptionType.badResponse) {
      return 'HTTP ${error.response?.statusCode ?? '错误'}';
    }
    if (error.type == DioExceptionType.connectionError) return '无法连接';
    if (error.type == DioExceptionType.badCertificate) return '证书无效';
    if (error.type == DioExceptionType.cancel) return '已取消';
    if (error.type.name.toLowerCase().contains('timeout')) return '连接超时';
    return '网络错误';
  }
  return error.toString().replaceFirst('Exception: ', '');
}
