import 'dart:async';

import 'package:flutter/material.dart';
import 'app_dialog.dart';

/// 等待可放弃的加载；取消不会被当作空结果或加载失败。
Future<({T? value, bool cancelled})> loadWithDialog<T>({
  required BuildContext context,
  required Future<T?> Function() load,
  String label = '正在获取详情…',
}) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  final result = Completer<({T? value, bool cancelled})>();
  void cancel() {
    if (!result.isCompleted) result.complete((value: null, cancelled: true));
  }

  final route = AppDialogRoute<void>(
    context: context,
    builder: (_) => PopScope<void>(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) cancel();
      },
      child: AlertDialog(
        key: const ValueKey('detail-loading'),
        title: Text(label),
        content: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 16),
            Flexible(child: Text('网络较慢时可取消后重试。')),
          ],
        ),
        actions: [TextButton(onPressed: cancel, child: const Text('取消 · Esc'))],
      ),
    ),
  );
  unawaited(navigator.push(route).then((_) => cancel()));
  unawaited(Future<T?>.sync(load).then<void>((value) {
    if (!result.isCompleted) result.complete((value: value, cancelled: false));
  }, onError: (Object error, StackTrace stack) {
    if (!result.isCompleted) result.completeError(error, stack);
  }));

  try {
    return await result.future;
  } finally {
    // invariant: 站源可在其上方弹出扫码窗口，只移除本次加载持有的路由。
    if (navigator.mounted && route.isActive) navigator.removeRoute(route);
  }
}
