import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../core/player/models/player_state.dart';
import '../../../core/player/playback_diagnostics.dart';
import '../../../core/player/playback_error_text.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';
import '../widgets/app_message.dart';
import '../widgets/focus_ring.dart';

/// 播放失败面板（④ 直播播放报错诊断闭环）。
///
/// 默认只显示友好文案与两个动作；「详情」渐进披露原始错误 / 脱敏地址 /
/// 请求头概览 / 引擎日志（最近 40 条），「复制诊断」把脱敏后的诊断文本
/// 写入剪贴板并给出反馈。
///
/// skill 命中（ui-ux-pro-max，`--domain ux`）：
/// - Error Messages：错误需被宣告（本面板挂 `liveRegion`）；
/// - Error Recovery：错误必须给恢复路径（文案 + 复制诊断提供可行动的下一步）；
/// - progressive disclosure：复杂信息渐进披露，不一次压给用户。
/// Flutter 栈检索无对口条目（仅命中通用布局规则），实现沿用本仓令牌与
/// FocusOutline 约定。
class PlaybackErrorPanel extends StatefulWidget {
  final String? rawError;
  final MediaPlaySpec? spec;
  final List<String> engineLogs;

  const PlaybackErrorPanel({
    super.key,
    required this.rawError,
    required this.spec,
    required this.engineLogs,
  });

  @override
  State<PlaybackErrorPanel> createState() => _PlaybackErrorPanelState();
}

class _PlaybackErrorPanelState extends State<PlaybackErrorPanel> {
  bool _expanded = false;

  void _toggleExpanded() => setState(() => _expanded = !_expanded);

  Future<void> _copyDiagnostics() async {
    final text = buildPlaybackDiagnosticText(
      rawError: widget.rawError,
      spec: widget.spec,
      engineLogs: widget.engineLogs,
    );
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    showAppMessage('诊断信息已复制', type: AppMessageType.success);
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Semantics(
      container: true,
      liveRegion: true,
      child: Container(
        width: 480,
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg, vertical: AppSpacing.md),
        decoration: BoxDecoration(
          color: palette.playerChrome,
          borderRadius: BorderRadius.circular(AppRadii.sm),
          border: Border.all(color: palette.danger.withValues(alpha: 0.5)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.error_outline_rounded,
                    size: 20, color: palette.danger),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    friendlyPlaybackError(widget.rawError),
                    style: TextStyle(
                        color: palette.playerText, fontSize: AppType.label),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                _PanelTextButton(
                  icon: _expanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  label: '详情',
                  onPressed: _toggleExpanded,
                ),
                const SizedBox(width: AppSpacing.sm),
                _PanelTextButton(
                  icon: Icons.copy_rounded,
                  label: '复制诊断',
                  onPressed: _copyDiagnostics,
                ),
              ],
            ),
            AnimatedSize(
              duration: AppMotion.enter,
              curve: AppMotion.ease,
              alignment: Alignment.topCenter,
              child:
                  _expanded ? _buildDetails(context) : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDetails(BuildContext context) {
    final palette = context.palette;
    final spec = widget.spec;
    final maskedUrl = spec == null ? null : maskSensitiveUrl(spec.url);
    final headers = maskSensitiveHeaders(spec?.headers);
    final logs = maskLogLines(
      widget.engineLogs,
      rawUrl: spec?.url,
      maskedUrl: maskedUrl,
      rawHeaders: spec?.headers,
    );
    final headerText = headers.isEmpty
        ? '(无)'
        : [for (final e in headers.entries) '${e.key}: ${e.value}'].join('\n');
    final logText = logs.isEmpty ? '(无)' : logs.join('\n');
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: AppSpacing.sm),
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: palette.playerText.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(AppRadii.xs),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 220),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _DetailRow(
                  label: '原始错误', value: _rawErrorText(), palette: palette),
              _DetailRow(
                  label: '地址', value: maskedUrl ?? '(无)', palette: palette),
              _DetailRow(label: '请求头', value: headerText, palette: palette),
              _DetailRow(
                  label: '引擎日志（最近 ${logs.length} 条）',
                  value: logText,
                  palette: palette),
            ],
          ),
        ),
      ),
    );
  }

  String _rawErrorText() {
    final raw = widget.rawError?.trim() ?? '';
    if (raw.isEmpty) return '(空)';
    // 原始错误里常带完整播放地址：与日志同口径脱敏后再展示。
    final spec = widget.spec;
    return maskDiagnosticText(
      raw,
      rawUrl: spec?.url,
      maskedUrl: spec == null ? null : maskSensitiveUrl(spec.url),
      rawHeaders: spec?.headers,
    );
  }
}

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;
  final AppPalette palette;

  const _DetailRow(
      {required this.label, required this.value, required this.palette});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: palette.playerText.withValues(alpha: 0.6),
              fontSize: AppType.caption,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          SelectableText(
            _wrapLongTokens(value),
            style: TextStyle(
              color: palette.playerText.withValues(alpha: 0.85),
              fontSize: AppType.caption,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }

  /// 长 token（URL / 哈希）插入零宽空格避免撑破面板（skill: long-token-wrapping）；
  /// 仅影响展示，复制诊断走独立文本通道不受影响。
  String _wrapLongTokens(String value) => value
      .replaceAll('/', '/\u200B')
      .replaceAll('&', '&\u200B')
      .replaceAll('?', '?\u200B');
}

/// 面板内小按钮：与播放器设置面板同款紧凑样式 + 叠画焦点描边（focus-states）。
class _PanelTextButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  const _PanelTextButton(
      {required this.icon, required this.label, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return FocusOutline(
      radius: AppRadii.pill,
      child: TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          foregroundColor: palette.playerText.withValues(alpha: 0.85),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.compact,
          overlayColor: palette.playerText.withValues(alpha: 0.12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16),
            const SizedBox(width: AppSpacing.xs),
            Text(label, style: const TextStyle(fontSize: AppType.body)),
          ],
        ),
      ),
    );
  }
}
