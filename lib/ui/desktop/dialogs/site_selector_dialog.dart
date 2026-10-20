import 'package:flutter/material.dart';
import '../../../core/config/models/vod_config.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';

/// 站点源快速切换选择弹窗
class SiteSelectorDialog extends StatefulWidget {
  final List<Site> sites;
  final Site? currentSite;
  final ValueChanged<Site> onSiteSelected;

  const SiteSelectorDialog({
    super.key,
    required this.sites,
    required this.currentSite,
    required this.onSiteSelected,
  });

  @override
  State<SiteSelectorDialog> createState() => _SiteSelectorDialogState();
}

class _SiteSelectorDialogState extends State<SiteSelectorDialog> {
  late final TextEditingController _searchController;
  String _filterKeyword = '';

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final filteredSites = widget.sites.where((site) {
      if (_filterKeyword.isEmpty) return true;
      final kw = _filterKeyword.toLowerCase();
      return site.name.toLowerCase().contains(kw) ||
          site.key.toLowerCase().contains(kw);
    }).toList();

    return Dialog(
      backgroundColor: palette.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.lg),
        side: BorderSide(color: palette.borderStrong, width: 1),
      ),
      child: Container(
        width: 680,
        height: 520,
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 头部标题与关闭按钮
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: palette.raised,
                    borderRadius: BorderRadius.circular(AppRadii.md),
                  ),
                  child: Icon(Icons.hub_rounded,
                      color: palette.accentInk, size: 20),
                ),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '切换点播站源',
                      style: TextStyle(
                          fontSize: AppType.h2,
                          fontWeight: FontWeight.bold,
                          color: palette.textTitle),
                    ),
                    Text(
                      '共 ${widget.sites.length} 个可用站点',
                      style: TextStyle(fontSize: AppType.body, color: palette.textSub),
                    ),
                  ],
                ),
                const Spacer(),
                IconButton(
                  icon: Icon(Icons.close_rounded,
                      color: palette.textSub, size: 22),
                  onPressed: () => Navigator.of(context).pop(),
                  tooltip: '关闭',
                ),
              ],
            ),
            const SizedBox(height: 16),

            // 搜索过滤栏
            TextField(
              controller: _searchController,
              style: TextStyle(fontSize: AppType.label, color: palette.textMain),
              onChanged: (val) => setState(() => _filterKeyword = val.trim()),
              decoration: InputDecoration(
                hintText: '搜索站源名称或关键字...',
                hintStyle: TextStyle(fontSize: AppType.label, color: palette.textDim),
                prefixIcon: Icon(Icons.search_rounded,
                    size: 20, color: palette.textSub),
                suffixIcon: _filterKeyword.isNotEmpty
                    ? IconButton(
                        icon: Icon(Icons.clear_rounded,
                            size: 18, color: palette.textSub),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _filterKeyword = '');
                        },
                      )
                    : null,
                filled: true,
                fillColor: palette.raised,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadii.md),
                  borderSide: BorderSide(color: palette.pressed),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadii.md),
                  borderSide: BorderSide(color: palette.pressed),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadii.md),
                  borderSide: BorderSide(color: palette.accentInk, width: 1.5),
                ),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              ),
            ),
            const SizedBox(height: 16),

            // 站点列表网格
            Expanded(
              child: filteredSites.isEmpty
                  ? Center(
                      child: Text(
                        '未找到匹配的站源',
                        style: TextStyle(color: palette.textDim, fontSize: AppType.title),
                      ),
                    )
                  : GridView.builder(
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 3,
                        childAspectRatio: 2.5,
                        crossAxisSpacing: 12,
                        mainAxisSpacing: 12,
                      ),
                      itemCount: filteredSites.length,
                      itemBuilder: (context, index) {
                        final site = filteredSites[index];
                        final isSelected = site.key == widget.currentSite?.key;
                        return _SiteCard(
                          site: site,
                          isSelected: isSelected,
                          onTap: () {
                            Navigator.of(context).pop();
                            widget.onSiteSelected(site);
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SiteCard extends StatefulWidget {
  final Site site;
  final bool isSelected;
  final VoidCallback onTap;

  const _SiteCard({
    required this.site,
    required this.isSelected,
    required this.onTap,
  });

  @override
  State<_SiteCard> createState() => _SiteCardState();
}

class _SiteCardState extends State<_SiteCard> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final site = widget.site;
    final isSelected = widget.isSelected;

    String tag;
    Color tagColor = isSelected ? palette.danger : palette.textSub;
    final rawApi = site.api.trim();
    final rawExt = site.ext?.trim() ?? '';
    if (site.type == 0 || site.type == 1) {
      tag = site.type == 0 ? 'CMS XML' : 'CMS JSON';
    } else if (rawApi.startsWith('http://') ||
        rawApi.startsWith('https://') ||
        rawExt.startsWith('http://') ||
        rawExt.startsWith('https://')) {
      tag = 'HTTP 扩展';
    } else {
      tag = 'Dex 插件 (Android)';
      tagColor = palette.textDim;
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: AppMotion.base,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: isSelected
                ? palette.accentWash
                : _isHovered
                    ? palette.hover
                    : palette.raised,
            borderRadius: BorderRadius.circular(AppRadii.md),
            border: Border.all(
              color: isSelected
                  ? palette.accentInk
                  : _isHovered
                      ? palette.borderStrong
                      : palette.pressed,
              width: isSelected ? 1.5 : 1,
            ),
          ),
          child: Row(
            children: [
              Icon(
                isSelected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                size: 16,
                color: isSelected ? palette.accentInk : palette.textDim,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      site.name,
                      style: TextStyle(
                        fontSize: AppType.label,
                        fontWeight:
                            isSelected ? FontWeight.bold : FontWeight.w500,
                        color:
                            isSelected ? palette.textTitle : palette.textBody,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      tag,
                      style: TextStyle(
                        fontSize: AppType.caption,
                        color: tagColor,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
