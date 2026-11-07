import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/settings/models/config_source_entry.dart';
import '../../theme/app_tokens.dart';
import '../widgets/focus_ring.dart';

/// 播放器顶栏「当前配置源」胶囊的可选来源（方案 §6.2）。
///
/// 只描述展示内容与是否当前项；切换动作由宿主提供的 [PlayerConfigSourceNav.onSelect]
/// 决定。`entry == null` 表示菜单里合成的「当前项」（历史缺失时）。
class PlayerConfigSourceOption {
  const PlayerConfigSourceOption({
    this.entry,
    required this.name,
    required this.subtitle,
    this.current = false,
  });

  final ConfigSourceEntry? entry;
  final String name;
  final String subtitle;
  final bool current;
}

/// B 段配置源胶囊的视图模型（方案 §6.2）。
///
/// 组件保持哑视图：文案、忙碌态、回调都由宿主装配；`onAddConfig` 与
/// `headerDetail` 是为满足 §4.2 菜单页脚与头部而新增的可选字段。
class PlayerConfigSourceNav {
  const PlayerConfigSourceNav({
    required this.label,
    this.detail,
    this.busy = false,
    required this.sources,
    required this.onSelect,
    required this.onManage,
    this.onAddConfig,
    this.headerDetail,
    this.onMenuOpenChanged,
  });

  final String label;
  final String? detail;

  /// 菜单头部右侧摘要（如 `39 个站点 · 1 个直播源`）。
  final String? headerDetail;
  final bool busy;
  final List<PlayerConfigSourceOption> sources;
  final ValueChanged<PlayerConfigSourceOption> onSelect;
  final VoidCallback onManage;
  final VoidCallback? onAddConfig;
  final ValueChanged<bool>? onMenuOpenChanged;
}

/// 播放器顶栏的「配置源」胶囊 + 下拉菜单（B 段，只读展示 + 切换入口）。
class PlayerConfigSourceBadge extends StatefulWidget {
  const PlayerConfigSourceBadge({
    super.key,
    required this.nav,
    this.maxWidth = 200,
    this.onMenuOpenChanged,
  });

  final PlayerConfigSourceNav nav;
  final double maxWidth;

  /// 菜单开合通知（宿主用它暂停 / 恢复顶栏自动隐藏）；优先于 nav 上的同名字段。
  final ValueChanged<bool>? onMenuOpenChanged;

  @override
  State<PlayerConfigSourceBadge> createState() =>
      _PlayerConfigSourceBadgeState();
}

class _PlayerConfigSourceBadgeState extends State<PlayerConfigSourceBadge> {
  static const Color _ink = Color(0xFFFFFFFF);
  static const Color _highlight = Color(0xFF94A3B8);

  final GlobalKey _anchorKey = GlobalKey();
  bool _hovered = false;
  bool _menuOpen = false;

  bool get _busy => widget.nav.busy;
  bool get _enabled => !_busy;

  void _notifyMenuOpen(bool open) {
    final callback = widget.onMenuOpenChanged ?? widget.nav.onMenuOpenChanged;
    callback?.call(open);
  }

  Future<void> _openMenu() async {
    if (!_enabled || _menuOpen) return;
    final anchorContext = _anchorKey.currentContext;
    if (anchorContext == null) return;
    final renderBox = anchorContext.findRenderObject();
    final overlay = Overlay.maybeOf(anchorContext);
    if (renderBox is! RenderBox || overlay == null || !renderBox.hasSize)
      return;

    final topLeft = renderBox.localToGlobal(Offset.zero);
    final overlayBox = overlay.context.findRenderObject();
    final overlaySize =
        overlayBox is RenderBox ? overlayBox.size : MediaQuery.sizeOf(context);
    final position = RelativeRect.fromRect(
      Rect.fromLTWH(
        topLeft.dx,
        topLeft.dy + renderBox.size.height + 8,
        renderBox.size.width,
        0,
      ),
      Offset.zero & overlaySize,
    );

    setState(() => _menuOpen = true);
    _notifyMenuOpen(true);

    _MenuChoice? choice;
    try {
      choice = await showMenu<_MenuChoice>(
        context: context,
        position: position,
        color: const Color(0xFF16161C),
        elevation: 8,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.md),
          side: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
        ),
        constraints: const BoxConstraints(
          minWidth: 300,
          maxWidth: 300,
          maxHeight: 360,
        ),
        items: _buildMenuItems(),
      );
    } finally {
      if (mounted) {
        setState(() => _menuOpen = false);
        _notifyMenuOpen(false);
      }
    }

    switch (choice) {
      case _SourceChoice(:final option):
        widget.nav.onSelect(option);
      case _ManageChoice():
        widget.nav.onManage();
      case _AddChoice():
        widget.nav.onAddConfig?.call();
      case null:
        break;
    }
  }

  List<PopupMenuEntry<_MenuChoice>> _buildMenuItems() {
    final nav = widget.nav;
    return [
      PopupMenuItem<_MenuChoice>(
        enabled: false,
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 0),
        child: _MenuHeader(
          detail: nav.headerDetail,
          busy: nav.busy,
        ),
      ),
      if (nav.sources.isEmpty)
        const PopupMenuItem<_MenuChoice>(
          enabled: false,
          height: 56,
          padding: EdgeInsets.symmetric(horizontal: 14, vertical: 0),
          child: Text(
            '成功加载过的配置会自动出现在这里',
            style: TextStyle(color: _highlight, fontSize: AppType.body),
          ),
        )
      else
        for (final option in nav.sources)
          PopupMenuItem<_MenuChoice>(
            value: _SourceChoice(option),
            enabled: !nav.busy && !option.current,
            height: 56,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 0),
            child: _SourceRow(option: option),
          ),
      const PopupMenuDivider(height: 9),
      PopupMenuItem<_MenuChoice>(
        value: const _ManageChoice(),
        enabled: !nav.busy,
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 0),
        child: const _FooterRow(
          icon: Icons.settings_outlined,
          label: '管理配置源…',
        ),
      ),
      if (nav.onAddConfig != null)
        PopupMenuItem<_MenuChoice>(
          value: const _AddChoice(),
          enabled: !nav.busy,
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 0),
          child: const _FooterRow(
            icon: Icons.add_rounded,
            label: '添加配置源…',
          ),
        ),
    ];
  }

  String get _semanticLabel {
    final action = _busy ? '正在切换配置源' : '点击切换';
    return '当前配置源：${widget.nav.label}，$action';
  }

  @override
  Widget build(BuildContext context) {
    final busy = _busy;
    return FocusRing(
      onTap: _enabled ? () => unawaited(_openMenu()) : null,
      borderRadius: const BorderRadius.all(Radius.circular(AppRadii.pill)),
      semanticLabel: _semanticLabel,
      color: _ink,
      child: ExcludeSemantics(
        child: Tooltip(
          message: widget.nav.detail ?? widget.nav.label,
          waitDuration: const Duration(milliseconds: 400),
          child: MouseRegion(
            cursor:
                _enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
            onEnter: (_) {
              if (!_enabled) return;
              setState(() => _hovered = true);
            },
            onExit: (_) {
              if (_hovered) setState(() => _hovered = false);
            },
            child: GestureDetector(
              key: _anchorKey,
              behavior: HitTestBehavior.opaque,
              excludeFromSemantics: true,
              onTap: _enabled ? () => unawaited(_openMenu()) : null,
              child: AnimatedContainer(
                key: const ValueKey('player-config-source-badge'),
                duration: AppMotion.exit,
                curve: AppMotion.ease,
                height: 28,
                constraints: BoxConstraints(maxWidth: widget.maxWidth),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: Colors.white
                      .withValues(alpha: (_hovered || _menuOpen) ? 0.16 : 0.10),
                  borderRadius:
                      const BorderRadius.all(Radius.circular(AppRadii.pill)),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.18),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (busy)
                      const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                          key: ValueKey('player-config-source-busy'),
                          strokeWidth: 1.8,
                          color: _ink,
                        ),
                      )
                    else
                      const Icon(
                        Icons.source_rounded,
                        size: 14,
                        color: _highlight,
                      ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        busy ? '切换中…' : widget.nav.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: _ink,
                          fontSize: AppType.body,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (!busy) ...[
                      const SizedBox(width: 2),
                      const Icon(
                        Icons.expand_more_rounded,
                        size: 16,
                        color: _highlight,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MenuHeader extends StatelessWidget {
  const _MenuHeader({required this.detail, required this.busy});

  final String? detail;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text(
              '当前配置源',
              style: TextStyle(
                color: Color(0xFFFFFFFF),
                fontSize: AppType.label,
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            if (busy)
              const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.8,
                      color: Color(0xFFFFFFFF),
                    ),
                  ),
                  SizedBox(width: 6),
                  Text(
                    '正在切换配置源…',
                    style: TextStyle(
                      color: Color(0xFF94A3B8),
                      fontSize: AppType.caption,
                    ),
                  ),
                ],
              ),
          ],
        ),
        if (detail != null && detail!.trim().isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            detail!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Color(0xFF94A3B8),
              fontSize: AppType.caption,
            ),
          ),
        ],
      ],
    );
  }
}

class _SourceRow extends StatelessWidget {
  const _SourceRow({required this.option});

  final PlayerConfigSourceOption option;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      button: true,
      selected: option.current,
      enabled: !option.current,
      label: '${option.name}，${option.subtitle}${option.current ? '，当前' : ''}',
      child: ExcludeSemantics(
        child: Row(
          children: [
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    option.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFFFFFFFF),
                      fontSize: AppType.label,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    option.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFF94A3B8),
                      fontSize: AppType.caption,
                    ),
                  ),
                ],
              ),
            ),
            if (option.current) ...[
              const SizedBox(width: 10),
              const Icon(Icons.check_rounded,
                  size: 16, color: Color(0xFFFFFFFF)),
              const SizedBox(width: 4),
              const Text(
                '当前',
                style: TextStyle(
                  color: Color(0xFFFFFFFF),
                  fontSize: AppType.caption,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _FooterRow extends StatelessWidget {
  const _FooterRow({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 16, color: const Color(0xFF94A3B8)),
        const SizedBox(width: 8),
        Text(
          label,
          style: const TextStyle(
            color: Color(0xFFFFFFFF),
            fontSize: AppType.body,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

sealed class _MenuChoice {
  const _MenuChoice();
}

class _SourceChoice extends _MenuChoice {
  const _SourceChoice(this.option);
  final PlayerConfigSourceOption option;
}

class _ManageChoice extends _MenuChoice {
  const _ManageChoice();
}

class _AddChoice extends _MenuChoice {
  const _AddChoice();
}
