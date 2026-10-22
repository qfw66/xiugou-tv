import 'dart:async';
import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../../../core/config/config_repository.dart';
import '../../../core/companion/companion_process_manager.dart';
import '../../../core/companion/companion_spider_api.dart';
import '../../../core/config/models/vod_config.dart';
import '../../../core/config/windows_config_storage.dart';
import '../../../core/live/epg_repository.dart';
import '../../../core/player/models/player_settings.dart';
import '../../../core/settings/models/appearance_preferences.dart';
import '../../theme/app_icon_assets.dart';
import '../../theme/app_palette.dart';
import '../widgets/app_message.dart';
import '../widgets/focus_ring.dart';
import '../../theme/app_tokens.dart';
import '../../../core/settings/models/play_skip_preferences.dart';
import '../../../core/settings/wallpaper_store.dart';
import '../../../core/storage/cache_maintenance.dart';
import '../../../core/storage/data_backup_service.dart';
import '../../../core/storage/data_directory_manager.dart';
import '../../../core/storage/data_restore_guard.dart';
import '../../../core/storage/models/data_backup.dart';
import '../../../core/player/mpv_player_engine.dart';
import '../../../core/player/player_engine.dart';
import '../../../core/player/player_settings_application.dart';
import '../../../core/settings/models/config_source_entry.dart';
import '../../../core/settings/models/history_preferences.dart';
import '../../../core/settings/models/search_preferences.dart';
import '../../../core/settings/models/self_check_preferences.dart';
import '../../../core/settings/models/startup_preferences.dart';
import '../../../core/settings/settings_repository.dart';
import '../dialogs/depot_selection_dialog.dart';
import '../wallpaper/wallpaper_size_probe.dart';
import 'site_self_check_dialog.dart';

/// 设置中心分区
enum SettingsSection { configSources, general, appearance, player, about }

/// 独立全屏设置中心：左侧分区导航 + 右侧内容面板
class SettingsPage extends StatefulWidget {
  final ConfigRepository configRepository;
  final SettingsRepository settingsRepository;
  final VoidCallback onClose;

  /// 打开「添加 / 导入配置源」弹窗
  final Future<void> Function(BuildContext context) onAddConfig;

  /// 多仓选择（可注入以便测试；缺省弹出选仓弹窗）
  final DepotSelector? selectDepot;

  /// 导出保存位置选择（可注入以便测试；缺省弹出系统保存对话框）
  final Future<String?> Function(String suggestedName)? pickExportPath;

  final SettingsSection initialSection;
  final PlayerSettingsApplication? playerSettingsApplication;

  /// 播放引擎（关于分区展示引擎版本；缺省或非 mpv 引擎时显示不可用）
  final PlayerEngine? playerEngine;

  /// 存储与缓存盘点 / 清理（SET-09；可注入以便测试）
  final CacheMaintenance? cacheMaintenance;

  /// 节目单仓库（SET-09 清理 EPG 内存缓存；可注入以便测试）
  final EpgRepository? epgRepository;

  /// 数据备份与恢复（SET-10；可注入以便测试）
  final DataBackupService? dataBackupService;

  /// 恢复前检查是否正在播放（SET-10；播放中拒绝恢复）
  final bool Function()? isPlaybackActive;

  /// 备份保存位置选择（可注入以便测试；缺省弹出系统保存对话框）
  final Future<String?> Function(String suggestedName)? pickBackupSavePath;

  /// 备份文件选择（可注入以便测试；缺省弹出系统打开对话框）
  final Future<String?> Function()? pickBackupOpenPath;

  /// 壁纸副本管理（SET-08；可注入以便测试）
  final WallpaperStore? wallpaperStore;

  /// 壁纸选择器（可注入以便测试；缺省弹出系统文件选择框）
  final Future<String?> Function()? pickWallpaperPath;

  /// 关于页的更新区块（由宿主注入，缺省不显示，避免设置页依赖更新控制器）
  final Widget? updateSection;

  const SettingsPage({
    super.key,
    required this.configRepository,
    required this.settingsRepository,
    required this.onClose,
    required this.onAddConfig,
    this.selectDepot,
    this.pickExportPath,
    this.initialSection = SettingsSection.configSources,
    this.playerSettingsApplication,
    this.playerEngine,
    this.cacheMaintenance,
    this.epgRepository,
    this.dataBackupService,
    this.isPlaybackActive,
    this.pickBackupSavePath,
    this.pickBackupOpenPath,
    this.wallpaperStore,
    this.pickWallpaperPath,
    this.updateSection,
  });

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late SettingsSection _section = widget.initialSection;
  final FocusNode _focusNode = FocusNode(debugLabel: 'SettingsPage');

  @override
  void initState() {
    super.initState();
    // 设置页覆盖在主视图 / 播放器之上打开：主动取得焦点，保证 Esc 等按键由设置页处理
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): widget.onClose
      },
      child: Focus(
        focusNode: _focusNode,
        autofocus: true,
        child: ColoredBox(
          color: context.palette.background,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildSidebar(),
                const SizedBox(width: 14),
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: context.palette.panel,
                      borderRadius: BorderRadius.circular(AppRadii.lg),
                      border: Border.all(color: context.palette.divider),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      children: [
                        _SettingsSaveBanner(
                            key: ObjectKey(widget.settingsRepository),
                            repository: widget.settingsRepository),
                        _HomeSiteStatusBanner(
                            repository: widget.configRepository),
                        Expanded(
                          child: switch (_section) {
                            SettingsSection.configSources => ConfigSourcesPanel(
                                key: const ValueKey('settings-config-sources'),
                                configRepository: widget.configRepository,
                                settingsRepository: widget.settingsRepository,
                                onAddConfig: widget.onAddConfig,
                                selectDepot: widget.selectDepot,
                                pickExportPath: widget.pickExportPath,
                              ),
                            SettingsSection.general => GeneralSettingsPanel(
                                key: const ValueKey('settings-general'),
                                configRepository: widget.configRepository,
                                settingsRepository: widget.settingsRepository,
                                cacheMaintenance: widget.cacheMaintenance,
                                epgRepository: widget.epgRepository,
                                dataBackupService: widget.dataBackupService,
                                isPlaybackActive: widget.isPlaybackActive,
                                pickBackupSavePath: widget.pickBackupSavePath,
                                pickBackupOpenPath: widget.pickBackupOpenPath,
                              ),
                            SettingsSection.appearance => AppearancePanel(
                                key: const ValueKey('settings-appearance'),
                                settingsRepository: widget.settingsRepository,
                                wallpaperStore: widget.wallpaperStore ??
                                    WallpaperStore(
                                        probeSize: probeWallpaperImageSize),
                                pickWallpaperPath: widget.pickWallpaperPath,
                              ),
                            SettingsSection.player => PlayerSettingsPanel(
                                key: const ValueKey('settings-player'),
                                settingsRepository: widget.settingsRepository,
                                application: widget.playerSettingsApplication,
                              ),
                            SettingsSection.about => AboutPanel(
                                key: const ValueKey('settings-about'),
                                playerEngine: widget.playerEngine,
                                updateSection: widget.updateSection,
                              ),
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSidebar() {
    return Container(
      width: 180,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
      decoration: BoxDecoration(
        color: context.palette.panel,
        borderRadius: BorderRadius.circular(AppRadii.lg),
        border: Border.all(color: context.palette.border, width: 1.2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextButton.icon(
            onPressed: widget.onClose,
            icon: const Icon(Icons.arrow_back_rounded, size: 18),
            label: const Text('返回'),
            style: TextButton.styleFrom(
              foregroundColor: context.palette.textSub,
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            child: Text('设置中心',
                style: TextStyle(
                    fontSize: AppType.h2,
                    fontWeight: FontWeight.bold,
                    color: context.palette.textTitle)),
          ),
          _SectionTab(
            icon: Icons.cloud_sync_outlined,
            label: '配置源管理',
            selected: _section == SettingsSection.configSources,
            onTap: () =>
                setState(() => _section = SettingsSection.configSources),
          ),
          const SizedBox(height: 8),
          _SectionTab(
            icon: Icons.rocket_launch_outlined,
            label: '通用',
            selected: _section == SettingsSection.general,
            onTap: () => setState(() => _section = SettingsSection.general),
          ),
          const SizedBox(height: 8),
          _SectionTab(
            icon: Icons.image_outlined,
            label: '外观',
            selected: _section == SettingsSection.appearance,
            onTap: () => setState(() => _section = SettingsSection.appearance),
          ),
          const SizedBox(height: 8),
          _SectionTab(
            icon: Icons.tune_rounded,
            label: '播放器与解码',
            selected: _section == SettingsSection.player,
            onTap: () => setState(() => _section = SettingsSection.player),
          ),
          const SizedBox(height: 8),
          _SectionTab(
            icon: Icons.info_outline,
            label: '关于',
            selected: _section == SettingsSection.about,
            onTap: () => setState(() => _section = SettingsSection.about),
          ),
        ],
      ),
    );
  }
}

class _SectionTab extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _SectionTab(
      {required this.icon,
      required this.label,
      required this.selected,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    return FocusRing(
        onTap: onTap,
        semanticLabel: label,
        borderRadius: const BorderRadius.all(Radius.circular(AppRadii.md)),
        child: Material(
          color: selected ? context.palette.accentWash : Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadii.md),
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadii.md),
            // hover 底用语义色板（B6：与主题同源，深浅两端都可辨）
            hoverColor: context.palette.hover,
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppRadii.md),
                border: Border.all(
                    color: selected
                        ? context.palette.accentInk
                        : Colors.transparent),
              ),
              child: Row(
                children: [
                  Icon(icon,
                      size: 18,
                      color: selected
                          ? context.palette.accentInk
                          : context.palette.textSub),
                  const SizedBox(width: 12),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: AppType.label,
                      fontWeight: selected ? FontWeight.bold : FontWeight.w500,
                      color: selected
                          ? context.palette.textTitle
                          : context.palette.textBody,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ));
  }
}

/// 分区通用骨架：标题 + 说明 + 可滚动内容
class _PanelScaffold extends StatelessWidget {
  final String title;
  final String subtitle;
  final List<Widget> actions;
  final List<Widget> children;

  const _PanelScaffold(
      {required this.title,
      required this.subtitle,
      this.actions = const [],
      required this.children});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: TextStyle(
                            fontSize: AppType.h2,
                            fontWeight: FontWeight.bold,
                            color: context.palette.textTitle)),
                    const SizedBox(height: 4),
                    Text(subtitle,
                        style: TextStyle(
                            fontSize: AppType.body,
                            color: context.palette.textSub)),
                  ],
                ),
              ),
              ...actions,
            ],
          ),
          const SizedBox(height: 24),
          ...children,
        ],
      ),
    );
  }
}

Widget _card(BuildContext context,
    {required Widget child,
    EdgeInsetsGeometry padding = const EdgeInsets.all(16)}) {
  return Container(
    padding: padding,
    decoration: BoxDecoration(
      color: context.palette.card,
      borderRadius: BorderRadius.circular(AppRadii.md),
      border: Border.all(color: context.palette.border),
    ),
    child: child,
  );
}

ButtonStyle _outlinedStyle(BuildContext context) => OutlinedButton.styleFrom(
      foregroundColor: context.palette.textBody,
      side: BorderSide(color: context.palette.borderStrong),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.sm)),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      textStyle: const TextStyle(fontSize: AppType.label),
    );

/// 主按钮（品牌底）统一样式：弹窗确认、添加配置源、选择壁纸共用。
///
/// `foregroundColor` 必须显式给 `onPrimary`：M3 下 `ElevatedButton` 的默认
/// 前景是 `colorScheme.primary`（品牌色本身），只换背景会得到「同色字压同色底」
/// 的不可见按钮（2026-10-19 实机复现后修复）。
ButtonStyle _primaryStyle(BuildContext context) => ElevatedButton.styleFrom(
      backgroundColor: context.palette.accent,
      foregroundColor: Theme.of(context).colorScheme.onPrimary,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.sm)),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      textStyle: const TextStyle(fontSize: AppType.label),
    );

/// 设置项行内下拉的统一外观：深底 + 描边 + 定宽。
///
/// 外壳只是绘制层：内部的 `DropdownButton`（含 key 与 onChanged）保持原样，
/// 测试与无障碍对控件类型的依赖不受影响。
Widget _boxedDropdown(BuildContext context,
    {double width = _kSelectWidth, required Widget child}) {
  return Container(
    width: width,
    padding: const EdgeInsets.symmetric(horizontal: 12),
    decoration: BoxDecoration(
      color: context.palette.raised,
      borderRadius: BorderRadius.circular(AppRadii.sm),
      border: Border.all(color: context.palette.borderStrong),
    ),
    child: DropdownButtonHideUnderline(child: child),
  );
}

String _formatTime(int millis) {
  if (millis <= 0) return '—';
  final t = DateTime.fromMillisecondsSinceEpoch(millis);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}

String _errorText(Object error) {
  if (error is FormatException) return error.message;
  if (error is StateError) return error.message;
  return error.toString().replaceFirst('Exception: ', '');
}

/// 设置项行内控件定宽（下拉 / 滑块右置时的统一宽度）。
const double _kSelectWidth = 240;
const double _kSliderWidth = 300;

// =====================================================================
// 配置源管理
// =====================================================================

/// 配置源管理：当前配置概览、重新加载 / 导出、配置源历史（切换 / 测试 / 重命名 / 删除）
class ConfigSourcesPanel extends StatefulWidget {
  final ConfigRepository configRepository;
  final SettingsRepository settingsRepository;
  final Future<void> Function(BuildContext context) onAddConfig;
  final DepotSelector? selectDepot;
  final Future<String?> Function(String suggestedName)? pickExportPath;

  const ConfigSourcesPanel({
    super.key,
    required this.configRepository,
    required this.settingsRepository,
    required this.onAddConfig,
    this.selectDepot,
    this.pickExportPath,
  });

  @override
  State<ConfigSourcesPanel> createState() => _ConfigSourcesPanelState();
}

class _ConfigSourcesPanelState extends State<ConfigSourcesPanel> {
  final Map<String, ConfigProbeResult> _probeResults = {};
  final Set<String> _probing = {};

  /// 正在执行的加载动作（地址 / 'reload'）；同一时间只允许一个加载
  String? _loadingKey;
  bool _exporting = false;

  ConfigRepository get _repo => widget.configRepository;
  SettingsRepository get _settings => widget.settingsRepository;

  // 流只创建一次：每次 build 重新取 getter 会让 StreamBuilder 反复退订 / 重订
  late final Stream<VodConfig> _configStream = _repo.vodConfigStream;
  late final Stream<List<ConfigSourceEntry>> _sourcesStream =
      _settings.configSourcesStream;
  late final Stream<SelfCheckPreferences> _selfCheckStream =
      _settings.selfCheckPreferencesStream;

  void _toast(String message, {AppMessageType type = AppMessageType.info}) {
    if (!mounted) return;
    // 同文案消息由 AppMessageHost 合并并重置倒计时，替代 hideCurrentSnackBar 的
    // 「替换上一条」语义。
    showAppMessage(message, type: type);
  }

  Future<int?> _defaultSelectDepot(List<DepotEntry> entries) async {
    // 加载期间用户可能已离开设置中心：此时视为取消选仓
    if (!mounted) return null;
    return showDialog<int>(
      context: context,
      barrierDismissible: false,
      builder: (_) => DepotSelectionDialog(entries: entries),
    );
  }

  Future<void> _runLoad(String key, Future<VodConfig> Function() task,
      String successLabel) async {
    if (_loadingKey != null) return;
    setState(() => _loadingKey = key);
    try {
      final config = await task();
      _toast(
          '$successLabel：${config.sites.length} 个站点 · ${config.lives.length} 个直播',
          type: AppMessageType.success);
    } on DepotSelectionCancelled {
      // 用户取消选仓：保持当前配置
    } catch (error) {
      _toast('加载失败：${_errorText(error)}', type: AppMessageType.error);
    } finally {
      if (mounted) setState(() => _loadingKey = null);
    }
  }

  Future<void> _useEntry(ConfigSourceEntry entry) {
    final selectDepot = widget.selectDepot ?? _defaultSelectDepot;
    return _runLoad(
      entry.location,
      () => entry.kind == ConfigSourceKind.file
          ? _repo.loadFromFile(entry.location, selectDepot: selectDepot)
          : _repo.loadFromInput(entry.location, selectDepot: selectDepot),
      '已切换到「${entry.displayName}」',
    );
  }

  Future<void> _reload() => _runLoad('reload', _repo.reloadCurrent, '已重新加载');

  Future<void> _setHomeSite(Site? site, String identity) async {
    try {
      await _repo.setDefaultHomeSite(site, configIdentity: identity);
    } catch (error) {
      if (_repo.homeSiteSaveError == null) {
        _toast(_errorText(error), type: AppMessageType.error);
      }
    }
  }

  Widget _buildHomeSiteCard() => StreamBuilder<void>(
        stream: _repo.homeSitePreferencesStream,
        builder: (context, _) {
          final sites = _repo.availableHomeSites;
          // 下拉额外包含内置虚拟站（豆瓣热播）；footer 的失效提示仍按配置站源算（§17）
          final choices = _repo.homeSiteChoices;
          final identity = _repo.currentConfigIdentity;
          final preferred = _repo.defaultHomeSite;
          final fallback = _repo.homeSiteFallbackMessage;
          final selected = preferred == null ? -1 : choices.indexOf(preferred);
          final enabled = identity != null &&
              _repo.homeSiteReadError == null &&
              (choices.isNotEmpty || _repo.homeSitePreference != null);
          return _card(
            context,
            child: _SettingRow(
              title: '首页默认站源',
              description: _repo.currentVodConfig.sites.isEmpty
                  ? '请先导入包含站点的配置'
                  : '下次启动或切回此配置时生效；标题栏临时切站不会修改此偏好。「自动选择」= 没有固定站源时默认落在「豆瓣热播」。',
              trailing: _boxedDropdown(
                context,
                child: Semantics(
                  label: '首页默认站源',
                  child: DropdownButton<int>(
                    key: const ValueKey('default-home-site'),
                    value: fallback == null ? selected : -2,
                    isExpanded: true,
                    dropdownColor: context.palette.raised,
                    style: TextStyle(
                        fontSize: AppType.label,
                        color: context.palette.textMain),
                    items: [
                      const DropdownMenuItem(value: -1, child: Text('自动选择')),
                      if (fallback != null)
                        DropdownMenuItem(
                          value: -2,
                          enabled: false,
                          child: Text('已失效：${_repo.homeSitePreference!.name}',
                              overflow: TextOverflow.ellipsis),
                        ),
                      for (var i = 0; i < choices.length; i++)
                        DropdownMenuItem(
                          value: i,
                          child: Text(
                            choices
                                        .where((site) =>
                                            site.name == choices[i].name)
                                        .length >
                                    1
                                ? '${choices[i].name}（${choices[i].key}）'
                                : choices[i].name,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: !enabled
                        ? null
                        : (index) {
                            if (index == null || index == -2) return;
                            unawaited(_setHomeSite(
                                index == -1 ? null : choices[index], identity));
                          },
                  ),
                ),
              ),
              footer: (sites.length < _repo.currentVodConfig.sites.length ||
                      fallback != null)
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (sites.length < _repo.currentVodConfig.sites.length)
                          Text('无有效请求路径或标识重复的站源不可设为默认；可选择不代表远端可用。',
                              style: TextStyle(
                                  fontSize: AppType.caption,
                                  color: context.palette.textSub)),
                        if (fallback != null) ...[
                          const SizedBox(height: 8),
                          Text(fallback,
                              style: TextStyle(
                                  fontSize: AppType.body,
                                  color: context.palette.warning)),
                        ],
                      ],
                    )
                  : null,
            ),
          );
        },
      );

  /// 打开站点体检：先确保本地站点服务就绪，再把开关状态推到 Java 侧，
  /// 然后逐站探测（弹窗内部负责分批与进度）。
  Future<void> _openSelfCheck(VodConfig config) async {
    final sites = config.sites.where((site) => site.usesCompanion).toList();
    if (sites.isEmpty) {
      _toast('当前配置没有需要本地站点服务的站源');
      return;
    }

    final manager = CompanionProcessManager();
    if (!manager.isRunning) {
      _toast('正在启动本地站点服务…');
      final started = await manager.start();
      if (!started || !manager.isRunning) {
        _toast('本地站点服务未启动，无法体检', type: AppMessageType.warning);
        return;
      }
    }
    final api = CompanionSpiderApi(processManager: manager);
    // 服务刚启动时 Java 侧默认关闭自检：这里补一次下发，保证"能点按钮"就"能跑体检"。
    await api.configureSelfCheck(true);

    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => SiteSelfCheckDialog(sites: sites, api: api),
    );
  }

  Future<void> _probe(ConfigSourceEntry entry) async {
    if (_probing.contains(entry.location)) return;
    setState(() => _probing.add(entry.location));
    final result = await _repo.probeSource(entry.location);
    if (!mounted) return;
    setState(() {
      _probing.remove(entry.location);
      _probeResults[entry.location] = result;
    });
  }

  Future<void> _probeAll(List<ConfigSourceEntry> entries) async {
    await Future.wait(entries.map(_probe));
  }

  Future<void> _rename(ConfigSourceEntry entry) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _RenameDialog(initialName: entry.name),
    );
    if (name == null) return;
    await _saveWithStatus(_settings.renameConfigSource(entry.location, name));
  }

  Future<void> _remove(ConfigSourceEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: context.palette.raised,
        title: Text('移除配置源',
            style: TextStyle(
                fontSize: AppType.heading, color: context.palette.textTitle)),
        content: Text(
          '从历史中移除「${entry.displayName}」？\n不影响当前已加载的配置，也不会删除本地文件。',
          style: TextStyle(
              fontSize: AppType.label,
              height: 1.5,
              color: context.palette.textBody),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            // 「移除配置源」是破坏性操作，按 destructive-emphasis 用危险色
            child: Text('移除', style: TextStyle(color: context.palette.danger)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _saveWithStatus(_settings.removeConfigSource(entry.location));
    if (mounted) setState(() => _probeResults.remove(entry.location));
  }

  Future<String?> _defaultPickExportPath(String suggestedName) async {
    final location = await getSaveLocation(
      suggestedName: suggestedName,
      acceptedTypeGroups: const [
        XTypeGroup(label: 'JSON 配置', extensions: ['json'])
      ],
    );
    return location?.path;
  }

  Future<void> _export() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      final picker = widget.pickExportPath ?? _defaultPickExportPath;
      var path = await picker('xiugou-tv-config.json');
      if (path == null || path.trim().isEmpty) return;
      if (!path.toLowerCase().endsWith('.json')) path = '$path.json';
      await _repo.exportCurrentConfig(path);
      _toast('已导出到 $path', type: AppMessageType.success);
    } catch (error) {
      _toast('导出失败：${_errorText(error)}', type: AppMessageType.error);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // 配置来源随配置一同变化：每次配置广播后按仓库当前来源重建
    return StreamBuilder<VodConfig>(
      stream: _configStream,
      initialData: _repo.currentVodConfig,
      builder: (context, configSnap) => StreamBuilder<List<ConfigSourceEntry>>(
        stream: _sourcesStream,
        initialData: _settings.configSources,
        builder: (context, sourcesSnap) => StreamBuilder<SelfCheckPreferences>(
          stream: _selfCheckStream,
          initialData: _settings.selfCheckPreferences,
          builder: (context, selfCheckSnap) => _buildContent(
            configSnap.data ?? _repo.currentVodConfig,
            _repo.currentSourceKind,
            _repo.currentSourceLocation,
            sourcesSnap.data ?? const [],
            (selfCheckSnap.data ?? _settings.selfCheckPreferences).enabled,
          ),
        ),
      ),
    );
  }

  Widget _buildContent(
    VodConfig config,
    ConfigSourceKind? currentKind,
    String? currentLocation,
    List<ConfigSourceEntry> sources,
    bool selfCheckEnabled,
  ) {
    final hasConfig = config.sites.isNotEmpty || config.lives.isNotEmpty;
    final canReload =
        hasConfig && currentKind != null && currentLocation != null;
    final companionSites =
        config.sites.where((site) => site.usesCompanion).toList();
    final sourceText = !hasConfig
        ? '尚未加载配置'
        : currentLocation == null
            ? '粘贴内容'
            : '${currentKind == ConfigSourceKind.file ? '本地文件' : '远程订阅'}：$currentLocation';

    return _PanelScaffold(
      title: '配置源管理',
      subtitle: '管理订阅地址与本地配置，测试连通性，一键切换、重新加载或导出',
      actions: [
        ElevatedButton.icon(
          onPressed:
              _loadingKey != null ? null : () => widget.onAddConfig(context),
          icon: const Icon(Icons.add_rounded, size: 18),
          label: const Text('添加配置源'),
          style: _primaryStyle(context),
        ),
      ],
      children: [
        if (_repo.sourceRecoveryError case final error?) ...[
          _card(context,
              child: Text(error,
                  style: TextStyle(color: context.palette.warning))),
          const SizedBox(height: 16),
        ],
        _card(
          context,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('当前配置',
                  style: TextStyle(
                      fontSize: AppType.label,
                      fontWeight: FontWeight.bold,
                      color: context.palette.textMain)),
              const SizedBox(height: 8),
              SelectableText(
                sourceText,
                style: TextStyle(
                    fontSize: AppType.label, color: context.palette.textSub),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _StatChip(label: '站点', value: config.sites.length),
                  _StatChip(label: '直播', value: config.lives.length),
                  _StatChip(label: '解析', value: config.parses.length),
                ],
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  OutlinedButton.icon(
                    onPressed:
                        canReload && _loadingKey == null ? _reload : null,
                    icon: _loadingKey == 'reload'
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.refresh_rounded, size: 16),
                    label: const Text('重新加载'),
                    style: _outlinedStyle(context),
                  ),
                  OutlinedButton.icon(
                    onPressed: hasConfig && !_exporting ? _export : null,
                    icon: const Icon(Icons.file_download_outlined, size: 16),
                    label: const Text('导出当前配置'),
                    style: _outlinedStyle(context),
                  ),
                  OutlinedButton.icon(
                    onPressed: selfCheckEnabled && companionSites.isNotEmpty
                        ? () => unawaited(_openSelfCheck(config))
                        : null,
                    icon:
                        const Icon(Icons.health_and_safety_outlined, size: 16),
                    label: const Text('站点体检'),
                    style: _outlinedStyle(context),
                  ),
                ],
              ),
              if (!selfCheckEnabled)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '「站点体检」需先在「通用」中开启「站点自检」开关；关闭时不打印体检日志，也不发起探测。',
                    style: TextStyle(
                        fontSize: AppType.body, color: context.palette.textSub),
                  ),
                )
              else if (companionSites.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '当前配置没有需要本地站点服务的站源（csp_ / .js 等），无需体检。',
                    style: TextStyle(
                        fontSize: AppType.body, color: context.palette.textSub),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _buildHomeSiteCard(),
        const SizedBox(height: 24),
        Row(
          children: [
            Text('配置源历史（${sources.length}）',
                style: TextStyle(
                    fontSize: AppType.title,
                    fontWeight: FontWeight.bold,
                    color: context.palette.textMain)),
            const Spacer(),
            TextButton.icon(
              onPressed: sources.isEmpty ? null : () => _probeAll(sources),
              icon: const Icon(Icons.network_check_rounded, size: 16),
              label: const Text('全部测试'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (sources.isEmpty)
          _card(
            context,
            child: Text(
              '暂无记录。通过「添加配置源」成功加载的地址或本地文件会自动出现在这里。',
              style: TextStyle(
                  fontSize: AppType.label, color: context.palette.textSub),
            ),
          )
        else
          for (final entry in sources) ...[
            _SourceRow(
              entry: entry,
              isCurrent: entry.kind == currentKind &&
                  entry.location == currentLocation,
              probe: _probeResults[entry.location],
              probing: _probing.contains(entry.location),
              loading: _loadingKey == entry.location,
              loadDisabled: _loadingKey != null,
              onUse: () => _useEntry(entry),
              onProbe: () => _probe(entry),
              onRename: () => _rename(entry),
              onRemove: () => _remove(entry),
            ),
            const SizedBox(height: 8),
          ],
      ],
    );
  }
}

/// 重命名弹窗：自行持有输入控制器，避免关闭动画期间控制器已被释放
class _RenameDialog extends StatefulWidget {
  final String initialName;

  const _RenameDialog({required this.initialName});

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialName);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: context.palette.raised,
      title: Text('重命名配置源',
          style: TextStyle(
              fontSize: AppType.heading, color: context.palette.textTitle)),
      content: SizedBox(
        width: 420,
        child: TextField(
          controller: _controller,
          autofocus: true,
          style: TextStyle(
              fontSize: AppType.label, color: context.palette.textMain),
          decoration: const InputDecoration(hintText: '留空则显示地址'),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消')),
        TextButton(
            onPressed: () => Navigator.of(context).pop(_controller.text),
            child: const Text('保存')),
      ],
    );
  }
}

class _StatChip extends StatelessWidget {
  final String label;
  final int value;

  const _StatChip({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
          color: context.palette.raised,
          borderRadius: BorderRadius.circular(AppRadii.sm)),
      child: Text('$label $value',
          style: TextStyle(
              fontSize: AppType.body, color: context.palette.textBody)),
    );
  }
}

class _SourceRow extends StatelessWidget {
  final ConfigSourceEntry entry;
  final bool isCurrent;
  final ConfigProbeResult? probe;
  final bool probing;
  final bool loading;
  final bool loadDisabled;
  final VoidCallback onUse;
  final VoidCallback onProbe;
  final VoidCallback onRename;
  final VoidCallback onRemove;

  const _SourceRow({
    required this.entry,
    required this.isCurrent,
    required this.probe,
    required this.probing,
    required this.loading,
    required this.loadDisabled,
    required this.onUse,
    required this.onProbe,
    required this.onRename,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final isFile = entry.kind == ConfigSourceKind.file;
    return _card(
      context,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Icon(isFile ? Icons.insert_drive_file_outlined : Icons.link_rounded,
              size: 18, color: context.palette.textSub),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        entry.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: AppType.label,
                            fontWeight: FontWeight.w600,
                            color: context.palette.textMain),
                      ),
                    ),
                    if (isCurrent) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                            color: context.palette.accent,
                            borderRadius: BorderRadius.circular(AppRadii.xs)),
                        // 角标压在品牌色上，文字跟随 onPrimary（近黑）
                        child: Text('当前',
                            style: TextStyle(
                                fontSize: AppType.caption,
                                color:
                                    Theme.of(context).colorScheme.onPrimary)),
                      ),
                    ],
                  ],
                ),
                if (entry.name.trim().isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(entry.location,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: AppType.body,
                          color: context.palette.textSub)),
                ],
                const SizedBox(height: 4),
                Text(
                  '${isFile ? '本地文件' : '远程订阅'} · 上次使用 ${_formatTime(entry.lastUsedAt)} · ${entry.siteCount} 个站点',
                  style: TextStyle(
                      fontSize: AppType.body, color: context.palette.textSub),
                ),
                if (probing || probe != null) ...[
                  const SizedBox(height: 4),
                  _ProbeLine(probe: probe, probing: probing),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: loadDisabled ? null : onUse,
            child: loading
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : Text(isCurrent ? '重新使用' : '使用'),
          ),
          IconButton(
            tooltip: '测试连通性',
            onPressed: probing ? null : onProbe,
            icon: const Icon(Icons.network_check_rounded, size: 18),
          ),
          IconButton(
              tooltip: '重命名',
              onPressed: onRename,
              icon: const Icon(Icons.edit_outlined, size: 18)),
          IconButton(
              tooltip: '移除',
              onPressed: onRemove,
              icon: const Icon(Icons.delete_outline_rounded, size: 18)),
        ],
      ),
    );
  }
}

class _ProbeLine extends StatelessWidget {
  final ConfigProbeResult? probe;
  final bool probing;

  const _ProbeLine({required this.probe, required this.probing});

  @override
  Widget build(BuildContext context) {
    if (probing) {
      return Text('测试中…',
          style: TextStyle(
              fontSize: AppType.body, color: context.palette.textSub));
    }
    final result = probe!;
    final color = result.ok ? context.palette.success : context.palette.danger;
    return Row(
      children: [
        Icon(result.ok ? Icons.check_circle_rounded : Icons.error_rounded,
            size: 14, color: color),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            '${result.message} · ${result.latency.inMilliseconds} ms',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: AppType.body, color: color),
          ),
        ),
      ],
    );
  }
}

// =====================================================================
// 播放器与解码
// =====================================================================

/// 播放器与解码设置：分别展示保存状态与播放器参数确认结果
class PlayerSettingsPanel extends StatefulWidget {
  final SettingsRepository settingsRepository;

  final PlayerSettingsApplication? application;

  const PlayerSettingsPanel(
      {super.key, required this.settingsRepository, this.application});

  static const List<double> rateOptions = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0];

  @override
  State<PlayerSettingsPanel> createState() => _PlayerSettingsPanelState();
}

class _PlayerSettingsPanelState extends State<PlayerSettingsPanel> {
  static const List<double> rateOptions = PlayerSettingsPanel.rateOptions;

  SettingsRepository get settingsRepository => widget.settingsRepository;
  late final Stream<PlayerSettings> _stream =
      settingsRepository.playerSettingsStream;

  /// 片头片尾偏好：本面板持有一条订阅（避免 StreamBuilder 在懒加载列表中重复监听同一流）
  PlaySkipPreferences _playSkip = const PlaySkipPreferences();
  bool _playSkipReadFailed = false;
  StreamSubscription<PlaySkipPreferences>? _playSkipSubscription;

  @override
  void initState() {
    super.initState();
    _playSkip = settingsRepository.playSkipPreferences;
    _playSkipReadFailed = settingsRepository.playSkipReadFailed;
    _playSkipSubscription =
        settingsRepository.playSkipPreferencesStream.listen((next) {
      if (!mounted) return;
      setState(() {
        _playSkip = next;
        _playSkipReadFailed = settingsRepository.playSkipReadFailed;
      });
    });
  }

  @override
  void dispose() {
    unawaited(_playSkipSubscription?.cancel());
    super.dispose();
  }

  void _update(PlayerSettings next) {
    unawaited(_saveWithStatus(settingsRepository.updatePlayerSettings(next)));
  }

  /// 切换「片头片尾跳过」总开关（先落盘，失败走统一状态提示）。
  Future<void> _setPlaySkipEnabled(bool enabled) {
    final repository = settingsRepository;
    return _saveWithStatus(repository.updatePlaySkipPreferences(
      repository.playSkipPreferences.copyWith(enabled: enabled),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<PlayerSettings>(
      stream: _stream,
      initialData: settingsRepository.playerSettings,
      builder: (context, snapshot) {
        final s = snapshot.data ?? settingsRepository.playerSettings;
        return _PanelScaffold(
          title: '播放器与解码',
          subtitle: '修改后自动保存；即时参数的播放器确认结果见下方，保存与应用相互独立',
          actions: [
            OutlinedButton.icon(
              onPressed: s == PlayerSettings.defaults
                  ? null
                  : () => unawaited(_saveWithStatus(
                      settingsRepository.resetPlayerSettings())),
              icon: const Icon(Icons.restart_alt_rounded, size: 16),
              label: const Text('恢复默认'),
              style: _outlinedStyle(context),
            ),
          ],
          children: [
            _PlayerApplicationStatus(application: widget.application),
            const _GroupTitle('解码'),
            _card(
              context,
              child: Column(
                children: [
                  _SettingRow(
                    title: '解码方式',
                    description: '自动模式优先硬解并在失败时回退软解；画面异常或黑屏时可改用「拷回模式」或软件解码',
                    trailing: _OptionDropdown(
                      key: const ValueKey('setting-hwdec'),
                      options: PlayerSettings.hwdecOptions,
                      value: s.hwdec,
                      onChanged: (v) => _update(s.copyWith(hwdec: v)),
                    ),
                  ),
                  const _RowDivider(),
                  _SettingRow(
                    title: '网络缓冲时长',
                    description: '预读的最大秒数；网络不稳定时适当调大',
                    trailing: _SliderControl(
                      key: const ValueKey('setting-cache'),
                      value: s.cacheSecs.toDouble(),
                      min: PlayerSettings.minCacheSecs.toDouble(),
                      max: PlayerSettings.maxCacheSecs.toDouble(),
                      divisions: (PlayerSettings.maxCacheSecs -
                              PlayerSettings.minCacheSecs) ~/
                          5,
                      format: (v) => '${v.round()} 秒',
                      onCommit: (v) =>
                          _update(s.copyWith(cacheSecs: v.round())),
                    ),
                  ),
                ],
              ),
            ),
            const _GroupTitle('音频'),
            _card(
              context,
              child: Column(
                children: [
                  _SettingRow(
                    title: '声道输出',
                    description: '双声道混音适合耳机与普通音箱；5.1 / 7.1 需要对应的音响设备',
                    trailing: _OptionDropdown(
                      key: const ValueKey('setting-audio-channels'),
                      options: PlayerSettings.audioChannelOptions,
                      value: s.audioChannels,
                      onChanged: (v) => _update(s.copyWith(audioChannels: v)),
                    ),
                  ),
                  const _RowDivider(),
                  _SettingRow(
                    title: '音画同步偏置',
                    description: '正值让声音延后，负值让声音提前',
                    trailing: _SliderControl(
                      key: const ValueKey('setting-audio-delay'),
                      value: s.audioDelayMs.toDouble(),
                      min: PlayerSettings.minAudioDelayMs.toDouble(),
                      max: PlayerSettings.maxAudioDelayMs.toDouble(),
                      divisions: (PlayerSettings.maxAudioDelayMs -
                              PlayerSettings.minAudioDelayMs) ~/
                          100,
                      format: (v) =>
                          '${v >= 0 ? '+' : ''}${(v / 1000).toStringAsFixed(1)} 秒',
                      onCommit: (v) =>
                          _update(s.copyWith(audioDelayMs: v.round())),
                    ),
                  ),
                  const _RowDivider(),
                  _SettingRow(
                    title: '默认音量',
                    description: '下次启动时的初始音量',
                    trailing: _SliderControl(
                      key: const ValueKey('setting-volume'),
                      value: s.defaultVolume,
                      min: 0,
                      max: 100,
                      divisions: 20,
                      format: (v) => '${v.round()}%',
                      onCommit: (v) =>
                          _update(s.copyWith(defaultVolume: v.roundToDouble())),
                    ),
                  ),
                  const _RowDivider(),
                  _SettingRow(
                    title: '默认倍速',
                    description: '下次启动时的初始播放倍速',
                    trailing: _OptionDropdown(
                      key: const ValueKey('setting-rate'),
                      options: [
                        for (final r in rateOptions) PlayerOption('$r', '${r}x')
                      ],
                      value:
                          '${rateOptions.contains(s.defaultRate) ? s.defaultRate : 1.0}',
                      onChanged: (v) =>
                          _update(s.copyWith(defaultRate: double.parse(v))),
                    ),
                  ),
                ],
              ),
            ),
            const _GroupTitle('片头片尾'),
            _card(
              context,
              child: _SettingRow(
                title: '片头片尾跳过',
                description: _playSkipReadFailed
                    ? '片头片尾偏好读取失败，修复文件后可重新读取'
                    : '开启后：起播跳过片头，到达片尾点自动进入下一集（按影片记忆、跨集共享；播放器内可设置时间点）',
                trailing: Switch(
                  key: const ValueKey('setting-play-skip'),
                  value: _playSkip.enabled,
                  onChanged: _playSkipReadFailed
                      ? null
                      : (value) => unawaited(_setPlaySkipEnabled(value)),
                ),
                footer: _playSkipReadFailed
                    ? Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          onPressed: () => unawaited(_saveWithStatus(
                              settingsRepository.reloadPlaySkipPreferences())),
                          child: const Text('重新读取片头片尾偏好'),
                        ),
                      )
                    : null,
              ),
            ),
            const _GroupTitle('画面'),
            _card(
              context,
              child: Column(
                children: [
                  _SettingRow(
                    title: '画面缩放',
                    description: '画面在窗口中的适配方式，播放中即时生效；「填充」会拉伸、「裁剪」会裁边，均不改变片源',
                    trailing: _OptionDropdown(
                      key: const ValueKey('setting-scale'),
                      options: PlayerSettings.scaleOptions,
                      value: s.scale,
                      onChanged: (v) => _update(s.copyWith(scale: v)),
                    ),
                  ),
                  const _RowDivider(),
                  _SettingRow(
                    title: 'HDR 色调映射',
                    description: 'HDR 片源在 SDR 显示器上的映射算法',
                    trailing: _OptionDropdown(
                      key: const ValueKey('setting-tone-mapping'),
                      options: PlayerSettings.toneMappingOptions,
                      value: s.toneMapping,
                      onChanged: (v) => _update(s.copyWith(toneMapping: v)),
                    ),
                  ),
                  for (final item in [
                    ('亮度', s.brightness, (int v) => s.copyWith(brightness: v)),
                    ('对比度', s.contrast, (int v) => s.copyWith(contrast: v)),
                    ('饱和度', s.saturation, (int v) => s.copyWith(saturation: v)),
                    ('伽马', s.gamma, (int v) => s.copyWith(gamma: v)),
                  ]) ...[
                    const _RowDivider(),
                    _SettingRow(
                      title: item.$1,
                      description: '色彩补偿，0 为原始画面',
                      trailing: _SliderControl(
                        key: ValueKey('setting-picture-${item.$1}'),
                        value: item.$2.toDouble(),
                        min: PlayerSettings.minPicture.toDouble(),
                        max: PlayerSettings.maxPicture.toDouble(),
                        divisions: 40,
                        format: (v) => '${v >= 0 ? '+' : ''}${v.round()}',
                        onCommit: (v) => _update(item.$3(v.round())),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 16),
            Text(
              '说明：渲染由 media_kit 纹理管线（Direct3D 11）负责，本版本不提供渲染后端与播放内核切换。',
              style: TextStyle(
                  fontSize: AppType.body, color: context.palette.textSub),
            ),
          ],
        );
      },
    );
  }
}

class _GroupTitle extends StatelessWidget {
  final String text;

  const _GroupTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 24, 2, 8),
      child: Text(text,
          style: TextStyle(
              fontSize: AppType.label,
              fontWeight: FontWeight.bold,
              color: context.palette.textSub)),
    );
  }
}

class _RowDivider extends StatelessWidget {
  const _RowDivider();

  @override
  Widget build(BuildContext context) =>
      Divider(height: 26, color: context.palette.divider);
}

class _SettingRow extends StatelessWidget {
  final String title;
  final String description;

  /// 覆盖描述颜色（读取失败等警示场景用 `warning`）。
  final Color? descriptionColor;

  final Widget trailing;

  /// 可选脚注（如读取失败后的「重新读取」入口），占满整行宽度。
  final Widget? footer;

  const _SettingRow(
      {required this.title,
      required this.description,
      this.descriptionColor,
      required this.trailing,
      this.footer});

  @override
  Widget build(BuildContext context) {
    final row = Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: TextStyle(
                      fontSize: AppType.label,
                      fontWeight: FontWeight.w600,
                      color: context.palette.textMain)),
              const SizedBox(height: 4),
              Text(description,
                  style: TextStyle(
                      fontSize: AppType.body,
                      height: 1.4,
                      color: descriptionColor ?? context.palette.textSub)),
            ],
          ),
        ),
        const SizedBox(width: 16),
        trailing,
      ],
    );
    if (footer == null) return row;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [row, const SizedBox(height: 8), footer!],
    );
  }
}

class _OptionDropdown extends StatelessWidget {
  final List<PlayerOption> options;
  final String value;
  final ValueChanged<String> onChanged;

  const _OptionDropdown(
      {super.key,
      required this.options,
      required this.value,
      required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final selected =
        options.any((o) => o.value == value) ? value : options.first.value;
    return _boxedDropdown(
      context,
      child: DropdownButton<String>(
        value: selected,
        isExpanded: true,
        dropdownColor: context.palette.raised,
        style:
            TextStyle(fontSize: AppType.label, color: context.palette.textMain),
        items: [
          for (final o in options)
            DropdownMenuItem(
              value: o.value,
              child: Text(o.label, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: (v) {
          if (v != null && v != selected) onChanged(v);
        },
      ),
    );
  }
}

/// 拖动过程中只更新本地显示，松手后才提交（避免拖动期间高频写盘与频繁设置 mpv 属性）
class _SliderControl extends StatefulWidget {
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String Function(double) format;
  final ValueChanged<double> onCommit;

  const _SliderControl({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.format,
    required this.onCommit,
  });

  @override
  State<_SliderControl> createState() => _SliderControlState();
}

class _SliderControlState extends State<_SliderControl> {
  /// 拖动中 / 已提交但外部值尚未更新时显示的本地值
  double? _dragValue;

  @override
  void didUpdateWidget(covariant _SliderControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) _dragValue = null;
  }

  @override
  Widget build(BuildContext context) {
    final value =
        (_dragValue ?? widget.value).clamp(widget.min, widget.max).toDouble();
    return SizedBox(
      width: _kSliderWidth,
      child: Row(
        children: [
          Expanded(
            // 滚出视口时，滑块及其浮层必须一起移出语义树。
            child: Overlay.wrap(
              alwaysSizeToContent: true,
              clipBehavior: Clip.none,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  activeTrackColor: context.palette.accentInk,
                  inactiveTrackColor: context.palette.borderStrong,
                  // 滑块圆点压在品牌色轨道上，跟随 onPrimary（近黑）
                  thumbColor: Theme.of(context).colorScheme.onPrimary,
                  overlayShape: SliderComponentShape.noOverlay,
                  trackHeight: 3,
                ),
                child: Slider(
                  value: value,
                  min: widget.min,
                  max: widget.max,
                  divisions: widget.divisions,
                  onChanged: (v) => setState(() => _dragValue = v),
                  onChangeEnd: (v) {
                    if (v == widget.value) {
                      setState(() => _dragValue = null);
                    } else {
                      widget.onCommit(v);
                    }
                  },
                ),
              ),
            ),
          ),
          SizedBox(
            width: 64,
            child: Text(
              widget.format(value),
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: AppType.body,
                color: context.palette.textBody,
                // 等宽数字：拖动时读数不跳动（skill `number-tabular`，B6）
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> _saveWithStatus(Future<void> save) async {
  try {
    await save;
  } catch (_) {
    // 仓库保留失败状态，UI 统一通过状态栏反馈，而非抛出未处理异常。
  }
}

// =====================================================================
// 通用
// =====================================================================

/// 通用：启动与页面行为偏好
class GeneralSettingsPanel extends StatelessWidget {
  final ConfigRepository configRepository;
  final SettingsRepository settingsRepository;
  final CacheMaintenance? cacheMaintenance;
  final EpgRepository? epgRepository;
  final DataBackupService? dataBackupService;
  final bool Function()? isPlaybackActive;
  final Future<String?> Function(String suggestedName)? pickBackupSavePath;
  final Future<String?> Function()? pickBackupOpenPath;

  const GeneralSettingsPanel({
    super.key,
    required this.configRepository,
    required this.settingsRepository,
    this.cacheMaintenance,
    this.epgRepository,
    this.dataBackupService,
    this.isPlaybackActive,
    this.pickBackupSavePath,
    this.pickBackupOpenPath,
  });

  Future<void> _setNextEntry(StartupEntry entry) {
    final repository = settingsRepository;
    return _saveWithStatus(repository.updateStartupPreferences(
      repository.startupPreferences.copyWith(nextEntry: entry),
    ));
  }

  Future<void> _setSearchDisplay(SearchDisplay display) {
    final repository = settingsRepository;
    return _saveWithStatus(repository.updateSearchPreferences(
      repository.searchPreferences.copyWith(display: display),
    ));
  }

  Future<void> _setSearchAggregate(bool aggregate) {
    final repository = settingsRepository;
    return _saveWithStatus(repository.updateSearchPreferences(
      repository.searchPreferences.copyWith(aggregate: aggregate),
    ));
  }

  /// 切换「站点自检」开关：先落盘，成功后再同步给本地站点服务。
  ///
  /// 顺序很重要：先持久化再下发，避免"磁盘没记住、进程却已开启"的错位状态；
  /// 服务未运行时 [CompanionSpiderApi.configureSelfCheck] 返回 false，
  /// 下次懒启动会按设置自动补发（见 SiteApi）。
  Future<void> _setSelfCheck(bool enabled) async {
    final repository = settingsRepository;
    try {
      await repository.updateSelfCheckPreferences(
        repository.selfCheckPreferences.copyWith(enabled: enabled),
      );
    } catch (_) {
      // 落盘失败：保存横幅已提示，开关保持内存旧值对应的展示
      return;
    }
    await CompanionSpiderApi().configureSelfCheck(enabled);
  }

  Future<void> _setHistoryLimit(BuildContext context, int value) async {
    final repository = settingsRepository;
    if (value == repository.historyPreferences.limit) return;

    if (value < repository.historyPreferences.limit) {
      final count = configRepository.historyRecords.length;
      final deleteCount = count > value ? count - value : 0;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: context.palette.card,
          title: Text('降低历史记录数量',
              style: TextStyle(
                  color: context.palette.textTitle, fontSize: AppType.heading)),
          content: Text(
            deleteCount > 0
                ? '将最多保留 $value 条播放历史，超出上限的最旧 $deleteCount 条记录将被立即删除且不可恢复。'
                : '历史将最多保留 $value 条；当前 $count 条记录不受影响。',
            style: TextStyle(
                color: context.palette.textBody, fontSize: AppType.label),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child:
                  Text('取消', style: TextStyle(color: context.palette.textSub)),
            ),
            ElevatedButton(
              style: _primaryStyle(context),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text('保留 $value 条'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }

    try {
      await repository.updateHistoryPreferences(
        repository.historyPreferences.copyWith(limit: value),
      );
    } catch (_) {
      // 偏好保存失败：保存横幅已提示；不触发裁剪（避免「设置未保存却已删数据」）
      return;
    }
    await configRepository.setHistoryLimit(value);
  }

  @override
  Widget build(BuildContext context) {
    return _PanelScaffold(
      title: '通用',
      subtitle: '启动与页面行为偏好。',
      children: [
        StreamBuilder<StartupPreferences>(
          stream: settingsRepository.startupPreferencesStream,
          builder: (context, _) {
            final repository = settingsRepository;
            final preferences = repository.startupPreferences;
            final readFailed = repository.startupReadFailed;
            return _card(
              context,
              child: _SettingRow(
                title: '下次进入页面',
                description: readFailed
                    ? '启动偏好读取失败，原文件已保留；当前按默认（点播首页）运行。修复文件后可重新读取。'
                    : '下次启动应用时生效；「直播」进入直播入口但不自动播放；「上次入口」恢复上次使用的主入口。',
                descriptionColor: readFailed ? context.palette.warning : null,
                trailing: _boxedDropdown(
                  context,
                  child: Semantics(
                    label: '下次进入页面',
                    child: DropdownButton<StartupEntry>(
                      key: const ValueKey('startup-entry'),
                      value: preferences.nextEntry,
                      isExpanded: true,
                      dropdownColor: context.palette.raised,
                      style: TextStyle(
                          fontSize: AppType.label,
                          color: context.palette.textMain),
                      items: const [
                        DropdownMenuItem(
                            value: StartupEntry.vod, child: Text('点播首页')),
                        DropdownMenuItem(
                            value: StartupEntry.live, child: Text('直播')),
                        DropdownMenuItem(
                            value: StartupEntry.last, child: Text('上次入口')),
                      ],
                      onChanged: readFailed
                          ? null
                          : (entry) {
                              if (entry == null) return;
                              unawaited(_setNextEntry(entry));
                            },
                    ),
                  ),
                ),
                footer: readFailed
                    ? Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          onPressed: () => unawaited(_saveWithStatus(
                              repository.reloadStartupPreferences())),
                          child: const Text('重新读取启动偏好'),
                        ),
                      )
                    : null,
              ),
            );
          },
        ),
        const SizedBox(height: 16),
        StreamBuilder<SearchPreferences>(
          stream: settingsRepository.searchPreferencesStream,
          builder: (context, _) {
            final repository = settingsRepository;
            final preferences = repository.searchPreferences;
            final readFailed = repository.searchReadFailed;
            return _card(
              context,
              child: _SettingRow(
                title: '搜索显示',
                description: readFailed
                    ? '搜索偏好读取失败，原文件已保留；当前按默认（海报模式 / 聚合开）运行。修复文件后可重新读取。'
                    : '仅作用于搜索结果展示；切换即时生效。',
                descriptionColor: readFailed ? context.palette.warning : null,
                trailing: _boxedDropdown(
                  context,
                  child: Semantics(
                    label: '搜索显示',
                    child: DropdownButton<SearchDisplay>(
                      key: const ValueKey('search-display'),
                      value: preferences.display,
                      isExpanded: true,
                      dropdownColor: context.palette.raised,
                      style: TextStyle(
                          fontSize: AppType.label,
                          color: context.palette.textMain),
                      items: const [
                        DropdownMenuItem(
                            value: SearchDisplay.poster, child: Text('海报模式')),
                        DropdownMenuItem(
                            value: SearchDisplay.list, child: Text('文字列表')),
                      ],
                      onChanged: readFailed
                          ? null
                          : (display) {
                              if (display == null) return;
                              unawaited(_setSearchDisplay(display));
                            },
                    ),
                  ),
                ),
                footer: readFailed
                    ? Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          onPressed: () => unawaited(_saveWithStatus(
                              repository.reloadSearchPreferences())),
                          child: const Text('重新读取搜索偏好'),
                        ),
                      )
                    : null,
              ),
            );
          },
        ),
        const SizedBox(height: 16),
        StreamBuilder<SearchPreferences>(
          stream: settingsRepository.searchPreferencesStream,
          builder: (context, _) {
            final repository = settingsRepository;
            final preferences = repository.searchPreferences;
            final readFailed = repository.searchReadFailed;
            return _card(
              context,
              child: _SettingRow(
                title: '聚合搜索',
                description: readFailed
                    ? '聚合搜索暂不可用（搜索偏好读取失败），修复文件后可重新读取。'
                    : '开启时并发检索所有可搜索的站源；关闭后仅检索当前站源。',
                descriptionColor: readFailed ? context.palette.warning : null,
                trailing: Switch(
                  key: const ValueKey('search-aggregate'),
                  value: preferences.aggregate,
                  onChanged: readFailed
                      ? null
                      : (value) => unawaited(_setSearchAggregate(value)),
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 16),
        StreamBuilder<HistoryPreferences>(
          stream: settingsRepository.historyPreferencesStream,
          builder: (context, _) {
            final repository = settingsRepository;
            final preferences = repository.historyPreferences;
            final readFailed = repository.historyReadFailed;
            final displayValues = [
              ...HistoryPreferences.limitOptions,
              if (!HistoryPreferences.limitOptions.contains(preferences.limit))
                preferences.limit,
            ]..sort();
            return _card(
              context,
              child: _SettingRow(
                title: '历史记录数量',
                description: readFailed
                    ? '历史偏好读取失败，原文件已保留；当前按默认（150 条）运行。修复文件后可重新读取。'
                    : '播放历史最多保留的条数；超出上限时自动删除最早的记录，降低上限会立即删除超出部分（先确认）。',
                descriptionColor: readFailed ? context.palette.warning : null,
                trailing: _boxedDropdown(
                  context,
                  child: Semantics(
                    label: '历史记录数量',
                    child: DropdownButton<int>(
                      key: const ValueKey('history-limit'),
                      value: preferences.limit,
                      isExpanded: true,
                      dropdownColor: context.palette.raised,
                      style: TextStyle(
                          fontSize: AppType.label,
                          color: context.palette.textMain),
                      items: [
                        for (final option in displayValues)
                          DropdownMenuItem(
                            value: option,
                            child: Text(
                                option == HistoryPreferences.defaultLimit
                                    ? '$option 条（默认）'
                                    : '$option 条'),
                          ),
                      ],
                      onChanged: readFailed
                          ? null
                          : (value) {
                              if (value == null) return;
                              unawaited(_setHistoryLimit(context, value));
                            },
                    ),
                  ),
                ),
                footer: readFailed
                    ? Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          onPressed: () => unawaited(_saveWithStatus(
                              repository.reloadHistoryPreferences())),
                          child: const Text('重新读取历史偏好'),
                        ),
                      )
                    : null,
              ),
            );
          },
        ),
        const SizedBox(height: 16),
        StreamBuilder<SelfCheckPreferences>(
          stream: settingsRepository.selfCheckPreferencesStream,
          builder: (context, _) {
            final repository = settingsRepository;
            final preferences = repository.selfCheckPreferences;
            final readFailed = repository.selfCheckReadFailed;
            return _card(
              context,
              child: _SettingRow(
                title: '站点自检',
                description: readFailed
                    ? '自检偏好读取失败，原文件已保留；当前按默认（关闭）运行。修复文件后可重新读取。'
                    : preferences.enabled
                        ? '已开启：加载加固壳 / 载荷时会在日志打印体检结论（架构是否兼容、是否依赖 ARM-only 原生库）；'
                            '可在「配置源管理」中对当前配置执行「站点体检」。'
                        : '已关闭：不打印任何体检日志，也不允许发起体检。开启后立即同步给本地站点服务，无需重启应用。',
                descriptionColor: readFailed ? context.palette.warning : null,
                trailing: Switch(
                  key: const ValueKey('site-self-check'),
                  value: preferences.enabled,
                  onChanged: readFailed
                      ? null
                      : (value) => unawaited(_setSelfCheck(value)),
                ),
                footer: readFailed
                    ? Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          onPressed: () => unawaited(_saveWithStatus(
                              repository.reloadSelfCheckPreferences())),
                          child: const Text('重新读取自检偏好'),
                        ),
                      )
                    : null,
              ),
            );
          },
        ),
        const SizedBox(height: 16),
        if (cacheMaintenance != null)
          _StorageCacheCard(
            maintenance: cacheMaintenance!,
            epgRepository: epgRepository,
          ),
        const SizedBox(height: 16),
        if (dataBackupService != null)
          _DataBackupCard(
            service: dataBackupService!,
            isPlaybackActive: isPlaybackActive,
            pickSavePath: pickBackupSavePath,
            pickOpenPath: pickBackupOpenPath,
          ),
      ],
    );
  }
}

// =====================================================================
// 存储与缓存（SET-09）
// =====================================================================

class _StorageCacheCard extends StatefulWidget {
  final CacheMaintenance maintenance;
  final EpgRepository? epgRepository;

  const _StorageCacheCard({
    required this.maintenance,
    this.epgRepository,
  });

  @override
  State<_StorageCacheCard> createState() => _StorageCacheCardState();
}

class _StorageCacheCardState extends State<_StorageCacheCard> {
  late Future<CacheInventory> _future;
  late DataDirectoryStatus _dataStatus;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _future = widget.maintenance.inspect();
    _dataStatus = DataDirectoryManager.status ??
        DataDirectoryStatus(
          activePath: DataDirectoryManager.currentPath,
          defaultPath: DataDirectoryManager.defaultDirectoryPath(),
        );
  }

  void _reload() {
    setState(() {
      _future = widget.maintenance.inspect();
    });
  }

  void _toast(String message, {AppMessageType type = AppMessageType.info}) {
    if (!mounted) return;
    showAppMessage(message, type: type);
  }

  void _clearImages() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    _toast('已清理图片内存缓存', type: AppMessageType.success);
  }

  void _clearEpg() {
    final repository = widget.epgRepository;
    if (repository == null) return;
    repository.clearCache();
    _toast('已清理节目单内存缓存', type: AppMessageType.success);
  }

  Future<void> _changeDataDirectory() async {
    String? path;
    try {
      path = await getDirectoryPath(confirmButtonText: '选择此目录');
    } catch (error) {
      _toast('无法打开目录选择器：$error', type: AppMessageType.error);
      return;
    }
    if (path == null || path.trim().isEmpty) return;
    try {
      final status = await DataDirectoryManager.requestDirectory(path);
      if (!mounted) return;
      setState(() => _dataStatus = status);
      _toast('已安排迁移到 $path；重启应用后生效，旧目录会保留', type: AppMessageType.success);
    } on DataDirectoryException catch (error) {
      _toast(error.message, type: AppMessageType.error);
    } catch (error) {
      _toast('无法切换数据目录：$error', type: AppMessageType.error);
    }
  }

  Future<void> _cancelDataDirectoryChange() async {
    final status = await DataDirectoryManager.cancelPending();
    if (!mounted) return;
    setState(() => _dataStatus = status);
    _toast('已取消数据目录迁移');
  }

  Future<void> _restoreDefaultDataDirectory() async {
    try {
      final status = await DataDirectoryManager.requestDirectory(
          DataDirectoryManager.defaultDirectoryPath());
      if (!mounted) return;
      setState(() => _dataStatus = status);
      _toast('已安排迁回默认目录；重启应用后生效', type: AppMessageType.success);
    } on DataDirectoryException catch (error) {
      _toast(error.message, type: AppMessageType.error);
    } catch (error) {
      _toast('无法恢复默认目录：$error', type: AppMessageType.error);
    }
  }

  Future<void> _forgetCustomDataDirectory() async {
    final status = await DataDirectoryManager.forgetCustomDirectory();
    if (!mounted) return;
    setState(() => _dataStatus = status);
    _toast('已停用自定义目录，继续使用默认目录', type: AppMessageType.success);
  }

  Future<void> _cleanTemp(CacheInventory inventory) async {
    if (_busy) return;
    if (inventory.tempFileCount == 0) {
      _toast('没有可清理的临时文件（只清理超过 24 小时的孤儿副本；写入中的副本会保留）');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: context.palette.card,
        title: Text('清理临时文件',
            style: TextStyle(
                color: context.palette.textTitle, fontSize: AppType.heading)),
        content: Text(
          '将删除 ${inventory.tempFileCount} 个超过 24 小时的写入临时文件'
          '（${_formatBytes(inventory.tempBytes)}）。这些文件是保存过程中断留下的副本，'
          '删除不会影响历史、收藏、设置或配置。是否继续？',
          style: TextStyle(
              color: context.palette.textBody, fontSize: AppType.label),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('取消', style: TextStyle(color: context.palette.textSub)),
          ),
          ElevatedButton(
            style: _primaryStyle(context),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('删除 ${inventory.tempFileCount} 个文件'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    final result = await widget.maintenance.cleanOrphanTempFiles();
    if (!mounted) return;
    setState(() => _busy = false);
    final suffix = result.failed > 0
        ? '；${result.failed} 个文件因占用或权限跳过'
        : (result.skipped > 0 ? '；${result.skipped} 个文件已跳过' : '');
    _toast('已删除 ${result.deleted} 个临时文件$suffix', type: AppMessageType.success);
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return _card(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('存储与缓存',
                    style: TextStyle(
                        fontSize: AppType.label,
                        fontWeight: FontWeight.bold,
                        color: context.palette.textMain)),
              ),
              IconButton(
                key: const ValueKey('cache-refresh'),
                tooltip: '重新盘点',
                icon: Icon(Icons.refresh_rounded,
                    size: 18, color: context.palette.textSub),
                onPressed: _busy ? null : _reload,
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '数据目录：${_dataStatus.activePath}',
            key: const ValueKey('data-dir-path'),
            style: TextStyle(
                fontSize: AppType.body, color: context.palette.textSub),
          ),
          if (_dataStatus.usesCustom)
            Text(
              '默认目录：${_dataStatus.defaultPath}',
              style: TextStyle(
                  fontSize: AppType.body, color: context.palette.textSub),
            ),
          if (_dataStatus.unavailableReason != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '自定义数据目录不可用：${_dataStatus.unavailableReason}'
                      '（已临时使用默认目录，新改动会写入默认目录）',
                      style: TextStyle(
                          fontSize: AppType.body,
                          color: context.palette.warning),
                    ),
                  ),
                  TextButton(
                    key: const ValueKey('data-dir-forget'),
                    onPressed: _busy ? null : _forgetCustomDataDirectory,
                    child: const Text('停用自定义目录'),
                  ),
                ],
              ),
            ),
          if (_dataStatus.migrationPending) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '已安排迁移到 ${_dataStatus.pendingPath}；重启应用后生效',
                    style: TextStyle(
                        fontSize: AppType.body,
                        color: context.palette.textBody),
                  ),
                ),
                TextButton(
                  key: const ValueKey('data-dir-cancel'),
                  onPressed: _busy ? null : _cancelDataDirectoryChange,
                  child: const Text('取消迁移'),
                ),
              ],
            ),
          ],
          if (_dataStatus.pendingError != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '上次迁移失败：${_dataStatus.pendingError}（已继续使用原目录）',
                style: TextStyle(
                    fontSize: AppType.body, color: context.palette.warning),
              ),
            ),
          const SizedBox(height: 4),
          Row(
            children: [
              OutlinedButton(
                key: const ValueKey('data-dir-change'),
                style: _outlinedStyle(context),
                onPressed: _busy ? null : _changeDataDirectory,
                child: const Text('更改目录…'),
              ),
              if (_dataStatus.usesCustom) ...[
                const SizedBox(width: 8),
                TextButton(
                  key: const ValueKey('data-dir-restore'),
                  onPressed: _busy ? null : _restoreDefaultDataDirectory,
                  child: const Text('恢复默认目录'),
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '只迁移用户数据（15 个 JSON + 壁纸 + 备份）；随包 JRE / 伴随运行时仍在默认目录。',
            style: TextStyle(
                fontSize: AppType.caption, color: context.palette.textSub),
          ),
          const SizedBox(height: 12),
          FutureBuilder<CacheInventory>(
            future: _future,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: LinearProgressIndicator(minHeight: 2),
                );
              }
              final inventory = snapshot.data;
              if (inventory == null || !inventory.directoryReadable) {
                return Row(
                  children: [
                    Expanded(
                      child: Text('无法读取数据目录；未执行任何清理。',
                          style: TextStyle(
                              fontSize: AppType.body,
                              color: context.palette.warning)),
                    ),
                    TextButton(
                      onPressed: _busy ? null : _reload,
                      child: const Text('重试'),
                    ),
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _cacheRow(
                    context,
                    key: const ValueKey('cache-user-data'),
                    title: '用户数据',
                    subtitle:
                        '${inventory.userFileCount} 个文件 · ${_formatBytes(inventory.userDataBytes)}'
                        '\n历史、收藏、设置、配置源等；清理不涉及',
                  ),
                  Divider(height: 26, color: context.palette.divider),
                  _cacheRow(
                    context,
                    key: const ValueKey('cache-temp-files'),
                    title: '临时文件',
                    subtitle:
                        '${inventory.tempFileCount} 个 · ${_formatBytes(inventory.tempBytes)}'
                        '\n保存过程中断留下的副本，超过 24 小时才可清理',
                    action: OutlinedButton(
                      key: const ValueKey('cache-clean-temp'),
                      style: _outlinedStyle(context),
                      onPressed:
                          _busy ? null : () => unawaited(_cleanTemp(inventory)),
                      child: const Text('清理临时文件'),
                    ),
                  ),
                  Divider(height: 26, color: context.palette.divider),
                  _cacheRow(
                    context,
                    key: const ValueKey('cache-image-memory'),
                    title: '图片内存缓存',
                    subtitle: '海报 / 剧照的本次运行缓存；清理后按需重新加载',
                    action: TextButton(
                      key: const ValueKey('cache-clear-images'),
                      onPressed: _busy ? null : _clearImages,
                      child: const Text('清理'),
                    ),
                  ),
                  Divider(height: 26, color: context.palette.divider),
                  _cacheRow(
                    context,
                    key: const ValueKey('cache-epg-memory'),
                    title: '节目单内存缓存',
                    subtitle: '节目单的本次运行缓存；清理后下次打开重新请求',
                    action: TextButton(
                      key: const ValueKey('cache-clear-epg'),
                      onPressed: _busy || widget.epgRepository == null
                          ? null
                          : _clearEpg,
                      child: const Text('清理'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '随包 JRE / companion JAR、配置快照、历史、收藏与设置均不属于缓存，绝不在这里删除。',
                    style: TextStyle(
                        fontSize: AppType.caption,
                        color: context.palette.textSub),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

Widget _cacheRow(
  BuildContext context, {
  Key? key,
  required String title,
  required String subtitle,
  Widget? action,
}) {
  return Row(
    key: key,
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: TextStyle(
                    fontSize: AppType.label,
                    fontWeight: FontWeight.w600,
                    color: context.palette.textMain)),
            const SizedBox(height: 4),
            Text(subtitle,
                style: TextStyle(
                    fontSize: AppType.caption, color: context.palette.textSub)),
          ],
        ),
      ),
      if (action != null) ...[
        const SizedBox(width: 12),
        action,
      ],
    ],
  );
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

// =====================================================================
// 数据备份与恢复（SET-10）
// =====================================================================

class _DataBackupCard extends StatefulWidget {
  final DataBackupService service;
  final bool Function()? isPlaybackActive;
  final Future<String?> Function(String suggestedName)? pickSavePath;
  final Future<String?> Function()? pickOpenPath;

  const _DataBackupCard({
    required this.service,
    this.isPlaybackActive,
    this.pickSavePath,
    this.pickOpenPath,
  });

  @override
  State<_DataBackupCard> createState() => _DataBackupCardState();
}

class _DataBackupCardState extends State<_DataBackupCard> {
  bool _busy = false;
  bool _restored = false;
  String? _status;
  bool _statusIsError = false;

  @override
  void initState() {
    super.initState();
    _restored = dataRestorePendingRestart;
  }

  void _setStatus(String message, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _status = message;
      _statusIsError = error;
    });
  }

  String _suggestedName() {
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    return 'xiugou-tv-backup-${now.year}${two(now.month)}${two(now.day)}-'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}.json';
  }

  Future<String?> _pickSave(String suggestedName) async {
    final pick = widget.pickSavePath;
    if (pick != null) return pick(suggestedName);
    final location = await getSaveLocation(
      suggestedName: suggestedName,
      acceptedTypeGroups: const [
        XTypeGroup(label: '修狗TV 数据备份', extensions: ['json']),
      ],
    );
    return location?.path;
  }

  Future<String?> _pickOpen() async {
    final pick = widget.pickOpenPath;
    if (pick != null) return pick();
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: '修狗TV 数据备份', extensions: ['json']),
      ],
    );
    return file?.path;
  }

  Future<void> _export() async {
    if (_busy || _restored) return;
    final path = await _pickSave(_suggestedName());
    if (path == null || path.trim().isEmpty || !mounted) return;

    setState(() => _busy = true);
    try {
      await widget.service.exportBackup(path);
      _setStatus('备份已保存：$path');
      if (mounted) {
        showAppMessage('数据备份已保存', type: AppMessageType.success);
      }
    } on DataBackupException catch (error) {
      _setStatus(error.message, error: true);
    } catch (error) {
      _setStatus(_errorText(error), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore() async {
    if (_busy || _restored) return;
    if (widget.isPlaybackActive?.call() ?? false) {
      _setStatus('请先停止播放，再恢复数据备份', error: true);
      return;
    }
    final path = await _pickOpen();
    if (path == null || path.trim().isEmpty || !mounted) return;

    setState(() => _busy = true);
    DataBackup backup;
    try {
      backup = await widget.service.readBackupFile(path);
    } on DataBackupException catch (error) {
      _setStatus(error.message, error: true);
      if (mounted) setState(() => _busy = false);
      return;
    } catch (error) {
      _setStatus(_errorText(error), error: true);
      if (mounted) setState(() => _busy = false);
      return;
    }

    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: context.palette.card,
        title: Text('恢复数据备份？',
            style: TextStyle(
                color: context.palette.textTitle, fontSize: AppType.heading)),
        content: Text(
          '备份创建时间：${_formatTime(backup.createdAt.millisecondsSinceEpoch)}\n'
          '应用版本：${backup.appVersion ?? '未记录'}\n'
          '文件：${backup.files.length} 个 · ${_formatBytes(backup.totalBytes)}'
          '${backup.consistent ? '' : '\n注意：该备份生成时有文件正在写入，可能不是同一时刻。'}\n\n'
          '将覆盖当前的历史、收藏、设置、配置源与直播源；恢复前会自动备份当前数据。\n'
          '仅覆盖备份中包含的文件；备份未包含的文件保持现状。\n'
          '备份中可能包含订阅地址、请求头或令牌，请妥善保管。\n'
          '恢复完成后需要关闭并重新打开应用。',
          style: TextStyle(
              color: context.palette.textBody,
              fontSize: AppType.label,
              height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('取消', style: TextStyle(color: context.palette.textSub)),
          ),
          ElevatedButton(
            style: _primaryStyle(context),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('恢复并覆盖'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      if (mounted) setState(() => _busy = false);
      return;
    }

    try {
      final result = await widget.service.restoreBackup(path, expected: backup);
      if (!mounted) return;
      dataRestorePendingRestart = true;
      _restored = true;
      _setStatus('恢复完成：${result.restoredFiles.length} 个文件；请重启应用');
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          backgroundColor: context.palette.card,
          title: Text('恢复完成',
              style: TextStyle(
                  color: context.palette.textTitle, fontSize: AppType.heading)),
          content: Text(
            '已恢复 ${result.restoredFiles.length} 个文件。\n'
            '恢复前备份：${result.preRestorePath}\n'
            '${result.preRestoreSkipped.isEmpty ? '' : '注意：恢复前有 ${result.preRestoreSkipped.length} 个文件未能备份（过大或不可读），其原内容不可还原。\n'}'
            '\n'
            '请关闭并重新打开应用后生效；在此之前请勿播放或修改设置。',
            style: TextStyle(
                color: context.palette.textBody,
                fontSize: AppType.label,
                height: 1.5),
          ),
          actions: [
            ElevatedButton(
              style: _primaryStyle(context),
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
    } on DataBackupException catch (error) {
      _setStatus(error.message, error: true);
    } catch (error) {
      _setStatus(_errorText(error), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _card(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('数据备份与恢复',
              style: TextStyle(
                  fontSize: AppType.label,
                  fontWeight: FontWeight.bold,
                  color: context.palette.textMain)),
          const SizedBox(height: 4),
          Text(
            '备份历史、收藏、设置、配置源与直播源等 13 个数据文件；'
            '不含窗口状态、JRE / JAR、缓存或日志。备份可能包含订阅地址与令牌，请妥善保管。',
            style: TextStyle(
                fontSize: AppType.body,
                color: context.palette.textSub,
                height: 1.4),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              OutlinedButton(
                key: const ValueKey('data-backup-export'),
                style: _outlinedStyle(context),
                onPressed:
                    _busy || _restored ? null : () => unawaited(_export()),
                child: const Text('导出备份…'),
              ),
              OutlinedButton(
                key: const ValueKey('data-backup-restore'),
                style: _outlinedStyle(context),
                onPressed:
                    _busy || _restored ? null : () => unawaited(_restore()),
                child: const Text('从备份恢复…'),
              ),
            ],
          ),
          if (_restored) ...[
            const SizedBox(height: 8),
            Text('本次会话已完成恢复；请重启应用后再操作。',
                style: TextStyle(
                    fontSize: AppType.body, color: context.palette.warning)),
          ],
          if (_status != null) ...[
            const SizedBox(height: 8),
            Text(
              _status!,
              key: const ValueKey('data-backup-status'),
              style: TextStyle(
                fontSize: AppType.body,
                color: _statusIsError
                    ? context.palette.warning
                    : context.palette.textSub,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// =====================================================================
// 关于
// =====================================================================

// 外观（SET-08）

/// 外观：主题（深色 / 浅色 / 跟随系统）+ 壁纸（本地图片，只影响主界面）。
class AppearancePanel extends StatefulWidget {
  final SettingsRepository settingsRepository;
  final WallpaperStore wallpaperStore;
  final Future<String?> Function()? pickWallpaperPath;

  const AppearancePanel({
    super.key,
    required this.settingsRepository,
    required this.wallpaperStore,
    this.pickWallpaperPath,
  });

  @override
  State<AppearancePanel> createState() => _AppearancePanelState();
}

class _AppearancePanelState extends State<AppearancePanel> {
  bool _busy = false;
  String? _message;
  bool _messageIsError = false;

  void _setMessage(String message, {bool isError = false}) {
    if (!mounted) return;
    setState(() {
      _message = message;
      _messageIsError = isError;
    });
  }

  Future<String?> _pickPath() async {
    final picker = widget.pickWallpaperPath;
    if (picker != null) return picker();
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
            label: '图片', extensions: ['jpg', 'jpeg', 'png', 'webp', 'bmp']),
      ],
    );
    return file?.path;
  }

  Future<void> _choose() async {
    if (_busy) return;
    final path = await _pickPath();
    if (path == null || !mounted) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final next = await widget.wallpaperStore
          .importFrom(path, widget.settingsRepository.appearancePreferences);
      await widget.settingsRepository.updateAppearancePreferences(next);
      _setMessage('壁纸已更新');
    } on WallpaperImportException catch (error) {
      _setMessage(error.message, isError: true);
    } on DataRestorePendingRestartException catch (error) {
      _setMessage(error.message, isError: true);
    } catch (_) {
      _setMessage('壁纸保存失败，请重试', isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restoreDefault() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final next = await widget.wallpaperStore.clear();
      await widget.settingsRepository.updateAppearancePreferences(next);
      _setMessage('已恢复默认背景');
    } on DataRestorePendingRestartException catch (error) {
      _setMessage(error.message, isError: true);
    } catch (_) {
      _setMessage('恢复默认失败，请重试', isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _chooseTheme(AppThemeMode mode) async {
    final current = widget.settingsRepository.appearancePreferences;
    if (current.themeMode == mode) return;
    try {
      await widget.settingsRepository
          .updateAppearancePreferences(current.withThemeMode(mode));
      _setMessage('已切换主题：${mode.label}');
    } on DataRestorePendingRestartException catch (error) {
      _setMessage(error.message, isError: true);
    } catch (_) {
      _setMessage('主题切换失败，请重试', isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _PanelScaffold(
      title: '外观',
      subtitle: '主题可切换深色 / 浅色 / 跟随系统；壁纸只影响主界面，浅色主题使用浅色遮罩保证文字可读。',
      children: [
        StreamBuilder<AppearancePreferences>(
          stream: widget.settingsRepository.appearancePreferencesStream,
          initialData: widget.settingsRepository.appearancePreferences,
          builder: (context, snapshot) {
            final preferences = snapshot.data ?? AppearancePreferences.none;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _ThemeCard(
                  value: preferences.themeMode,
                  onChanged: _chooseTheme,
                ),
                const SizedBox(height: 16),
                _WallpaperCard(
                  preferences: preferences,
                  store: widget.wallpaperStore,
                  busy: _busy,
                  message: _message,
                  messageIsError: _messageIsError,
                  onChoose: _choose,
                  onReset: _restoreDefault,
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}

/// 主题选择：三选一，选中态用品牌红描边。
class _ThemeCard extends StatelessWidget {
  final AppThemeMode value;
  final ValueChanged<AppThemeMode> onChanged;

  const _ThemeCard({required this.value, required this.onChanged});

  static const _icons = {
    AppThemeMode.dark: Icons.dark_mode_outlined,
    AppThemeMode.light: Icons.light_mode_outlined,
    AppThemeMode.system: Icons.brightness_auto_outlined,
  };

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: context.palette.card,
        borderRadius: BorderRadius.circular(AppRadii.md),
        border: Border.all(color: context.palette.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('主题',
              style: TextStyle(
                  fontSize: AppType.label,
                  fontWeight: FontWeight.bold,
                  color: context.palette.textMain)),
          const SizedBox(height: 4),
          Text('深色保持现有观感；跟随系统会随 Windows 的亮暗设置自动切换。',
              style: TextStyle(
                  fontSize: AppType.body, color: context.palette.textSub)),
          const SizedBox(height: 12),
          Row(
            children: [
              for (final mode in AppThemeMode.values) ...[
                Expanded(
                  child: FocusRing(
                      onTap: () => onChanged(mode),
                      semanticLabel: '主题：${mode.label}',
                      borderRadius:
                          const BorderRadius.all(Radius.circular(AppRadii.md)),
                      child: InkWell(
                        key: ValueKey('theme-mode-${mode.name}'),
                        borderRadius: BorderRadius.circular(AppRadii.md),
                        hoverColor: context.palette.hover,
                        // 焦点由外层 FocusRing 承担，避免双重焦点节点
                        canRequestFocus: false,
                        onTap: () => onChanged(mode),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          decoration: BoxDecoration(
                            color: value == mode
                                ? context.palette.accent.withValues(alpha: 0.12)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(AppRadii.md),
                            border: Border.all(
                              color: value == mode
                                  ? context.palette.accentInk
                                  : context.palette.border,
                              // 选中描边取 1.5（与叠画焦点描边同宽，B6）
                              width: value == mode ? 1.5 : 1,
                            ),
                          ),
                          child: Column(
                            children: [
                              Icon(_icons[mode],
                                  size: 20,
                                  color: value == mode
                                      ? context.palette.accentInk
                                      : context.palette.textSub),
                              const SizedBox(height: 6),
                              Text(mode.label,
                                  style: TextStyle(
                                    fontSize: AppType.body,
                                    fontWeight: value == mode
                                        ? FontWeight.w600
                                        : FontWeight.w400,
                                    color: value == mode
                                        ? context.palette.textMain
                                        : context.palette.textSub,
                                  )),
                            ],
                          ),
                        ),
                      )),
                ),
                if (mode != AppThemeMode.values.last) const SizedBox(width: 12),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _WallpaperCard extends StatelessWidget {
  final AppearancePreferences preferences;
  final WallpaperStore store;
  final bool busy;
  final String? message;
  final bool messageIsError;
  final VoidCallback onChoose;
  final VoidCallback onReset;

  const _WallpaperCard({
    required this.preferences,
    required this.store,
    required this.busy,
    required this.message,
    required this.messageIsError,
    required this.onChoose,
    required this.onReset,
  });

  @override
  Widget build(BuildContext context) {
    return _card(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('壁纸',
              style: TextStyle(
                  fontSize: AppType.label,
                  fontWeight: FontWeight.bold,
                  color: context.palette.textMain)),
          const SizedBox(height: 4),
          Text(
            '支持 jpg / jpeg / png / webp / bmp；单张不超过 20 MB、8000×8000。'
            '选图后会复制一份到数据目录，移动或删除原图都不影响壁纸。',
            style: TextStyle(
                fontSize: AppType.body, color: context.palette.textSub),
          ),
          const SizedBox(height: 12),
          _WallpaperPreview(
            fileName: preferences.wallpaperFileName,
            store: store,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              FilledButton(
                key: const ValueKey('appearance-pick'),
                onPressed: busy ? null : onChoose,
                style: _primaryStyle(context),
                child: const Text('选择壁纸…'),
              ),
              const SizedBox(width: 12),
              OutlinedButton(
                key: const ValueKey('appearance-reset'),
                onPressed: (busy || !preferences.hasWallpaper) ? null : onReset,
                style: _outlinedStyle(context),
                child: const Text('恢复默认'),
              ),
              if (busy) ...[
                const SizedBox(width: 12),
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ],
            ],
          ),
          if (message != null) ...[
            const SizedBox(height: 12),
            Text(
              message!,
              style: TextStyle(
                  fontSize: AppType.body,
                  color: messageIsError
                      ? context.palette.warning
                      : context.palette.success),
            ),
          ],
          const SizedBox(height: 12),
          Text(
            '「恢复默认」只删除应用内的副本，不会删除你的原图；'
            '壁纸不计入数据备份（备份只含配置 / 收藏 / 历史等 13 个文件）。',
            style: TextStyle(
                fontSize: AppType.caption, color: context.palette.textSub),
          ),
        ],
      ),
    );
  }
}

/// 壁纸预览：自己缓存解析 Future，避免每次 rebuild 都新建 Future 造成无限重建。
class _WallpaperPreview extends StatefulWidget {
  final String? fileName;
  final WallpaperStore store;

  const _WallpaperPreview({required this.fileName, required this.store});

  @override
  State<_WallpaperPreview> createState() => _WallpaperPreviewState();
}

class _WallpaperPreviewState extends State<_WallpaperPreview> {
  String? _fileName;
  Future<String?>? _resolved;

  @override
  void initState() {
    super.initState();
    _fileName = widget.fileName;
    _resolved = widget.store.resolvePath(_fileName);
  }

  @override
  void didUpdateWidget(_WallpaperPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.fileName != _fileName) {
      _fileName = widget.fileName;
      _resolved = widget.store.resolvePath(_fileName);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String?>(
      future: _resolved,
      builder: (context, snapshot) {
        final path = snapshot.data;
        final missing = widget.fileName != null &&
            snapshot.connectionState == ConnectionState.done &&
            path == null;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              key: const ValueKey('appearance-preview'),
              width: 216,
              height: 122,
              decoration: BoxDecoration(
                color: context.palette.background,
                borderRadius: BorderRadius.circular(AppRadii.sm),
                border: Border.all(color: context.palette.border),
              ),
              clipBehavior: Clip.antiAlias,
              child: path == null
                  ? Center(
                      child: Text('默认深色背景',
                          style: TextStyle(
                              fontSize: AppType.body,
                              color: context.palette.textSub)),
                    )
                  : Image.file(
                      File(path),
                      fit: BoxFit.cover,
                      cacheWidth: 432,
                      errorBuilder: (_, __, ___) => Center(
                        child: Text('默认深色背景',
                            style: TextStyle(
                                fontSize: AppType.body,
                                color: context.palette.textSub)),
                      ),
                    ),
            ),
            if (missing) ...[
              const SizedBox(height: 12),
              Text('壁纸文件已失效，请重新选择',
                  style: TextStyle(
                      fontSize: AppType.body, color: context.palette.warning)),
            ],
          ],
        );
      },
    );
  }
}

/// 关于：应用信息、运行环境、开源许可与诊断信息
class AboutPanel extends StatefulWidget {
  /// 播放引擎（可为空：不可用时引擎信息显示「不可用」，其余内容不受影响）
  final PlayerEngine? playerEngine;

  /// 更新区块（宿主注入；为空时不显示，保持设置页与更新控制器解耦）
  final Widget? updateSection;

  const AboutPanel({super.key, this.playerEngine, this.updateSection});

  @override
  State<AboutPanel> createState() => _AboutPanelState();
}

class _AboutPanelState extends State<AboutPanel> {
  String? _version;
  bool _versionFailed = false;
  String? _mpvVersion;
  bool _mpvUnavailable = false;
  String _dataDirectory = '';

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    String? version;
    var versionFailed = false;
    try {
      // 版本来自构建注入的 exe 版本资源（package_info_plus 读取），不硬编码
      final info = await PackageInfo.fromPlatform();
      version = info.version;
    } catch (_) {
      // 读取失败：显示「读取失败」，不显示占位版本
      versionFailed = true;
    }

    String? mpvVersion;
    var mpvUnavailable = false;
    final engine = widget.playerEngine;
    if (engine is MpvPlayerEngine) {
      mpvVersion = await engine.readEngineVersion();
      mpvUnavailable = mpvVersion == null || mpvVersion.trim().isEmpty;
    } else {
      mpvUnavailable = true;
    }

    String dataDirectory;
    try {
      // 同步路径计算（与 WindowsConfigStorage 同一约定，不触盘）：
      // 避免在 UI 加载路径上等待真实文件 IO
      dataDirectory = WindowsConfigStorage.storageDirectoryPath();
    } catch (_) {
      dataDirectory = '不可用';
    }

    if (!mounted) return;
    setState(() {
      _version = version;
      _versionFailed = versionFailed;
      _mpvVersion = mpvVersion;
      _mpvUnavailable = mpvUnavailable;
      _dataDirectory = dataDirectory;
    });
  }

  String get _versionText => _versionFailed ? '读取失败' : (_version ?? '…');

  String get _mpvVersionText =>
      _mpvUnavailable ? '不可用（播放器未初始化）' : (_mpvVersion ?? '…');

  /// 诊断信息：仅白名单字段（版本 / 引擎 / 系统 / 运行时 / 数据目录）。
  /// 不含订阅地址、令牌、请求头、凭据、历史或收藏内容。
  String _diagnosticsText() => [
        '修狗TV 诊断信息',
        '应用版本: $_versionText',
        '播放引擎: mpv（经 media_kit 接入）',
        'mpv 版本: $_mpvVersionText',
        '系统: ${Platform.operatingSystemVersion}',
        '运行时: ${Platform.version}',
        '数据目录: ${_dataDirectory.isEmpty ? '…' : _dataDirectory}',
      ].join('\n');

  Future<void> _copyDiagnostics() async {
    await Clipboard.setData(ClipboardData(text: _diagnosticsText()));
    if (!mounted) return;
    showAppMessage('诊断信息已复制到剪贴板（不含订阅地址与凭据）', type: AppMessageType.success);
  }

  void _openLicenses() {
    showLicensePage(
      context: context,
      applicationName: '修狗TV',
      applicationVersion: _versionText,
    );
  }

  @override
  Widget build(BuildContext context) {
    return _PanelScaffold(
      title: '关于',
      subtitle: '应用信息、运行环境、开源许可与诊断信息。',
      children: [
        _card(
          context,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('应用信息',
                  style: TextStyle(
                      fontSize: AppType.label,
                      fontWeight: FontWeight.bold,
                      color: context.palette.textMain)),
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Image.asset(
                    appIconAsset,
                    width: 40,
                    height: 40,
                    filterQuality: FilterQuality.high,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('修狗TV',
                            style: TextStyle(
                                fontSize: AppType.label,
                                color: context.palette.textMain)),
                        const SizedBox(height: 4),
                        Text(
                            '面向 Windows 10/11 x64 的影视桌面客户端；基于 Flutter 与 mpv（media_kit）。',
                            style: TextStyle(
                                fontSize: AppType.body,
                                color: context.palette.textSub)),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _AboutRow(
                  label: '版本',
                  value: _versionText,
                  valueKey: const ValueKey('about-version')),
              if (widget.updateSection != null) ...[
                const SizedBox(height: 12),
                widget.updateSection!,
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),
        _card(
          context,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('运行环境',
                  style: TextStyle(
                      fontSize: AppType.label,
                      fontWeight: FontWeight.bold,
                      color: context.palette.textMain)),
              const SizedBox(height: 8),
              const _AboutRow(label: '播放引擎', value: 'mpv（经 media_kit 接入）'),
              _AboutRow(label: 'mpv 版本', value: _mpvVersionText),
              _AboutRow(label: '系统', value: Platform.operatingSystemVersion),
              _AboutRow(label: '运行时', value: Platform.version),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _card(
          context,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('开源许可',
                  style: TextStyle(
                      fontSize: AppType.label,
                      fontWeight: FontWeight.bold,
                      color: context.palette.textMain)),
              const SizedBox(height: 6),
              Text('查看应用与依赖组件（Flutter、mpv / media_kit 等）的开源许可。',
                  style: TextStyle(
                      fontSize: AppType.body, color: context.palette.textSub)),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton(
                  style: _outlinedStyle(context),
                  onPressed: _openLicenses,
                  child: const Text('查看开源许可'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _card(
          context,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('诊断信息',
                  style: TextStyle(
                      fontSize: AppType.label,
                      fontWeight: FontWeight.bold,
                      color: context.palette.textMain)),
              const SizedBox(height: 6),
              Text('仅含以下字段，不含订阅地址与凭据；点击复制后由你自行粘贴使用。',
                  style: TextStyle(
                      fontSize: AppType.body, color: context.palette.textSub)),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: context.palette.panel,
                  borderRadius: BorderRadius.circular(AppRadii.sm),
                  border: Border.all(color: context.palette.border),
                ),
                child: SelectableText(
                  _diagnosticsText(),
                  key: const ValueKey('about-diagnostics'),
                  style: TextStyle(
                      fontSize: AppType.body,
                      color: context.palette.textBody,
                      height: 1.6),
                ),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton(
                  style: _outlinedStyle(context),
                  onPressed: () => unawaited(_copyDiagnostics()),
                  child: const Text('复制诊断信息'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _AboutRow extends StatelessWidget {
  final String label;
  final String value;
  final Key? valueKey;

  const _AboutRow({required this.label, required this.value, this.valueKey});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 88,
            child: Text(label,
                style: TextStyle(
                    fontSize: AppType.label, color: context.palette.textSub)),
          ),
          Expanded(
            child: Text(value,
                key: valueKey,
                style: TextStyle(
                    fontSize: AppType.label, color: context.palette.textMain)),
          ),
        ],
      ),
    );
  }
}

class _HomeSiteStatusBanner extends StatelessWidget {
  final ConfigRepository repository;
  const _HomeSiteStatusBanner({required this.repository});

  @override
  Widget build(BuildContext context) => StreamBuilder<void>(
        stream: repository.homeSitePreferencesStream,
        builder: (context, _) {
          final readError = repository.homeSiteReadError;
          final saveError = repository.homeSiteSaveError;
          final saving = repository.isSavingHomeSite;
          if (readError == null && saveError == null && !saving) {
            return const SizedBox.shrink();
          }
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(readError ?? saveError ?? '正在保存首页站源…',
                      style: TextStyle(
                          fontSize: AppType.body,
                          color: readError != null || saveError != null
                              ? context.palette.warning
                              : context.palette.textSub)),
                ),
                if (readError != null)
                  TextButton(
                    onPressed: () => unawaited(_saveWithStatus(
                        repository.reloadHomeSitePreferences())),
                    child: const Text('重新读取首页站源'),
                  )
                else if (saveError != null)
                  TextButton(
                    onPressed: saving
                        ? null
                        : () => unawaited(
                            _saveWithStatus(repository.retryHomeSiteSave())),
                    child: const Text('重试保存首页站源'),
                  ),
              ],
            ),
          );
        },
      );
}

class _SettingsSaveBanner extends StatefulWidget {
  final SettingsRepository repository;
  const _SettingsSaveBanner({super.key, required this.repository});
  @override
  State<_SettingsSaveBanner> createState() => _SettingsSaveBannerState();
}

class _SettingsSaveBannerState extends State<_SettingsSaveBanner> {
  late final _stream = widget.repository.saveStateStream;
  @override
  Widget build(BuildContext context) => StreamBuilder<SettingsSaveState>(
        stream: _stream,
        initialData: widget.repository.saveState,
        builder: (context, snapshot) {
          final state = snapshot.data ?? widget.repository.saveState;
          if (!state.hasFailure && !state.isSaving) {
            return const SizedBox.shrink();
          }
          final names = [
            if (state.failedTargets.contains(SettingsSaveTarget.player))
              '播放器设置',
            if (state.failedTargets.contains(SettingsSaveTarget.sources))
              '配置源历史',
            if (state.failedTargets.contains(SettingsSaveTarget.startup))
              '下次进入页面',
            if (state.failedTargets.contains(SettingsSaveTarget.search)) '搜索设置',
            if (state.failedTargets.contains(SettingsSaveTarget.history))
              '历史记录数量',
            if (state.failedTargets.contains(SettingsSaveTarget.selfCheck))
              '自检偏好',
            if (state.failedTargets.contains(SettingsSaveTarget.playSkip))
              '片头片尾',
            if (state.failedTargets.contains(SettingsSaveTarget.appearance))
              '外观',
          ].join('、');
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(children: [
              Expanded(
                  child: Text(
                state.hasFailure
                    ? (dataRestorePendingRestart
                        ? '$names 未保存：数据已恢复，请重启应用后再修改（本次修改不会写入磁盘）。'
                        : '$names 尚未保存到磁盘，修改暂留本次会话。')
                    : '正在保存设置…',
                style: TextStyle(
                    fontSize: AppType.body,
                    color: state.hasFailure
                        ? context.palette.warning
                        : context.palette.textSub),
              )),
              if (state.hasFailure)
                TextButton(
                  onPressed: state.isSaving
                      ? null
                      : () => unawaited(_saveWithStatus(
                          widget.repository.retryFailedSaves())),
                  child: const Text('重试保存'),
                ),
            ]),
          );
        },
      );
}

class _PlayerApplicationStatus extends StatelessWidget {
  final PlayerSettingsApplication? application;
  const _PlayerApplicationStatus({this.application});

  @override
  Widget build(BuildContext context) {
    final app = application;
    if (app == null) {
      return Text('尚未连接播放器，不能确认参数应用状态。',
          style: TextStyle(
              fontSize: AppType.body, color: context.palette.textSub));
    }
    return StreamBuilder<SettingsApplicationState>(
      stream: app.states,
      initialData: app.state,
      builder: (context, snapshot) {
        final state = snapshot.data ?? app.state;
        final message = switch (state.phase) {
          SettingsApplicationPhase.waiting => '等待播放器初始化，参数尚未确认。',
          SettingsApplicationPhase.applying => '正在应用并确认播放器参数…',
          SettingsApplicationPhase.confirmed => '播放器已回读确认即时参数。',
          SettingsApplicationPhase.failed => '部分播放器参数未确认，请查看失败项。',
          SettingsApplicationPhase.closed => '播放器已关闭，参数不再应用。',
        };
        return _card(context,
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(message,
                  style: TextStyle(
                      fontSize: AppType.label,
                      color: state.failures.isEmpty
                          ? context.palette.textMain
                          : context.palette.warning)),
              const SizedBox(height: 8),
              Text('参数确认不代表正在使用硬解；实际解码与画面效果需播放验证。默认音量 / 倍速仅在初始化时应用。',
                  style: TextStyle(
                      fontSize: AppType.body, color: context.palette.textSub)),
              if (state.defaultsPending)
                Text('默认音量 / 倍速已修改，下次初始化播放器时应用，不改变当前播放。',
                    style: TextStyle(
                        fontSize: AppType.body,
                        color: context.palette.textSub)),
              for (final failure in state.failures.entries)
                Text('${failure.key}：${failure.value}',
                    style: TextStyle(
                        fontSize: AppType.body,
                        color: context.palette.warning)),
              if (state.failures.isNotEmpty)
                TextButton(
                    onPressed:
                        state.canRetry ? () => unawaited(app.retry()) : null,
                    child: const Text('重试应用')),
            ]));
      },
    );
  }
}
