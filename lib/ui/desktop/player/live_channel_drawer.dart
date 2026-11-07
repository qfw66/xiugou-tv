import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/config/models/vod_config.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';
import '../widgets/focus_ring.dart';
import 'live_source_picker.dart';

/// 直播频道抽屉层（TVBox 式两栏：左分组、右频道）。
///
/// 1. 点击左缘热区弹出（不再随鼠标划过自动弹出）；点抽屉外任意处、
///    Esc 或选台后收起。
/// 2. 左栏是分组（首项固定为「收藏频道」），右栏只列所选分组的频道。
/// 3. 键盘：↑/↓ 在当前栏移动（频道栏到分组边界会接着走到相邻分组），
///    ← 进分组栏、→ / Enter 回频道栏，频道栏 Enter 选台。
/// 4. 本层包住整个播放器（含顶栏 / 时间轴工具栏），抽屉画在工具栏之上；
///    [canOpen] 控制左缘热区，显式选台请求不受工具栏显隐限制。
class LiveChannelLayer extends StatefulWidget {
  final List<Live> channels;
  final int currentIndex;
  final ValueChanged<int> onSelect;
  final VoidCallback onManage;
  final Widget child;

  /// 已收藏频道的键集合（§34）：左栏首项「收藏频道」。
  final Set<String> favoriteKeys;

  /// §35：画中画小窗里整层不生效（无热区、无抽屉），还原后恢复。
  final bool enabled;

  /// 能否点左缘弹出抽屉；只管打开，不会收起已打开的抽屉。
  final bool canOpen;

  /// 热区为顶栏 / 底栏保留的可点击空间。
  final EdgeInsets hotzoneInsets;

  /// 每次变化表示显式打开请求，重复请求不会把抽屉切换为关闭。
  final int openRequest;

  final ValueChanged<bool>? onOpenChanged;

  /// 挂载（进入直播页）时抽屉先展开，不受 [canOpen] 限制；之后的开合仍按
  /// 热区 / 选台 / Esc 走。画中画或无频道时不生效。
  final bool initiallyOpen;

  /// 抽屉头部的「直播源」下拉；null 时不显示。
  final LiveSourceNav? sourceNav;

  const LiveChannelLayer({
    super.key,
    required this.channels,
    required this.currentIndex,
    required this.onSelect,
    required this.onManage,
    required this.child,
    this.favoriteKeys = const {},
    this.enabled = true,
    this.canOpen = true,
    this.hotzoneInsets = EdgeInsets.zero,
    this.openRequest = 0,
    this.onOpenChanged,
    this.initiallyOpen = false,
    this.sourceNav,
  });

  @override
  State<LiveChannelLayer> createState() => _LiveChannelLayerState();
}

class _LiveChannelLayerState extends State<LiveChannelLayer> {
  static const double _drawerMaxWidth = 380;
  static const double _drawerMaxRatio = 0.7;
  static const double _hotzoneMax = 220;
  static const double _hotzoneRatio = 0.16;

  late bool _open =
      widget.initiallyOpen && widget.enabled && widget.channels.isNotEmpty;
  double _layoutWidth = 0;

  double get _hotzoneWidth => _layoutWidth == 0
      ? _hotzoneMax
      : math.min(_layoutWidth * _hotzoneRatio, _hotzoneMax);

  double get _drawerWidth => _layoutWidth == 0
      ? _drawerMaxWidth
      : math.min(_drawerMaxWidth, _layoutWidth * _drawerMaxRatio);

  @override
  void initState() {
    super.initState();
    _notifyOpenAfterBuild();
  }

  void _notifyOpenAfterBuild() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onOpenChanged?.call(_open);
    });
  }

  @override
  void didUpdateWidget(covariant LiveChannelLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    final wasOpen = _open;
    if (widget.channels.isEmpty && _open) {
      _open = false;
    }
    // §35：进画中画时立刻收起，避免抽屉留在小窗里。
    if (!widget.enabled && _open) {
      _open = false;
    }
    if (widget.openRequest != oldWidget.openRequest &&
        widget.enabled && widget.channels.isNotEmpty) {
      _open = true;
    }
    if (wasOpen != _open) _notifyOpenAfterBuild();
  }

  void _openDrawer() {
    if (!_open && widget.canOpen && widget.enabled &&
        widget.channels.isNotEmpty) {
      setState(() => _open = true);
      widget.onOpenChanged?.call(true);
    }
  }

  void _close() {
    if (!_open) return;
    setState(() => _open = false);
    widget.onOpenChanged?.call(false);
  }

  void _handleSelect(int index) {
    widget.onSelect(index);
    _close();
  }

  @override
  Widget build(BuildContext context) {
    // §35 方案 A：画中画下整层直通（不留热区，不会误弹）。
    final active = widget.enabled && widget.channels.isNotEmpty;
    return LayoutBuilder(
      builder: (context, constraints) {
        _layoutWidth = constraints.maxWidth;
        final width = _drawerWidth;
        // 停用时也保持同一个 Stack、child 固定在第一位：结构一变整个播放器
        // （画面、顶栏胶囊的菜单状态）都会被卸载重建。
        return Stack(
            fit: StackFit.expand,
            children: [
              widget.child,
              if (active) ..._buildOverlays(width),
            ],
        );
      },
    );
  }

  List<Widget> _buildOverlays(double width) {
    return [
      // 热区与工具栏错开；错误态保持可达，也不会挡住返回 / 播放按钮。
      if (!_open && widget.canOpen)
        Positioned(
          key: const ValueKey('live-channel-hotzone'),
          left: 0,
          top: widget.hotzoneInsets.top,
          bottom: widget.hotzoneInsets.bottom,
          width: _hotzoneWidth,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _openDrawer,
          ),
        ),
      // 抽屉打开时铺一层透明遮罩：点空白处只收起抽屉，
      // 不会穿透成播放 / 暂停或唤出工具栏。
      if (_open)
        Positioned.fill(
          child: GestureDetector(
            key: const ValueKey('live-channel-barrier'),
            behavior: HitTestBehavior.opaque,
            onTap: _close,
          ),
        ),
      AnimatedPositioned(
        duration: _open ? AppMotion.enter : AppMotion.exit,
        curve: AppMotion.ease,
        left: _open ? 0 : -width,
        top: 0,
        bottom: 0,
        width: width,
        child: IgnorePointer(
          ignoring: !_open,
          child: _LiveChannelDrawer(
            channels: widget.channels,
            currentIndex: widget.currentIndex,
            favoriteKeys: widget.favoriteKeys,
            open: _open,
            onSelect: _handleSelect,
            onManage: widget.onManage,
            onRequestClose: _close,
            sourceNav: widget.sourceNav,
          ),
        ),
      ),
    ];
  }
}

/// 左栏的一项：一个分组及其频道下标（按频道列表原顺序）。
class _LiveGroup {
  final String title;
  final List<int> channels;
  final bool favorites;

  const _LiveGroup(this.title, this.channels, {this.favorites = false});
}

enum _DrawerColumn { groups, channels }

class _LiveChannelDrawer extends StatefulWidget {
  final List<Live> channels;
  final int currentIndex;
  final Set<String> favoriteKeys;
  final bool open;
  final ValueChanged<int> onSelect;
  final VoidCallback onManage;
  final VoidCallback onRequestClose;
  final LiveSourceNav? sourceNav;

  const _LiveChannelDrawer({
    required this.channels,
    required this.currentIndex,
    required this.favoriteKeys,
    required this.open,
    required this.onSelect,
    required this.onManage,
    required this.onRequestClose,
    this.sourceNav,
  });

  @override
  State<_LiveChannelDrawer> createState() => _LiveChannelDrawerState();
}

class _LiveChannelDrawerState extends State<_LiveChannelDrawer> {
  static const double _groupItemHeight = 40;
  static const double _itemHeight = 44;
  static const double _listPadding = 6;

  /// 抽屉画在顶栏 / 时间轴工具栏之上，不必再给它们让位，只留一点呼吸空间。
  static const double _topBarInset = 12;
  static const double _bottomBarInset = 0;

  /// 左栏首项（§34）。与管理弹窗里的分类同名同口径。
  static const String favoriteSectionTitle = '收藏频道';

  final FocusNode _focusNode = FocusNode(debugLabel: 'live-channel-drawer');
  final ScrollController _groupScroll = ScrollController();
  final ScrollController _channelScroll = ScrollController();

  /// 左栏分组；下标 0 固定是「收藏频道」（可能为空）。
  List<_LiveGroup> _groups = const [];

  /// 频道下标 → 所在**真实**分组的下标（不含收藏）。按频道列表身份缓存，
  /// 频道上千时悬停 / 按键不再每次全量遍历。
  List<int> _groupOfChannel = const [];

  /// 右栏正在显示的分组。
  int _groupIndex = 0;

  /// 鼠标悬停中的分组行（只影响样式）。
  int _groupHover = -1;

  /// 右栏光标所在频道（频道列表下标）。
  int _cursor = 0;

  /// 键盘当前操作的栏。
  _DrawerColumn _column = _DrawerColumn.channels;

  @override
  void initState() {
    super.initState();
    _rebuildGroups();
    _syncToCurrent();
    if (widget.open) _afterFrame(_focusAndReveal);
  }

  void _focusAndReveal() {
    _focusNode.requestFocus();
    _scrollGroups(animate: false);
    _scrollChannels(animate: false);
  }

  @override
  void didUpdateWidget(covariant _LiveChannelDrawer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.channels, widget.channels) ||
        !setEquals(oldWidget.favoriteKeys, widget.favoriteKeys)) {
      _rebuildGroups();
      if (_groupIndex >= _groups.length) _groupIndex = 0;
      if (_cursor >= widget.channels.length) {
        _cursor = widget.channels.isEmpty ? 0 : widget.channels.length - 1;
      }
      if (!identical(oldWidget.channels, widget.channels)) _syncToCurrent();
    }
    if (widget.open && !oldWidget.open) {
      _syncToCurrent();
      _afterFrame(_focusAndReveal);
    } else if (!widget.open && oldWidget.open) {
      // 焦点交还给外层（播放器），收起后 ← / → 切台、Esc 返回照常可用。
      _focusNode.unfocus(disposition: UnfocusDisposition.previouslyFocusedChild);
      _groupHover = -1;
    } else if (widget.open && widget.currentIndex != oldWidget.currentIndex) {
      _syncToCurrent();
      _afterFrame(() {
        _scrollGroups(animate: false);
        _scrollChannels(animate: false);
      });
    }
  }

  void _afterFrame(VoidCallback action) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.open) action();
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _groupScroll.dispose();
    _channelScroll.dispose();
    super.dispose();
  }

  void _rebuildGroups() {
    final channels = widget.channels;
    final favorites = <int>[];
    final order = <String, int>{};
    final titles = <String>[];
    final buckets = <List<int>>[];
    final groupOf = List<int>.filled(channels.length, 0);
    for (var i = 0; i < channels.length; i++) {
      final channel = channels[i];
      if (widget.favoriteKeys.any(channel.matchesKey)) favorites.add(i);
      final name = channel.groupName;
      final bucket = order.putIfAbsent(name, () {
        titles.add(name);
        buckets.add(<int>[]);
        return buckets.length - 1;
      });
      buckets[bucket].add(i);
      groupOf[i] = bucket + 1;
    }
    _groups = [
      _LiveGroup(favoriteSectionTitle, favorites, favorites: true),
      for (var k = 0; k < titles.length; k++) _LiveGroup(titles[k], buckets[k]),
    ];
    _groupOfChannel = groupOf;
  }

  bool _validChannel(int index) =>
      index >= 0 && index < widget.channels.length;

  /// 打开 / 切台时：右栏回到正在播放频道所在的真实分组，光标落在它上面。
  void _syncToCurrent() {
    _column = _DrawerColumn.channels;
    final current = widget.currentIndex;
    if (_validChannel(current)) {
      _groupIndex = _groupOfChannel[current];
      _cursor = current;
      return;
    }
    final first = _groups.indexWhere((g) => g.channels.isNotEmpty);
    _groupIndex = first < 0 ? 0 : first;
    _cursor = first < 0 ? 0 : _groups[first].channels.first;
  }

  List<int> get _shownChannels => _groups[_groupIndex].channels;

  /// 切到某个分组时光标的落点：正在播放的频道在组内就停在它上面，否则第一项。
  int _cursorFor(_LiveGroup group) {
    if (group.channels.isEmpty) return _cursor;
    if (group.channels.contains(widget.currentIndex)) {
      return widget.currentIndex;
    }
    return group.channels.first;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowUp) {
      final delta = key == LogicalKeyboardKey.arrowDown ? 1 : -1;
      if (_column == _DrawerColumn.groups) {
        _moveGroup(delta);
      } else {
        _moveChannel(delta);
      }
      return KeyEventResult.handled;
    }
    // ←/→ 只在两栏之间切换；一律吞掉，免得播放器同时切台或快进。
    if (key == LogicalKeyboardKey.arrowLeft) {
      if (_column != _DrawerColumn.groups) {
        setState(() => _column = _DrawerColumn.groups);
        _scrollGroups();
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      _enterChannels();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      if (_column == _DrawerColumn.groups) {
        _enterChannels();
      } else if (_shownChannels.contains(_cursor)) {
        widget.onSelect(_cursor);
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      widget.onRequestClose();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _enterChannels() {
    if (_column == _DrawerColumn.channels) return;
    final group = _groups[_groupIndex];
    if (group.channels.isEmpty) return;
    setState(() {
      _column = _DrawerColumn.channels;
      if (!group.channels.contains(_cursor)) _cursor = _cursorFor(group);
    });
    _scrollChannels();
  }

  /// 分组栏 ↑/↓：右栏随之切换（TVBox 行为）。
  void _moveGroup(int delta) {
    final next = _groupIndex + delta;
    if (next < 0 || next >= _groups.length) return;
    _showGroup(next, column: _DrawerColumn.groups);
  }

  /// 频道栏 ↑/↓：到分组边界时接着走到相邻的非空分组。
  void _moveChannel(int delta) {
    final list = _shownChannels;
    final pos = list.indexOf(_cursor);
    final next = pos < 0 ? (delta > 0 ? 0 : list.length - 1) : pos + delta;
    if (next >= 0 && next < list.length) {
      setState(() => _cursor = list[next]);
      _scrollChannels();
      return;
    }
    var g = _groupIndex + delta;
    while (g >= 0 && g < _groups.length && _groups[g].channels.isEmpty) {
      g += delta;
    }
    if (g < 0 || g >= _groups.length) return;
    final target = _groups[g].channels;
    setState(() {
      _groupIndex = g;
      _cursor = delta > 0 ? target.first : target.last;
    });
    _afterFrame(() {
      _scrollGroups();
      _scrollChannels(animate: false);
    });
  }

  void _showGroup(int index, {required _DrawerColumn column}) {
    final group = _groups[index];
    setState(() {
      _groupIndex = index;
      _column = column;
      _cursor = _cursorFor(group);
    });
    _afterFrame(() {
      _scrollGroups();
      _scrollChannels(animate: false);
    });
  }

  void _tapGroup(int index) {
    _focusNode.requestFocus();
    _showGroup(index, column: _DrawerColumn.groups);
  }

  void _scrollGroups({bool animate = true}) {
    _scrollTo(_groupScroll, _groupIndex * _groupItemHeight, _groupItemHeight,
        animate);
  }

  void _scrollChannels({bool animate = true}) {
    final pos = _shownChannels.indexOf(_cursor);
    if (pos < 0) {
      if (_channelScroll.hasClients) _channelScroll.jumpTo(0);
      return;
    }
    _scrollTo(_channelScroll, pos * _itemHeight, _itemHeight, animate);
  }

  void _scrollTo(
      ScrollController controller, double top, double extent, bool animate) {
    if (!controller.hasClients) return;
    final position = controller.position;
    final target = (top + _listPadding - position.viewportDimension / 2 + extent)
        .clamp(0.0, position.maxScrollExtent)
        .toDouble();
    if (animate) {
      controller.animateTo(target,
          duration: AppMotion.enter, curve: AppMotion.ease);
    } else {
      controller.jumpTo(target);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return Focus(
      focusNode: _focusNode,
      onKeyEvent: _onKey,
      child: ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: Container(
            key: const ValueKey('live-channel-drawer-panel'),
            // 跟随主题（与选集 / 播放设置抽屉同一套 player 色）：
            // 浅色主题下原先写死的深底会整块发黑（issue #10-②）。
            decoration: BoxDecoration(
              color: palette.playerChrome,
              border: Border(
                right: BorderSide(
                  color: palette.playerText.withValues(alpha: 0.12),
                  width: 1,
                ),
              ),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x66000000),
                  blurRadius: 24,
                  offset: Offset(8, 0),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: _topBarInset),
                _buildHeader(palette),
                Divider(
                  height: 1,
                  thickness: 1,
                  color: palette.playerText.withValues(alpha: 0.08),
                ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final groupWidth =
                          (constraints.maxWidth * 0.34).clamp(92.0, 132.0);
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(
                            width: groupWidth,
                            child: _buildGroupColumn(palette),
                          ),
                          Container(
                            width: 1,
                            color: palette.playerText.withValues(alpha: 0.08),
                          ),
                          Expanded(child: _buildChannelColumn(palette)),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(AppPalette palette) {
    final sourceNav = widget.sourceNav;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildTitleRow(palette),
          if (sourceNav != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: LiveSourcePicker(nav: sourceNav),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildTitleRow(AppPalette palette) {
    return Row(
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: palette.accentWash,
              borderRadius: BorderRadius.circular(AppRadii.sm),
              border: Border.all(
                color: palette.accentInk.withValues(alpha: 0.3),
                width: 0.8,
              ),
            ),
            child: Center(
              child: Icon(
                Icons.live_tv_rounded,
                size: 16,
                color: palette.accentInk,
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '直播频道',
                  style: TextStyle(
                    color: palette.playerText,
                    fontSize: AppType.title,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                  ),
                ),
                Text(
                  '共 ${widget.channels.length} 个电台 · '
                  '${_groups.length - 1} 个分组',
                  style: TextStyle(
                    color: palette.playerText.withValues(alpha: 0.55),
                    fontSize: AppType.caption,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
          FocusOutline(
            radius: AppRadii.pill,
            child: IconButton(
              icon: Icon(
                Icons.tune_rounded,
                size: 18,
                color: palette.playerText.withValues(alpha: 0.85),
              ),
              tooltip: '管理直播频道',
              onPressed: widget.onManage,
            ),
          ),
        ],
    );
  }

  Widget _buildGroupColumn(AppPalette palette) {
    return ListView.builder(
      key: const ValueKey('live-group-list'),
      controller: _groupScroll,
      padding: const EdgeInsets.only(
        top: _listPadding,
        bottom: _listPadding + _bottomBarInset,
      ),
      itemCount: _groups.length,
      itemExtent: _groupItemHeight,
      itemBuilder: (context, index) => _buildGroupRow(palette, index),
    );
  }

  Widget _buildGroupRow(AppPalette palette, int index) {
    final group = _groups[index];
    final selected = index == _groupIndex;
    final focused = selected && _column == _DrawerColumn.groups;
    final hovered = index == _groupHover;
    final current = widget.currentIndex;
    final playingHere = !group.favorites &&
        _validChannel(current) &&
        _groupOfChannel[current] == index;

    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 2, 4, 2),
      child: Semantics(
        button: true,
        selected: selected,
        label: group.title,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) {
            if (_groupHover != index) setState(() => _groupHover = index);
          },
          onExit: (_) {
            if (_groupHover == index) setState(() => _groupHover = -1);
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _tapGroup(index),
            child: AnimatedContainer(
              duration: selected ? AppMotion.enter : AppMotion.exit,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: selected
                    ? palette.accentInk.withValues(alpha: 0.18)
                    : (hovered
                        ? palette.playerText.withValues(alpha: 0.06)
                        : Colors.transparent),
                borderRadius: BorderRadius.circular(AppRadii.sm),
                border: Border.all(
                  color: focused
                      ? palette.accentInk.withValues(alpha: 0.55)
                      : Colors.transparent,
                  width: 1,
                ),
              ),
              child: Row(
                children: [
                  if (group.favorites) ...[
                    Icon(
                      Icons.star_rounded,
                      size: 14,
                      color: palette.accentInk,
                    ),
                    const SizedBox(width: 4),
                  ],
                  Expanded(
                    child: Text(
                      group.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: selected
                            ? palette.playerText
                            : palette.playerText.withValues(alpha: 0.7),
                        fontSize: AppType.body,
                        fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                  ),
                  if (playingHere) ...[
                    Container(
                      width: 5,
                      height: 5,
                      decoration: BoxDecoration(
                        color: palette.danger,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 4),
                  ],
                  Text(
                    '${group.channels.length}',
                    style: TextStyle(
                      color: palette.playerText.withValues(alpha: 0.4),
                      fontSize: AppType.caption,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildChannelColumn(AppPalette palette) {
    final group = _groups[_groupIndex];
    if (group.channels.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(14, 16, 14, 0),
        child: Align(
          alignment: Alignment.topLeft,
          child: Text(
            group.favorites ? '还没有收藏频道，点「管理频道」加星标' : '这个分组没有频道',
            style: TextStyle(
              color: palette.playerText.withValues(alpha: 0.45),
              fontSize: AppType.caption,
            ),
          ),
        ),
      );
    }
    final list = group.channels;
    return ListView.builder(
      key: const ValueKey('live-channel-list'),
      controller: _channelScroll,
      padding: const EdgeInsets.only(
        top: _listPadding,
        bottom: _listPadding + _bottomBarInset,
      ),
      itemCount: list.length,
      // 所有行同高：拖动滚动条跳到深处是 O(1)，频道上千也不卡。
      itemExtent: _itemHeight,
      itemBuilder: (context, pos) => _buildChannelRow(palette, list[pos]),
    );
  }

  Widget _buildChannelRow(AppPalette palette, int i) {
    final channel = widget.channels[i];
    final isCurrent = i == widget.currentIndex;
    final isCursor = _column == _DrawerColumn.channels && i == _cursor;

    // 台号格式化：三位对齐
    final channelNumber = (i + 1).toString().padLeft(3, '0');

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      child: FocusRing(
        onTap: () => widget.onSelect(i),
        borderRadius: BorderRadius.circular(AppRadii.sm),
        semanticLabel: channel.name,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) {
            if (i == _cursor && _column == _DrawerColumn.channels) return;
            setState(() {
              _cursor = i;
              _column = _DrawerColumn.channels;
            });
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => widget.onSelect(i),
            child: AnimatedContainer(
              duration: isCursor || isCurrent ? AppMotion.enter : AppMotion.exit,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: isCurrent
                    ? palette.accentInk.withValues(alpha: 0.22)
                    : (isCursor
                        ? palette.playerText.withValues(alpha: 0.08)
                        : Colors.transparent),
                borderRadius: BorderRadius.circular(AppRadii.sm),
                border: Border.all(
                  color: isCurrent
                      ? palette.accentInk.withValues(alpha: 0.45)
                      : (isCursor
                          ? palette.playerText.withValues(alpha: 0.12)
                          : Colors.transparent),
                  width: 1,
                ),
              ),
              child: Row(
                children: [
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                    decoration: BoxDecoration(
                      color: isCurrent
                          ? palette.accentInk.withValues(alpha: 0.25)
                          : palette.playerText.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(AppRadii.xs),
                    ),
                    child: Text(
                      channelNumber,
                      style: TextStyle(
                        color: isCurrent
                            ? palette.accentInk
                            : palette.playerText.withValues(alpha: 0.45),
                        fontSize: AppType.caption,
                        fontWeight: FontWeight.w600,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      channel.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: isCurrent
                            ? palette.playerText
                            : palette.playerText.withValues(alpha: 0.85),
                        fontSize: AppType.body,
                        fontWeight:
                            isCurrent ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                  ),
                  if (isCurrent) ...[
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: palette.danger,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: palette.danger.withValues(alpha: 0.6),
                            blurRadius: 4,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '正在播出',
                      style: TextStyle(
                        color: palette.danger,
                        fontSize: AppType.caption,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
