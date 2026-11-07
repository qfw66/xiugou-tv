import 'package:flutter/material.dart';

import '../../../core/config/models/vod_config.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';
import '../widgets/focus_ring.dart';
import 'live_channel_logo.dart';

/// 左栏的一个分组：[value] 为 null 表示「全部」，其余由弹窗定义（含收藏哨兵值）。
class LiveGroupItem {
  final String? value;
  final String label;
  final int count;

  /// 测试与键盘定位用的分组键（与标签布局胶囊同名：`live-group-…`）。
  final String keyName;

  const LiveGroupItem({
    required this.value,
    required this.label,
    required this.count,
    required this.keyName,
  });
}

/// 「直播」管理弹窗的两栏布局（TVBox 样式，试用）：左分组、右频道。
///
/// 与播放器内频道抽屉（`live_channel_drawer.dart`）同一结构，配色用弹窗常规色。
/// 只负责展示，分组选中 / 搜索过滤 / 收藏 / 播放都由弹窗传入；
/// 不保留时删掉本文件与弹窗里 [LiveChannelsLayout.columns] 分支即可。
class LiveChannelColumns extends StatelessWidget {
  final List<LiveGroupItem> groups;
  final String? selectedGroup;
  final ValueChanged<String?> onSelectGroup;

  /// 当前分组 + 搜索过滤后的频道；为空时右栏显示 [emptyState]。
  final List<Live> channels;
  final Widget emptyState;
  final ValueChanged<Live> onPlay;
  final bool Function(Live channel) isFavorited;

  /// 为 null 时行内不展示收藏星标。
  final ValueChanged<Live>? onToggleFavorite;

  /// 返回 null 表示该频道没有节目单入口。
  final VoidCallback? Function(Live channel) epgAction;

  const LiveChannelColumns({
    super.key,
    required this.groups,
    required this.selectedGroup,
    required this.onSelectGroup,
    required this.channels,
    required this.emptyState,
    required this.onPlay,
    required this.isFavorited,
    required this.epgAction,
    this.onToggleFavorite,
  });

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return LayoutBuilder(builder: (context, constraints) {
      final groupWidth = (constraints.maxWidth * 0.24).clamp(120.0, 220.0);
      // 窄窗口下省掉编号，给频道名留位置。
      final showNumber = constraints.maxWidth - groupWidth > 320;
      return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(
          width: groupWidth,
          child: ListView.builder(
            itemCount: groups.length,
            itemBuilder: (_, index) {
              final group = groups[index];
              return _GroupRow(
                key: ValueKey('live-group-${group.keyName}'),
                group: group,
                selected: group.value == selectedGroup,
                onTap: () => onSelectGroup(group.value),
              );
            },
          ),
        ),
        Container(
          width: 1,
          margin: const EdgeInsets.symmetric(horizontal: 10),
          color: palette.border,
        ),
        Expanded(
          child: channels.isEmpty
              ? emptyState
              : ListView.builder(
                  // 换分组时回到列表顶部。
                  key: ValueKey('live-channel-rows:${selectedGroup ?? ''}'),
                  itemCount: channels.length,
                  itemExtent: 58,
                  itemBuilder: (_, index) {
                    final channel = channels[index];
                    return _ChannelRow(
                      key: ValueKey(channel.key),
                      channel: channel,
                      number: showNumber
                          ? (index + 1).toString().padLeft(3, '0')
                          : null,
                      showGroup: selectedGroup == null ||
                          selectedGroup != channel.groupName,
                      favorited: isFavorited(channel),
                      onPlay: () => onPlay(channel),
                      onToggleFavorite: onToggleFavorite == null
                          ? null
                          : () => onToggleFavorite!(channel),
                      onEpg: epgAction(channel),
                    );
                  },
                ),
        ),
      ]);
    });
  }
}

class _GroupRow extends StatefulWidget {
  final LiveGroupItem group;
  final bool selected;
  final VoidCallback onTap;

  const _GroupRow({
    super.key,
    required this.group,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_GroupRow> createState() => _GroupRowState();
}

class _GroupRowState extends State<_GroupRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final selected = widget.selected;
    final background = selected
        ? palette.accent.withValues(alpha: 0.22)
        : _hovered
            ? palette.hover
            : Colors.transparent;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: FocusRing(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(AppRadii.sm),
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: AnimatedContainer(
              duration: _hovered ? AppMotion.enter : AppMotion.exit,
              curve: AppMotion.ease,
              height: 40,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: background,
                borderRadius: BorderRadius.circular(AppRadii.sm),
              ),
              child: Row(children: [
                Expanded(
                  child: Text(widget.group.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: selected ? palette.textTitle : palette.textBody,
                          fontSize: AppType.label,
                          fontWeight:
                              selected ? FontWeight.w600 : FontWeight.normal)),
                ),
                const SizedBox(width: 6),
                Text('${widget.group.count}',
                    style: TextStyle(
                        color: palette.textSub,
                        fontSize: AppType.caption,
                        fontFeatures: const [FontFeature.tabularFigures()])),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class _ChannelRow extends StatefulWidget {
  final Live channel;

  /// 三位编号（TVBox 习惯）；窄窗口为 null 不显示。
  final String? number;

  /// 「全部」/「收藏」里显示频道所属分组，具体分组里不重复显示。
  final bool showGroup;
  final bool favorited;
  final VoidCallback onPlay;
  final VoidCallback? onToggleFavorite;
  final VoidCallback? onEpg;

  const _ChannelRow({
    super.key,
    required this.channel,
    required this.number,
    required this.showGroup,
    required this.favorited,
    required this.onPlay,
    this.onToggleFavorite,
    this.onEpg,
  });

  @override
  State<_ChannelRow> createState() => _ChannelRowState();
}

class _ChannelRowState extends State<_ChannelRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final channel = widget.channel;
    final number = widget.number;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: FocusRing(
        onTap: widget.onPlay,
        semanticLabel: channel.name,
        borderRadius: BorderRadius.circular(AppRadii.md),
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          cursor: SystemMouseCursors.click,
          child: AnimatedContainer(
            duration: _hovered ? AppMotion.enter : AppMotion.exit,
            curve: AppMotion.ease,
            decoration: BoxDecoration(
              color: _hovered ? palette.hover : palette.card,
              borderRadius: BorderRadius.circular(AppRadii.md),
              border: Border.all(
                  color: _hovered ? palette.accentInk : palette.border),
            ),
            clipBehavior: Clip.antiAlias,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: widget.onPlay,
                hoverColor: Colors.transparent,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Row(children: [
                    if (number != null) ...[
                      Container(
                        width: 38,
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: palette.raised,
                          borderRadius: BorderRadius.circular(AppRadii.sm),
                        ),
                        child: Text(number,
                            style: TextStyle(
                                color: palette.textSub,
                                fontSize: AppType.caption,
                                fontWeight: FontWeight.w600,
                                fontFeatures: const [
                                  FontFeature.tabularFigures()
                                ])),
                      ),
                      const SizedBox(width: 10),
                    ],
                    SizedBox(
                      width: 32,
                      height: 32,
                      child: LiveChannelLogo(
                          channel: channel, size: 32, fallbackSize: 20),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(channel.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    color: palette.textTitle,
                                    fontSize: AppType.label,
                                    fontWeight: FontWeight.w600)),
                            if (widget.showGroup)
                              Text(channel.groupName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      color: palette.textSub,
                                      fontSize: AppType.caption)),
                          ]),
                    ),
                    if (widget.onToggleFavorite != null)
                      Tooltip(
                        message: widget.favorited ? '取消收藏' : '收藏频道',
                        child: IconButton(
                          key: ValueKey('live-fav-${channel.key}'),
                          onPressed: widget.onToggleFavorite,
                          icon: Icon(
                            widget.favorited
                                ? Icons.star_rounded
                                : Icons.star_border_rounded,
                            size: 20,
                          ),
                          color: widget.favorited
                              ? palette.warning
                              : palette.textSub,
                          visualDensity: VisualDensity.compact,
                          constraints:
                              const BoxConstraints(minWidth: 32, minHeight: 32),
                          padding: EdgeInsets.zero,
                        ),
                      ),
                    if (widget.onEpg != null)
                      TextButton.icon(
                        onPressed: widget.onEpg,
                        icon: const Icon(Icons.event_note, size: 16),
                        label: const Text('节目单',
                            style: TextStyle(fontSize: AppType.body)),
                        style: TextButton.styleFrom(
                            foregroundColor: palette.textBody,
                            minimumSize: Size.zero,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 6)),
                      ),
                    const SizedBox(width: 4),
                    Icon(Icons.play_circle_outline,
                        size: 20, color: palette.accentInk),
                  ]),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
