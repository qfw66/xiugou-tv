import 'package:flutter/material.dart';

import '../../../core/api/models/vod_models.dart';
import 'vod_detail_dialog.dart';

class SiteInformationDialog extends StatefulWidget {
  const SiteInformationDialog({
    super.key,
    required this.item,
    required this.onOpenUrl,
    this.webUrl,
  });

  final VodItem item;
  final Future<bool> Function(String url) onOpenUrl;
  final String? webUrl;

  @override
  State<SiteInformationDialog> createState() => _SiteInformationDialogState();
}

class _SiteInformationDialogState extends State<SiteInformationDialog> {
  bool _opening = false;
  String? _error;

  Future<void> _open(String url) async {
    setState(() {
      _opening = true;
      _error = null;
    });
    var opened = false;
    try {
      opened = await widget.onOpenUrl(url);
    } catch (_) {
      opened = false;
    }
    if (!mounted) return;
    setState(() {
      _opening = false;
      if (!opened) _error = '打开失败，请复制上方地址到浏览器中打开';
    });
  }

  @override
  Widget build(BuildContext context) {
    final content = widget.item.content?.trim() ?? '';
    final url = widget.webUrl ?? localConfigCenterUrlOf(content);
    return AlertDialog(
      key: const ValueKey('site-information-dialog'),
      title: Text(widget.item.name.isEmpty ? '站源提示' : widget.item.name),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(content.isEmpty ? '此项目没有可播放的选集' : content),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        if (url != null)
          TextButton.icon(
            onPressed: _opening ? null : () => _open(url),
            icon: const Icon(Icons.open_in_browser_rounded),
            label: Text(_opening ? '正在打开…' : '打开网页配置'),
          ),
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭')),
      ],
    );
  }
}
