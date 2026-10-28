import 'package:flutter/material.dart';

import '../../../core/update/update_controller.dart';
import '../../../core/update/update_preferences.dart';
import '../../../core/update/update_service.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';
import '../widgets/focus_ring.dart';

/// 关于页的更新相关行（纯展示：状态与回调由宿主注入）。
///
/// 2026-10-27 关于页重构：只保留两行——
/// - 「当前版本 ………… v1.0.1」整行可点，点击检查更新；检查中 / 有新版本 / 下载中 / 失败显示在版本号后；
/// - 「自动检查」开关（每次启动检查一次，默认开）。
/// 更新源、镜像开关从界面移除：固定「官方 GitHub Releases，不通时自动改用镜像」。
class AboutUpdateSection extends StatelessWidget {
  final UpdatePreferences preferences;
  final UpdateUiState state;
  final String currentVersion;
  final VoidCallback onCheck;
  final ValueChanged<bool> onAutoCheckChanged;
  final VoidCallback onOpenResult;

  /// 两行之间插入的内容（构建信息），由关于页提供，保持「版本 → 构建信息 → 自动检查」的顺序。
  final Widget? between;

  const AboutUpdateSection({
    super.key,
    required this.preferences,
    required this.state,
    required this.currentVersion,
    required this.onCheck,
    required this.onAutoCheckChanged,
    required this.onOpenResult,
    this.between,
  });

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final checking = state.phase == UpdatePhase.checking;
    final result = state.result;
    final hasUpdate = result?.status == UpdateCheckStatus.available && !state.busy;
    final downloading = state.phase == UpdatePhase.downloading || state.phase == UpdatePhase.verifying;
    final failed = result?.status == UpdateCheckStatus.error && state.phase == UpdatePhase.idle;
    final upToDate = result?.status == UpdateCheckStatus.upToDate && state.phase == UpdatePhase.idle;

    final (String? status, Color statusColor) = checking
        ? ('检查中…', palette.textSub)
        : downloading
            ? (
                state.phase == UpdatePhase.verifying
                    ? '正在校验安装包…'
                    : '正在下载 ${(state.progress * 100).toStringAsFixed(0)}%',
                palette.textSub
              )
            : hasUpdate
                ? ('有新版本 ${result?.manifest?.tag ?? ''}', palette.accentInk)
                : failed
                    ? ('检查失败，点击重试', palette.warning)
                    : upToDate
                        ? ('已是最新', palette.textSub)
                        : (null, palette.textSub);

    final version = currentVersion.startsWith('v') ? currentVersion : 'v$currentVersion';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AboutLine(
          key: const ValueKey('about-check-update'),
          label: '当前版本',
          tooltip: hasUpdate || downloading ? '查看更新' : '点击检查更新',
          // 有结果（新版本 / 下载中）时点开结果弹窗；否则发起检查
          onTap: checking ? null : (hasUpdate || downloading ? onOpenResult : onCheck),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (status != null) ...[
                if (checking)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(strokeWidth: 1.6, color: palette.textSub)),
                  ),
                Text(status,
                    key: const ValueKey('about-update-status'),
                    style: TextStyle(fontSize: AppType.body, color: statusColor)),
                const SizedBox(width: 10),
              ],
              Text(version,
                  key: const ValueKey('about-version'),
                  style: TextStyle(fontSize: AppType.label, color: palette.textMain, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
        if (between != null) between!,
        AboutLine(
          label: '自动检查',
          description: '每次启动时检查一次更新；官方地址不通时自动改用镜像下载',
          trailing: Switch(
            key: const ValueKey('about-auto-check'),
            value: preferences.autoCheck,
            onChanged: onAutoCheckChanged,
          ),
        ),
      ],
    );
  }
}

/// 关于页的一行：左标签（可带说明）· 中间虚线引导 · 右侧值 / 控件。整行可点（[onTap] / [onLongPress]）。
class AboutLine extends StatelessWidget {
  const AboutLine({
    super.key,
    required this.label,
    this.description,
    this.trailing,
    this.onTap,
    this.onLongPress,
    this.tooltip,
    this.danger = false,
    this.leader = true,
  });

  final String label;
  final String? description;
  final Widget? trailing;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final String? tooltip;
  final bool danger;

  /// 标签与值之间的虚线（「当前版本 -------- v1.0.1」）；有说明文字的行不画
  final bool leader;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final clickable = onTap != null || onLongPress != null;
    final labelStyle = TextStyle(
      fontSize: AppType.label,
      fontWeight: FontWeight.w600,
      color: danger ? palette.danger : palette.textMain,
    );
    Widget row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      child: Row(
        children: [
          if (description == null)
            Text(label, style: labelStyle)
          else
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: labelStyle),
                  const SizedBox(height: 3),
                  Text(description!,
                      style: TextStyle(fontSize: AppType.body, height: 1.4, color: palette.textSub)),
                ],
              ),
            ),
          if (description == null)
            Expanded(
              child: leader && trailing != null
                  ? Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: CustomPaint(
                        size: const Size(double.infinity, 1),
                        painter: _DashPainter(palette.divider),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          if (description != null) const SizedBox(width: 16),
          if (trailing != null) trailing!,
          if (clickable && trailing == null)
            Icon(Icons.chevron_right_rounded, size: 18, color: palette.textDim),
        ],
      ),
    );
    if (!clickable) return row;
    row = FocusOutline(
      radius: AppRadii.sm,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadii.sm),
          onTap: onTap,
          onLongPress: onLongPress,
          child: row,
        ),
      ),
    );
    return tooltip == null ? row : Tooltip(message: tooltip!, waitDuration: const Duration(milliseconds: 500), child: row);
  }
}

class _DashPainter extends CustomPainter {
  _DashPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    const dash = 3.0, gap = 3.0;
    for (var x = 0.0; x < size.width; x += dash + gap) {
      canvas.drawLine(Offset(x, 0), Offset((x + dash).clamp(0, size.width), 0), paint);
    }
  }

  @override
  bool shouldRepaint(_DashPainter old) => old.color != color;
}
