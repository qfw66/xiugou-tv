import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/config/models/vod_config.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';
import '../widgets/focus_ring.dart';

/// ⑤-3 直播频道抽屉层（Infuse × Netflix 融合质感）：
///
/// 特性：
/// 1. 微透磨砂玻璃抽屉（BackdropFilter 24px + 1px 细微高光右边框 + 柔和环境光晕）。
/// 2. 交互逻辑：左缘热区自动滑出，Esc / 选台收起防回弹，↑/↓ 键盘焦点平滑滚动。
/// 3. 精致频道行项：三位等宽台号微胶囊、正在播出动态红点、活跃态品牌色流光指示。
/// 4. 完美避开顶底播放器控制条带（顶 54px，底 96px 留白）。
class LiveChannelLayer extends StatefulWidget {
  final List<Live> channels;
  final int currentIndex;
  final ValueChanged<int> onSelect;
  final VoidCallback onManage;
  final Widget child;

  /// 已收藏频道的键集合（§34）：抽屉顶部置顶「收藏频道」小节。
  final Set<String> favoriteKeys;

  /// §35：画中画小窗里整层不生效（无热区、无抽屉），还原后恢复。
  final bool enabled;

  const LiveChannelLayer({
    super.key,
    required this.channels,
    required this.currentIndex,
    required this.onSelect,
    required this.onManage,
    required this.child,
    this.favoriteKeys = const {},
    this.enabled = true,
  });

  @override
  State<LiveChannelLayer> createState() => _LiveChannelLayerState();
}

class _LiveChannelLayerState extends State<LiveChannelLayer> {
  static const double _drawerWidth = 290;
  static const double _hotzoneMax = 220;
  static const double _hotzoneRatio = 0.16;

  bool _open = false;

  /// 选台 / Esc 显式收起后置位：指针仍在热区内时不自动重开，
  /// 待指针移出热区一次后清零。
  bool _suppressReopen = false;
  double _layoutWidth = 0;

  double get _hotzoneWidth => _layoutWidth == 0
      ? _hotzoneMax
      : math.min(_layoutWidth * _hotzoneRatio, _hotzoneMax);

  @override
  void didUpdateWidget(covariant LiveChannelLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.channels.isEmpty && _open) {
      _open = false;
    }
    // §35：进画中画时立刻收起，避免抽屉留在小窗里。
    if (!widget.enabled && _open) {
      _open = false;
    }
  }

  void _onHover(PointerHoverEvent event) {
    if (widget.channels.isEmpty) return;
    final dx = event.localPosition.dx;
    final inZone = dx <= (_open ? _drawerWidth : _hotzoneWidth);
    if (_open) {
      if (!inZone) _close();
      return;
    }
    if (!inZone) {
      _suppressReopen = false;
      return;
    }
    if (_suppressReopen) return;
    setState(() => _open = true);
  }

  void _close() {
    if (_open) setState(() => _open = false);
  }

  void _handleSelect(int index) {
    widget.onSelect(index);
    _suppressReopen = true;
    _close();
  }

  void _dismiss() {
    _suppressReopen = true;
    _close();
  }

  @override
  Widget build(BuildContext context) {
    // §35 方案 A：画中画下整层直通（不留热区，不会误弹）。
    if (!widget.enabled || widget.channels.isEmpty) return widget.child;
    return LayoutBuilder(
      builder: (context, constraints) {
        _layoutWidth = constraints.maxWidth;
        return MouseRegion(
          onHover: _onHover,
          onExit: (_) => _close(),
          child: Stack(
            fit: StackFit.expand,
            children: [
              widget.child,
              AnimatedPositioned(
                duration: _open ? AppMotion.enter : AppMotion.exit,
                curve: AppMotion.ease,
                left: _open ? 0 : -_drawerWidth,
                top: 0,
                bottom: 0,
                width: _drawerWidth,
                child: IgnorePointer(
                  ignoring: !_open,
                  child: _LiveChannelDrawer(
                    channels: widget.channels,
                    currentIndex: widget.currentIndex,
                    favoriteKeys: widget.favoriteKeys,
                    open: _open,
                    onSelect: _handleSelect,
                    onManage: widget.onManage,
                    onRequestClose: _dismiss,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _DrawerEntry {
  final String? group;
  final int? channelIndex;
  final Live? channel;

  /// 非 null 时是提示行（例如「收藏频道」为空时的引导文案，§34）。
  final String? hint;

  /// true = 置顶「收藏频道」小节里的快捷入口行（§34-R）。
  /// 它不参与悬停/播放高亮，避免与下方主列表同一频道双亮。
  final bool quickEntry;

  const _DrawerEntry.header(this.group)
      : channelIndex = null,
        channel = null,
        hint = null,
        quickEntry = false;

  const _DrawerEntry.channel(this.channelIndex, this.channel,
      {this.quickEntry = false})
      : group = null,
        hint = null;

  /// 同一频道可能在置顶小节与主列表各出现一次（§34），
  /// 用「行身份」而不是「频道下标」区分选中态。
  String get rowId => quickEntry ? 'q:$channelIndex' : 'm:$channelIndex';

  const _DrawerEntry.hint(this.hint)
      : group = null,
        channelIndex = null,
        channel = null,
        quickEntry = false;

  bool get isHeader => group != null;
  bool get isHint => hint != null;
  bool get isChannel => channelIndex != null;
}

class _LiveChannelDrawer extends StatefulWidget {
  final List<Live> channels;
  final int currentIndex;
  final Set<String> favoriteKeys;
  final bool open;
  final ValueChanged<int> onSelect;
  final VoidCallback onManage;
  final VoidCallback onRequestClose;

  const _LiveChannelDrawer({
    required this.channels,
    required this.currentIndex,
    required this.favoriteKeys,
    required this.open,
    required this.onSelect,
    required this.onManage,
    required this.onRequestClose,
  });

  @override
  State<_LiveChannelDrawer> createState() => _LiveChannelDrawerState();
}

class _LiveChannelDrawerState extends State<_LiveChannelDrawer> {
  static const double _headerHeight = 34;
  static const double _itemHeight = 44;

  static const double _topBarInset = 54;
  static const double _bottomBarInset = 96;

  final FocusNode _focusNode = FocusNode(debugLabel: 'live-channel-drawer');
  final ScrollController _scrollController = ScrollController();
  int _cursor = 0;

  /// 当前光标的**行身份**（非 null 时优先于 [_cursor]）。
  ///
  /// §34-R：置顶「收藏频道」小节与下方主列表可能指向同一频道，但它们是两行。
  /// 用行身份记录光标，两行各自的悬停/选中互不牵连；播放高亮（正在播出）仍只认主列表。
  String? _cursorRowId;

  /// 分组行 / 「频道下标 → 行下标」/「行下标 → 顶部偏移」缓存。
  ///
  /// 频道上千时 `_buildEntries()` 每次 build 都要全量遍历，而鼠标在列表上悬停
  /// 会不断 setState（`_cursor` 变化）——相当于每移动一次鼠标 O(n) 扫两遍，
  /// 表现为「数据多时下滑特别卡」。改为按通道列表身份缓存，滚动与悬停都走 O(1)。
  List<_DrawerEntry> _entries = const [];
  List<int> _channelEntryIndex = const [];
  List<double> _entryTops = const [];

  @override
  void initState() {
    super.initState();
    _cursor = widget.currentIndex;
    _rebuildEntryCache();
  }

  /// 置顶「收藏频道」小节标题（§34）。与弹窗里的分类同名同口径。
  static const String favoriteSectionTitle = '收藏频道';

  @override
  void didUpdateWidget(covariant _LiveChannelDrawer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.channels, widget.channels) ||
        !setEquals(oldWidget.favoriteKeys, widget.favoriteKeys)) {
      _rebuildEntryCache();
      if (_cursor >= widget.channels.length) {
        _cursor = widget.channels.isEmpty ? 0 : widget.channels.length - 1;
      }
    }
    if (widget.open && !oldWidget.open) {
      _cursor = widget.currentIndex;
      _cursorRowId = null;
      _afterFrame(() {
        _focusNode.requestFocus();
        _scrollToCursor();
      });
    } else if (!widget.open && oldWidget.open) {
      _focusNode.unfocus();
    } else if (widget.open && widget.currentIndex != oldWidget.currentIndex) {
      _cursor = widget.currentIndex;
      _cursorRowId = null;
      _afterFrame(_scrollToCursor);
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
    _scrollController.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown) {
      _moveCursor(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _moveCursor(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      widget.onSelect(_cursor);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      widget.onRequestClose();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// 键盘移动光标：在**行序列**上移动（收藏小节的行也参与），
  /// 因此键盘可以选中置顶小节里的快捷入口。
  void _moveCursor(int delta) {
    if (_entries.isEmpty) return;
    final currentRow = _cursorRowId;
    var index = currentRow == null
        ? -1
        : _entries.indexWhere((e) => e.rowId == currentRow);
    if (index < 0) index = _entries.indexWhere((e) => e.rowId == 'm:$_cursor');
    if (index < 0) index = 0;

    var next = index + delta;
    // 跳过标题行与提示行，只停在可选的频道行上。
    while (next >= 0 && next < _entries.length && !_entries[next].isChannel) {
      next += delta;
    }
    if (next < 0 || next >= _entries.length) return;

    final entry = _entries[next];
    setState(() {
      _cursorRowId = entry.rowId;
      _cursor = entry.channelIndex!;
    });
    _scrollToRow(next);
  }

  void _rebuildEntryCache() {
    final entries = <_DrawerEntry>[];
    final channelEntryIndex = List<int>.filled(widget.channels.length, 0);
    final assigned = List<bool>.filled(widget.channels.length, false);
    final tops = <double>[];
    var offset = 0.0;

    // 置顶「收藏频道」小节（§34）：一直显示，空时给引导。
    tops.add(offset);
    entries.add(const _DrawerEntry.header(favoriteSectionTitle));
    offset += _headerHeight;
    var favoriteCount = 0;
    for (var i = 0; i < widget.channels.length; i++) {
      final channel = widget.channels[i];
      if (!widget.favoriteKeys.contains(channel.key)) continue;
      tops.add(offset);
      channelEntryIndex[i] = entries.length;
      assigned[i] = true;
      entries.add(_DrawerEntry.channel(i, channel, quickEntry: true));
      offset += _itemHeight;
      favoriteCount++;
    }
    if (favoriteCount == 0) {
      tops.add(offset);
      entries.add(const _DrawerEntry.hint('还没有收藏频道，点「管理频道」加星标'));
      offset += _itemHeight;
    }

    String? lastGroup;
    for (var i = 0; i < widget.channels.length; i++) {
      final channel = widget.channels[i];
      final group = channel.groupName;
      if (group != lastGroup) {
        tops.add(offset);
        entries.add(_DrawerEntry.header(group));
        offset += _headerHeight;
        lastGroup = group;
      }
      tops.add(offset);
      // 收藏过的频道在置顶小节里已经出现过，滚动定位仍指第一次出现的位置。
      if (!assigned[i]) channelEntryIndex[i] = entries.length;
      entries.add(_DrawerEntry.channel(i, channel));
      offset += _itemHeight;
    }
    _entries = entries;
    _channelEntryIndex = channelEntryIndex;
    _entryTops = tops;
  }

  /// 光标所在行的滚动定位：有行身份时按该行，否则退回「该频道第一次出现」的行。
  void _scrollToCursor() {
    if (!_scrollController.hasClients) return;
    var rowIndex = -1;
    final rowId = _cursorRowId;
    if (rowId != null) {
      rowIndex = _entries.indexWhere((e) => e.rowId == rowId);
    }
    if (rowIndex < 0) {
      if (_cursor < 0 || _cursor >= _channelEntryIndex.length) return;
      rowIndex = _channelEntryIndex[_cursor];
    }
    if (rowIndex < 0 || rowIndex >= _entryTops.length) return;
    _scrollToRow(rowIndex);
  }

  /// 按**行下标**滚动到目标行（键盘在行序列上移动时用）。
  void _scrollToRow(int rowIndex) {
    if (!_scrollController.hasClients) return;
    if (rowIndex < 0 || rowIndex >= _entryTops.length) return;
    final offset = _entryTops[rowIndex];
    final position = _scrollController.position;
    final target = (offset - position.viewportDimension / 2 + _itemHeight)
        .clamp(0.0, position.maxScrollExtent)
        .toDouble();
    _scrollController.animateTo(
      target,
      duration: AppMotion.enter,
      curve: AppMotion.ease,
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final entries = _entries;

    return Focus(
      focusNode: _focusNode,
      onKeyEvent: _onKey,
      child: ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xE0101014),
              border: Border(
                right: BorderSide(
                  color: Colors.white.withValues(alpha: 0.12),
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
                // 顶部控制条带留白（避开播放器顶栏返回与标题）
                const SizedBox(height: _topBarInset),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 12, 10),
                  child: Row(
                    children: [
                      // 微型图标胶囊底座
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
                              '共 ${widget.channels.length} 个电台',
                              style: TextStyle(
                                color: palette.playerText.withValues(alpha: 0.55),
                                fontSize: AppType.caption,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
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
                  ),
                ),
                Divider(
                  height: 1,
                  thickness: 1,
                  color: Colors.white.withValues(alpha: 0.08),
                ),
                Expanded(
                  child: ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.only(
                      top: 8,
                      bottom: 8 + _bottomBarInset,
                    ),
                    itemCount: entries.length,
                    // 行高只有两档（分组头 34 / 频道行 44）。不给固定 extent 时，
                    // 拖动滚动条跳到列表深处会让 SliverList 逐个 child 布局去估算
                    // 偏移，频道上千就是一次长卡顿；给出 extent 后跳转是 O(1)。
                    itemExtentBuilder: (index, _) => entries[index].isHeader
                        ? _headerHeight
                        : _itemHeight,
                    itemBuilder: (context, index) =>
                        _buildEntry(palette, entries[index]),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEntry(AppPalette palette, _DrawerEntry entry) {
    if (entry.isHint) {
      return Container(
        height: _itemHeight,
        padding: const EdgeInsets.fromLTRB(18, 6, 14, 6),
        alignment: Alignment.centerLeft,
        child: Text(
          entry.hint!,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: palette.playerText.withValues(alpha: 0.45),
            fontSize: AppType.caption,
          ),
        ),
      );
    }
    if (entry.isHeader) {
      return Container(
        height: _headerHeight,
        padding: const EdgeInsets.fromLTRB(16, 12, 14, 4),
        child: Row(
          children: [
            Container(
              width: 3,
              height: 10,
              decoration: BoxDecoration(
                color: palette.accentInk.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(AppRadii.hairline),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                entry.group!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: palette.playerText.withValues(alpha: 0.65),
                  fontSize: AppType.caption,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.2,
                ),
              ),
            ),
          ],
        ),
      );
    }
    final i = entry.channelIndex!;
    final channel = entry.channel!;
    // §34-R：置顶「收藏频道」小节只是快捷入口，不参与**播放高亮** ——
    // 否则同一频道会在置顶小节和下方主列表两处同时挂「正在播出」红点。
    // §34-R2：但它自己可以被光标选中（悬停态只在这一行显示），两行互不联动。
    final isQuickEntry = entry.quickEntry;
    final isCurrent = !isQuickEntry && i == widget.currentIndex;
    final isCursor = _cursorRowId != null
        ? entry.rowId == _cursorRowId
        : (!isQuickEntry && i == _cursor);

    // 台号格式化：三位对齐
    final channelNumber = (i + 1).toString().padLeft(3, '0');

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: FocusRing(
        onTap: () => widget.onSelect(i),
        borderRadius: BorderRadius.circular(AppRadii.sm),
        semanticLabel: channel.name,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) {
            if (entry.rowId == _cursorRowId) return;
            setState(() {
              _cursorRowId = entry.rowId;
              _cursor = i;
            });
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => widget.onSelect(i),
            child: AnimatedContainer(
              duration: isCursor || isCurrent ? AppMotion.enter : AppMotion.exit,
              height: _itemHeight - 4,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: isCurrent
                    ? palette.accentInk.withValues(alpha: 0.22)
                    : (isCursor
                        ? Colors.white.withValues(alpha: 0.08)
                        : Colors.transparent),
                borderRadius: BorderRadius.circular(AppRadii.sm),
                border: Border.all(
                  color: isCurrent
                      ? palette.accentInk.withValues(alpha: 0.45)
                      : (isCursor
                          ? Colors.white.withValues(alpha: 0.12)
                          : Colors.transparent),
                  width: 1,
                ),
              ),
              child: Row(
                children: [
                  // 三位台号微胶囊
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: isCurrent
                          ? palette.accentInk.withValues(alpha: 0.25)
                          : Colors.white.withValues(alpha: 0.06),
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
                        fontFeatures: const [
                          FontFeature.tabularFigures(),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // 频道名称
                  Expanded(
                    child: Text(
                      channel.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: isCurrent
                            ? Colors.white
                            : palette.playerText.withValues(alpha: 0.85),
                        fontSize: AppType.body,
                        fontWeight: isCurrent ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                  ),
                  // 当前播放热标
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
