import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/danmaku/danmaku_api.dart';
import '../../../core/danmaku/danmaku_controller.dart';
import '../../../core/danmaku/danmaku_models.dart';
import '../../../core/danmaku/danmaku_search.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';
import '../dialogs/app_dialog.dart';

/// 播放页「搜索弹幕」：按关键词搜候选，选中一条即绑定并立即刷新屏幕上的弹幕。
///
/// 手动搜索是自动匹配的兜底：自动匹配宁缺毋错（片名 / 集号对不上就一条不显示），
/// 这里把服务端候选原样列出来让用户自己挑。绑定走 [DanmakuController.bind]，
/// 与自动加载共用同一条取数 / 缓存路径，播放器照常重绘弹幕层。
Future<void> showDanmakuSearchDialog({
  required BuildContext context,
  required DanmakuController controller,
}) =>
    showAppDialog<void>(
      context: context,
      barrierLabel: '关闭弹幕搜索',
      builder: (_) => DanmakuSearchDialog(controller: controller),
    );

class DanmakuSearchDialog extends StatefulWidget {
  const DanmakuSearchDialog({super.key, required this.controller});

  final DanmakuController controller;

  @override
  State<DanmakuSearchDialog> createState() => _DanmakuSearchDialogState();
}

class _DanmakuSearchDialogState extends State<DanmakuSearchDialog> {
  late final TextEditingController _keyword;
  late final String _queryName;
  late final int? _episodeNumber;
  late final bool _onlyCurrentEpisode;

  DanmakuCancelToken? _token;
  List<DanmakuCandidate> _candidates = const [];
  DanmakuSearchView? _view;
  bool _searching = false;
  String? _error;

  /// 正在绑定的候选地址（只锁这一行，其余行照常可点）
  String? _bindingUrl;

  @override
  void initState() {
    super.initState();
    final query = widget.controller.currentQuery;
    _queryName = query?.name ?? '';
    _episodeNumber = query?.episodeNumber;
    // 认出集号才默认「仅本集」；认不出时列表就是全部候选（手动搜索的价值正在这里）
    _onlyCurrentEpisode = _episodeNumber != null;
    final text = danmakuSearchKeyword(_queryName);
    _keyword = TextEditingController(text: text)
      ..selection = TextSelection(baseOffset: 0, extentOffset: text.length);
    // 打开即用当前片名搜一次：多数情况下第一个候选就是要的那条
    _searching = true;
    unawaited(_runSearch(_resetToken(), text.trim()));
  }

  @override
  void dispose() {
    _token?.cancel();
    _keyword.dispose();
    super.dispose();
  }

  DanmakuCancelToken _resetToken() {
    _token?.cancel();
    return _token = DanmakuCancelToken();
  }

  DanmakuSearchView _viewOf(List<DanmakuCandidate> candidates, String keyword) =>
      DanmakuSearchView.build(
        keyword: keyword,
        candidates: candidates,
        episodeNumber: _episodeNumber,
        onlyCurrentEpisode: _onlyCurrentEpisode,
      );

  Future<void> _runSearch(DanmakuCancelToken token, String keyword) async {
    try {
      final candidates = await widget.controller.searchCandidates(keyword, cancel: token);
      if (!mounted || token.isCancelled) return;
      setState(() {
        _searching = false;
        _candidates = candidates;
        _view = _viewOf(candidates, keyword);
      });
    } catch (e) {
      if (!mounted || token.isCancelled) return;
      setState(() {
        _searching = false;
        _candidates = const [];
        _view = null;
        _error = danmakuSearchErrorText(e);
      });
    }
  }

  void _submit() {
    final keyword = _keyword.text.trim();
    if (keyword.isEmpty) {
      setState(() => _error = '请输入片名');
      return;
    }
    setState(() {
      _searching = true;
      _error = null;
      _view = null;
      _candidates = const [];
    });
    unawaited(_runSearch(_resetToken(), keyword));
  }

  void _toggleFilter() {
    final view = _view;
    if (view == null) return;
    setState(() {
      _onlyCurrentEpisode = !_onlyCurrentEpisode;
      _view = _viewOf(_candidates, view.keyword);
    });
  }

  Future<void> _bind(DanmakuSearchEntry entry) async {
    if (_bindingUrl != null) return;
    setState(() {
      _bindingUrl = entry.candidate.url;
      _error = null;
    });
    final state = await widget.controller.bind(entry.candidate);
    if (!mounted) return;
    if (state.phase == DanmakuLoadPhase.ready) {
      // 绑完立即关窗：弹幕已经在播放器上刷新，留着弹窗反而挡住画面
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _bindingUrl = null;
      _error = danmakuBindErrorText(state.message);
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Dialog(
      backgroundColor: palette.panel,
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.lg),
        side: BorderSide(color: palette.borderStrong),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(palette),
              const SizedBox(height: 14),
              _buildSearchRow(palette),
              if (_episodeNumber != null) ...[
                const SizedBox(height: 4),
                _buildFilterRow(palette),
              ],
              const SizedBox(height: 4),
              SizedBox(
                height: 2,
                child: _searching ? const LinearProgressIndicator() : null,
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  key: const ValueKey('danmaku-search-error'),
                  style: TextStyle(color: palette.danger, fontSize: AppType.label),
                ),
              ],
              const SizedBox(height: 10),
              // 窗口矮 / 有错误行时让列表先缩：弹窗整体不出现溢出的黄黑条纹
              Flexible(
                child: SizedBox(height: 300, child: _buildResultArea(palette)),
              ),
              const SizedBox(height: 6),
              _buildFooter(palette),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(AppPalette palette) {
    return Row(children: [
      Icon(Icons.manage_search_rounded, color: palette.accentInk, size: 24),
      const SizedBox(width: 10),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '搜索弹幕',
              style: TextStyle(
                  fontSize: AppType.h2,
                  fontWeight: FontWeight.bold,
                  color: palette.textTitle),
            ),
            Text(
              danmakuSearchSubtitle(_queryName, episodeNumber: _episodeNumber),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: AppType.caption, color: palette.textSub),
            ),
          ],
        ),
      ),
      IconButton(
        tooltip: '关闭弹幕搜索',
        onPressed: () => Navigator.of(context).pop(),
        icon: Icon(Icons.close_rounded, color: palette.textSub),
      ),
    ]);
  }

  Widget _buildSearchRow(AppPalette palette) {
    return Row(children: [
      Expanded(
        child: TextField(
          key: const ValueKey('danmaku-search-field'),
          controller: _keyword,
          autofocus: true,
          textInputAction: TextInputAction.search,
          enabled: !_searching,
          onSubmitted: (_) => _submit(),
          style: TextStyle(color: palette.textMain, fontSize: AppType.label),
          decoration: InputDecoration(
            hintText: '输入片名，回车搜索',
            prefixIcon: Icon(Icons.search_rounded, color: palette.textSub, size: 20),
            hintStyle: TextStyle(color: palette.textDim, fontSize: AppType.body),
            filled: true,
            fillColor: palette.raised,
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(vertical: 12),
            border:
                OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadii.md)),
          ),
        ),
      ),
      const SizedBox(width: 10),
      FilledButton.icon(
        key: const ValueKey('danmaku-search-submit'),
        style: FilledButton.styleFrom(backgroundColor: palette.accent),
        onPressed: _searching ? null : _submit,
        icon: const Icon(Icons.search_rounded, size: 18),
        label: const Text('搜索'),
      ),
    ]);
  }

  Widget _buildFilterRow(AppPalette palette) {
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        key: const ValueKey('danmaku-search-only-episode'),
        onPressed: _searching ? null : _toggleFilter,
        style: TextButton.styleFrom(
          foregroundColor: _onlyCurrentEpisode ? palette.accentInk : palette.textSub,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        icon: Icon(
          _onlyCurrentEpisode
              ? Icons.check_box_rounded
              : Icons.check_box_outline_blank_rounded,
          size: 18,
        ),
        label: Text(
          '仅第 $_episodeNumber 集',
          style: const TextStyle(fontSize: AppType.body),
        ),
      ),
    );
  }

  Widget _buildResultArea(AppPalette palette) {
    final view = _view;
    if (_searching && view == null) {
      return Center(
        child: Text(
          '正在搜索「${_keyword.text.trim()}」…',
          style: TextStyle(color: palette.textSub, fontSize: AppType.label),
        ),
      );
    }
    if (view == null) {
      return Center(
        child: Text(
          _error == null ? '输入片名后点「搜索」' : '搜索失败，可以改关键词再试',
          textAlign: TextAlign.center,
          style: TextStyle(color: palette.textSub, fontSize: AppType.label),
        ),
      );
    }
    if (view.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search_off_rounded, color: palette.textDim, size: 32),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                view.emptyMessage,
                key: const ValueKey('danmaku-search-empty'),
                textAlign: TextAlign.center,
                style: TextStyle(color: palette.textSub, fontSize: AppType.label),
              ),
            ),
            if (view.filterHidesAll)
              TextButton(
                key: const ValueKey('danmaku-search-show-all'),
                onPressed: _toggleFilter,
                child: const Text('查看全部候选'),
              ),
          ],
        ),
      );
    }
    return ListView.separated(
      key: const ValueKey('danmaku-search-results'),
      padding: EdgeInsets.zero,
      itemCount: view.entries.length,
      separatorBuilder: (_, __) => Divider(height: 1, color: palette.divider),
      itemBuilder: (_, index) => _buildRow(palette, view.entries[index], index),
    );
  }

  Widget _buildRow(AppPalette palette, DanmakuSearchEntry entry, int index) {
    final state = widget.controller.value;
    final current = state.candidate?.url == entry.candidate.url;
    final loaded = current ? state.track?.length : null;
    final binding = _bindingUrl == entry.candidate.url;
    final detail = [
      if (current) '当前使用',
      if (entry.detail.isNotEmpty) entry.detail,
      if (loaded != null) '已加载 $loaded 条',
    ].join(' · ');
    return ListTile(
      key: ValueKey('danmaku-search-row-${entry.id ?? index}'),
      dense: true,
      enabled: _bindingUrl == null,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      onTap: _bindingUrl == null ? () => _bind(entry) : null,
      leading: Icon(
        current ? Icons.radio_button_checked_rounded : Icons.subtitles_rounded,
        size: 18,
        color: current ? palette.accentInk : palette.textDim,
      ),
      title: Tooltip(
        message: entry.fullName,
        waitDuration: const Duration(milliseconds: 600),
        child: Row(children: [
          Flexible(
            child: Text(
              entry.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: palette.textMain,
                  fontSize: AppType.label,
                  fontWeight: FontWeight.w600),
            ),
          ),
          if (entry.episodeLabel != null) ...[
            const SizedBox(width: 8),
            _buildTag(palette, entry.episodeLabel!),
          ],
        ]),
      ),
      subtitle: detail.isEmpty
          ? null
          : Text(
              detail,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: palette.textSub, fontSize: AppType.caption),
            ),
      trailing: binding
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(
              current ? Icons.check_rounded : Icons.chevron_right_rounded,
              size: 18,
              color: current ? palette.accentInk : palette.textDim,
            ),
    );
  }

  Widget _buildTag(AppPalette palette, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: palette.accentWash,
        borderRadius: BorderRadius.circular(AppRadii.pill),
      ),
      child: Text(
        text,
        style: TextStyle(color: palette.accentInk, fontSize: AppType.micro),
      ),
    );
  }

  Widget _buildFooter(AppPalette palette) {
    final view = _view;
    final hint = _bindingUrl != null
        ? '正在加载所选弹幕…'
        : (view != null && view.total > 0
            ? '共 ${view.total} 条候选，选中一条即切换并立即生效'
            : '服务端按片名模糊匹配，可以改关键词重搜');
    return Row(children: [
      Expanded(
        child: Text(
          hint,
          maxLines: 2,
          style: TextStyle(color: palette.textDim, fontSize: AppType.caption),
        ),
      ),
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('关闭'),
      ),
    ]);
  }
}
