import 'package:flutter/widgets.dart';

/// 让「不允许点遮罩关闭」的弹窗仍然响应 Esc。
///
/// 模态路由自带的 Esc（[DismissIntent]）只在 `barrierDismissible: true` 时生效；
/// 桌面端为防误点把遮罩关闭禁掉后，键盘用户就失去了退出途径。这里在弹窗内部
/// 就近接管 [DismissIntent]，统一走 [NavigatorState.maybePop]：
/// 弹窗里已有的 `PopScope(canPop: false)`（保存中、下载中）照样拦截，
/// 不会出现「按钮禁用了但 Esc 能关掉」的旁路。
///
/// [autofocus] 让焦点落进弹窗，使 Esc 从这里开始查找动作；弹窗内已有自动聚焦
/// 的输入框时应传 false，否则会抢走输入框的初始焦点。
class EscapeClosable extends StatelessWidget {
  final Widget child;
  final bool autofocus;

  const EscapeClosable({super.key, required this.child, this.autofocus = true});

  @override
  Widget build(BuildContext context) => Actions(
        actions: <Type, Action<Intent>>{
          DismissIntent: CallbackAction<DismissIntent>(
            onInvoke: (_) => Navigator.of(context).maybePop(),
          ),
        },
        child: Focus(
          autofocus: autofocus,
          skipTraversal: true,
          child: child,
        ),
      );
}
