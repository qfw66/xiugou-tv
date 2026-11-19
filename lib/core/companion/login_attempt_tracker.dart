import 'spider_ui_models.dart';

/// 提示语气；由 UI 层映射到 `AppMessageType`，让本文件保持纯 Dart 可单测。
enum LoginNoticeKind { info, success, warning, error }

/// 一条要给用户看的登录结果提示。
class LoginNotice {
  const LoginNotice(this.message, {this.kind = LoginNoticeKind.warning});

  final String message;
  final LoginNoticeKind kind;

  @override
  String toString() => 'LoginNotice($kind, $message)';
}

/// 载荷 Toast 的转发决定：可能补一句「登录信息保存在哪」，并带上语气。
class LoginToast {
  const LoginToast(this.text, {this.kind = LoginNoticeKind.info});

  final String text;
  final LoginNoticeKind kind;

  @override
  String toString() => 'LoginToast($kind, $text)';
}

/// 交互式登录弹窗的形态：直接给二维码，或让用户粘贴 cookie / 填验证码。
enum LoginDialogKind { qr, credentials }

/// 一次站源动作的反馈归属；与服务端弹窗编号的生命周期分开。
class LoginAction {
  LoginAction._(this.startedAt);

  final DateTime startedAt;
  bool _hasResult = false;
}

class _Attempt {
  _Attempt({
    required this.dialog,
    required this.kind,
    required this.startedAt,
    this.action,
  });

  final SpiderDialog dialog;
  final LoginDialogKind kind;
  final DateTime startedAt;
  final LoginAction? action;
  bool dismissed = false;

  /// 用户按了取消 / Esc（界面回放 `cancel`）。取消不是失败，提示语气要温和。
  bool cancelled = false;

  /// 载荷在弹窗存活期间发过的最后一条 Toast 及其结论。
  String? toast;
  LoginNoticeKind? toastKind;

  String get key => LoginAttemptTracker.noticeKey(dialog);
}

/// 合并站源动作结果和弹窗事件；正常关闭本身不代表登录失败。
/// 未确认提示只在可归属的动作已结束且弹窗已关闭后产生。
class LoginAttemptTracker {
  LoginAttemptTracker({
    DateTime Function()? clock,
    this.staleAfter = const Duration(minutes: 30),
    this.maxPendingNotices = 8,
  }) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  /// 超过该时长的未结束尝试视为失效（进程被杀 / 界面重建后不再误报）。
  final Duration staleAfter;

  /// 待补提示的条数上限，避免长时间运行时无限增长。
  final int maxPendingNotices;

  final Map<int, _Attempt> _attempts = {};
  final Map<String, LoginNotice> _pending = {};
  final Set<LoginAction> _actions = {};

  LoginAction beginAction() {
    _pruneStale();
    final action = LoginAction._(_clock());
    _actions.add(action);
    return action;
  }

  LoginNotice? onActionFinished(LoginAction action, {required bool hasResult}) {
    if (!_actions.remove(action)) return null;
    action._hasResult = hasResult;
    LoginNotice? notice;
    final owned = _attempts.values.where((a) => identical(a.action, action)).toList();
    for (final attempt in owned) {
      if (hasResult) _pending.remove(attempt.key);
      if (attempt.dismissed) {
        _attempts.remove(attempt.dialog.id);
        notice ??= _conclude(attempt);
      }
    }
    return notice;
  }

  void abandonAction(LoginAction action) {
    _actions.remove(action);
    _attempts.removeWhere((_, attempt) => identical(attempt.action, action));
  }

  /// Toast 里出现这些词，说明载荷已经给了结论。
  static const List<String> _successWords = [
    '成功',
    '已设置',
    '已经设置',
    '已保存',
    '已更新',
    '已完成',
    '已登录',
    '已导入',
    '已写入',
    '已记录',
  ];

  static const List<String> _failureWords = [
    '失败',
    '错误',
    '无效',
    '过期',
    '超时',
    '未登录',
    '异常',
    '拒绝',
  ];

  static const List<String> _cancelWords = ['取消', '放弃', '已退出'];

  /// 登录信息被载荷持久化在哪（companion 目录，见 `AppDataReset` 的重置范围）。
  static const String savedHint = '登录信息已保存在站源服务里';

  /// 供 UI 判断是否要跟踪（也是单测入口）。
  static bool isInteractiveLogin(SpiderDialog dialog) =>
      detectKind(dialog) != null;

  /// 返回弹窗形态；不是扫码 / 登录类返回 null。
  static LoginDialogKind? detectKind(SpiderDialog dialog) {
    var hasImage = false;
    var hasInput = false;
    final buffer = StringBuffer(dialog.title)..write(' ${dialog.message}');
    for (final node in dialog.content?.descendants ?? const <SpiderUiNode>[]) {
      if (node.kind == 'image') hasImage = true;
      if (node.kind == 'input') hasInput = true;
      buffer
        ..write(' ')
        ..write(node.text)
        ..write(' ')
        ..write(node.hint);
      for (final option in node.options) {
        buffer
          ..write(' ')
          ..write(option);
      }
    }
    final text = buffer.toString().toLowerCase();
    final mentionsScan = const ['扫码', '二维码', '验证码', 'cookie'].any(
      text.contains,
    );
    if (hasImage || mentionsScan) return LoginDialogKind.qr;
    if (hasInput) return LoginDialogKind.credentials;
    return null;
  }

  static String noticeKey(SpiderDialog dialog) {
    final title = dialog.title.trim();
    return title.isEmpty ? '#untitled' : title;
  }

  /// 弹窗出现 / 原地更新。返回「上次这类登录的结论」，用于下次进入时补状态。
  LoginNotice? onDialogShown(SpiderDialog dialog, {bool isUpdate = false}) {
    _pruneStale();
    final kind = detectKind(dialog);
    if (kind != null) {
      final attempt = _attempts[dialog.id];
      if (attempt == null || attempt.dismissed) {
        // 没有请求ID的旧UI协议只能关联唯一在途动作；并发时不猜归属。
        final action = _actions.length == 1 ? _actions.single : null;
        if (action != null) {
          _attempts.removeWhere((_, old) => old.dismissed && identical(old.action, action));
        }
        _attempts[dialog.id] = _Attempt(
          dialog: dialog,
          kind: kind,
          startedAt: _clock(),
          action: action,
        );
      }
    }
    if (isUpdate) return null;
    return _pending.remove(noticeKey(dialog));
  }

  /// 载荷 Toast：判断结论、必要时补一句保存位置。
  LoginToast onToast(String text) {
    _pruneStale();
    final kind = _classify(text);
    final attempt = _latestAttempt();
    if (attempt == null) {
      return LoginToast(text, kind: _kindOf(kind));
    }
    if (kind != _ToastConclusion.neutral || attempt.toastKind == null) {
      attempt
        ..toast = text
        ..toastKind = _kindOf(kind);
    }
    if (kind != _ToastConclusion.success) {
      return LoginToast(text, kind: _kindOf(kind));
    }
    final mentionsSave = const ['保存', '设置', '写入', '记录', '导入']
        .any((word) => text.contains(word));
    if (mentionsSave) return LoginToast(text, kind: LoginNoticeKind.success);
    return LoginToast(
      '$text（$savedHint）',
      kind: LoginNoticeKind.success,
    );
  }

  /// 界面回放了 `cancel`（Esc / 关闭按钮）：取消不是失败。
  void markCancelled(int dialogId) {
    final attempt = _attempts[dialogId];
    if (attempt == null) return;
    attempt.cancelled = true;
  }

  /// 载荷已不认识这个弹窗（服务重启 / 弹窗已被关掉），界面本地关掉它。
  LoginNotice? onInputRejected(int dialogId) {
    final attempt = _attempts.remove(dialogId);
    if (attempt == null) return null;
    final what =
        attempt.kind == LoginDialogKind.qr ? '扫码登录结果未保存' : '填写内容未保存';
    return LoginNotice('站源未响应本次操作，$what，弹窗已关闭，请重新打开再试');
  }

  /// 弹窗与动作都结束后才能判断是否缺少结果，兼容两条通道的任意先后顺序。
  LoginNotice? onDialogDismissed(int dialogId) {
    final attempt = _attempts[dialogId];
    if (attempt == null || attempt.dismissed) return null;
    attempt.dismissed = true;
    if (_actions.contains(attempt.action)) return null;
    _attempts.remove(dialogId);
    return _conclude(attempt);
  }

  LoginNotice? _conclude(_Attempt attempt) {
    if (attempt.action?._hasResult == true) return null;
    if (attempt.cancelled) return _cancelledNotice(attempt);
    switch (attempt.toastKind) {
      case LoginNoticeKind.success:
      case LoginNoticeKind.error:
      case LoginNoticeKind.warning:
        // 载荷的 Toast 已经说清成功 / 失败 / 取消，不再叠一条
        return null;
      case LoginNoticeKind.info:
      case null:
        break;
    }
    // 未关联的弹窗可能通过另一个RPC返回结果，关闭事件不能证明它没有结果。
    if (attempt.action == null) return null;
    final notice = _unconfirmedNotice(attempt);
    _remember(attempt.key, _pendingNotice(attempt));
    return notice;
  }

  /// 服务中断（companion 退出 / 界面重置）导致的被动关闭。
  LoginNotice? onServiceReset(Iterable<int> closedDialogIds) {
    LoginNotice? first;
    final closed = {...closedDialogIds, for (final a in _attempts.values) if (a.dismissed) a.dialog.id};
    for (final id in closed) {
      final attempt = _attempts.remove(id);
      if (attempt == null) continue;
      _actions.remove(attempt.action);
      if (attempt.action?._hasResult == true || attempt.toastKind == LoginNoticeKind.success) continue;
      final notice =
          attempt.cancelled ? _cancelledNotice(attempt) : _interruptedNotice(attempt);
      _remember(attempt.key, _pendingNotice(attempt, interrupted: true));
      first ??= notice;
    }
    return first;
  }

  /// 清空所有状态（宿主 dispose 时调用）。
  void clear() {
    _attempts.clear();
    _pending.clear();
    _actions.clear();
  }

  LoginNotice _cancelledNotice(_Attempt attempt) {
    final message = attempt.kind == LoginDialogKind.qr
        ? '已取消扫码登录，未保存登录信息'
        : '已取消登录设置，未保存填写内容';
    return LoginNotice(message, kind: LoginNoticeKind.info);
  }

  LoginNotice _unconfirmedNotice(_Attempt attempt) {
    final base = attempt.kind == LoginDialogKind.qr
        ? '扫码窗口已关闭，站源没有返回登录结果，请重新扫码'
        : '登录窗口已关闭，站源没有返回结果，请重新打开再试';
    final toast = attempt.toast?.trim() ?? '';
    if (toast.isEmpty) return LoginNotice(base);
    return LoginNotice('$base（站源最后提示：$toast）');
  }

  LoginNotice _interruptedNotice(_Attempt attempt) {
    final message = attempt.kind == LoginDialogKind.qr
        ? '站源服务已中断，本次扫码登录未完成，登录信息未保存，请重新扫码'
        : '站源服务已中断，本次登录设置未完成，填写内容未保存，请重新打开再试';
    return LoginNotice(message);
  }

  LoginNotice _pendingNotice(_Attempt attempt, {bool interrupted = false}) {
    if (interrupted) {
      return LoginNotice(
        attempt.kind == LoginDialogKind.qr
            ? '上次扫码登录被中断（站源服务退出），登录信息未保存，请重新扫码'
            : '上次登录设置被中断（站源服务退出），内容未保存，请重新打开再试',
      );
    }
    return LoginNotice(
      attempt.kind == LoginDialogKind.qr
          ? '上次扫码登录没有返回结果，登录信息可能未保存，请重新扫码'
          : '上次登录设置没有返回结果，内容可能未保存，请重新打开再试',
    );
  }

  void _remember(String key, LoginNotice notice) {
    _pending.remove(key);
    if (maxPendingNotices <= 0) return;
    while (_pending.length >= maxPendingNotices) {
      _pending.remove(_pending.keys.first);
    }
    _pending[key] = notice;
  }

  _Attempt? _latestAttempt() {
    _Attempt? latest;
    for (final attempt in _attempts.values) {
      if (latest == null || attempt.startedAt.isAfter(latest.startedAt)) {
        latest = attempt;
      }
    }
    return latest;
  }

  void _pruneStale() {
    final now = _clock();
    _actions.removeWhere((action) => now.difference(action.startedAt) > staleAfter);
    _attempts.removeWhere(
      (_, attempt) => now.difference(attempt.startedAt) > staleAfter,
    );
  }

  _ToastConclusion _classify(String text) {
    if (_cancelWords.any(text.contains)) return _ToastConclusion.cancelled;
    // 先判失败：「cookie 设置失败」里也有「设置」，不能被当成成功。
    if (_failureWords.any(text.contains)) return _ToastConclusion.failure;
    if (_successWords.any(text.contains)) return _ToastConclusion.success;
    return _ToastConclusion.neutral;
  }

  LoginNoticeKind _kindOf(_ToastConclusion conclusion) => switch (conclusion) {
        _ToastConclusion.success => LoginNoticeKind.success,
        _ToastConclusion.failure => LoginNoticeKind.error,
        _ToastConclusion.cancelled => LoginNoticeKind.warning,
        _ToastConclusion.neutral => LoginNoticeKind.info,
      };
}

enum _ToastConclusion { success, failure, cancelled, neutral }
