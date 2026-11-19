import 'package:flutter/material.dart';

import '../../../core/config/config_credentials.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';

/// 配置源要求认证时出现的账号密码弹窗。
///
/// 只在加载真的拿到 401 时才出现（不做独立页面）：与 Fongmi 壳子的行为一致，
/// 用户看到的仍然只是「填地址 → 加载」这一条路径。
class ConfigAuthDialog extends StatefulWidget {
  const ConfigAuthDialog({
    super.key,
    required this.host,
    this.rejected = false,
    this.initialUsername,
    this.initialPassword,
  });

  /// 需要认证的主机名（不含端口）。
  final String host;

  /// 上一轮输入被服务端拒绝：标题与提示改为「账号或密码错误」。
  final bool rejected;

  /// 回填上次用过的用户名；为空时默认 `guest`。
  final String? initialUsername;

  /// 回填上次用过的密码（明文，仅本机使用）。
  final String? initialPassword;

  @override
  State<ConfigAuthDialog> createState() => _ConfigAuthDialogState();
}

class _ConfigAuthDialogState extends State<ConfigAuthDialog> {
  late final TextEditingController _username;
  late final TextEditingController _password;
  String? _error;

  @override
  void initState() {
    super.initState();
    final username = widget.initialUsername?.trim();
    _username =
        TextEditingController(text: (username == null || username.isEmpty) ? 'guest' : username);
    _password = TextEditingController(text: widget.initialPassword ?? '');
  }

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  void _submit() {
    final username = _username.text.trim();
    if (username.isEmpty) {
      setState(() => _error = '请输入用户名');
      return;
    }
    Navigator.of(context).pop(ConfigCredentials(
      host: widget.host,
      username: username,
      password: _password.text,
    ));
  }

  InputDecoration _decoration(String hint) => InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: context.palette.textDim),
        filled: true,
        fillColor: context.palette.raised,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.sm),
          borderSide: BorderSide(color: context.palette.borderStrong),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      );

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: context.palette.raised,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadii.lg)),
      title: Text(
        widget.rejected ? '账号或密码错误' : '需要账号密码',
        style: TextStyle(
            fontSize: AppType.heading,
            color: context.palette.textTitle,
            fontWeight: FontWeight.bold),
      ),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${widget.host} 返回 401，需要 HTTP 认证。'
              '小雅可用的用户名是 dav 或 guest，密码见 guestpass.txt（默认 guest_Api789）。',
              style: TextStyle(
                  fontSize: AppType.label,
                  height: 1.4,
                  color: context.palette.textBody),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _username,
              autofocus: true,
              style: TextStyle(
                  fontSize: AppType.label, color: context.palette.textMain),
              decoration: _decoration('用户名'),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _password,
              obscureText: true,
              style: TextStyle(
                  fontSize: AppType.label, color: context.palette.textMain),
              decoration: _decoration('密码'),
              onSubmitted: (_) => _submit(),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!,
                  style: TextStyle(
                      fontSize: AppType.body, color: context.palette.danger)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('取消', style: TextStyle(color: context.palette.textSub)),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: context.palette.accent,
            foregroundColor: Theme.of(context).colorScheme.onPrimary,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadii.sm)),
          ),
          onPressed: _submit,
          child: const Text('连接',
              style: TextStyle(fontWeight: FontWeight.bold)),
        ),
      ],
    );
  }
}
