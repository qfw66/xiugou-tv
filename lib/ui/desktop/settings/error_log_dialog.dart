import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/diagnostics/error_log.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';
import '../widgets/app_message.dart';

/// 关于页「错误日志」查看器（应用内弹窗；只含本次打开期间的记录，关闭软件即清空）。
Future<void> showErrorLogDialog(BuildContext context, ErrorLog log) => showDialog<void>(
      context: context,
      builder: (ctx) => _ErrorLogDialog(log: log),
    );

class _ErrorLogDialog extends StatelessWidget {
  const _ErrorLogDialog({required this.log});
  final ErrorLog log;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Dialog(
      backgroundColor: palette.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadii.md)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760, maxHeight: 560),
        child: ListenableBuilder(
          listenable: log,
          builder: (context, _) {
            final entries = log.entries.reversed.toList(); // 新的在上
            return Column(
              key: const ValueKey('error-log-dialog'),
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
                  child: Row(
                    children: [
                      Text('错误日志',
                          style: TextStyle(
                              fontSize: AppType.heading, fontWeight: FontWeight.bold, color: palette.textTitle)),
                      const SizedBox(width: 10),
                      Text(entries.isEmpty ? '本次运行暂无错误' : '本次运行 ${entries.length} 条（关闭软件后清空）',
                          style: TextStyle(fontSize: AppType.body, color: palette.textSub)),
                      const Spacer(),
                      TextButton.icon(
                        key: const ValueKey('error-log-copy'),
                        onPressed: entries.isEmpty
                            ? null
                            : () async {
                                await Clipboard.setData(ClipboardData(text: log.text));
                                showAppMessage('已复制错误日志', type: AppMessageType.success);
                              },
                        icon: const Icon(Icons.copy_rounded, size: 16),
                        label: const Text('复制全部'),
                      ),
                      TextButton.icon(
                        key: const ValueKey('error-log-clear'),
                        onPressed: entries.isEmpty ? null : log.clear,
                        icon: const Icon(Icons.delete_outline_rounded, size: 16),
                        label: const Text('清除'),
                      ),
                      IconButton(
                        tooltip: '关闭',
                        icon: Icon(Icons.close_rounded, color: palette.textSub),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: palette.divider),
                Flexible(
                  child: entries.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.all(40),
                          child: Center(
                            child: Text('没有错误，一切正常',
                                style: TextStyle(fontSize: AppType.label, color: palette.textSub)),
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          shrinkWrap: true,
                          itemCount: entries.length,
                          separatorBuilder: (_, __) =>
                              Divider(height: 1, indent: 20, endIndent: 20, color: palette.divider),
                          itemBuilder: (context, i) => _EntryTile(entry: entries[i]),
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.entry});
  final ErrorLogEntry entry;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final mono = TextStyle(
      fontSize: AppType.caption,
      color: palette.textSub,
      fontFamily: 'Consolas',
      fontFamilyFallback: const ['Courier New', 'monospace'],
      height: 1.45,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Text(entry.timeText,
                style: TextStyle(
                    fontSize: AppType.body,
                    color: palette.textSub,
                    fontFeatures: const [FontFeature.tabularFigures()])),
            const SizedBox(width: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: palette.danger.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(AppRadii.xs),
              ),
              child: Text(entry.source, style: TextStyle(fontSize: AppType.caption, color: palette.danger)),
            ),
          ]),
          const SizedBox(height: 4),
          SelectableText(entry.message, style: TextStyle(fontSize: AppType.body, color: palette.textMain)),
          if (entry.stack != null)
            Theme(
              data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                dense: true,
                visualDensity: VisualDensity.compact,
                title: Text('堆栈', style: TextStyle(fontSize: AppType.caption, color: palette.textSub)),
                children: [
                  Align(alignment: Alignment.centerLeft, child: SelectableText(entry.stack!, style: mono)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
