import 'package:flutter/material.dart';

import '../../../core/config/models/vod_config.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';

class SearchSiteSelectionDialog extends StatefulWidget {
  const SearchSiteSelectionDialog({
    super.key,
    required this.sites,
    required this.selectedKeys,
  });

  final List<Site> sites;
  final Set<String> selectedKeys;

  @override
  State<SearchSiteSelectionDialog> createState() =>
      _SearchSiteSelectionDialogState();
}

class _SearchSiteSelectionDialogState extends State<SearchSiteSelectionDialog> {
  late final TextEditingController _searchController;
  late final Set<String> _selected;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
    _selected = {...widget.selectedKeys};
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final sites = widget.sites
        .where((site) {
          final query = _query.toLowerCase();
          return query.isEmpty ||
              site.name.toLowerCase().contains(query) ||
              site.key.toLowerCase().contains(query);
        })
        .toList(growable: false);
    final allSelected =
        widget.sites.isNotEmpty &&
        widget.sites.every((site) => _selected.contains(site.key));

    return AlertDialog(
      title: const Text('聚合搜索站点'),
      content: SizedBox(
        width: 520,
        height: 440,
        child: Column(
          children: [
            TextField(
              controller: _searchController,
              onChanged: (value) => setState(() => _query = value.trim()),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: '搜索站点名称或 key',
              ),
            ),
            Row(
              children: [
                Text('${_selected.length}/${widget.sites.length} 个站点'),
                const Spacer(),
                TextButton(
                  onPressed: widget.sites.isEmpty
                      ? null
                      : () => setState(() {
                          if (allSelected) {
                            _selected.clear();
                          } else {
                            _selected
                              ..clear()
                              ..addAll(widget.sites.map((site) => site.key));
                          }
                        }),
                  child: Text(allSelected ? '取消全选' : '全选'),
                ),
              ],
            ),
            Expanded(
              child: sites.isEmpty
                  ? Center(
                      child: Text(
                        widget.sites.isEmpty ? '没有可搜索的站点' : '没有匹配的站点',
                      ),
                    )
                  : ListView.builder(
                      itemCount: sites.length,
                      itemBuilder: (context, index) {
                        final site = sites[index];
                        return CheckboxListTile(
                          dense: true,
                          value: _selected.contains(site.key),
                          title: Text(
                            site.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            site.key,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          controlAffinity: ListTileControlAffinity.leading,
                          onChanged: (value) => setState(() {
                            if (value == true) {
                              _selected.add(site.key);
                            } else {
                              _selected.remove(site.key);
                            }
                          }),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, Set<String>.of(_selected)),
          child: const Text('确定'),
        ),
      ],
      backgroundColor: palette.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.md),
      ),
    );
  }
}
