import 'package:flutter/material.dart';

import '../../../core/update/update_controller.dart';
import '../../../core/update/update_preferences.dart';
import '../../../core/update/update_service.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';
import '../widgets/focus_ring.dart';

/// 关于页的更新区块（纯展示：状态与回调由宿主注入）。
class AboutUpdateSection extends StatelessWidget {
  final UpdatePreferences preferences;
  final UpdateUiState state;
  final String currentVersion;
  final VoidCallback onCheck;
  final VoidCallback onEditSource;
  final ValueChanged<bool> onAutoCheckChanged;
  final ValueChanged<bool> onUseMirrorChanged;
  final VoidCallback onClearSkipped;
  final VoidCallback onOpenResult;

  const AboutUpdateSection({
    super.key,
    required this.preferences,
    required this.state,
    required this.currentVersion,
    required this.onCheck,
    required this.onEditSource,
    required this.onAutoCheckChanged,
    required this.onUseMirrorChanged,
    required this.onClearSkipped,
    required this.onOpenResult,
  });

  @override
  Widget build(BuildContext context) {
    final checking = state.phase == UpdatePhase.checking;
    final result = state.result;
    final hasUpdate =
        result?.status == UpdateCheckStatus.available && !state.busy;
    final downloading = state.phase == UpdatePhase.downloading ||
        state.phase == UpdatePhase.verifying;
    final skipped = preferences.skippedVersion;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          SizedBox(
              width: 88,
              child: Text('版本',
                  style: TextStyle(
                      fontSize: AppType.label,
                      color: context.palette.textSub))),
          Expanded(
              child: Text(currentVersion,
                  style: TextStyle(
                      fontSize: AppType.label,
                      color: context.palette.textMain))),
          FocusOutline(
            radius: AppRadii.pill,
            child: TextButton(
              key: const ValueKey('about-check-update'),
              onPressed: checking ? null : onCheck,
              child: Text(checking ? '检查中…' : '检查更新',
                  style: const TextStyle(fontSize: AppType.label)),
            ),
          ),
        ]),
        if (hasUpdate)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Row(children: [
              Icon(Icons.new_releases_outlined,
                  size: 15, color: context.palette.accentInk),
              const SizedBox(width: 6),
              Text('有新版本 ${result?.manifest?.tag ?? ''}',
                  style: TextStyle(
                      fontSize: AppType.body,
                      color: context.palette.accentInk)),
              FocusOutline(
                radius: AppRadii.pill,
                child: TextButton(
                  onPressed: onOpenResult,
                  child: const Text('查看',
                      style: TextStyle(fontSize: AppType.label)),
                ),
              ),
            ]),
          ),
        if (downloading)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Row(children: [
              Icon(Icons.downloading_outlined,
                  size: 15, color: context.palette.textSub),
              const SizedBox(width: 6),
              Text(
                  state.phase == UpdatePhase.verifying
                      ? '正在校验安装包…'
                      : '正在下载安装包 ${(state.progress * 100).toStringAsFixed(0)}%',
                  style: TextStyle(
                      fontSize: AppType.body, color: context.palette.textSub)),
              FocusOutline(
                radius: AppRadii.pill,
                child: TextButton(
                  onPressed: onOpenResult,
                  child: const Text('查看',
                      style: TextStyle(fontSize: AppType.label)),
                ),
              ),
            ]),
          ),
        Row(children: [
          SizedBox(
              width: 88,
              child: Text('更新源',
                  style: TextStyle(
                      fontSize: AppType.label,
                      color: context.palette.textSub))),
          Expanded(
            child: Text(
              preferences.source.isEmpty
                  ? (preferences.useMirror
                      ? '官方（GitHub Releases）+ 镜像兜底'
                      : '官方（GitHub Releases）')
                  : '自定义：${Uri.tryParse(preferences.source)?.host ?? preferences.source}',
              style: TextStyle(
                  fontSize: AppType.label, color: context.palette.textMain),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          FocusOutline(
            radius: AppRadii.pill,
            child: TextButton(
              onPressed: onEditSource,
              child:
                  const Text('更改', style: TextStyle(fontSize: AppType.label)),
            ),
          ),
        ]),
        if (result?.sourceLabel != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Row(children: [
              const SizedBox(width: 88),
              Icon(Icons.cloud_outlined,
                  size: 14, color: context.palette.textSub),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '上次来源：${result!.sourceLabel}'
                  '${result.viaMirror ? '（摘要同源，仅供参考）' : ''}',
                  style: TextStyle(
                      fontSize: AppType.body, color: context.palette.textSub),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ]),
          ),
        Row(children: [
          SizedBox(
              width: 88,
              child: Text('自动检查',
                  style: TextStyle(
                      fontSize: AppType.label,
                      color: context.palette.textSub))),
          Expanded(
            child: Text('每次启动检查一次',
                style: TextStyle(
                    fontSize: AppType.body, color: context.palette.textSub)),
          ),
          Switch(
            key: const ValueKey('about-auto-check'),
            value: preferences.autoCheck,
            onChanged: onAutoCheckChanged,
          ),
        ]),
        Row(children: [
          SizedBox(
              width: 88,
              child: Text('镜像加速',
                  style: TextStyle(
                      fontSize: AppType.label,
                      color: context.palette.textSub))),
          Expanded(
            child: Text(
              preferences.useMirror
                  ? '官方不通时改用镜像下载'
                  : '只用官方直连',
              style: TextStyle(
                  fontSize: AppType.body, color: context.palette.textSub),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Switch(
            key: const ValueKey('about-mirror-enabled'),
            value: preferences.useMirror,
            onChanged: onUseMirrorChanged,
          ),
        ]),
        if (skipped != null)
          Row(children: [
            Icon(Icons.visibility_off_outlined,
                size: 14, color: context.palette.textSub),
            const SizedBox(width: 6),
            Text('已跳过：$skipped',
                style: TextStyle(
                    fontSize: AppType.body, color: context.palette.textSub)),
            FocusOutline(
              radius: AppRadii.pill,
              child: TextButton(
                onPressed: onClearSkipped,
                child: const Text('取消跳过',
                    style: TextStyle(fontSize: AppType.label)),
              ),
            ),
          ]),
        if (result?.status == UpdateCheckStatus.error &&
            state.phase == UpdatePhase.idle)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('上次检查失败：${result?.failure ?? ''}',
                style: TextStyle(
                    fontSize: AppType.body, color: context.palette.textSub)),
          ),
      ],
    );
  }
}
