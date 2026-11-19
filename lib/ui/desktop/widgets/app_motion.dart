import 'package:animations/animations.dart';
import 'package:flutter/material.dart';

import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';

enum AppTransitionType { fadeThrough, horizontal, vertical }

/// Content identity is independent of ordinary data rebuilds. Only the active
/// entry can receive input or expose semantics while an old entry fades away.
class AppContentTransition extends StatefulWidget {
  const AppContentTransition({
    super.key,
    required this.identity,
    required this.child,
    this.type = AppTransitionType.fadeThrough,
    this.reverse = false,
    this.alignment = Alignment.center,
    this.duration = AppMotion.slow,
  });

  final Object identity;
  final Widget child;
  final AppTransitionType type;
  final bool reverse;
  final Alignment alignment;
  final Duration duration;

  @override
  State<AppContentTransition> createState() => _AppContentTransitionState();
}

class _AppContentTransitionState extends State<AppContentTransition> {
  late final ValueNotifier<Object> _active = ValueNotifier(Object());

  @override
  void didUpdateWidget(AppContentTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.identity != oldWidget.identity) _active.value = Object();
  }

  @override
  void dispose() {
    _active.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduced = AppMotion.reduced(context);
    return PageTransitionSwitcher(
      duration: AppMotion.durationOf(context, widget.duration),
      reverse: widget.reverse,
      layoutBuilder: (entries) =>
          Stack(alignment: widget.alignment, children: entries),
      transitionBuilder: (child, primary, secondary) {
        final entry = child as KeyedSubtree;
        final identity = (entry.key! as ValueKey<Object>).value;
        final transition = switch (widget.type) {
          AppTransitionType.fadeThrough => FadeThroughTransition(
            animation: reduced ? const AlwaysStoppedAnimation(1.0) : primary,
            secondaryAnimation: reduced
                ? const AlwaysStoppedAnimation(0.0)
                : secondary,
            fillColor: Colors.transparent,
            child: child,
          ),
          AppTransitionType.horizontal ||
          AppTransitionType.vertical => SharedAxisTransition(
            animation: reduced ? const AlwaysStoppedAnimation(1.0) : primary,
            secondaryAnimation: reduced
                ? const AlwaysStoppedAnimation(0.0)
                : secondary,
            transitionType: widget.type == AppTransitionType.horizontal
                ? SharedAxisTransitionType.horizontal
                : SharedAxisTransitionType.vertical,
            fillColor: Colors.transparent,
            child: child,
          ),
        };
        return ValueListenableBuilder<Object>(
          valueListenable: _active,
          child: transition,
          builder: (context, active, content) {
            final current = identity == active;
            return ExcludeSemantics(
              excluding: !current,
              child: ExcludeFocus(
                excluding: !current,
                child: IgnorePointer(
                  ignoring: !current,
                  child: Visibility(
                    visible: !reduced || current,
                    maintainState: true,
                    child: content!,
                  ),
                ),
              ),
            );
          },
        );
      },
      child: KeyedSubtree(
        key: ValueKey<Object>(_active.value),
        child: widget.child,
      ),
    );
  }
}

/// A single bounded entrance. No delayed item timers or repeating tickers.
class AppEntrance extends StatefulWidget {
  const AppEntrance({
    super.key,
    required this.child,
    this.duration = AppMotion.enter,
  });

  final Widget child;
  final Duration duration;

  @override
  State<AppEntrance> createState() => _AppEntranceState();
}

class _AppEntranceState extends State<AppEntrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this);
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller.duration = AppMotion.durationOf(context, widget.duration);
    if (AppMotion.reduced(context)) {
      _controller.value = 1;
      _started = true;
    } else if (!_started) {
      _started = true;
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      FadeScaleTransition(animation: _controller, child: widget.child);
}

/// Shared empty-state hierarchy, with a bounded width and scalable copy.
class AppEmptyState extends StatelessWidget {
  const AppEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: AppEntrance(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: palette.accentWash,
                    borderRadius: BorderRadius.circular(AppRadii.lg),
                    border: Border.all(color: palette.divider),
                  ),
                  child: Icon(icon, size: 28, color: palette.accentInk),
                ),
                const SizedBox(height: 20),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: palette.textTitle,
                    fontSize: AppType.heading,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (message != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    message!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: palette.textSub,
                      fontSize: AppType.label,
                      height: 1.6,
                    ),
                  ),
                ],
                if (action != null) ...[const SizedBox(height: 20), action!],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
