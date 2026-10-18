import 'package:flutter/material.dart';

/// 片头 / 片尾设置面板。
///
/// 返回值：`null` 取消；`0` 清除；`> 0` 新的时间点（片头为头部绝对毫秒，
/// 片尾为距片尾的尾部偏移毫秒）。校验与落盘由调用方负责。
Future<int?> showEpisodeSkipDialog(
  BuildContext context, {
  required String label,
  required int currentMs,
  required int positionMs,
  required int limitMs,
}) {
  final canUsePosition = positionMs > 0 && positionMs <= limitMs;
  return showDialog<int>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: const Color(0xFF18181C),
      title: Text('设置$label'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _row('当前值', currentMs > 0 ? _fmt(currentMs) : '未设置'),
          _row('当前位置', positionMs > 0 ? _fmt(positionMs) : '—'),
          const SizedBox(height: 8),
          Text(
            canUsePosition
                ? '可把当前位置设为$label，或用 ±1 秒微调。'
                : '仅允许在$label附近的 ${_fmt(limitMs)} 内设置，请先调整播放位置。',
            style: const TextStyle(fontSize: 11.5, color: Color(0xFF9090A0)),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: currentMs > 0
              ? () => Navigator.of(dialogContext).pop(0)
              : null,
          child: const Text('清除'),
        ),
        TextButton(
          onPressed: currentMs > 0
              ? () => Navigator.of(dialogContext).pop(
                  (currentMs - 1000).clamp(0, limitMs))
              : null,
          child: const Text('−1s'),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(
              ((currentMs > 0 ? currentMs : positionMs) + 1000)
                  .clamp(0, limitMs)),
          child: const Text('+1s'),
        ),
        FilledButton(
          onPressed: canUsePosition
              ? () => Navigator.of(dialogContext).pop(positionMs)
              : null,
          child: const Text('设为当前位置'),
        ),
      ],
    ),
  );
}

Widget _row(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 72,
            child: Text(label,
                style: const TextStyle(fontSize: 12, color: Color(0xFF9090A0))),
          ),
          Text(value, style: const TextStyle(fontSize: 12.5)),
        ],
      ),
    );

String _fmt(int ms) {
  final d = Duration(milliseconds: ms);
  final hours = d.inHours;
  final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
}
