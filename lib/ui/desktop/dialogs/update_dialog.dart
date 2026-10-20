import 'package:flutter/material.dart';

import '../../../core/update/update_controller.dart';
import '../../../core/update/update_service.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';

/// 更新对话框（纯展示：状态与回调由 [UpdateDialogHost] 注入，便于测试）。
class UpdateDialog extends StatelessWidget {
  final UpdateUiState state;
  final String currentVersion;
  final bool isPortable;
  final bool skipped;
  final VoidCallback onDownload;
  final VoidCallback onCancelDownload;
  final VoidCallback onInstall;
  final VoidCallback onSkip;
  final VoidCallback onClearSkip;
  final VoidCallback onRetry;
  final VoidCallback onClose;
  final VoidCallback onOpenReleasePage;
  final VoidCallback onOpenFolder;

  const UpdateDialog({
    super.key,
    required this.state,
    required this.currentVersion,
    required this.isPortable,
    required this.skipped,
    required this.onDownload,
    required this.onCancelDownload,
    required this.onInstall,
    required this.onSkip,
    required this.onClearSkip,
    required this.onRetry,
    required this.onClose,
    required this.onOpenReleasePage,
    required this.onOpenFolder,
  });

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final result = state.result;
    final busy = state.busy;
    return PopScope<void>(
      canPop: !busy,
      child: Dialog(
        backgroundColor: palette.panel,
        insetPadding: const EdgeInsets.all(24),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.lg),
          side: BorderSide(color: palette.borderStrong),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _header(context, palette),
                const SizedBox(height: 18),
                if (result == null)
                  _checkingBody(palette)
                else
                  _body(result, palette),
                const SizedBox(height: 18),
                _footer(result, busy, palette),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(BuildContext context, AppPalette palette) {
    final (title, subtitle) = switch (state.result?.status) {
      null => ('检查更新', '正在读取发布信息…'),
      UpdateCheckStatus.error => ('检查更新失败', '更新源暂时不可用'),
      UpdateCheckStatus.upToDate => ('已是最新版本', '当前 $currentVersion'),
      UpdateCheckStatus.ignoredPrerelease => ('暂无正式版更新', '已忽略预发布版本'),
      UpdateCheckStatus.noInstaller => ('该版本未提供安装版', '可到发布页手动下载'),
      UpdateCheckStatus.cancelled => ('检查已取消', ''),
      UpdateCheckStatus.available => (
          '发现新版本 ${state.result?.manifest?.tag ?? ''}',
          '当前 $currentVersion'
        ),
    };
    return Row(
      children: [
        Icon(Icons.system_update_rounded, color: palette.accentInk, size: 26),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: TextStyle(
                      fontSize: AppType.h2,
                      fontWeight: FontWeight.bold,
                      color: palette.textTitle)),
              if (subtitle.isNotEmpty)
                Text(subtitle,
                    style: TextStyle(
                        fontSize: AppType.body, color: palette.textSub)),
            ],
          ),
        ),
        IconButton(
          tooltip: state.busy ? '下载中无法关闭，请先取消' : '关闭',
          onPressed: state.busy ? null : onClose,
          icon: Icon(Icons.close, color: palette.textSub),
        ),
      ],
    );
  }

  Widget _checkingBody(AppPalette palette) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(children: [
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
                strokeWidth: 2, color: palette.accentInk),
          ),
          const SizedBox(width: 12),
          Text('正在检查更新…',
              style:
                  TextStyle(fontSize: AppType.label, color: palette.textSub)),
        ]),
      );

  Widget _body(UpdateCheckResult result, AppPalette palette) {
    switch (result.status) {
      case UpdateCheckStatus.error:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(result.failure ?? '检查更新失败',
                style: TextStyle(
                    fontSize: AppType.label, color: palette.textMain)),
            if (result.sourceHost != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('更新源：${result.sourceHost}',
                    style: TextStyle(
                        fontSize: AppType.body, color: palette.textDim)),
              ),
            const SizedBox(height: 14),
            Row(children: [
              FilledButton(onPressed: onRetry, child: const Text('重试')),
              const SizedBox(width: 8),
              TextButton(onPressed: onClose, child: const Text('关闭')),
            ]),
          ],
        );
      case UpdateCheckStatus.upToDate:
      case UpdateCheckStatus.ignoredPrerelease:
      case UpdateCheckStatus.cancelled:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
                result.status == UpdateCheckStatus.ignoredPrerelease
                    ? '最新发布是预发布版本（${result.manifest?.tag ?? ''}），已按设置跳过。'
                    : '当前已是最新版本（$currentVersion），无需更新。',
                style: TextStyle(
                    fontSize: AppType.label, color: palette.textMain)),
            const SizedBox(height: 14),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(onPressed: onClose, child: const Text('关闭')),
            ),
          ],
        );
      case UpdateCheckStatus.noInstaller:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
                '${result.manifest?.tag ?? ''} 只提供了便携版压缩包，无法自动安装。'
                '请到发布页下载后手动替换。',
                style: TextStyle(
                    fontSize: AppType.label, color: palette.textMain)),
            const SizedBox(height: 14),
            Row(children: [
              FilledButton(
                  onPressed: onOpenReleasePage, child: const Text('打开发布页')),
              const SizedBox(width: 8),
              TextButton(onPressed: onClose, child: const Text('关闭')),
            ]),
          ],
        );
      case UpdateCheckStatus.available:
        return _availableBody(result, palette);
    }
  }

  Widget _availableBody(UpdateCheckResult result, AppPalette palette) {
    final manifest = result.manifest!;
    final asset = result.installer!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _infoRow('新版本', manifest.tag, palette),
        _infoRow('当前版本', currentVersion, palette),
        if (manifest.publishedAt != null)
          _infoRow('发布时间', _formatDate(manifest.publishedAt!), palette),
        _infoRow('安装包大小', asset.size == null ? '未知' : _formatBytes(asset.size!),
            palette),
        if (skipped)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(children: [
              Icon(Icons.visibility_off_outlined,
                  size: 15, color: palette.textDim),
              const SizedBox(width: 6),
              Text('已跳过此版本（自动检查不再提示）',
                  style: TextStyle(
                      fontSize: AppType.body, color: palette.textDim)),
              TextButton(
                  onPressed: onClearSkip,
                  child: const Text('取消跳过',
                      style: TextStyle(fontSize: AppType.body))),
            ]),
          ),
        const SizedBox(height: 10),
        _notes(manifest.notes, palette),
        const SizedBox(height: 14),
        _progressOrButtons(asset.size, palette),
      ],
    );
  }

  Widget _infoRow(String label, String value, AppPalette palette) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          SizedBox(
              width: 88,
              child: Text(label,
                  style: TextStyle(
                      fontSize: AppType.body, color: palette.textSub))),
          Expanded(
              child: Text(value,
                  style: TextStyle(
                      fontSize: AppType.label, color: palette.textMain))),
        ]),
      );

  Widget _notes(String notes, AppPalette palette) {
    final text = notes.trim();
    if (text.isEmpty) {
      return Text('（该版本没有填写更新说明）',
          style: TextStyle(fontSize: AppType.body, color: palette.textDim));
    }
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 220),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: palette.raised,
        borderRadius: BorderRadius.circular(AppRadii.md),
        border: Border.all(color: palette.borderStrong),
      ),
      child: SingleChildScrollView(
        child: SelectableText(
          text.length > 4000
              ? '${text.substring(0, 4000)}\n\n……（说明过长，完整内容见发布页）'
              : text,
          style: TextStyle(
              fontSize: AppType.body, height: 1.55, color: palette.textMain),
        ),
      ),
    );
  }

  Widget _progressOrButtons(int? assetSize, AppPalette palette) {
    if (state.phase == UpdatePhase.downloading) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadii.xs),
            child: LinearProgressIndicator(
              value: state.progress <= 0 ? null : state.progress,
              minHeight: 6,
              backgroundColor: palette.border,
              color: palette.accentInk,
            ),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Text(_progressText(assetSize),
                style:
                    TextStyle(fontSize: AppType.body, color: palette.textSub)),
            const Spacer(),
            TextButton(onPressed: onCancelDownload, child: const Text('取消')),
          ]),
        ],
      );
    }
    if (state.phase == UpdatePhase.verifying) {
      return Row(children: [
        SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
                strokeWidth: 2, color: palette.accentInk)),
        const SizedBox(width: 10),
        Text('正在校验安装包…',
            style: TextStyle(fontSize: AppType.body, color: palette.textSub)),
      ]);
    }
    if (state.phase == UpdatePhase.ready) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.verified_outlined, size: 16, color: palette.success),
            const SizedBox(width: 6),
            Text('校验通过（SHA-256），可安装',
                style:
                    TextStyle(fontSize: AppType.body, color: palette.success)),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            FilledButton(onPressed: onInstall, child: const Text('立即安装并退出')),
            const SizedBox(width: 8),
            TextButton(onPressed: onOpenFolder, child: const Text('打开所在文件夹')),
            const SizedBox(width: 8),
            TextButton(onPressed: onClose, child: const Text('稍后')),
          ]),
          const SizedBox(height: 8),
          Text('安装程序启动后本应用会退出；安装向导按提示下一步即可。',
              style: TextStyle(fontSize: AppType.body, color: palette.textDim)),
        ],
      );
    }

    if (isPortable) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('当前是便携版，无法自动升级。请下载压缩包后手动替换程序目录。',
              style:
                  TextStyle(fontSize: AppType.label, color: palette.textMain)),
          const SizedBox(height: 12),
          Row(children: [
            FilledButton(
                onPressed: onOpenReleasePage, child: const Text('打开发布页')),
            const SizedBox(width: 8),
            TextButton(onPressed: onClose, child: const Text('稍后')),
          ]),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (state.downloadError != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(state.downloadError!,
                style:
                    TextStyle(fontSize: AppType.body, color: palette.danger)),
          ),
        Row(children: [
          FilledButton(onPressed: onDownload, child: const Text('下载并安装')),
          const SizedBox(width: 8),
          TextButton(onPressed: onSkip, child: const Text('跳过此版本')),
          const SizedBox(width: 8),
          TextButton(onPressed: onClose, child: const Text('稍后')),
        ]),
        const SizedBox(height: 8),
        Text('安装包会下载到数据目录的 updates 文件夹，校验通过后才会启动安装程序。',
            style: TextStyle(fontSize: AppType.body, color: palette.textDim)),
      ],
    );
  }

  Widget _footer(UpdateCheckResult? result, bool busy, AppPalette palette) {
    if (busy || result?.status != UpdateCheckStatus.available || isPortable) {
      return const SizedBox.shrink();
    }
    return Text('未签名的安装包可能触发 Windows SmartScreen 提示，选择「仍要运行」即可。',
        style: TextStyle(fontSize: AppType.caption, color: palette.textDim));
  }

  String _progressText(int? assetSize) {
    final total = state.total > 0 ? state.total : assetSize ?? 0;
    if (total <= 0) return '已下载 ${_formatBytes(state.received)}';
    final percent = (state.progress * 100).toStringAsFixed(0);
    return '${_formatBytes(state.received)} / ${_formatBytes(total)}（$percent%）';
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  static String _formatDate(DateTime value) {
    final local = value.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}
