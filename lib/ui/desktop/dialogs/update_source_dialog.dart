import 'package:flutter/material.dart';

import '../../../core/update/update_preferences.dart';
import '../../../core/update/update_service.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';

/// 更新源设置（纯展示：保存动作由宿主注入）。
class UpdateSourceDialog extends StatefulWidget {
  final String initialSource;
  final Future<void> Function(String source) onSave;

  const UpdateSourceDialog({
    super.key,
    required this.initialSource,
    required this.onSave,
  });

  @override
  State<UpdateSourceDialog> createState() => _UpdateSourceDialogState();
}

class _UpdateSourceDialogState extends State<UpdateSourceDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialSource);
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final value = _controller.text.trim();
    if (!UpdatePreferences.isValidSource(value)) {
      setState(() => _error = '请输入 https:// 开头的地址，或留空使用官方源');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    await widget.onSave(value);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Dialog(
      backgroundColor: palette.panel,
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.lg),
        side: BorderSide(color: palette.border),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(Icons.cloud_sync_outlined,
                    color: palette.accentInk, size: 22),
                const SizedBox(width: 10),
                Text('更新源',
                    style: TextStyle(
                        fontSize: AppType.heading,
                        fontWeight: FontWeight.bold,
                        color: palette.textTitle)),
                const Spacer(),
                IconButton(
                  tooltip: '关闭',
                  onPressed: _saving ? null : () => Navigator.of(context).pop(),
                  icon: Icon(Icons.close, color: palette.textSub),
                ),
              ]),
              const SizedBox(height: 8),
              Text(
                '留空使用官方 GitHub Releases。若官方地址访问不了，可填写镜像提供的清单地址'
                '（https:// 开头，返回 GitHub API 同形状 JSON 或精简清单均可）。',
                style: TextStyle(
                    fontSize: AppType.body,
                    height: 1.5,
                    color: palette.textSub),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _controller,
                autofocus: true,
                style:
                    TextStyle(fontSize: AppType.label, color: palette.textMain),
                decoration: InputDecoration(
                  hintText: 'https://mirror.example.com/xiugou-tv/latest.json',
                  hintStyle:
                      TextStyle(fontSize: AppType.body, color: palette.textDim),
                  errorText: _error,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: palette.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: palette.accentInk),
                  ),
                ),
                onChanged: (_) {
                  if (_error != null) setState(() => _error = null);
                },
                onSubmitted: (_) => _save(),
              ),
              const SizedBox(height: 14),
              Row(children: [
                TextButton(
                  onPressed: _saving
                      ? null
                      : () {
                          _controller.text = '';
                          _save();
                        },
                  child: const Text('恢复默认'),
                ),
                const Spacer(),
                TextButton(
                  onPressed: _saving ? null : () => Navigator.of(context).pop(),
                  child: const Text('取消'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _saving ? null : _save,
                  child: Text(_saving ? '保存中…' : '保存'),
                ),
              ]),
              const SizedBox(height: 4),
              Text('官方源：${Uri.parse(officialUpdateSourceUrl).host}',
                  style: TextStyle(
                      fontSize: AppType.caption, color: palette.textDim)),
            ],
          ),
        ),
      ),
    );
  }
}
