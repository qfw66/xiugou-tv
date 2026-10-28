import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/companion/spider_ui_models.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';

/// 载荷弹窗的渲染：把 [SpiderDialog] 快照画成应用内对话框，并把用户操作交给 [onInput]。
///
/// 关闭（右上角关闭 / Esc）不在本地直接关，而是请求载荷取消（等同 Android 返回键），
/// 由载荷决定是否关闭；真正的关闭由宿主收到 dismiss 事件后执行。
class SpiderDialogView extends StatefulWidget {
  final ValueListenable<SpiderDialog> dialog;
  final Future<bool> Function(SpiderUiInput input) onInput;

  const SpiderDialogView(
      {super.key, required this.dialog, required this.onInput});

  @override
  State<SpiderDialogView> createState() => _SpiderDialogViewState();
}

class _SpiderDialogViewState extends State<SpiderDialogView> {
  /// 输入框控件 id → 编辑器。
  final Map<int, TextEditingController> _controllers = {};

  /// 输入框最近一次从载荷同步来的文字：载荷改了才覆盖用户输入，避免刷新时吞掉正在输入的内容。
  final Map<int, String> _syncedText = {};

  @override
  void initState() {
    super.initState();
    widget.dialog.addListener(_onModel);
    _syncInputs(widget.dialog.value);
  }

  @override
  void dispose() {
    widget.dialog.removeListener(_onModel);
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _onModel() {
    _syncInputs(widget.dialog.value);
    if (mounted) setState(() {});
  }

  void _syncInputs(SpiderDialog dialog) {
    final content = dialog.content;
    if (content == null) return;
    for (final node in content.descendants) {
      if (node.kind != 'input') continue;
      final controller =
          _controllers.putIfAbsent(node.id, () => TextEditingController());
      if (_syncedText[node.id] != node.text) {
        _syncedText[node.id] = node.text;
        controller.text = node.text;
      }
    }
  }

  Map<int, String> get _inputs =>
      _controllers.map((id, c) => MapEntry(id, c.text));

  void _send(String type,
      {int? which, int? index, int? viewId, bool? checked}) {
    widget.onInput(SpiderUiInput(
      dialogId: widget.dialog.value.id,
      type: type,
      which: which,
      index: index,
      viewId: viewId,
      checked: checked,
      inputs: _inputs,
    ));
  }

  void _requestCancel() => _send('cancel');

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final dialog = widget.dialog.value;
    final buttons = dialog.visibleButtons;
    final neutral = buttons.where((b) => b.which == SpiderDialogButton.neutral);
    final trailing = buttons
        .where((b) => b.which != SpiderDialogButton.neutral)
        .toList()
      ..sort((a, b) => b.which.compareTo(a.which)); // 否定在左、肯定在右

    final body = <Widget>[
      if (dialog.message.trim().isNotEmpty)
        SelectableText(dialog.message,
            style: TextStyle(
                fontSize: AppType.body, height: 1.5, color: palette.textBody)),
      if (dialog.content != null) _node(context, dialog.content!),
      if (dialog.list != null) _list(context, dialog.list!),
    ];

    // Esc 单独绑定：路由不允许点遮罩关闭（桌面上容易误点掉扫码窗），而模态路由只在
    // barrierDismissible 时才响应 Esc。
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (dialog.cancelable) _requestCancel();
        },
      },
      child: Focus(
        autofocus: true,
        child: PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _requestCancel();
          },
          child: Dialog(
            backgroundColor: palette.panel,
            insetPadding: const EdgeInsets.all(AppSpacing.xl),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadii.lg),
              side: BorderSide(color: palette.border),
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: 560,
                maxHeight: MediaQuery.sizeOf(context).height * 0.85,
              ),
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.xl),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(children: [
                      Expanded(
                        child: Text(
                          dialog.title.trim().isEmpty
                              ? '站源设置'
                              : dialog.title.trim(),
                          style: TextStyle(
                              fontSize: AppType.heading,
                              fontWeight: FontWeight.bold,
                              color: palette.textTitle),
                        ),
                      ),
                      if (dialog.cancelable)
                        IconButton(
                          tooltip: '关闭',
                          onPressed: _requestCancel,
                          icon:
                              Icon(Icons.close_rounded, color: palette.textSub),
                        ),
                    ]),
                    if (body.isNotEmpty) ...[
                      const SizedBox(height: AppSpacing.sm),
                      Flexible(
                        child: SingleChildScrollView(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: _spaced(body),
                          ),
                        ),
                      ),
                    ],
                    if (buttons.isNotEmpty) ...[
                      const SizedBox(height: AppSpacing.lg),
                      Row(children: [
                        for (final b in neutral)
                          _dialogButton(b, filled: false),
                        const Spacer(),
                        for (final b in trailing) ...[
                          const SizedBox(width: AppSpacing.sm),
                          _dialogButton(b,
                              filled: b.which == SpiderDialogButton.positive),
                        ],
                      ]),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _dialogButton(SpiderDialogButton b, {required bool filled}) {
    final onPressed = b.enabled ? () => _send('button', which: b.which) : null;
    return filled
        ? FilledButton(onPressed: onPressed, child: Text(b.text))
        : TextButton(onPressed: onPressed, child: Text(b.text));
  }

  List<Widget> _spaced(List<Widget> children) => [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(height: AppSpacing.md),
          children[i],
        ],
      ];

  Widget _list(BuildContext context, SpiderDialogList list) {
    final palette = AppPalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < list.items.length; i++)
          InkWell(
            borderRadius: BorderRadius.circular(AppRadii.sm),
            onTap: () => _send('item', index: i),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                  vertical: 10, horizontal: AppSpacing.sm),
              child: Row(children: [
                if (list.mode == 'single') ...[
                  Icon(
                    list.isChecked(i)
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: 18,
                    color:
                        list.isChecked(i) ? palette.accentInk : palette.textSub,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                ],
                if (list.mode == 'multi') ...[
                  Checkbox(
                      value: list.isChecked(i),
                      onChanged: (_) => _send('item', index: i)),
                  const SizedBox(width: AppSpacing.xs),
                ],
                Expanded(
                  child: Text(list.items[i],
                      style: TextStyle(
                          fontSize: AppType.label, color: palette.textMain)),
                ),
              ]),
            ),
          ),
      ],
    );
  }

  Widget _node(BuildContext context, SpiderUiNode node) {
    final palette = AppPalette.of(context);
    final textStyle =
        TextStyle(fontSize: AppType.body, height: 1.5, color: palette.textBody);
    VoidCallback? click() => node.clickable && node.enabled
        ? () => _send('click', viewId: node.id)
        : null;

    switch (node.kind) {
      case 'text':
        final onTap = click();
        final style = textStyle.copyWith(
          fontWeight: node.bold ? FontWeight.bold : null,
          color: onTap != null ? palette.accentInk : null,
        );
        if (onTap == null) return SelectableText(node.text, style: style);
        return InkWell(
          borderRadius: BorderRadius.circular(AppRadii.xs),
          onTap: onTap,
          child: Text(node.text, style: style),
        );
      case 'button':
        final onTap =
            node.enabled ? () => _send('click', viewId: node.id) : null;
        return OutlinedButton(onPressed: onTap, child: Text(node.text));
      case 'input':
        final controller = _controllers.putIfAbsent(
            node.id, () => TextEditingController(text: node.text));
        return TextField(
          controller: controller,
          enabled: node.enabled,
          obscureText: node.password,
          minLines: node.multiline ? 2 : 1,
          maxLines: node.multiline ? 6 : 1,
          style: TextStyle(fontSize: AppType.label, color: palette.textMain),
          decoration: InputDecoration(
            hintText: node.hint.isEmpty ? null : node.hint,
            hintStyle:
                TextStyle(fontSize: AppType.body, color: palette.textDim),
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            enabledBorder: OutlineInputBorder(
                borderSide: BorderSide(color: palette.border)),
            focusedBorder: OutlineInputBorder(
                borderSide: BorderSide(color: palette.accentInk)),
          ),
          onSubmitted: (_) => _send('submit', viewId: node.id),
        );
      case 'image':
        final png = node.png;
        if (png == null || node.width <= 0 || node.height <= 0) {
          return const SizedBox.shrink();
        }
        // 二维码常是几十像素的小图：放大到可扫尺寸，并用最近邻采样保持边缘锐利
        final displayWidth =
            node.width < 180 ? 180.0 : math.min(node.width.toDouble(), 300.0);
        final displayHeight = displayWidth * node.height / node.width;
        final image = Container(
          color: Colors.white,
          padding: const EdgeInsets.all(AppSpacing.sm),
          child: Image.memory(
            png,
            width: displayWidth,
            height: displayHeight,
            fit: BoxFit.contain,
            filterQuality: node.width < displayWidth
                ? FilterQuality.none
                : FilterQuality.medium,
            gaplessPlayback: true,
          ),
        );
        final onTap = click();
        return onTap == null ? image : InkWell(onTap: onTap, child: image);
      case 'switch':
        return Row(mainAxisSize: MainAxisSize.min, children: [
          Flexible(child: Text(node.text, style: textStyle)),
          const SizedBox(width: AppSpacing.sm),
          Switch(
            value: node.checked,
            onChanged: node.enabled
                ? (v) => _send('check', viewId: node.id, checked: v)
                : null,
          ),
        ]);
      case 'check':
        return Row(mainAxisSize: MainAxisSize.min, children: [
          Checkbox(
            value: node.checked,
            onChanged: node.enabled
                ? (v) => _send('check', viewId: node.id, checked: v == true)
                : null,
          ),
          Flexible(child: Text(node.text, style: textStyle)),
        ]);
      case 'radio':
        return InkWell(
          borderRadius: BorderRadius.circular(AppRadii.sm),
          onTap: node.enabled
              ? () => _send('check', viewId: node.id, checked: true)
              : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(
                  node.checked
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 18,
                  color: node.checked ? palette.accentInk : palette.textSub),
              const SizedBox(width: AppSpacing.sm),
              Flexible(child: Text(node.text, style: textStyle)),
            ]),
          ),
        );
      case 'select':
        if (node.options.isEmpty) return const SizedBox.shrink();
        return DropdownButton<int>(
          value: node.selected >= 0 && node.selected < node.options.length
              ? node.selected
              : null,
          isExpanded: true,
          items: [
            for (var i = 0; i < node.options.length; i++)
              DropdownMenuItem(
                  value: i,
                  child:
                      Text(node.options[i], overflow: TextOverflow.ellipsis)),
          ],
          onChanged: node.enabled
              ? (i) =>
                  i == null ? null : _send('select', viewId: node.id, index: i)
              : null,
        );
      case 'progress':
        return LinearProgressIndicator(
          value: node.indeterminate || node.max <= 0
              ? null
              : node.value / node.max,
        );
      case 'grid':
        return LayoutBuilder(builder: (context, constraints) {
          const gap = AppSpacing.sm;
          final cols = node.columns;
          final width =
              constraints.maxWidth.isFinite ? constraints.maxWidth : 480.0;
          final itemWidth = (width - gap * (cols - 1)) / cols;
          return Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              for (final child in node.children)
                SizedBox(width: itemWidth, child: _node(context, child)),
            ],
          );
        });
      default: // group
        final children = [
          for (final child in node.children) _node(context, child)
        ];
        Widget group = node.axis == 'h'
            ? Wrap(
                spacing: AppSpacing.md,
                runSpacing: AppSpacing.sm,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: children,
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: _spaced(children),
              );
        if (node.scroll) {
          group = ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 360),
            child: SingleChildScrollView(
              scrollDirection:
                  node.axis == 'h' ? Axis.horizontal : Axis.vertical,
              child: group,
            ),
          );
        }
        final onTap = click();
        return onTap == null ? group : InkWell(onTap: onTap, child: group);
    }
  }
}
