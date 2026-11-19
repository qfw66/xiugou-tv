import 'package:animations/animations.dart';
import 'package:flutter/material.dart';

import '../../theme/app_tokens.dart';

/// Uses DialogRoute so barrier, focus traversal, PopScope and route observers
/// retain their normal behavior. Only the visual transition is replaced.
class AppDialogRoute<T> extends DialogRoute<T> {
  AppDialogRoute({
    required super.context,
    required super.builder,
    super.themes,
    super.barrierColor,
    super.barrierDismissible = true,
    super.barrierLabel,
    super.useSafeArea,
    super.settings,
    super.anchorPoint,
    super.traversalEdgeBehavior = TraversalEdgeBehavior.closedLoop,
    super.requestFocus,
  }) : _reduced = AppMotion.reduced(context);

  final bool _reduced;

  @override
  Duration get transitionDuration => _reduced ? Duration.zero : AppMotion.enter;

  @override
  Duration get reverseTransitionDuration =>
      _reduced ? Duration.zero : AppMotion.exit;

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return FadeScaleTransition(
      animation: _reduced || AppMotion.reduced(context)
          ? const AlwaysStoppedAnimation(1.0)
          : animation,
      child: child,
    );
  }
}

Future<T?> showAppDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  Color? barrierColor,
  String? barrierLabel,
  bool useSafeArea = true,
  bool useRootNavigator = true,
  RouteSettings? routeSettings,
  Offset? anchorPoint,
  TraversalEdgeBehavior traversalEdgeBehavior =
      TraversalEdgeBehavior.closedLoop,
  bool? requestFocus,
}) {
  final navigator = Navigator.of(context, rootNavigator: useRootNavigator);
  return navigator.push(
    AppDialogRoute<T>(
      context: context,
      builder: builder,
      themes: InheritedTheme.capture(from: context, to: navigator.context),
      barrierDismissible: barrierDismissible,
      barrierColor:
          barrierColor ??
          DialogTheme.of(context).barrierColor ??
          Theme.of(context).dialogTheme.barrierColor ??
          Colors.black54,
      barrierLabel: barrierLabel,
      useSafeArea: useSafeArea,
      settings: routeSettings,
      anchorPoint: anchorPoint,
      traversalEdgeBehavior: traversalEdgeBehavior,
      requestFocus: requestFocus,
    ),
  );
}
