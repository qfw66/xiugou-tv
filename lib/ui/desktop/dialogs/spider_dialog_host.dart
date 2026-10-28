import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/companion/companion_ui_channel.dart';
import '../../../core/companion/spider_ui_models.dart';
import '../widgets/app_message.dart';
import 'spider_dialog_view.dart';

/// 载荷界面宿主：订阅 [CompanionUiChannel]，把载荷弹窗推成应用内对话框，
/// Toast 转成应用内消息，剪贴板写入系统剪贴板，外部网页交给 [openUrl]。
///
/// 必须挂在 Navigator 之下（包住 home），以便推送对话框路由。
/// 弹窗的生死以载荷为准：只有收到 dismiss / reset 事件或载荷确认弹窗已不存在时才移除路由。
class SpiderDialogHost extends StatefulWidget {
  final CompanionUiChannel channel;
  final Future<bool> Function(String url) openUrl;
  final Widget child;

  const SpiderDialogHost({
    super.key,
    required this.channel,
    required this.openUrl,
    required this.child,
  });

  @override
  State<SpiderDialogHost> createState() => _SpiderDialogHostState();
}

class _OpenDialog {
  final ValueNotifier<SpiderDialog> model;
  final Route<void> route;

  _OpenDialog(this.model, this.route);
}

class _SpiderDialogHostState extends State<SpiderDialogHost> {
  final Map<int, _OpenDialog> _open = {};
  StreamSubscription<SpiderUiEvent>? _subscription;

  /// 缓存的 Navigator：dispose 时 context 已失效，不能再 Navigator.of(context)。
  NavigatorState? _navigator;

  @override
  void initState() {
    super.initState();
    _subscription = widget.channel.events.listen(_onEvent);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _navigator = Navigator.of(context);
  }

  @override
  void dispose() {
    _subscription?.cancel();
    for (final id in _open.keys.toList()) {
      _close(id);
    }
    super.dispose();
  }

  void _onEvent(SpiderUiEvent event) {
    if (!mounted) return;
    switch (event) {
      case SpiderDialogShown(:final dialog):
        _showOrUpdate(dialog);
      case SpiderDialogDismissed(:final id):
        _close(id);
      case SpiderUiReset(:final dialogs):
        final keep = {for (final d in dialogs) d.id};
        for (final id
            in _open.keys.where((id) => !keep.contains(id)).toList()) {
          _close(id);
        }
        for (final dialog in dialogs) {
          _showOrUpdate(dialog);
        }
      case SpiderToast(:final text):
        showAppMessage(text);
      case SpiderClipboard(:final text):
        unawaited(Clipboard.setData(ClipboardData(text: text)));
        showAppMessage('站源已复制内容到剪贴板', type: AppMessageType.success);
      case SpiderOpenUri(:final uri):
        unawaited(_openUri(uri));
    }
  }

  void _showOrUpdate(SpiderDialog dialog) {
    final existing = _open[dialog.id];
    if (existing != null) {
      existing.model.value = dialog;
      return;
    }
    final model = ValueNotifier<SpiderDialog>(dialog);
    final route = DialogRoute<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => SpiderDialogView(dialog: model, onInput: _onInput),
    );
    _open[dialog.id] = _OpenDialog(model, route);
    unawaited(_navigator?.push(route));
  }

  void _close(int id) {
    final open = _open.remove(id);
    if (open == null) return;
    if (open.route.isActive) _navigator?.removeRoute(open.route);
    // 路由移除后其子树在本帧内销毁，再释放模型，避免视图在 dispose 时访问已释放的监听器
    WidgetsBinding.instance.addPostFrameCallback((_) => open.model.dispose());
  }

  Future<bool> _onInput(SpiderUiInput input) async {
    final accepted = await widget.channel.send(input);
    // 载荷那边弹窗已不存在（服务重启 / 已被关闭）：界面上的残留一并关掉
    if (!accepted && mounted) _close(input.dialogId);
    return accepted;
  }

  Future<void> _openUri(String uri) async {
    final parsed = Uri.tryParse(uri);
    final isWeb =
        parsed != null && (parsed.scheme == 'http' || parsed.scheme == 'https');
    if (isWeb && await widget.openUrl(uri)) return;
    // 唤起手机 App 之类的地址桌面端打不开：把地址交给用户自行处理
    showAppMessage(
      '站源请求打开：$uri',
      type: AppMessageType.warning,
      duration: const Duration(seconds: 8),
      action: AppMessageAction(
        label: '复制',
        onPressed: () => unawaited(Clipboard.setData(ClipboardData(text: uri))),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
