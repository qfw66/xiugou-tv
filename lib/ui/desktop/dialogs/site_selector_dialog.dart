import 'package:flutter/material.dart';
import '../../../core/config/models/vod_config.dart';

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
    final filteredSites = widget.sites.where((site) {
      if (_filterKeyword.isEmpty) return true;
      final kw = _filterKeyword.toLowerCase();
      return site.name.toLowerCase().contains(kw) || site.key.toLowerCase().contains(kw);
    }).toList();

    return Dialog(
      backgroundColor: const Color(0xFF181820),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Color(0xFF2E2E3C), width: 1),
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
                    color: const Color(0xFF282834),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.hub_rounded, color: Color(0xFFE50914), size: 20),
                ),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '切换点播站源',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                    Text(
                      '共 ${widget.sites.length} 个可用站点',
                      style: const TextStyle(fontSize: 12, color: Color(0xFF888898)),
                    ),
                  ],
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close_rounded, color: Color(0xFFA0A0B0), size: 22),
                  onPressed: () => Navigator.of(context).pop(),
                  tooltip: '关闭',
                ),
              ],
            ),
            const SizedBox(height: 16),

            // 搜索过滤栏
            TextField(
              controller: _searchController,
              style: const TextStyle(fontSize: 13, color: Colors.white),
              onChanged: (val) => setState(() => _filterKeyword = val.trim()),
              decoration: InputDecoration(
                hintText: '搜索站源名称或关键字...',
                hintStyle: const TextStyle(fontSize: 13, color: Color(0xFF686878)),
                prefixIcon: const Icon(Icons.search_rounded, size: 20, color: Color(0xFF808090)),
                suffixIcon: _filterKeyword.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear_rounded, size: 18, color: Color(0xFF808090)),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _filterKeyword = '');
                        },
                      )
                    : null,
                filled: true,
                fillColor: const Color(0xFF20202A),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: Color(0xFF323242)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: Color(0xFF323242)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: Color(0xFFE50914), width: 1.5),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              ),
            ),
            const SizedBox(height: 16),

            // 站点列表网格
            Expanded(
              child: filteredSites.isEmpty
                  ? const Center(
                      child: Text(
                        '未找到匹配的站源',
                        style: TextStyle(color: Color(0xFF707082), fontSize: 14),
                      ),
                    )
                  : GridView.builder(
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
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
    final site = widget.site;
    final isSelected = widget.isSelected;

    String tag;
    Color tagColor = isSelected ? const Color(0xFFFF8B94) : const Color(0xFF808092);
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
      tagColor = const Color(0xFF707080);
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: isSelected
                ? const Color(0xFF381519)
                : _isHovered
                    ? const Color(0xFF262634)
                    : const Color(0xFF1E1E28),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isSelected
                  ? const Color(0xFFE50914)
                  : _isHovered
                      ? const Color(0xFF48485C)
                      : const Color(0xFF2C2C3A),
              width: isSelected ? 1.5 : 1,
            ),
          ),
          child: Row(
            children: [
              Icon(
                isSelected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                size: 16,
                color: isSelected ? const Color(0xFFE50914) : const Color(0xFF707080),
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
                        fontSize: 13,
                        fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                        color: isSelected ? Colors.white : const Color(0xFFDCDCE8),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      tag,
                      style: TextStyle(
                        fontSize: 10,
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
