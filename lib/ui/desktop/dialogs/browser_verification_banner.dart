import 'package:flutter/material.dart';

import '../../../core/companion/browser_verification_request.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';

class BrowserVerificationBanner extends StatefulWidget {
  const BrowserVerificationBanner({
    super.key,
    required this.request,
    required this.command,
    required this.onVerified,
    required this.onCancel,
  });

  final BrowserVerificationRequest request;
  final Future<String> Function(String operation) command;
  final Future<void> Function() onVerified;
  final Future<void> Function() onCancel;

  @override
  State<BrowserVerificationBanner> createState() =>
      _BrowserVerificationBannerState();
}

class _BrowserVerificationBannerState extends State<BrowserVerificationBanner> {
  bool _busy = false;
  bool _opened = false;
  String? _message;
  int _epoch = 0;

  @override
  void didUpdateWidget(BrowserVerificationBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.request.id != widget.request.id ||
        oldWidget.request.site.key != widget.request.site.key) {
      _epoch++;
      _busy = false;
      _opened = false;
      _message = null;
    }
  }

  Future<void> _run(String operation) async {
    final epoch = ++_epoch;
    final onVerified = widget.onVerified;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final state = await widget.command(operation);
      if (!mounted || epoch != _epoch) return;
      if (state == 'verified') {
        await onVerified();
      } else {
        setState(() {
          _opened = state == 'waiting';
          _message = operation == 'complete'
              ? '尚未完成验证，请在网页中完成后再试'
              : '请在网页中完成验证，保留该窗口并返回这里继续';
        });
      }
    } catch (_) {
      if (mounted && epoch == _epoch) {
        setState(() => _message = operation == 'open'
            ? '无法打开验证窗口，请确认已安装 Edge 或 Chrome 后重试'
            : '验证检查失败，请确认网页窗口仍打开后重试');
      }
    } finally {
      if (mounted && epoch == _epoch) setState(() => _busy = false);
    }
  }

  Future<void> _cancel() async {
    _epoch++;
    await widget.onCancel();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 600),
      child: Material(
        key: const ValueKey('browser-verification-banner'),
        elevation: 8,
        color: palette.card,
        borderRadius: BorderRadius.circular(AppRadii.md),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(Icons.verified_user_outlined, color: palette.accentInk),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                    child: Text('${widget.request.site.name}需要网页验证',
                        style: TextStyle(
                            color: palette.textTitle,
                            fontWeight: FontWeight.w600))),
              ]),
              const SizedBox(height: AppSpacing.sm),
              Text(widget.request.origin.host,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: palette.textSub)),
              const SizedBox(height: AppSpacing.sm),
              Text(_message ?? '在独立网页窗口中手动完成站点验证，然后返回重试。',
                  key: const ValueKey('browser-verification-status'),
                  style: TextStyle(color: palette.textBody)),
              const SizedBox(height: AppSpacing.md),
              Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.sm,
                  children: [
                    FilledButton.icon(
                      key: const ValueKey('browser-verification-open'),
                      onPressed: _busy ? null : () => _run('open'),
                      icon: const Icon(Icons.open_in_browser_rounded, size: 18),
                      label: Text(_busy
                          ? '正在处理…'
                          : _opened
                              ? '重新打开网页'
                              : '打开验证网页'),
                    ),
                    if (_opened)
                      OutlinedButton(
                        key: const ValueKey('browser-verification-complete'),
                        onPressed: _busy ? null : () => _run('complete'),
                        child: const Text('验证完成并重试'),
                      ),
                    TextButton(
                      key: const ValueKey('browser-verification-cancel'),
                      onPressed: _cancel,
                      child: const Text('取消'),
                    ),
                  ]),
            ],
          ),
        ),
      ),
    );
  }
}
