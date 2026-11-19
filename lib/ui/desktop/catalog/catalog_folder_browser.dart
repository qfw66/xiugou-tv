import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/api/models/vod_models.dart';
import '../../../core/api/search_cancel_token.dart';
import '../../../core/api/site_api.dart';
import '../../../core/config/models/vod_config.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';
import 'vod_grid_view.dart';

class CatalogFolderBrowser extends StatefulWidget {
  const CatalogFolderBrowser({
    super.key,
    required this.site,
    required this.root,
    required this.api,
    required this.onClose,
    required this.onItemTap,
    this.extend = const {},
  });

  final Site site;
  final VodItem root;
  final SiteApi api;
  final Map<String, String> extend;
  final VoidCallback onClose;
  final ValueChanged<VodItem> onItemTap;

  @override
  CatalogFolderBrowserState createState() => CatalogFolderBrowserState();
}

class _FolderPage {
  _FolderPage(this.folder);
  final VodItem folder;
  final scroll = ScrollController();
  List<VodItem> items = [];
  double offset = 0;
  int page = 0;
  bool hasMore = false;
  bool loading = false;
  String? error;
  bool retryRefresh = false;
}

class CatalogFolderBrowserState extends State<CatalogFolderBrowser> {
  final _pages = <_FolderPage>[];
  SearchCancelToken? _request;
  int _generation = 0;

  void refresh() => _load(refresh: true);
  _FolderPage get _current => _pages.last;

  @override
  void initState() {
    super.initState();
    _push(widget.root);
  }

  void _cancel() {
    _generation++;
    _request?.cancel();
    _request = null;
  }

  void _push(VodItem folder) {
    _cancel();
    if (_pages.isNotEmpty) {
      _current.loading = false;
      if (_current.scroll.hasClients) _current.offset = _current.scroll.offset;
    }
    final page = _FolderPage(folder);
    page.scroll.addListener(() {
      if (mounted &&
          identical(page, _current) &&
          page.scroll.hasClients &&
          page.error == null && page.scroll.position.extentAfter < 250) {
        _load();
      }
    });
    _pages.add(page);
    _load();
  }

  Future<void> _load({bool refresh = false}) async {
    final page = _current;
    if (page.loading || (!refresh && page.page > 0 && !page.hasMore)) return;
    _cancel();
    final generation = _generation;
    final token = _request = SearchCancelToken();
    final requested = refresh ? 1 : page.page + 1;
    setState(() {
      page.loading = true;
      page.error = null;
    });
    try {
      final result = await widget.api.fetchCategory(widget.site,
          categoryId: page.folder.id,
          page: requested,
          extend: widget.extend,
          cancelToken: token);
      if (!mounted || generation != _generation || !identical(page, _current)) {
        return;
      }
      final items = requested == 1 ? <VodItem>[] : List<VodItem>.of(page.items);
      final seen = items.map((item) => item.id).toSet();
      final added = result.list.where((item) => seen.add(item.id)).toList();
      items.addAll(added);
      setState(() {
        page.items = items;
        page.page = requested;
        page.hasMore = added.isNotEmpty &&
            (result.pageCount > requested ||
                (result.pageCount <= 1 && result.total > items.length));
        page.loading = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || generation != _generation || !page.scroll.hasClients) {
          return;
        }
        if (page.scroll.position.extentAfter < 250) _load();
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        page.loading = false;
        page.error = '目录加载失败：$error';
        page.retryRefresh = refresh;
      });
    }
  }

  void _back() {
    _cancel();
    if (_pages.length == 1) {
      widget.onClose();
      return;
    }
    final removed = _pages.removeLast();
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      removed.scroll.dispose();
      if (!mounted || !_current.scroll.hasClients) return;
      _current.scroll.jumpTo(
          _current.offset.clamp(0, _current.scroll.position.maxScrollExtent));
    });
  }

  void _open(VodItem item) {
    if (item.action?.trim().isNotEmpty ?? false) {
      widget.onItemTap(item);
    } else if (item.isFolder) {
      _push(item);
    } else {
      widget.onItemTap(item);
    }
  }

  @override
  void dispose() {
    _cancel();
    for (final page in _pages) {
      page.scroll.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final page = _current;
    final palette = context.palette;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true): _back,
      },
      child: Focus(
        autofocus: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              IconButton(
                  tooltip: '返回上一级',
                  onPressed: _back,
                  icon: const Icon(Icons.arrow_back_rounded)),
              Expanded(
                  child: Tooltip(
                message: _pages.map((entry) => entry.folder.name).join(' / '),
                child: Text(
                    _pages.map((entry) => entry.folder.name).join(' / '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: palette.textTitle,
                        fontSize: AppType.title,
                        fontWeight: FontWeight.w600)),
              )),
              IconButton(
                  tooltip: '刷新目录',
                  onPressed: page.loading ? null : () => _load(refresh: true),
                  icon: const Icon(Icons.refresh_rounded)),
            ]),
            const SizedBox(height: 8),
            Expanded(
                child: Container(
              decoration: const BoxDecoration(color: Colors.transparent),
              clipBehavior: Clip.antiAlias,
              child: Column(children: [
                if (page.loading) const LinearProgressIndicator(),
                if (page.error != null)
                  Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(children: [
                        Expanded(
                            child: Text(page.error!,
                                style: TextStyle(color: palette.danger))),
                        TextButton(
                            onPressed: () => _load(refresh: page.retryRefresh),
                            child: const Text('重试')),
                      ])),
                Expanded(
                    child: page.items.isEmpty
                        ? Center(
                            child: Text(
                                page.loading
                                    ? '正在加载目录…'
                                    : page.error == null
                                        ? '此目录暂无内容'
                                        : '可重试或返回上一级',
                                style: TextStyle(color: palette.textSub)))
                        : VodGridView(
                            key: ObjectKey(page),
                            items: page.items,
                            controller: page.scroll,
                            onItemTap: _open)),
              ]),
            )),
          ],
        ),
      ),
    );
  }
}
