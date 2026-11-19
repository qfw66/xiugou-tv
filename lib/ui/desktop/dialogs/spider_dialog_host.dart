import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/companion/companion_log.dart';
import '../../../core/companion/companion_recovery.dart';
import '../../../core/companion/companion_ui_channel.dart';
import '../../../core/companion/login_attempt_tracker.dart';
import '../../../core/companion/spider_ui_models.dart';
import '../widgets/app_message.dart';
import 'app_dialog.dart';
import 'spider_dialog_view.dart';

/// 宿主页面只需报告动作是否已有可见结果，关闭或换源后可丢弃旧动作。
class SpiderActionFeedback {
  SpiderActionFeedback._(this._finish);

  void Function(bool? hasResult)? _finish;

  void complete({required bool hasResult}) {
    final finish = _finish;
    _finish = null;
    finish?.call(hasResult);
  }

  void abandon() {
    final finish = _finish;
    _finish = null;
    finish?.call(null);
  }
}

/// 载荷界面宿主：订阅 [CompanionUiChannel]，把载荷弹窗推成应用内对话框，
/// Toast 转成应用内消息，剪贴板写入系统剪贴板，外部网页交给 [openUrl]。
///
/// 必须挂在 Navigator 之下（包住 home），以便推送对话框路由。
/// 弹窗的生死以载荷为准：只有收到 dismiss / reset 事件或载荷确认弹窗已不存在时才移除路由。
class SpiderDialogHost extends StatefulWidget {
  final CompanionUiChannel channel;
  final Future<bool> Function(String url) openUrl;
  final Widget child;

  /// 「站源服务异常」类提示里附带的诊断日志路径。
  final String? diagnosticsLogPath;

  const SpiderDialogHost({
    super.key,
    required this.channel,
    required this.openUrl,
    required this.child,
    this.diagnosticsLogPath,
  });

  static SpiderActionFeedback? beginAction(BuildContext context) =>
      context.findAncestorStateOfType<_SpiderDialogHostState>()?._beginAction();

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

  /// 扫码 / 登录弹窗的结果追踪：不让二维码「自己关掉、什么都没说」。
  final LoginAttemptTracker _logins = LoginAttemptTracker();

  /// 缓存的 Navigator：dispose 时 context 已失效，不能再 Navigator.of(context)。
  NavigatorState? _navigator;

  /// 诊断日志路径：默认取应用级 companion 日志（用户回报问题时要能找得到）。
  String? get _logPath =>
      widget.diagnosticsLogPath ?? CompanionLog.shared().path;

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
    _logins.clear();
    for (final id in _open.keys.toList()) {
      _close(id);
    }
    super.dispose();
  }

  void _onEvent(SpiderUiEvent event) {
    if (!mounted) return;
    switch (event) {
      case SpiderDialogShown(:final dialog, :final isUpdate):
        _showOrUpdate(dialog, isUpdate: isUpdate);
      case SpiderDialogDismissed(:final id):
        _close(id);
        _showNotice(_logins.onDialogDismissed(id));
      case SpiderUiReset(:final dialogs):
        final keep = {for (final d in dialogs) d.id};
        final closing = _open.keys.where((id) => !keep.contains(id)).toList();
        for (final id in closing) {
          _close(id);
        }
        // 进程退出 / 重置导致的被动关闭：说明是「服务中断」，不是用户操作
        final interrupted = _logins.onServiceReset(closing);
        if (interrupted != null) {
          _showNotice(LoginNotice(
            withCompanionLogPath(interrupted.message, _logPath),
            kind: interrupted.kind,
          ));
        }
        for (final dialog in dialogs) {
          _showOrUpdate(dialog);
        }
      case SpiderToast(:final text):
        final toast = _logins.onToast(text);
        showAppMessage(toast.text, type: _messageType(toast.kind));
      case SpiderClipboard(:final text):
        unawaited(Clipboard.setData(ClipboardData(text: text)));
        showAppMessage('站源已复制内容到剪贴板', type: AppMessageType.success);
      case SpiderOpenUri(:final uri):
        unawaited(_openUri(uri));
    }
  }

  void _showOrUpdate(SpiderDialog dialog, {bool isUpdate = false}) {
    final existing = _open[dialog.id];
    if (existing != null) {
      existing.model.value = dialog;
      _logins.onDialogShown(dialog, isUpdate: true);
      return;
    }
    final model = ValueNotifier<SpiderDialog>(dialog);
    final route = AppDialogRoute<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => SpiderDialogView(dialog: model, onInput: _onInput),
    );
    _open[dialog.id] = _OpenDialog(model, route);
    unawaited(_navigator?.push(route));
    // 上次同一类登录没有结论（窗口被关掉 / 服务中断）：这次进来先补一条状态
    _showNotice(_logins.onDialogShown(dialog, isUpdate: isUpdate));
  }

  SpiderActionFeedback _beginAction() {
    final action = _logins.beginAction();
    return SpiderActionFeedback._((hasResult) {
      if (!mounted) return;
      if (hasResult == null) {
        _logins.abandonAction(action);
      } else {
        _showNotice(_logins.onActionFinished(action, hasResult: hasResult));
      }
    });
  }

  void _showNotice(LoginNotice? notice) {
    if (notice == null || !mounted) return;
    showAppMessage(notice.message, type: _messageType(notice.kind));
  }

  static AppMessageType _messageType(LoginNoticeKind kind) => switch (kind) {
        LoginNoticeKind.info => AppMessageType.info,
        LoginNoticeKind.success => AppMessageType.success,
        LoginNoticeKind.warning => AppMessageType.warning,
        LoginNoticeKind.error => AppMessageType.error,
      };

  void _close(int id) {
    final open = _open.remove(id);
    if (open == null) return;
    if (open.route.isActive) _navigator?.removeRoute(open.route);
    // 路由移除后其子树在本帧内销毁，再释放模型，避免视图在 dispose 时访问已释放的监听器
    WidgetsBinding.instance.addPostFrameCallback((_) => open.model.dispose());
  }

  Future<bool> _onInput(SpiderUiInput input) async {
    final dialog = _open[input.dialogId]?.model.value;
    final cancelButton = input.type == 'button' &&
        dialog?.buttons.any((button) => button.which == input.which &&
            const ['取消', '关闭'].contains(button.text.trim())) == true;
    final cancelClick = input.type == 'click' &&
        dialog?.content?.descendants.any((node) => node.id == input.viewId &&
            const ['取消', '关闭'].contains(node.text.trim())) == true;
    if (input.type == 'cancel' || cancelButton || cancelClick) {
      _logins.markCancelled(input.dialogId);
    }
    final accepted = await widget.channel.send(input);
    // 载荷那边弹窗已不存在（服务重启 / 已被关闭）：界面上的残留一并关掉
    if (!accepted && mounted) {
      _close(input.dialogId);
      final notice = _logins.onInputRejected(input.dialogId);
      if (notice != null) {
        _showNotice(LoginNotice(
          withCompanionLogPath(notice.message, _logPath),
          kind: notice.kind,
        ));
      } else {
        // 不静默：点了没反应时用户至少知道操作没送达（诊断日志由通道记录）
        showAppMessage('站源未响应本次操作，弹窗已关闭，请重新打开再试',
            type: AppMessageType.warning);
      }
    }
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
