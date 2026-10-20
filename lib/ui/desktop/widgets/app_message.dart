/// 全局浮层消息（Element Plus `Message` 风格）。
///
/// 取代原先从**页面最底部**弹出的 `SnackBar`：消息在**窗口顶部居中**显示，
/// 可堆叠、自动消失、悬停暂停、按语义分色（success / warning / error / info）。
///
/// 关键约定：
/// - 层级：挂载在 `MaterialApp.builder` 的 Stack 顶层，盖过导航器（含对话框），
///   与 Element Plus 的消息层级一致；
/// - 外观：颜色只取自 [AppPalette]，几何只用 [AppRadii] / [AppSpacing] /
///   [AppType] / [AppMotion] 档位（静态测试会扫裸数值）；
/// - 行为（对齐 Element Plus 与 ui-ux skill 规则）：
///   - 默认 3 秒自动消失（skill `toast-dismiss`：3–5 秒），带按钮或错误 /
///     警告类 5 秒；
///   - 悬停暂停倒计时，移出后从剩余时间继续；
///   - 最多堆叠 [AppMessageHostState.maxVisible] 条，超出时最旧的先离场；
///   - 同文案（同类型）合并并重置倒计时——承接原 `hideCurrentSnackBar` 的
///     「替换上一条」语义；
///   - `liveRegion` 播报、不抢焦点（skill `toast-accessibility`）。
///
/// 用法：`showAppMessage('片头已更新', type: AppMessageType.success)`；
/// 宿主未挂载时静默丢弃（与 `ScaffoldMessenger.maybeOf` 行为一致）。
library;

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';
import 'desktop_title_bar.dart';
import 'focus_ring.dart';

/// 消息语义类型：决定图标与语义色。
enum AppMessageType { info, success, warning, error }

/// 消息内联动作按钮（如「从头播放」「重试」「查看」）。
@immutable
class AppMessageAction {
  /// 按钮文案
  final String label;

  /// 点按 / Enter / Space 触发的动作
  final VoidCallback onPressed;

  const AppMessageAction({required this.label, required this.onPressed});
}

/// 一条消息的内容定义。
@immutable
class AppMessageData {
  /// 消息正文（保持与原 SnackBar 文案一致）
  final String message;

  /// 语义类型（图标与颜色）
  final AppMessageType type;

  /// 自定义展示时长；省略时按 [effectiveDuration] 的规则推导
  final Duration? duration;

  /// 可选的内联按钮
  final AppMessageAction? action;

  const AppMessageData({
    required this.message,
    this.type = AppMessageType.info,
    this.duration,
    this.action,
  });

  /// 默认 3 秒；带按钮或错误 / 警告类 5 秒（skill：toast 停留 3–5 秒）。
  Duration get effectiveDuration =>
      duration ??
      ((action != null ||
              type == AppMessageType.error ||
              type == AppMessageType.warning)
          ? _longDuration
          : _shortDuration);

  static const Duration _shortDuration = Duration(seconds: 3);
  static const Duration _longDuration = Duration(seconds: 5);
}

/// 全局消息宿主的引用（与 `rootScaffoldMessengerKey` 同款用法）。
final appMessageKey = GlobalKey<AppMessageHostState>();

/// 顶层便捷入口：向 [AppMessageHost] 推一条消息。
void showAppMessage(
  String message, {
  AppMessageType type = AppMessageType.info,
  Duration? duration,
  AppMessageAction? action,
}) {
  appMessageKey.currentState?.show(AppMessageData(
    message: message,
    type: type,
    duration: duration,
    action: action,
  ));
}

/// 消息卡片宿主：挂到 `MaterialApp.builder` 的 Stack 顶层。
///
/// **挂载时必须携带 [appMessageKey]**（`AppMessageHost(key: appMessageKey)`），
/// 否则 [showAppMessage] 找不到宿主、消息会被静默丢弃。
class AppMessageHost extends StatefulWidget {
  const AppMessageHost({super.key});

  @override
  State<AppMessageHost> createState() => AppMessageHostState();
}

class AppMessageHostState extends State<AppMessageHost> {
  /// 同时最多显示的消息条数（超出时最旧的先离场）。
  static const int maxVisible = 4;

  final List<_MessageEntry> _entries = [];
  int _nextId = 0;

  /// 追加一条消息；同文案同类型合并到现有条目并重置倒计时。
  void show(AppMessageData data) {
    if (!mounted) return;
    setState(() {
      for (final entry in _entries) {
        if (entry.leaving) continue;
        if (entry.data.message == data.message &&
            entry.data.type == data.type) {
          entry.data = data;
          entry.revision++;
          return;
        }
      }
      _entries.add(_MessageEntry(id: _nextId++, data: data));
      final active = _entries.where((entry) => !entry.leaving).toList();
      if (active.length > maxVisible) {
        for (final entry in active.take(active.length - maxVisible)) {
          entry.leaving = true;
        }
      }
    });
  }

  /// 逐条播退出动画后清空。
  void dismissAll() {
    if (!mounted || _entries.isEmpty) return;
    setState(() {
      for (final entry in _entries) {
        entry.leaving = true;
      }
    });
  }

  void _remove(_MessageEntry entry) {
    if (!mounted) return;
    setState(() => _entries.remove(entry));
  }

  @override
  Widget build(BuildContext context) {
    if (_entries.isEmpty) return const SizedBox.shrink();
    final children = <Widget>[];
    for (final entry in _entries) {
      if (children.isNotEmpty) {
        children.add(const SizedBox(height: AppSpacing.sm));
      }
      children.add(_AppMessageCard(
        key: ValueKey('app-message-${entry.id}'),
        entry: entry,
        onGone: () => _remove(entry),
      ));
    }
    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        // 顶部让开标题栏（窗口控制区），消息从标题栏下方 8px 起排。
        padding:
            const EdgeInsets.only(top: kDesktopTitleBarHeight + AppSpacing.sm),
        child: Column(mainAxisSize: MainAxisSize.min, children: children),
      ),
    );
  }
}

/// 内部条目：可变的展示状态（卡组件按 revision / leaving 做增量响应）。
class _MessageEntry {
  _MessageEntry({required this.id, required this.data});

  final int id;
  AppMessageData data;

  /// 合并重置计数：变化时卡片重置倒计时
  int revision = 0;

  /// 已请求离场（播放退出动画后由宿主移除）
  bool leaving = false;
}

/// 单条消息卡片。
class _AppMessageCard extends StatefulWidget {
  const _AppMessageCard({super.key, required this.entry, required this.onGone});

  final _MessageEntry entry;
  final VoidCallback onGone;

  @override
  State<_AppMessageCard> createState() => _AppMessageCardState();
}

class _AppMessageCardState extends State<_AppMessageCard>
    with TickerProviderStateMixin {
  /// 展示状态：0 隐藏（未进入 / 已退出），1 完全展示
  late final AnimationController _presence = AnimationController(
    vsync: this,
    duration: AppMotion.enter,
    reverseDuration: AppMotion.exit,
  );

  /// 自动消失计时器（暂停 / 离场期间为空）。倒计时用 [Timer] 而不是动画控制器：
  /// 一条静态消息不该为 3–5 秒的展示持续请求 60fps 帧。
  Timer? _timer;

  /// 剩余展示时长；悬停暂停时按已消耗时间扣减。
  Duration _remaining = Duration.zero;

  /// 本段计时开始时刻（用于悬停暂停时扣减已消耗时间）。
  DateTime? _armedAt;

  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(0, -0.4),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _presence, curve: AppMotion.ease));

  bool _hovered = false;
  bool _leaving = false;

  /// 已消费的合并计数：entry 是同一可变对象，不能靠旧 widget 引用判断变化。
  int _seenRevision = 0;

  @override
  void initState() {
    super.initState();
    _seenRevision = widget.entry.revision;
    _presence.forward();
    if (widget.entry.leaving) {
      _leave();
    } else {
      _startCountdown(widget.entry.data.effectiveDuration);
    }
  }

  /// 从 [remaining] 开始（或继续）自动消失倒计时。
  void _startCountdown(Duration remaining) {
    _timer?.cancel();
    _remaining = remaining;
    _armedAt = DateTime.now();
    _timer = Timer(remaining, _leave);
  }

  /// 悬停暂停：按已消耗时间扣减剩余时长。
  void _pauseCountdown() {
    final timer = _timer;
    if (timer == null) return;
    timer.cancel();
    _timer = null;
    final armedAt = _armedAt;
    if (armedAt != null) {
      _remaining -= DateTime.now().difference(armedAt);
      if (_remaining < Duration.zero) _remaining = Duration.zero;
    }
  }

  @override
  void didUpdateWidget(covariant _AppMessageCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.entry.revision != _seenRevision) {
      _seenRevision = widget.entry.revision;
      // 同文案合并：重置倒计时（悬停中保持暂停，移出后按新时长继续）。
      final next = widget.entry.data.effectiveDuration;
      if (_hovered) {
        _remaining = next;
        _armedAt = null;
      } else if (!_leaving) {
        _startCountdown(next);
      }
    }
    if (widget.entry.leaving && !_leaving) {
      _leave();
    }
  }

  void _handleEnter(PointerEnterEvent _) {
    _hovered = true;
    _pauseCountdown();
  }

  void _handleExit(PointerExitEvent _) {
    _hovered = false;
    if (_leaving) return;
    if (_remaining > Duration.zero) {
      _startCountdown(_remaining);
    } else {
      _leave();
    }
  }

  /// 播放退出动画后通知宿主移除（重复调用安全）。
  Future<void> _leave() async {
    if (_leaving) return;
    _leaving = true;
    _timer?.cancel();
    _timer = null;
    await _presence.reverse();
    if (mounted) widget.onGone();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _presence.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final data = widget.entry.data;
    final statusColor = switch (data.type) {
      AppMessageType.success => palette.success,
      AppMessageType.warning => palette.warning,
      AppMessageType.error => palette.danger,
      AppMessageType.info => palette.accentInk,
    };
    final statusIcon = switch (data.type) {
      AppMessageType.success => Icons.check_circle_rounded,
      AppMessageType.warning => Icons.warning_amber_rounded,
      AppMessageType.error => Icons.error_rounded,
      AppMessageType.info => Icons.info_outline_rounded,
    };

    return SlideTransition(
      position: _slide,
      child: FadeTransition(
        opacity: _presence,
        child: MouseRegion(
          onEnter: _handleEnter,
          onExit: _handleExit,
          child: Semantics(
            liveRegion: true,
            container: true,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 280, maxWidth: 520),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: palette.raised,
                  borderRadius: BorderRadius.circular(AppRadii.md),
                  border: Border.all(color: palette.borderStrong),
                  // 不投影：浅色主题下黑色投影会在卡片底部形成一条暗带，
                  // 观感像「下划线」（用户反馈）；浮起感由底色 + 描边表达。
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.lg,
                    vertical: AppSpacing.md,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(statusIcon, size: 16, color: statusColor),
                      const SizedBox(width: AppSpacing.sm),
                      Flexible(
                        child: Text(
                          data.message,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: AppType.label,
                            color: palette.textMain,
                          ),
                        ),
                      ),
                      if (data.action != null) ...[
                        const SizedBox(width: AppSpacing.md),
                        _MessageActionButton(
                          action: data.action!,
                          onTap: () {
                            data.action!.onPressed();
                            _leave();
                          },
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 消息内联动作按钮：悬停提亮 + 键盘可达（复用 B1 的 [FocusRing]）。
class _MessageActionButton extends StatefulWidget {
  const _MessageActionButton({required this.action, required this.onTap});

  final AppMessageAction action;
  final VoidCallback onTap;

  @override
  State<_MessageActionButton> createState() => _MessageActionButtonState();
}

class _MessageActionButtonState extends State<_MessageActionButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return FocusRing(
      key: const ValueKey('app-message-action'),
      onTap: widget.onTap,
      borderRadius: const BorderRadius.all(Radius.circular(AppRadii.sm)),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: AppMotion.base,
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.sm,
              vertical: AppSpacing.xs,
            ),
            decoration: BoxDecoration(
              color: _hovered ? palette.hover : null,
              borderRadius:
                  const BorderRadius.all(Radius.circular(AppRadii.sm)),
            ),
            child: Text(
              widget.action.label,
              style: TextStyle(
                fontSize: AppType.label,
                color: palette.accentInk,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
