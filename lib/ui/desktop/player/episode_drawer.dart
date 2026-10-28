import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';
import '../widgets/focus_ring.dart';
import '../widgets/horizontal_scroll_area.dart';

/// 播放页「选集」抽屉里的一集（宿主装配，组件保持哑视图）。
class PlayerEpisodeOption {
  final int index;
  final String name;
  final bool current;

  const PlayerEpisodeOption({
    required this.index,
    required this.name,
    this.current = false,
  });
}

/// 抽屉顶部的一条线路（`index` 是 `PlaybackSession.sources` 的下标）。
class PlayerLineChoice {
  final int index;
  final String name;
  final bool current;

  /// 本次会话里**确认失败**的线路（灰显不可点）；只是「用过」不算。
  final bool unavailable;

  const PlayerLineChoice({
    required this.index,
    required this.name,
    this.current = false,
    this.unavailable = false,
  });
}

/// 播放页选集抽屉视图模型（backlog §20）。
///
/// 只描述「现在能选什么」与「选中后通知谁」；切集 / 换线的管线仍在宿主。
class PlayerEpisodeListNav {
  final List<PlayerEpisodeOption> episodes;
  final List<PlayerLineChoice> lines;

  /// 当前线路名（副标题用）；为空时不显示。
  final String? lineName;

  /// 切集 / 换线进行中：整块禁用，防重复触发。
  final bool switching;

  /// 选集回调：参数是当前线路里的集下标。
  final ValueChanged<int> onSelectEpisode;

  /// 换线路回调：参数是 `PlaybackSession.sources` 的下标。
  final ValueChanged<int> onSelectLine;

  const PlayerEpisodeListNav({
    required this.episodes,
    required this.lines,
    required this.onSelectEpisode,
    required this.onSelectLine,
    this.lineName,
    this.switching = false,
  });
}

/// 播放页右侧「选集 + 线路」抽屉（§20）。
///
/// - 由工具栏按钮控制 [open]，不从屏幕边缘热区触发（与直播频道抽屉区分）；
/// - 抽屉是模态侧面板：点遮罩 / Esc / 再点按钮都会收起；
/// - 选中某一集后**自动收起**（用户 2026-10-22 口径）；
/// - 换线路不收起抽屉，列表随会话更新（宿主的换线语义与 ⚙ 面板一致）。
class EpisodeDrawerLayer extends StatefulWidget {
  final bool open;
  final PlayerEpisodeListNav? nav;
  final VoidCallback onClose;
  final Widget child;

  const EpisodeDrawerLayer({
    super.key,
    required this.open,
    required this.nav,
    required this.onClose,
    required this.child,
  });

  @override
  State<EpisodeDrawerLayer> createState() => _EpisodeDrawerLayerState();
}

class _EpisodeDrawerLayerState extends State<EpisodeDrawerLayer> {
  static const double _panelMaxWidth = 320;
  static const double _topInset = 54;
  static const double _bottomInset = 96;
  static const double _itemExtent = 46;

  final ScrollController _scrollController = ScrollController();

  /// 线路胶囊条的横向滚动控制器。
  ///
  /// 桌面鼠标默认拖不动 `ListView`，滚轮又只有 `dy` —— 两者都要靠
  /// [HorizontalScrollArea] 补，控制器必须与它共用同一个实例。
  final ScrollController _lineScrollController = ScrollController();

  final FocusNode _focusNode = FocusNode(debugLabel: 'episode-drawer');

  /// 键盘游标（与「当前集」分开：↑↓ 只是移动焦点，Enter 才切集）。
  int _cursor = 0;

  /// 面板是否在树里：完全关闭后卸载，避免隐藏内容进入语义树 / 测试查找。
  bool _panelMounted = false;

  int get _currentIndex {
    final episodes = widget.nav?.episodes ?? const <PlayerEpisodeOption>[];
    final index = episodes.indexWhere((episode) => episode.current);
    return index < 0 ? 0 : index;
  }

  @override
  void initState() {
    super.initState();
    _cursor = _currentIndex;
    _panelMounted = widget.open;
    if (widget.open) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !widget.open) return;
        _scrollToCursor(animate: false);
        _focusNode.requestFocus();
      });
    }
  }

  @override
  void didUpdateWidget(covariant EpisodeDrawerLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.open && !oldWidget.open) {
      _panelMounted = true;
      _cursor = _currentIndex;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !widget.open) return;
        _scrollToCursor(animate: false);
        _focusNode.requestFocus();
      });
    } else if (!widget.open && oldWidget.open) {
      _focusNode.unfocus();
    }
    if (widget.open) {
      final length = widget.nav?.episodes.length ?? 0;
      if (length == 0) {
        // 会话被关闭：没有可选项时直接收起，避免空抽屉挂在屏幕上。
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted &&
              widget.open &&
              (widget.nav?.episodes.isEmpty ?? true)) {
            widget.onClose();
          }
        });
      } else if (_cursor >= length) {
        _cursor = length - 1;
      }
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _lineScrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _scrollToCursor({bool animate = true}) {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    final target =
        (_cursor * _itemExtent - position.viewportDimension / 2 + _itemExtent)
            .clamp(0.0, position.maxScrollExtent)
            .toDouble();
    if (animate) {
      _scrollController.animateTo(target,
          duration: AppMotion.enter, curve: AppMotion.ease);
    } else {
      _scrollController.jumpTo(target);
    }
  }

  void _moveCursor(int delta) {
    final length = widget.nav?.episodes.length ?? 0;
    if (length == 0) return;
    final next = (_cursor + delta).clamp(0, length - 1);
    if (next == _cursor) return;
    setState(() => _cursor = next);
    _scrollToCursor();
  }

  void _select(int index) {
    final nav = widget.nav;
    if (nav == null || nav.switching) return;
    if (index < 0 || index >= nav.episodes.length) return;
    nav.onSelectEpisode(index);
    widget.onClose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      widget.onClose();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _moveCursor(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _moveCursor(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.home) {
      setState(() => _cursor = 0);
      _scrollToCursor();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.end) {
      final length = widget.nav?.episodes.length ?? 0;
      if (length > 0) {
        setState(() => _cursor = length - 1);
        _scrollToCursor();
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      _select(_cursor);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final nav = widget.nav;
    if (nav == null || (!_panelMounted && !widget.open)) {
      return widget.child;
    }

    return LayoutBuilder(builder: (context, constraints) {
      final width = math.min(_panelMaxWidth, constraints.maxWidth * 0.8);
      return Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          // 遮罩：盖住视频与控制条，点空白处收起（模态侧面板）。
          AnimatedOpacity(
            duration: widget.open ? AppMotion.enter : AppMotion.exit,
            opacity: widget.open ? 1 : 0,
            child: IgnorePointer(
              ignoring: !widget.open,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: widget.onClose,
                child: const ColoredBox(color: Color(0x66000000)),
              ),
            ),
          ),
          AnimatedPositioned(
            duration: widget.open ? AppMotion.enter : AppMotion.exit,
            curve: AppMotion.ease,
            top: _topInset,
            bottom: _bottomInset,
            right: widget.open ? 0 : -width,
            width: width,
            onEnd: () {
              if (!widget.open && _panelMounted) {
                setState(() => _panelMounted = false);
              }
            },
            child: IgnorePointer(
              ignoring: !widget.open,
              child: Focus(
                focusNode: _focusNode,
                onKeyEvent: _onKey,
                child: _buildPanel(context, nav),
              ),
            ),
          ),
        ],
      );
    });
  }

  Widget _buildPanel(BuildContext context, PlayerEpisodeListNav nav) {
    final palette = context.palette;
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Container(
          key: const ValueKey('episode-drawer-panel'),
          // 跟随主题（与「播放设置」「弹幕设置」抽屉同一套 player 色）：
          // 浅色主题下原先写死的深底 + 白描边会显得突兀（2026-10-27 实机反馈）。
          decoration: BoxDecoration(
            color: palette.playerChrome,
            border: Border(
              left: BorderSide(
                color: palette.playerText.withValues(alpha: 0.12),
                width: 1,
              ),
            ),
            boxShadow: const [
              BoxShadow(
                color: Color(0x66000000),
                blurRadius: 24,
                offset: Offset(-8, 0),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildHeader(context, nav, palette),
              if (nav.lines.length > 1) ...[
                Divider(
                  height: 1,
                  thickness: 1,
                  color: palette.playerText.withValues(alpha: 0.08),
                ),
                _buildLinePills(context, nav, palette),
              ],
              Divider(
                height: 1,
                thickness: 1,
                color: palette.playerText.withValues(alpha: 0.08),
              ),
              Expanded(
                child: Opacity(
                  opacity: nav.switching ? 0.5 : 1,
                  child: IgnorePointer(
                    ignoring: nav.switching,
                    child: ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      itemExtent: _itemExtent,
                      itemCount: nav.episodes.length,
                      itemBuilder: (context, index) => _buildEpisodeRow(
                        context,
                        nav,
                        palette,
                        index,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(
      BuildContext context, PlayerEpisodeListNav nav, AppPalette palette) {
    final subtitle = nav.lineName == null || nav.lineName!.isEmpty
        ? '共 ${nav.episodes.length} 集'
        : '共 ${nav.episodes.length} 集 · ${nav.lineName}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 10, 10),
      child: Row(
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
                Icons.playlist_play_rounded,
                size: 17,
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
                  '选集',
                  style: TextStyle(
                    color: palette.playerText,
                    fontSize: AppType.title,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                  ),
                ),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: palette.playerText.withValues(alpha: 0.55),
                    fontSize: AppType.caption,
                  ),
                ),
              ],
            ),
          ),
          FocusRing(
            key: const ValueKey('episode-drawer-close'),
            onTap: widget.onClose,
            semanticLabel: '关闭选集',
            borderRadius:
                const BorderRadius.all(Radius.circular(AppRadii.pill)),
            child: IconButton(
              icon: Icon(Icons.close_rounded,
                  size: 18, color: palette.playerText.withValues(alpha: 0.7)),
              tooltip: '关闭（Esc）',
              onPressed: widget.onClose,
            ),
          ),
        ],
      ),
    );
  }

  /// 线路胶囊条：可横向滚动（线路多时不再只能看到前几条）。
  ///
  /// 桌面鼠标默认拖不动横向 `ListView`、滚轮又只给 `dy`，所以统一交给
  /// [HorizontalScrollArea]（与影片分类栏同一套口径）。
  Widget _buildLinePills(
      BuildContext context, PlayerEpisodeListNav nav, AppPalette palette) {
    final onAccent = Theme.of(context).colorScheme.onPrimary;
    return SizedBox(
      height: 46,
      child: HorizontalScrollArea(
        controller: _lineScrollController,
        child: ListView.separated(
          controller: _lineScrollController,
          // 胶囊自己是 `GestureDetector(onTap:)`，与拖拽共用一个手势竞技场：
          // 默认 `DragStartBehavior.start` 会把「接受拖拽」之前的位移整段丢掉
          // —— 按住胶囊拖完全不动（只有按住 8px 空白才滚）。改从按下点起算。
          dragStartBehavior: DragStartBehavior.down,
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          itemCount: nav.lines.length,
          separatorBuilder: (_, __) => const SizedBox(width: 8),
          itemBuilder: (context, index) {
            final line = nav.lines[index];
            final disabled = nav.switching || line.unavailable;
            final background = line.current
                ? palette.accent
                : palette.playerText.withValues(alpha: 0.08);
            final foreground = line.current
                ? onAccent
                : palette.playerText.withValues(alpha: 0.78);
            return FocusRing(
              key: ValueKey('episode-drawer-line-${line.index}'),
              onTap: disabled
                  ? null
                  : () {
                      if (!line.current) nav.onSelectLine(line.index);
                    },
              semanticLabel: line.unavailable ? '${line.name}（不可用）' : line.name,
              borderRadius:
                  const BorderRadius.all(Radius.circular(AppRadii.pill)),
              child: AnimatedOpacity(
                duration: AppMotion.exit,
                opacity: disabled && !line.current ? 0.4 : 1,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: disabled
                      ? null
                      : () {
                          if (!line.current) nav.onSelectLine(line.index);
                        },
                  child: Container(
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(
                      color: background,
                      borderRadius: BorderRadius.circular(AppRadii.pill),
                      border: Border.all(
                        color: line.current
                            ? palette.accentInk.withValues(alpha: 0.6)
                            : palette.playerText.withValues(alpha: 0.10),
                        width: 1,
                      ),
                    ),
                    child: Text(
                      line.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: foreground,
                        fontSize: AppType.caption,
                        fontWeight:
                            line.current ? FontWeight.bold : FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildEpisodeRow(BuildContext context, PlayerEpisodeListNav nav,
      AppPalette palette, int index) {
    final episode = nav.episodes[index];
    final isCurrent = episode.current;
    final isCursor = index == _cursor;
    final item = MergeSemantics(
      child: Semantics(
        selected: isCurrent,
        child: FocusRing(
          onTap: nav.switching ? null : () => _select(index),
          semanticLabel: episode.name,
          borderRadius: BorderRadius.circular(AppRadii.sm),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: nav.switching ? null : () => _select(index),
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              onEnter: (_) {
                if (isCursor) return;
                setState(() => _cursor = index);
              },
              child: AnimatedContainer(
                duration:
                    isCursor || isCurrent ? AppMotion.enter : AppMotion.exit,
                height: _itemExtent - 4,
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
                      padding: const EdgeInsets.symmetric(
                          horizontal: 5, vertical: 2),
                      decoration: BoxDecoration(
                        color: isCurrent
                            ? palette.accentInk.withValues(alpha: 0.25)
                            : palette.playerText.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(AppRadii.xs),
                      ),
                      child: Text(
                        (index + 1).toString().padLeft(2, '0'),
                        style: TextStyle(
                          color: isCurrent
                              ? palette.accentInk
                              : palette.playerText.withValues(alpha: 0.55),
                          fontSize: AppType.caption,
                          fontWeight: FontWeight.w700,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        episode.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: isCurrent
                              ? palette.playerText
                              : palette.playerText.withValues(alpha: 0.82),
                          fontSize: AppType.body,
                          fontWeight:
                              isCurrent ? FontWeight.w700 : FontWeight.w500,
                        ),
                      ),
                    ),
                    if (isCurrent)
                      Icon(
                        Icons.play_arrow_rounded,
                        size: 15,
                        color: palette.accentInk,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
      child: KeyedSubtree(
        key: ValueKey('episode-drawer-item-$index'),
        child: item,
      ),
    );
  }
}
