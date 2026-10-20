import 'package:flutter/material.dart';
import '../../../core/config/config_repository.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';

/// 多仓（Depot）订阅选择弹窗：列出仓库清单，返回用户选择的条目下标；取消返回 null
class DepotSelectionDialog extends StatelessWidget {
  final List<DepotEntry> entries;

  const DepotSelectionDialog({super.key, required this.entries});

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Dialog(
      backgroundColor: palette.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.lg),
        side: BorderSide(color: palette.borderStrong, width: 1),
      ),
      child: Container(
        width: 560,
        constraints: const BoxConstraints(maxHeight: 520),
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: palette.raised,
                    borderRadius: BorderRadius.circular(AppRadii.md),
                  ),
                  child: Icon(Icons.account_tree_rounded,
                      color: palette.accentInk, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '选择订阅仓库',
                        style: TextStyle(
                            fontSize: AppType.h2,
                            fontWeight: FontWeight.bold,
                            color: palette.textTitle),
                      ),
                      Text(
                        '检测到多仓订阅，共 ${entries.length} 个来源',
                        style: TextStyle(fontSize: AppType.body, color: palette.textSub),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.close_rounded,
                      color: palette.textSub, size: 22),
                  onPressed: () => Navigator.of(context).pop(),
                  tooltip: '取消',
                ),
              ],
            ),
            const SizedBox(height: 16),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: entries.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final entry = entries[index];
                  return _DepotEntryTile(
                    entry: entry,
                    onTap: () => Navigator.of(context).pop(index),
                  );
                },
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '提示：选择后将加载对应子配置；若选中的仍是多仓会继续提示选择。',
              style: TextStyle(fontSize: AppType.caption, color: palette.textDim),
            ),
          ],
        ),
      ),
    );
  }
}

class _DepotEntryTile extends StatefulWidget {
  final DepotEntry entry;
  final VoidCallback onTap;

  const _DepotEntryTile({required this.entry, required this.onTap});

  @override
  State<_DepotEntryTile> createState() => _DepotEntryTileState();
}

class _DepotEntryTileState extends State<_DepotEntryTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final entry = widget.entry;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: AppMotion.base,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: _hovered ? palette.hover : palette.raised,
            borderRadius: BorderRadius.circular(AppRadii.md),
            border: Border.all(
              color: _hovered ? palette.accentInk : palette.pressed,
              width: 1,
            ),
          ),
          child: Row(
            children: [
              Icon(
                Icons.folder_rounded,
                size: 18,
                color: _hovered ? palette.accentInk : palette.textSub,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppType.title,
                        color: palette.textTitle,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      entry.url,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: AppType.body, color: palette.textDim),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded,
                  size: 18, color: palette.textDim),
            ],
          ),
        ),
      ),
    );
  }
}
