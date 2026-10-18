import 'package:flutter/material.dart';
import '../../../core/config/config_repository.dart';

/// 多仓（Depot）订阅选择弹窗：列出仓库清单，返回用户选择的条目下标；取消返回 null
class DepotSelectionDialog extends StatelessWidget {
  final List<DepotEntry> entries;

  const DepotSelectionDialog({super.key, required this.entries});

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF181820),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Color(0xFF2E2E3C), width: 1),
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
                    color: const Color(0xFF282834),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.account_tree_rounded, color: Color(0xFFE50914), size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '选择订阅仓库',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
                      ),
                      Text(
                        '检测到多仓订阅，共 ${entries.length} 个来源',
                        style: const TextStyle(fontSize: 12, color: Color(0xFF888898)),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded, color: Color(0xFFA0A0B0), size: 22),
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
            const Text(
              '提示：选择后将加载对应子配置；若选中的仍是多仓会继续提示选择。',
              style: TextStyle(fontSize: 11, color: Color(0xFF686878)),
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
    final entry = widget.entry;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: _hovered ? const Color(0xFF2A2A38) : const Color(0xFF20202A),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: _hovered ? const Color(0xFFE50914) : const Color(0xFF323242),
              width: 1,
            ),
          ),
          child: Row(
            children: [
              Icon(
                Icons.folder_rounded,
                size: 18,
                color: _hovered ? const Color(0xFFE50914) : const Color(0xFF8A8A9A),
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
                      style: const TextStyle(
                        fontSize: 13.5,
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      entry.url,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11.5, color: Color(0xFF7A7A8A)),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, size: 18, color: Color(0xFF6A6A7A)),
            ],
          ),
        ),
      ),
    );
  }
}
