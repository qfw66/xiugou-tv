import 'dart:convert';
import 'dart:typed_data';

/// 载荷（Spider）弹窗协议的 Dart 侧模型，与 companion 的 `ui.UiSnapshot` / `ui.UiBridge` 一一对应。
///
/// 载荷在配置中心里用 Android 的 AlertDialog 弹出扫码登录、填写 cookie 等窗口；
/// companion 把它们序列化成事件，经 `/ui/events` 长轮询交给 Flutter 渲染，
/// 用户操作再经 `/ui/input` 回放给载荷。字段改动必须两端同步。

/// 控件节点。
class SpiderUiNode {
  final int id;

  /// group / grid / text / button / input / image / switch / check / radio / select / progress
  final String kind;
  final bool enabled;
  final bool clickable;
  final String text;
  final String hint;
  final bool password;
  final bool multiline;
  final bool bold;
  final bool checked;

  /// group：v（纵向）/ h（横向）
  final String axis;
  final bool scroll;
  final int columns;
  final List<SpiderUiNode> children;

  /// image：PNG 原始字节与像素尺寸
  final Uint8List? png;
  final int width;
  final int height;

  /// select：选项与当前选中下标（无选中为 -1）
  final List<String> options;
  final int selected;

  /// progress
  final bool indeterminate;
  final int max;
  final int value;

  const SpiderUiNode({
    required this.id,
    required this.kind,
    this.enabled = true,
    this.clickable = false,
    this.text = '',
    this.hint = '',
    this.password = false,
    this.multiline = false,
    this.bold = false,
    this.checked = false,
    this.axis = 'v',
    this.scroll = false,
    this.columns = 1,
    this.children = const [],
    this.png,
    this.width = 0,
    this.height = 0,
    this.options = const [],
    this.selected = -1,
    this.indeterminate = true,
    this.max = 100,
    this.value = 0,
  });

  static SpiderUiNode? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final id = _int(raw['id'], -1);
    final kind = '${raw['kind'] ?? ''}';
    if (id < 0 || kind.isEmpty) return null;
    Uint8List? png;
    final pngRaw = raw['png'];
    if (pngRaw is String && pngRaw.isNotEmpty) {
      try {
        png = base64Decode(pngRaw);
      } on FormatException {
        png = null;
      }
    }
    final childrenRaw = raw['children'];
    return SpiderUiNode(
      id: id,
      kind: kind,
      enabled: raw['enabled'] != false,
      clickable: raw['clickable'] == true,
      text: '${raw['text'] ?? ''}',
      hint: '${raw['hint'] ?? ''}',
      password: raw['password'] == true,
      multiline: raw['multiline'] == true,
      bold: raw['bold'] == true,
      checked: raw['checked'] == true,
      axis: '${raw['axis'] ?? 'v'}',
      scroll: raw['scroll'] == true,
      columns: _int(raw['columns'], 1).clamp(1, 12),
      children: childrenRaw is List
          ? childrenRaw.map(tryParse).whereType<SpiderUiNode>().toList()
          : const [],
      png: png,
      width: _int(raw['width'], 0),
      height: _int(raw['height'], 0),
      options: raw['options'] is List
          ? (raw['options'] as List).map((e) => '$e').toList()
          : const [],
      selected: _int(raw['selected'], -1),
      indeterminate: raw['indeterminate'] != false,
      max: _int(raw['max'], 100),
      value: _int(raw['value'], 0),
    );
  }

  /// 深度优先遍历本节点及其子孙。
  Iterable<SpiderUiNode> get descendants sync* {
    yield this;
    for (final child in children) {
      yield* child.descendants;
    }
  }
}

/// 对话框按钮：which 与 Android 的 BUTTON_POSITIVE(-1) / NEGATIVE(-2) / NEUTRAL(-3) 一致。
class SpiderDialogButton {
  static const int positive = -1;
  static const int negative = -2;
  static const int neutral = -3;

  final int which;
  final String text;
  final bool enabled;

  const SpiderDialogButton(
      {required this.which, required this.text, this.enabled = true});
}

/// 对话框列表项（AlertDialog 的 setItems / setSingleChoiceItems / setMultiChoiceItems）。
class SpiderDialogList {
  /// list（点即关闭）/ single / multi
  final String mode;
  final List<String> items;
  final int checkedIndex;
  final List<bool> checkedFlags;

  const SpiderDialogList({
    required this.mode,
    required this.items,
    this.checkedIndex = -1,
    this.checkedFlags = const [],
  });

  bool isChecked(int index) => mode == 'multi'
      ? index < checkedFlags.length && checkedFlags[index]
      : mode == 'single' && index == checkedIndex;
}

/// 一个载荷弹窗的完整快照。
class SpiderDialog {
  final int id;
  final String title;
  final String message;
  final bool cancelable;
  final SpiderUiNode? content;
  final List<SpiderDialogButton> buttons;
  final SpiderDialogList? list;

  const SpiderDialog({
    required this.id,
    this.title = '',
    this.message = '',
    this.cancelable = true,
    this.content,
    this.buttons = const [],
    this.list,
  });

  static SpiderDialog? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final id = _int(raw['id'], -1);
    if (id < 0) return null;
    final buttons = <SpiderDialogButton>[];
    if (raw['buttons'] is List) {
      for (final b in raw['buttons'] as List) {
        if (b is! Map) continue;
        buttons.add(SpiderDialogButton(
          which: _int(b['which'], 0),
          text: '${b['text'] ?? ''}',
          enabled: b['enabled'] != false,
        ));
      }
    }
    SpiderDialogList? list;
    final listRaw = raw['list'];
    if (listRaw is Map && listRaw['items'] is List) {
      final mode = '${listRaw['mode'] ?? 'list'}';
      final checked = listRaw['checked'];
      list = SpiderDialogList(
        mode: mode,
        items: (listRaw['items'] as List).map((e) => '$e').toList(),
        checkedIndex: checked is num ? checked.toInt() : -1,
        checkedFlags:
            checked is List ? checked.map((e) => e == true).toList() : const [],
      );
    }
    return SpiderDialog(
      id: id,
      title: '${raw['title'] ?? ''}',
      message: '${raw['message'] ?? ''}',
      cancelable: raw['cancelable'] != false,
      content: SpiderUiNode.tryParse(raw['content']),
      buttons: buttons,
      list: list,
    );
  }

  /// 有可见文字的按钮（载荷偶尔会设置空文字的占位按钮）。
  List<SpiderDialogButton> get visibleButtons =>
      buttons.where((b) => b.text.trim().isNotEmpty).toList();
}

/// 载荷界面事件。
sealed class SpiderUiEvent {
  const SpiderUiEvent();
}

/// 弹窗出现或内容更新（[isUpdate] 为 true 时宿主应原地刷新而不是新开）。
class SpiderDialogShown extends SpiderUiEvent {
  final SpiderDialog dialog;
  final bool isUpdate;

  const SpiderDialogShown(this.dialog, {this.isUpdate = false});
}

class SpiderDialogDismissed extends SpiderUiEvent {
  final int id;

  const SpiderDialogDismissed(this.id);
}

/// 宿主重连或落后太多：以 [dialogs] 为准重建界面（不在其中的弹窗都应关闭）。
class SpiderUiReset extends SpiderUiEvent {
  final List<SpiderDialog> dialogs;

  const SpiderUiReset(this.dialogs);
}

class SpiderToast extends SpiderUiEvent {
  final String text;

  const SpiderToast(this.text);
}

/// 载荷请求打开外部地址（网页注册 / 唤起 App）。
class SpiderOpenUri extends SpiderUiEvent {
  final String uri;

  const SpiderOpenUri(this.uri);
}

class SpiderClipboard extends SpiderUiEvent {
  final String text;

  const SpiderClipboard(this.text);
}

/// 一次长轮询的结果。
class SpiderUiPollResult {
  final int cursor;
  final List<SpiderUiEvent> events;

  const SpiderUiPollResult({required this.cursor, required this.events});

  /// 解析 `/ui/events` 的响应；格式不对返回 null（调用方按网络错误处理）。
  static SpiderUiPollResult? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final cursor = _int(raw['cursor'], -1);
    if (cursor < 0) return null;
    final reset = raw['reset'] == true;
    final events = <SpiderUiEvent>[];
    final shownOnReset = <SpiderDialog>[];
    if (raw['events'] is List) {
      for (final e in raw['events'] as List) {
        if (e is! Map) continue;
        switch ('${e['type'] ?? ''}') {
          case 'show':
          case 'update':
            final dialog = SpiderDialog.tryParse(e['dialog']);
            if (dialog == null) break;
            if (reset) {
              shownOnReset.add(dialog);
            } else {
              events.add(
                  SpiderDialogShown(dialog, isUpdate: e['type'] == 'update'));
            }
          case 'dismiss':
            events.add(SpiderDialogDismissed(_int(e['id'], -1)));
          case 'toast':
            final text = '${e['text'] ?? ''}'.trim();
            if (text.isNotEmpty) events.add(SpiderToast(text));
          case 'openUri':
            final uri = '${e['uri'] ?? ''}'.trim();
            if (uri.isNotEmpty) events.add(SpiderOpenUri(uri));
          case 'clipboard':
            events.add(SpiderClipboard('${e['text'] ?? ''}'));
        }
      }
    }
    if (reset) events.insert(0, SpiderUiReset(shownOnReset));
    return SpiderUiPollResult(cursor: cursor, events: events);
  }
}

/// 回放给载荷的一次用户操作。[inputs] 是弹窗里所有输入框的当前内容（控件 id → 文本），
/// 先于操作回填，载荷在按钮回调里读取。
class SpiderUiInput {
  final int dialogId;

  /// button / item / click / check / select / submit / cancel
  final String type;
  final int? which;
  final int? index;
  final int? viewId;
  final bool? checked;
  final Map<int, String> inputs;

  const SpiderUiInput({
    required this.dialogId,
    required this.type,
    this.which,
    this.index,
    this.viewId,
    this.checked,
    this.inputs = const {},
  });

  Map<String, Object?> toJson() => {
        'dialog': dialogId,
        'type': type,
        if (which != null) 'which': which,
        if (index != null) 'index': index,
        if (viewId != null) 'view': viewId,
        if (checked != null) 'checked': checked,
        if (inputs.isNotEmpty)
          'inputs': inputs.map((k, v) => MapEntry('$k', v)),
      };
}

int _int(Object? value, int fallback) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse('${value ?? ''}') ?? fallback;
}
