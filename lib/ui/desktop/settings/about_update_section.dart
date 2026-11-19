import 'package:flutter/material.dart';

import '../../../core/update/update_controller.dart';
import '../../../core/update/update_preferences.dart';
import '../../../core/update/update_service.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';
import '../widgets/focus_ring.dart';

/// 关于页的更新相关行（纯展示：状态与回调由宿主注入）。
///
/// 版本检查、启动检查开关与更新下载镜像设置。
class AboutUpdateSection extends StatelessWidget {
  final UpdatePreferences preferences;
  final UpdateUiState state;
  final String currentVersion;
  final VoidCallback onCheck;
  final ValueChanged<bool> onAutoCheckChanged;
  final VoidCallback onOpenResult;
  final VoidCallback? onMirrorSettings;

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
    this.onMirrorSettings,
  });

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final checking = state.phase == UpdatePhase.checking;
    final result = state.result;
    final hasUpdate =
        result?.status == UpdateCheckStatus.available && !state.busy;
    final downloading = state.phase == UpdatePhase.downloading ||
        state.phase == UpdatePhase.verifying;
    final failed = result?.status == UpdateCheckStatus.error &&
        state.phase == UpdatePhase.idle;
    final upToDate = result?.status == UpdateCheckStatus.upToDate &&
        state.phase == UpdatePhase.idle;

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

    final version =
        currentVersion.startsWith('v') ? currentVersion : 'v$currentVersion';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AboutLine(
          key: const ValueKey('about-check-update'),
          label: '当前版本',
          tooltip: hasUpdate || downloading ? '查看更新' : '点击检查更新',
          // 有结果（新版本 / 下载中）时点开结果弹窗；否则发起检查
          onTap: checking
              ? null
              : (hasUpdate || downloading ? onOpenResult : onCheck),
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
                        child: CircularProgressIndicator(
                            strokeWidth: 1.6, color: palette.textSub)),
                  ),
                Text(status,
                    key: const ValueKey('about-update-status'),
                    style:
                        TextStyle(fontSize: AppType.body, color: statusColor)),
                const SizedBox(width: 10),
              ],
              Text(version,
                  key: const ValueKey('about-version'),
                  style: TextStyle(
                      fontSize: AppType.label,
                      color: palette.textMain,
                      fontWeight: FontWeight.w600)),
            ],
          ),
        ),
        if (between != null) between!,
        AboutLine(
          label: '自动检查',
          description: '每次启动时检查一次更新，安装包优先通过可用镜像下载',
          trailing: Switch(
            key: const ValueKey('about-auto-check'),
            value: preferences.autoCheck,
            onChanged: onAutoCheckChanged,
          ),
        ),
        AboutLine(
          key: const ValueKey('about-mirror-settings'),
          label: '下载镜像',
          description: !preferences.useMirror
              ? '已关闭，安装包从原始地址下载'
              : preferences.mirrorsUrl.isEmpty
                  ? '优先尝试可用镜像，可设置远程镜像列表'
                  : '镜像列表随远程配置更新，不可用时自动回退',
          tooltip: state.busy ? '更新操作结束后可修改' : '设置下载镜像',
          onTap: state.busy ? null : onMirrorSettings,
        ),
      ],
    );
  }
}

class MirrorSettingsDialog extends StatefulWidget {
  final UpdatePreferences preferences;
  final Future<void> Function(bool enabled, String url)? onSave;
  const MirrorSettingsDialog(
      {super.key, required this.preferences, this.onSave});

  @override
  State<MirrorSettingsDialog> createState() => _MirrorSettingsDialogState();
}

class _MirrorSettingsDialogState extends State<MirrorSettingsDialog> {
  late final TextEditingController _url;
  late bool _enabled;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _url = TextEditingController(text: widget.preferences.mirrorsUrl);
    _enabled = widget.preferences.useMirror;
  }

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final url = _url.text.trim();
    if (!UpdatePreferences.isValidMirrorsUrl(url)) {
      setState(() => _error = '请输入有效的 HTTPS 地址，不支持本机地址、查询参数或登录信息');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSave?.call(_enabled, url);
      if (mounted) Navigator.of(context).pop((enabled: _enabled, url: url));
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '保存失败，请检查数据目录权限后重试';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: !_saving,
        child: AlertDialog(
          title: const Text('下载镜像'),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SwitchListTile.adaptive(
                    key: const ValueKey('mirror-enabled'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('优先使用镜像'),
                    subtitle: const Text('镜像超时或下载过慢时，自动尝试其他地址'),
                    value: _enabled,
                    onChanged: _saving
                        ? null
                        : (value) => setState(() => _enabled = value),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const ValueKey('mirror-catalog-url'),
                    controller: _url,
                    enabled: !_saving,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    maxLength: 2048,
                    decoration: InputDecoration(
                      labelText: '远程镜像配置地址',
                      hintText: 'https://…/v1/mirrors',
                      helperText: '留空使用默认列表；配置更新后自动生效',
                      helperMaxLines: 2,
                      errorText: _error,
                      errorMaxLines: 3,
                      counterText: '',
                    ),
                    onChanged: (_) {
                      if (_error != null) setState(() => _error = null);
                    },
                    onSubmitted: (_) => _save(),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
                onPressed: _saving ? null : () => Navigator.of(context).pop(),
                child: const Text('取消')),
            TextButton(
                onPressed: _saving
                    ? null
                    : () {
                        _url.clear();
                        setState(() => _error = null);
                      },
                child: const Text('恢复默认')),
            FilledButton(
                onPressed: _saving ? null : _save,
                child: Text(_saving ? '保存中…' : '保存')),
          ],
        ),
      );
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
                      style: TextStyle(
                          fontSize: AppType.body,
                          height: 1.4,
                          color: palette.textSub)),
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
    return tooltip == null
        ? row
        : Tooltip(
            message: tooltip!,
            waitDuration: const Duration(milliseconds: 500),
            child: row);
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
      canvas.drawLine(
          Offset(x, 0), Offset((x + dash).clamp(0, size.width), 0), paint);
    }
  }

  @override
  bool shouldRepaint(_DashPainter old) => old.color != color;
}
