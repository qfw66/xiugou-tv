import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/api/models/vod_models.dart';
import '../../../core/config/models/vod_config.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';
import 'vod_list_view.dart';

typedef VodFolderCategoryLoader = Future<VodPageResult> Function(
  String categoryId,
  int page,
);

class VodFolderBrowserDialog extends StatefulWidget {
  const VodFolderBrowserDialog({
    super.key,
    required this.site,
    required this.folder,
    required this.loadCategory,
    required this.onItemTap,
  });

  final Site site;
  final VodItem folder;
  final VodFolderCategoryLoader loadCategory;
  final ValueChanged<VodItem> onItemTap;

  @override
  State<VodFolderBrowserDialog> createState() => _VodFolderBrowserDialogState();
}

class _VodFolderBrowserDialogState extends State<VodFolderBrowserDialog> {
  late final List<_FolderLevel> _levels = [_FolderLevel(widget.folder)];
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;

  _FolderLevel get _current => _levels.last;

  @override
  void initState() {
    super.initState();
    _loadFolder(widget.folder, push: false);
  }

  Future<void> _loadFolder(VodItem folder, {required bool push}) async {
    setState(() {
      _loading = true;
      _error = null;
      if (push) _levels.add(_FolderLevel(folder));
    });
    try {
      final result = await widget.loadCategory(folder.id, 1);
      if (!mounted) return;
      setState(() {
        final level = _FolderLevel(folder)
          ..items = List<VodItem>.of(result.list)
          ..page = result.page < 1 ? 1 : result.page
          ..pageCount = result.pageCount < 1 ? 1 : result.pageCount;
        _levels[_levels.length - 1] = level;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$error';
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || _current.page >= _current.pageCount) return;
    setState(() => _loadingMore = true);
    try {
      final nextPage = _current.page + 1;
      final result = await widget.loadCategory(_current.folder.id, nextPage);
      if (!mounted) return;
      setState(() {
        final known = _current.items
            .map((item) => '${item.id}\\u0000${item.name}')
            .toSet();
        _current.items.addAll(result.list
            .where((item) => known.add('${item.id}\\u0000${item.name}')));
        _current.page = result.page < nextPage ? nextPage : result.page;
        _current.pageCount = result.pageCount < 1 ? 1 : result.pageCount;
        _loadingMore = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingMore = false;
        _error = '$error';
      });
    }
  }

  void _onItemTap(VodItem item) {
    if (item.action?.trim().isNotEmpty ?? false) {
      widget.onItemTap(item);
      return;
    }
    if (item.isFolder) {
      _loadFolder(item, push: true);
      return;
    }
    Navigator.of(context).pop();
    widget.onItemTap(item);
  }

  void _goUp() {
    if (_levels.length <= 1) return;
    setState(() {
      _levels.removeLast();
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final size = MediaQuery.sizeOf(context);
    final current = _current;
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: math.min(size.width * 0.86, 920),
        height: math.min(size.height * 0.84, 760),
        child: Column(
          children: [
            SizedBox(
              height: 58,
              child: Row(
                children: [
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: _levels.length > 1 ? '上一级' : '关闭目录',
                    onPressed: _levels.length > 1
                        ? _goUp
                        : () => Navigator.of(context).pop(),
                    icon: Icon(
                        _levels.length > 1 ? Icons.arrow_back : Icons.close),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          current.folder.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: palette.textTitle,
                            fontSize: AppType.title,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          widget.site.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: palette.textDim,
                              fontSize: AppType.caption),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                ],
              ),
            ),
            Divider(height: 1, color: palette.divider),
            Expanded(child: _buildContent(palette, current)),
            if (!_loading && current.page < current.pageCount)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                child: TextButton.icon(
                  onPressed: _loadingMore ? null : _loadMore,
                  icon: _loadingMore
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.expand_more),
                  label: const Text('加载更多'),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent(AppPalette palette, _FolderLevel current) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, style: TextStyle(color: palette.textSub)),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => _loadFolder(current.folder, push: false),
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('重试'),
            ),
          ],
        ),
      );
    }
    if (current.items.isEmpty) {
      return Center(
        child: Text('此目录为空', style: TextStyle(color: palette.textSub)),
      );
    }
    return VodListView(items: current.items, onItemTap: _onItemTap);
  }
}

class _FolderLevel {
  _FolderLevel(this.folder);

  final VodItem folder;
  List<VodItem> items = <VodItem>[];
  int page = 1;
  int pageCount = 1;
}
