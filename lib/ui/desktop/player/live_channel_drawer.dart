import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/config/models/vod_config.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';
import '../widgets/focus_ring.dart';

/// ⑤-3 直播频道抽屉层：包在播放器外层，处理「左缘热区 + 抽屉 + 键盘导航」。
///
/// - 热区：鼠标进入窗口左缘 `min(220px, 宽 16%)` 区域即拉出抽屉；指针离开
///   热区与抽屉后收起。用**祖先 MouseRegion** 跟踪悬停（不叠透明挡板），
///   不拦截任何点击——热区不能吃掉播放器左区的播放 / 双击全屏手势。
/// - 抽屉：半透明频道面板，按分组呈现；当前频道高亮 + 左侧 accent 条
///   （skill `Active State`）、打开与切台后自动滚动到当前项
///   （skill `Smooth Scroll`）、顶部管理入口。
/// - 键盘：抽屉打开即请求焦点——↑/↓ 移动高亮、Enter 切台、Esc 收起
///   （skill `Keyboard Navigation`，High）；←/→ 由播放器层路由为切台。
/// - 半透明只做单色 alpha，不用背景模糊（skill `blur-purpose`：模糊只用于
///   指示可关闭的背景，不做装饰）。
///
/// 仅直播播放时宿主传入非空 [channels]；点播恒为空、整层透明直通。
class LiveChannelLayer extends StatefulWidget {
  final List<Live> channels;
  final int currentIndex;
  final ValueChanged<int> onSelect;
  final VoidCallback onManage;
  final Widget child;

  const LiveChannelLayer({
    super.key,
    required this.channels,
    required this.currentIndex,
    required this.onSelect,
    required this.onManage,
    required this.child,
  });

  @override
  State<LiveChannelLayer> createState() => _LiveChannelLayerState();
}

class _LiveChannelLayerState extends State<LiveChannelLayer> {
  static const double _drawerWidth = 280;
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
  }

  void _onHover(PointerHoverEvent event) {
    if (widget.channels.isEmpty) return;
    final dx = event.localPosition.dx;
    // 收起边界 = 抽屉右缘（修复：此前误用热区宽 220，指针还在 280 宽的
    // 抽屉内就会被判「离开」而提前收起——祖先 MouseRegion 能收到子区域事件，
    // 原注释「抽屉上层、本层收不到」的假设不成立）；开启边界仍是热区宽。
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

  /// 选台（鼠标点击 / 键盘 Enter 共用）：收起抽屉；本次收起不因指针仍在
  /// 热区内而立刻重开——指针需先移出热区一次才允许再次自动拉出。
  void _handleSelect(int index) {
    widget.onSelect(index);
    _suppressReopen = true;
    _close();
  }

  /// Esc 等显式收起（指针可能仍停在内侧，同样避免「关掉又弹回」）。
  void _dismiss() {
    _suppressReopen = true;
    _close();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.channels.isEmpty) return widget.child;
    return LayoutBuilder(
      builder: (context, constraints) {
        _layoutWidth = constraints.maxWidth;
        return MouseRegion(
          onHover: _onHover,
          onExit: (_) => _close(),
          // 层须覆盖整块播放区域：显式 expand，不依赖子树自带尺寸
          // （子项若是无固有尺寸的占位盒也能成立）。
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

  const _DrawerEntry.header(this.group)
      : channelIndex = null,
        channel = null;

  const _DrawerEntry.channel(this.channelIndex, this.channel) : group = null;

  bool get isHeader => group != null;
}

class _LiveChannelDrawer extends StatefulWidget {
  final List<Live> channels;
  final int currentIndex;
  final bool open;
  final ValueChanged<int> onSelect;
  final VoidCallback onManage;
  final VoidCallback onRequestClose;

  const _LiveChannelDrawer({
    required this.channels,
    required this.currentIndex,
    required this.open,
    required this.onSelect,
    required this.onManage,
    required this.onRequestClose,
  });

  @override
  State<_LiveChannelDrawer> createState() => _LiveChannelDrawerState();
}

class _LiveChannelDrawerState extends State<_LiveChannelDrawer> {
  static const double _headerHeight = 30;
  static const double _itemHeight = 42;

  /// 控制条带高度（顶栏 54；底栏 8+20+2+44+8 ≈ 96）：抽屉头部与列表避开，
  /// 返回按钮 / 播放按钮 / 时间轴不被遮挡（skill `Sticky Navigation` 补白）。
  static const double _topBarInset = 54;
  static const double _bottomBarInset = 96;

  final FocusNode _focusNode = FocusNode(debugLabel: 'live-channel-drawer');
  final ScrollController _scrollController = ScrollController();
  int _cursor = 0;

  @override
  void initState() {
    super.initState();
    _cursor = widget.currentIndex;
  }

  @override
  void didUpdateWidget(covariant _LiveChannelDrawer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.open && !oldWidget.open) {
      _cursor = widget.currentIndex;
      _afterFrame(() {
        _focusNode.requestFocus();
        _scrollToCursor();
      });
    } else if (!widget.open && oldWidget.open) {
      _focusNode.unfocus();
    } else if (widget.open && widget.currentIndex != oldWidget.currentIndex) {
      // 切台（←/→ 或选台）后高亮跟随新当前项并滚动居中。
      _cursor = widget.currentIndex;
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

  void _moveCursor(int delta) {
    if (widget.channels.isEmpty) return;
    final next = (_cursor + delta).clamp(0, widget.channels.length - 1);
    if (next == _cursor) return;
    setState(() => _cursor = next);
    _scrollToCursor();
  }

  List<_DrawerEntry> _buildEntries() {
    final entries = <_DrawerEntry>[];
    String? lastGroup;
    for (var i = 0; i < widget.channels.length; i++) {
      final channel = widget.channels[i];
      final group = channel.groupName;
      if (group != lastGroup) {
        entries.add(_DrawerEntry.header(group));
        lastGroup = group;
      }
      entries.add(_DrawerEntry.channel(i, channel));
    }
    return entries;
  }

  /// 用固定行高累计目标偏移（不依赖 itemBuilder 的运行时上下文），
  /// 平滑滚动让高亮项尽量落在视口中部（skill `Smooth Scroll`）。
  void _scrollToCursor() {
    if (!_scrollController.hasClients) return;
    var offset = 0.0;
    for (final entry in _buildEntries()) {
      if (entry.channelIndex == _cursor) break;
      offset += entry.isHeader ? _headerHeight : _itemHeight;
    }
    final position = _scrollController.position;
    final target = (offset - position.viewportDimension / 2 + _itemHeight)
        .clamp(0.0, position.maxScrollExtent)
        .toDouble();
    _scrollController.animateTo(target,
        duration: AppMotion.enter, curve: AppMotion.ease);
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final entries = _buildEntries();
    return Focus(
      focusNode: _focusNode,
      onKeyEvent: _onKey,
      child: Container(
        decoration: BoxDecoration(
          color: palette.playerChrome.withValues(alpha: 0.92),
          border: Border(
              right: BorderSide(
                  color: palette.playerText.withValues(alpha: 0.12))),
          boxShadow: const [
            BoxShadow(
              // 面板投影固定黑色，与主题无关（同 OSD 浮层惯例）
              color: Color(0x66000000),
              blurRadius: 16,
              offset: Offset(4, 0),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 顶部控制条带留白：顶栏（返回按钮 / 标题）浮在抽屉之上，
            // 抽屉头部下沉到其下方，避免叠字与遮挡。
            const SizedBox(height: _topBarInset),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 6, 8),
              child: Row(
                children: [
                  Icon(Icons.live_tv_rounded,
                      size: 16, color: palette.accentInk),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      '直播频道',
                      style: TextStyle(
                        color: palette.playerText,
                        fontSize: AppType.title,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  FocusOutline(
                    radius: AppRadii.pill,
                    child: IconButton(
                      icon: Icon(Icons.tune_rounded,
                          size: 18,
                          color: palette.playerText.withValues(alpha: 0.85)),
                      tooltip: '管理直播频道',
                      onPressed: widget.onManage,
                    ),
                  ),
                ],
              ),
            ),
            Divider(
                height: 1, color: palette.playerText.withValues(alpha: 0.08)),
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                padding:
                    const EdgeInsets.only(top: 6, bottom: 6 + _bottomBarInset),
                itemCount: entries.length,
                itemBuilder: (context, index) =>
                    _buildEntry(palette, entries[index]),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEntry(AppPalette palette, _DrawerEntry entry) {
    if (entry.isHeader) {
      return Container(
        height: _headerHeight,
        padding: const EdgeInsets.fromLTRB(15, 10, 14, 4),
        child: Text(
          entry.group!,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: palette.playerText.withValues(alpha: 0.55),
            fontSize: AppType.caption,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }
    final i = entry.channelIndex!;
    final channel = entry.channel!;
    final isCurrent = i == widget.currentIndex;
    final isCursor = i == _cursor;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: FocusRing(
        onTap: () => widget.onSelect(i),
        borderRadius: BorderRadius.circular(AppRadii.xs),
        semanticLabel: channel.name,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          // 鼠标悬停与键盘光标共用同一高亮（skill `Hover States`：
          // 可点元素必须有 hover 视觉反馈）。
          onEnter: (_) {
            if (i != _cursor) setState(() => _cursor = i);
          },
          child: GestureDetector(
            // 整行可点：行容器可能无底色，必须 opaque 才保空白区也命中
            // （此前只有 FocusRing 的键盘激活，鼠标点击无效）。
            behavior: HitTestBehavior.opaque,
            onTap: () => widget.onSelect(i),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppRadii.xs),
              child: Container(
                height: _itemHeight - 2,
                color: isCurrent
                    ? palette.accentInk.withValues(alpha: 0.18)
                    : (isCursor
                        ? palette.playerText.withValues(alpha: 0.08)
                        : null),
                child: Row(
                  children: [
                    if (isCurrent)
                      Container(width: 3, color: palette.accentInk),
                    const SizedBox(width: 7),
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
                      // 当前频道热标（与 B6 直播弹窗同一视觉语言）
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                            color: palette.danger, shape: BoxShape.circle),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '正在播出',
                        style: TextStyle(
                          color: palette.playerText.withValues(alpha: 0.7),
                          fontSize: AppType.caption,
                        ),
                      ),
                    ],
                    const SizedBox(width: 12),
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
