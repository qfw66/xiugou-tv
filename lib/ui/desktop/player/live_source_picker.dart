import 'dart:async';

import 'package:flutter/material.dart';

import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';

/// 直播抽屉顶部「直播源」下拉的一个选项。
class LiveSourceOption {
  const LiveSourceOption({
    this.location,
    required this.name,
    required this.subtitle,
    this.current = false,
  });

  /// 独立直播源地址（`http(s)://` / `file://`）；null = 跟随主配置源。
  final String? location;
  final String name;
  final String subtitle;
  final bool current;
}

/// 直播抽屉顶部「直播源」下拉的视图模型。
///
/// 切换只改直播（点播的主配置源不动）；[onSelect] 完成前下拉显示「切换中…」。
class LiveSourceNav {
  const LiveSourceNav({
    required this.label,
    required this.options,
    required this.onSelect,
    this.onManage,
  });

  /// 当前直播源名称。
  final String label;
  final List<LiveSourceOption> options;
  final Future<void> Function(LiveSourceOption option) onSelect;
  final VoidCallback? onManage;
}

/// 直播抽屉头部的直播源下拉（跟随抽屉主题配色）。
class LiveSourcePicker extends StatefulWidget {
  const LiveSourcePicker({super.key, required this.nav});

  final LiveSourceNav nav;

  @override
  State<LiveSourcePicker> createState() => _LiveSourcePickerState();
}

class _LiveSourcePickerState extends State<LiveSourcePicker> {
  final GlobalKey _anchorKey = GlobalKey();
  bool _hovered = false;
  bool _menuOpen = false;
  bool _busy = false;

  bool get _enabled => !_busy && !_menuOpen;

  Future<void> _openMenu() async {
    if (!_enabled) return;
    final anchorContext = _anchorKey.currentContext;
    final renderBox = anchorContext?.findRenderObject();
    final overlay = anchorContext == null ? null : Overlay.maybeOf(anchorContext);
    if (renderBox is! RenderBox || overlay == null || !renderBox.hasSize) {
      return;
    }
    final topLeft = renderBox.localToGlobal(Offset.zero);
    final overlayBox = overlay.context.findRenderObject();
    final overlaySize =
        overlayBox is RenderBox ? overlayBox.size : MediaQuery.sizeOf(context);
    final position = RelativeRect.fromRect(
      Rect.fromLTWH(
        topLeft.dx,
        topLeft.dy + renderBox.size.height + 4,
        renderBox.size.width,
        0,
      ),
      Offset.zero & overlaySize,
    );
    final palette = context.palette;

    setState(() => _menuOpen = true);
    _Choice? choice;
    try {
      choice = await showMenu<_Choice>(
        context: context,
        position: position,
        color: palette.raised,
        elevation: 8,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.md),
          side: BorderSide(color: palette.border),
        ),
        constraints: BoxConstraints(
          minWidth: renderBox.size.width,
          maxWidth: renderBox.size.width,
          maxHeight: 420,
        ),
        items: _buildMenuItems(palette),
      );
    } finally {
      if (mounted) setState(() => _menuOpen = false);
    }
    switch (choice) {
      case _OptionChoice(:final option):
        await _select(option);
      case _ManageChoice():
        widget.nav.onManage?.call();
      case null:
        break;
    }
  }

  Future<void> _select(LiveSourceOption option) async {
    if (option.current || _busy) return;
    setState(() => _busy = true);
    try {
      await widget.nav.onSelect(option);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  List<PopupMenuEntry<_Choice>> _buildMenuItems(AppPalette palette) {
    return [
      PopupMenuItem<_Choice>(
        enabled: false,
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Text(
          '切换直播源（只换直播，点播不受影响）',
          style: TextStyle(color: palette.textSub, fontSize: AppType.caption),
        ),
      ),
      for (final option in widget.nav.options)
        PopupMenuItem<_Choice>(
          key: ValueKey('live-source-option-${option.location ?? 'follow'}'),
          value: _OptionChoice(option),
          enabled: !option.current,
          height: 52,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: _OptionRow(option: option, palette: palette),
        ),
      if (widget.nav.onManage != null) ...[
        const PopupMenuDivider(height: 9),
        PopupMenuItem<_Choice>(
          value: const _ManageChoice(),
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            children: [
              Icon(Icons.tune_rounded, size: 16, color: palette.textSub),
              const SizedBox(width: 8),
              Text(
                '管理直播源…',
                style: TextStyle(
                  color: palette.textMain,
                  fontSize: AppType.body,
                ),
              ),
            ],
          ),
        ),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final ink = palette.playerText;
    final label = _busy ? '切换中…' : widget.nav.label;
    return Semantics(
      button: true,
      enabled: _enabled,
      label: '直播源：$label，点击切换',
      child: ExcludeSemantics(
        child: MouseRegion(
          cursor: _enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            key: _anchorKey,
            behavior: HitTestBehavior.opaque,
            onTap: _enabled ? () => unawaited(_openMenu()) : null,
            child: AnimatedContainer(
              key: const ValueKey('live-source-picker'),
              duration: AppMotion.exit,
              curve: AppMotion.ease,
              height: 34,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: ink.withValues(
                    alpha: (_hovered && _enabled) || _menuOpen ? 0.12 : 0.06),
                borderRadius: BorderRadius.circular(AppRadii.sm),
                border: Border.all(color: ink.withValues(alpha: 0.14)),
              ),
              child: Row(
                children: [
                  if (_busy)
                    SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                        key: const ValueKey('live-source-picker-busy'),
                        strokeWidth: 1.8,
                        color: ink,
                      ),
                    )
                  else
                    Icon(Icons.source_rounded,
                        size: 14, color: ink.withValues(alpha: 0.6)),
                  const SizedBox(width: 8),
                  Text(
                    '直播源',
                    style: TextStyle(
                      color: ink.withValues(alpha: 0.55),
                      fontSize: AppType.caption,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: ink,
                        fontSize: AppType.body,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Icon(Icons.expand_more_rounded,
                      size: 16, color: ink.withValues(alpha: 0.6)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _OptionRow extends StatelessWidget {
  const _OptionRow({required this.option, required this.palette});

  final LiveSourceOption option;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      button: true,
      selected: option.current,
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
                    style: TextStyle(
                      color: palette.textMain,
                      fontSize: AppType.label,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    option.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: palette.textSub,
                      fontSize: AppType.caption,
                    ),
                  ),
                ],
              ),
            ),
            if (option.current) ...[
              const SizedBox(width: 10),
              Icon(Icons.check_rounded, size: 16, color: palette.accentInk),
            ],
          ],
        ),
      ),
    );
  }
}

sealed class _Choice {
  const _Choice();
}

class _OptionChoice extends _Choice {
  const _OptionChoice(this.option);
  final LiveSourceOption option;
}

class _ManageChoice extends _Choice {
  const _ManageChoice();
}
