import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/companion/companion_spider_api.dart';
import '../../../core/companion/site_self_check_report.dart';
import '../../../core/config/models/vod_config.dart';

const _kTextMain = Color(0xFFE6E6F0);
const _kTextSub = Color(0xFF8C8CA0);
const _kAccent = Color(0xFFE50914);
const _kPanel = Color(0xFF202026);

/// 站点体检弹窗：对当前配置里的 Spider 站点逐个探测，边跑边出结果。
///
/// 分批（每批 [_batchSize] 站）调用一次 `selfCheck` RPC，而不是一次性全量下发：
/// 单批的看门狗预算可控，用户也能看到进度；某批失败只影响该批，不会丢掉整轮结果。
class SiteSelfCheckDialog extends StatefulWidget {
  /// 待体检站点（调用方已过滤为需要伴随服务的站点）
  final List<Site> sites;

  /// 伴随服务 API（注入便于测试）
  final CompanionSpiderApi api;

  /// 单站预算（秒）；与 Java 侧 per-site 超时一致
  final int perSiteTimeoutSeconds;

  const SiteSelfCheckDialog({
    super.key,
    required this.sites,
    required this.api,
    this.perSiteTimeoutSeconds = 20,
  });

  @override
  State<SiteSelfCheckDialog> createState() => _SiteSelfCheckDialogState();
}

class _SiteSelfCheckDialogState extends State<SiteSelfCheckDialog> {
  static const int _batchSize = 8;

  final Map<String, String> _nameByKey = {};
  final List<SiteSelfCheckEntry> _entries = [];
  bool _running = true;
  bool _closed = false;

  int get _total => widget.sites.length;
  int get _processed => _entries.length;

  @override
  void initState() {
    super.initState();
    for (final site in widget.sites) {
      _nameByKey[site.key] = site.name;
    }
    unawaited(_run());
  }

  @override
  void dispose() {
    // 拉取仍在进行时关闭弹窗：后续 setState 直接丢弃
    _closed = true;
    super.dispose();
  }

  Future<void> _run() async {
    for (var start = 0; start < widget.sites.length; start += _batchSize) {
      if (_closed) return;
      final batch = widget.sites.sublist(
        start,
        (start + _batchSize).clamp(0, widget.sites.length),
      );
      final report = await widget.api.runSelfCheck(
        batch,
        perSiteTimeoutSeconds: widget.perSiteTimeoutSeconds,
      );

      if (report.isEmpty) {
        // 整批未取得结果：按站点逐条标记，避免"跑过但没输出"被误读成站点正常
        for (final site in batch) {
          _entries.add(SiteSelfCheckEntry(
            key: site.key,
            api: site.api,
            verdict: 'FAILED',
            error: '未取得结果（站点服务未就绪、开关已关闭或整批超时）',
          ));
        }
      } else {
        final byKey = {for (final entry in report.sites) entry.key: entry};
        for (final site in batch) {
          _entries.add(byKey[site.key] ??
              SiteSelfCheckEntry(
                key: site.key,
                api: site.api,
                verdict: 'FAILED',
                error: '未返回该站结果',
              ));
        }
      }
      if (_closed) return;
      setState(() {});
    }
    if (_closed) return;
    setState(() => _running = false);
  }

  String _nameOf(SiteSelfCheckEntry entry) =>
      _nameByKey[entry.key]?.trim().isNotEmpty == true ? _nameByKey[entry.key]! : entry.key;

  Color _badgeColor(SiteSelfCheckEntry entry) {
    if (entry.isOk) return const Color(0xFF4CAF50);
    if (entry.isDegraded) return const Color(0xFFFFB300);
    if (entry.isTimeout) return const Color(0xFF78909C);
    return _kAccent;
  }

  String _metricsText(SiteSelfCheckEntry entry) {
    final parts = <String>[
      if (entry.classes > 0) '分类 ${entry.classes}',
      '内容 ${entry.best} 条',
      '${entry.ms} ms',
    ];
    return parts.join(' · ');
  }

  String _reportText() {
    final ok = _entries.where((e) => e.isOk).length;
    final degraded = _entries.where((e) => e.isDegraded).length;
    final timeout = _entries.where((e) => e.isTimeout).length;
    final failed = _entries.length - ok - degraded - timeout;
    final buffer = StringBuffer()
      ..writeln('修狗TV 站点体检结果')
      ..writeln('共 ${_entries.length} 站：可用 $ok / 降级 $degraded / 失败 $failed / 超时 $timeout');
    for (final entry in _entries) {
      buffer.write('[${entry.verdictLabel}] ${_nameOf(entry)}（${entry.key}）');
      buffer.write(' ${_metricsText(entry)}');
      if (entry.error.isNotEmpty) buffer.write(' | ${entry.error}');
      buffer.writeln();
    }
    return buffer.toString();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _reportText()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('体检结果已复制到剪贴板（不含订阅地址与凭据）')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ok = _entries.where((e) => e.isOk).length;
    final degraded = _entries.where((e) => e.isDegraded).length;
    final timeout = _entries.where((e) => e.isTimeout).length;
    final failed = _entries.length - ok - degraded - timeout;

    return Dialog(
      backgroundColor: _kPanel,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620, maxHeight: 560),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text('站点体检',
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: _kTextMain)),
                  ),
                  if (_running)
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                _running
                    ? '正在逐个探测 $_processed / $_total 个站点（每站最多 ${widget.perSiteTimeoutSeconds} 秒）…'
                    : '完成：共 $_total 站 · 可用 $ok · 降级 $degraded · 失败 $failed · 超时 $timeout',
                style: const TextStyle(fontSize: 12, color: _kTextSub),
              ),
              if (_running) ...[
                const SizedBox(height: 10),
                LinearProgressIndicator(
                  value: _total == 0 ? null : (_processed / _total).clamp(0.0, 1.0),
                  backgroundColor: const Color(0xFF2C2C36),
                ),
              ],
              const SizedBox(height: 12),
              Flexible(
                child: _entries.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Center(
                          child: Text('正在准备探测…', style: TextStyle(fontSize: 12.5, color: _kTextSub)),
                        ),
                      )
                    : ListView.separated(
                        shrinkWrap: true,
                        itemCount: _entries.length,
                        separatorBuilder: (_, __) => const Divider(
                          height: 12,
                          thickness: 1,
                          color: Color(0xFF2C2C36),
                        ),
                        itemBuilder: (context, index) {
                          final entry = _entries[index];
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: _badgeColor(entry).withValues(alpha: 0.16),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      entry.verdictLabel,
                                      style: TextStyle(fontSize: 11, color: _badgeColor(entry)),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      _nameOf(entry),
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 12.5, color: _kTextMain),
                                    ),
                                  ),
                                  Text(
                                    _metricsText(entry),
                                    style: const TextStyle(fontSize: 11.5, color: _kTextSub),
                                  ),
                                ],
                              ),
                              if (entry.error.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 4, left: 2),
                                  child: Text(
                                    entry.error,
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 11.5, color: Color(0xFFFF8A80)),
                                  ),
                                ),
                            ],
                          );
                        },
                      ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  TextButton.icon(
                    onPressed: _entries.isEmpty ? null : () => unawaited(_copy()),
                    icon: const Icon(Icons.copy_all_outlined, size: 16),
                    label: const Text('复制结果'),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('关闭', style: TextStyle(color: _kTextSub)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
