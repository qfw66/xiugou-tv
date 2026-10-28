import 'dart:ui';
import 'package:flutter/material.dart';
import '../../../core/api/models/vod_models.dart';
import '../../../core/config/models/vod_config.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';
import '../catalog/poster_image.dart';
import '../widgets/focus_ring.dart';

/// 收藏夹弹窗（Infuse × Netflix 融合设计）。
///
/// 视觉特性：
/// 1. 微透磨砂玻璃外壳（BackdropFilter 24px + 1px 细微高光边缘 + 呼吸感圆角）。
/// 2. 画报海报网格：沉浸式铺满海报 + 电影级底层渐变黑场，文字直接叠印，杜绝纯色硬底块。
/// 3. 微透胶囊角标与浮动删除控制钮：支持键盘焦点环与悬停状态平滑过渡。
/// 4. 完美遵循 WCAG 2.2 AAA 与深浅色自适应色彩体系。
///
/// [onRemoveItem] 返回 null 表示删除成功；返回字符串表示失败原因，会在弹窗内
/// 就地显示（失败反馈贴近操作处，便于直接重试）。
class FavoritesDialog extends StatefulWidget {
  final List<VodItem> items;
  final ValueChanged<VodItem> onItemTap;
  final Future<String?> Function(String id) onRemoveItem;

  /// 直播收藏（§33）。与点播收藏是两份独立数据，因此单独传入。
  final List<Live> liveItems;

  /// 为 null 时不展示「直播」分栏（旧调用方 / 测试可以不传）。
  final ValueChanged<Live>? onLiveTap;
  final Future<String?> Function(String key)? onRemoveLiveItem;

  const FavoritesDialog({
    super.key,
    required this.items,
    required this.onItemTap,
    required this.onRemoveItem,
    this.liveItems = const [],
    this.onLiveTap,
    this.onRemoveLiveItem,
  });

  @override
  State<FavoritesDialog> createState() => _FavoritesDialogState();
}

class _FavoritesDialogState extends State<FavoritesDialog> {
  late final List<VodItem> _items = List.of(widget.items);
  late final List<Live> _liveItems = List.of(widget.liveItems);
  String? _error;
  bool _removing = false;

  /// 0 = 点播收藏，1 = 直播收藏。
  int _tab = 0;

  Future<void> _remove(String id) async {
    if (_removing) return;
    _removing = true;
    final message = await widget.onRemoveItem(id);
    _removing = false;
    if (!mounted) return;
    if (message != null) {
      setState(() => _error = message);
      return;
    }
    setState(() {
      _error = null;
      _items.removeWhere((e) => e.id == id);
    });
  }

  Future<void> _removeLive(String key) async {
    final remove = widget.onRemoveLiveItem;
    if (_removing || remove == null) return;
    _removing = true;
    final message = await remove(key);
    _removing = false;
    if (!mounted) return;
    if (message != null) {
      setState(() => _error = message);
      return;
    }
    setState(() {
      _error = null;
      _liveItems.removeWhere((e) => e.key == key);
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final dialog = Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadii.lg),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: Container(
            width: 880,
            height: 620,
            decoration: BoxDecoration(
              color: isDark
                  ? const Color(0xE6101014)
                  : palette.panel.withValues(alpha: 0.90),
              borderRadius: BorderRadius.circular(AppRadii.lg),
              border: Border.all(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.12)
                    : palette.borderStrong,
                width: 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: isDark
                      ? Colors.black.withValues(alpha: 0.50)
                      : palette.accent.withValues(alpha: 0.15),
                  blurRadius: 36,
                  offset: const Offset(0, 16),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 顶部标题栏（Infuse 磨砂胶囊徽章 + 操作区）
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 20, 20, 16),
                  child: Row(
                    children: [
                      // 左侧星标徽章
                      Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          color: palette.accentWash,
                          borderRadius: BorderRadius.circular(AppRadii.sm),
                          border: Border.all(
                            color: palette.accentInk.withValues(alpha: 0.3),
                            width: 0.8,
                          ),
                        ),
                        child: Center(
                          child: Icon(
                            Icons.star_rounded,
                            color: palette.accentInk,
                            size: 20,
                          ),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '我的收藏',
                            style: TextStyle(
                              fontSize: AppType.h2,
                              fontWeight: FontWeight.w700,
                              color: palette.textTitle,
                              letterSpacing: -0.2,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _tab == 0
                                ? '共收藏 ${_items.length} 部影片'
                                : '共收藏 ${_liveItems.length} 个直播频道',
                            style: TextStyle(
                              fontSize: AppType.label,
                              color: palette.textSub,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const Spacer(),
                      // 关闭按钮
                      FocusOutline(
                        radius: AppRadii.pill,
                        child: Material(
                          color: Colors.transparent,
                          child: InkWell(
                            onTap: () => Navigator.of(context).pop(),
                            borderRadius: BorderRadius.circular(AppRadii.pill),
                            hoverColor: palette.raised,
                            child: Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: palette.border,
                                  width: 1,
                                ),
                              ),
                              child: Icon(
                                Icons.close_rounded,
                                color: palette.textSub,
                                size: 18,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // 分割线
                Divider(
                  height: 1,
                  thickness: 1,
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.06)
                      : palette.border,
                ),

                // 错误提示条
                if (_error != null)
                  Container(
                    key: const ValueKey('favorites-error'),
                    width: double.infinity,
                    margin: const EdgeInsets.fromLTRB(24, 12, 24, 0),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: palette.danger.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(AppRadii.sm),
                      border: Border.all(
                        color: palette.danger.withValues(alpha: 0.35),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.error_outline_rounded,
                          size: 16,
                          color: palette.danger,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _error!,
                            style: TextStyle(
                              color: palette.danger,
                              fontSize: AppType.label,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                // 分栏：点播 / 直播（§33）。仅在调用方提供直播收藏能力时出现。
                if (widget.onLiveTap != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 14, 24, 0),
                    child: Row(
                      children: [
                        ChoiceChip(
                          key: const ValueKey('favorites-tab-vod'),
                          label: Text('点播 ${_items.length}'),
                          labelStyle: TextStyle(
                              color: palette.textBody, fontSize: AppType.body),
                          backgroundColor: palette.raised,
                          selectedColor: palette.accent.withValues(alpha: 0.22),
                          selected: _tab == 0,
                          onSelected: (_) => setState(() => _tab = 0),
                        ),
                        const SizedBox(width: 8),
                        ChoiceChip(
                          key: const ValueKey('favorites-tab-live'),
                          label: Text('直播 ${_liveItems.length}'),
                          labelStyle: TextStyle(
                              color: palette.textBody, fontSize: AppType.body),
                          backgroundColor: palette.raised,
                          selectedColor: palette.accent.withValues(alpha: 0.22),
                          selected: _tab == 1,
                          onSelected: (_) => setState(() => _tab = 1),
                        ),
                      ],
                    ),
                  ),

                // 收藏网格内容区
                if (_tab == 0)
                  Expanded(
                    child: _items.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  width: 72,
                                  height: 72,
                                  decoration: BoxDecoration(
                                    color: palette.raised,
                                    borderRadius:
                                        BorderRadius.circular(AppRadii.pill),
                                    border: Border.all(
                                      color: isDark
                                          ? Colors.white.withValues(alpha: 0.08)
                                          : palette.borderStrong,
                                      width: 1,
                                    ),
                                  ),
                                  child: Icon(
                                    Icons.star_outline_rounded,
                                    size: 38,
                                    color: palette.textDim,
                                  ),
                                ),
                                const SizedBox(height: 16),
                                Text(
                                  '暂无收藏影片',
                                  style: TextStyle(
                                    color: palette.textTitle,
                                    fontSize: AppType.title,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  '在影片详情页点击「收藏」即可保存在这里随时观看',
                                  style: TextStyle(
                                    color: palette.textSub,
                                    fontSize: AppType.body,
                                  ),
                                ),
                              ],
                            ),
                          )
                        : GridView.builder(
                            padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
                            gridDelegate:
                                const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 4,
                              childAspectRatio: 0.68,
                              crossAxisSpacing: 16,
                              mainAxisSpacing: 16,
                            ),
                            itemCount: _items.length,
                            itemBuilder: (context, index) {
                              final item = _items[index];
                              return _FavoriteItemCard(
                                item: item,
                                onTap: () {
                                  Navigator.of(context).pop();
                                  widget.onItemTap(item);
                                },
                                onRemove: () => _remove(item.id),
                              );
                            },
                          ),
                  ),
                if (_tab == 1) Expanded(child: _buildLiveTab(context)),
              ],
            ),
          ),
        ),
      ),
    );

    // 窗口拖动只保留在窗口顶部那条带（§40-R3）：面板内部不再接管拖动，
    // 避免「拖哪里窗口都动」——用户明确要求只有上方能拖。
    return dialog;
  }

  /// 直播收藏列表（§33）。用列表而不是海报网格：频道没有海报，网格里一行
  /// 只放一两张卡片反而浪费横向空间；点整行即起播，右侧可直接取关。
  Widget _buildLiveTab(BuildContext context) {
    final palette = AppPalette.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (_liveItems.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.live_tv_outlined, size: 38, color: palette.textDim),
            const SizedBox(height: 16),
            Text(
              '暂无收藏频道',
              style: TextStyle(
                color: palette.textTitle,
                fontSize: AppType.title,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '在「直播频道」里点频道卡片上的星标即可收藏',
              style: TextStyle(color: palette.textSub, fontSize: AppType.body),
            ),
          ],
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
      itemCount: _liveItems.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final channel = _liveItems[index];
        return Container(
          key: ValueKey('live-favorite-${channel.key}'),
          decoration: BoxDecoration(
            color: palette.card,
            borderRadius: BorderRadius.circular(AppRadii.sm),
            border: Border.all(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.08)
                  : palette.border,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () {
                Navigator.of(context).pop();
                widget.onLiveTap?.call(channel);
              },
              hoverColor: palette.hover,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: Row(
                  children: [
                    Icon(Icons.live_tv_rounded,
                        size: 22, color: palette.accentInk),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            channel.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: palette.textTitle,
                              fontSize: AppType.title,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            channel.groupName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: palette.textSub, fontSize: AppType.body),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      key: ValueKey('live-favorite-remove-${channel.key}'),
                      tooltip: '取消收藏',
                      onPressed: () => _removeLive(channel.key),
                      icon: const Icon(Icons.close_rounded, size: 18),
                      color: palette.textSub,
                      visualDensity: VisualDensity.compact,
                    ),
                    Icon(Icons.play_circle_outline,
                        size: 22, color: palette.accentInk),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 收藏项画报卡片（Netflix 画报感 × Infuse 微透胶囊）
class _FavoriteItemCard extends StatefulWidget {
  final VodItem item;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  const _FavoriteItemCard({
    required this.item,
    required this.onTap,
    required this.onRemove,
  });

  @override
  State<_FavoriteItemCard> createState() => _FavoriteItemCardState();
}

class _FavoriteItemCardState extends State<_FavoriteItemCard> {
  bool _isHovered = false;

  Duration get _hoverMotion => _isHovered ? AppMotion.enter : AppMotion.exit;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final item = widget.item;

    return FocusRing(
      onTap: widget.onTap,
      semanticLabel: item.name,
      borderRadius: const BorderRadius.all(Radius.circular(AppRadii.lg)),
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedScale(
            scale: _isHovered ? 1.035 : 1.0,
            duration: _hoverMotion,
            curve: AppMotion.ease,
            child: AnimatedContainer(
              duration: _hoverMotion,
              curve: AppMotion.ease,
              decoration: BoxDecoration(
                color: palette.card,
                borderRadius: BorderRadius.circular(AppRadii.lg),
                border: Border.all(
                  color: _isHovered
                      ? palette.accentInk
                      : isDark
                          ? Colors.white.withValues(alpha: 0.10)
                          : palette.border,
                  width: _isHovered ? 1.5 : 1.0,
                ),
                boxShadow: _isHovered
                    ? AppShadows.cardHover(palette.accentInk)
                    : null,
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // 1. 全景海报封面（Netflix 式画报铺满）
                  Image(
                    image: posterImageProvider(item.pic, targetWidth: 360) ??
                        ResizeImage(NetworkImage(item.pic), width: 360),
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                      color: palette.raised,
                      child: Center(
                        child: Icon(
                          Icons.movie_creation_outlined,
                          size: 36,
                          color: palette.textDim,
                        ),
                      ),
                    ),
                  ),

                  // 2. 底部电影级平滑黑场渐变（从透明平滑过渡至浓郁深黑，保证标题绝对可读）
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          stops: const [0.0, 0.45, 0.72, 1.0],
                          colors: [
                            Colors.transparent,
                            Colors.transparent,
                            Colors.black.withValues(alpha: 0.65),
                            Colors.black.withValues(alpha: 0.94),
                          ],
                        ),
                      ),
                    ),
                  ),

                  // 3. 悬停微光高亮边缘遮罩
                  if (_isHovered)
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: palette.accentInk.withValues(alpha: 0.35),
                            width: 1.0,
                          ),
                          borderRadius: BorderRadius.circular(AppRadii.lg),
                        ),
                      ),
                    ),

                  // 4. 左上角信息备注（Infuse 磨砂玻璃胶囊）
                  if (item.remarks != null && item.remarks!.isNotEmpty)
                    Positioned(
                      left: 8,
                      top: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 3.5,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xCC000000),
                          borderRadius: BorderRadius.circular(AppRadii.xs),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.15),
                            width: 0.5,
                          ),
                        ),
                        child: Text(
                          item.remarks!,
                          style: const TextStyle(
                            fontSize: AppType.caption,
                            color: Color(0xFFFFC107),
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),

                  // 5. 右上角浮动删除收藏按钮（微透磨砂圆形，悬停变深红）
                  Positioned(
                    top: 8,
                    right: 8,
                    child: _RemoveButton(
                      itemId: item.id,
                      onRemove: widget.onRemove,
                    ),
                  ),

                  // 6. 底部标题与信息叠印
                  Positioned(
                    left: 10,
                    right: 10,
                    bottom: 10,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          item.name,
                          style: const TextStyle(
                            fontSize: AppType.body,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                            shadows: [
                              Shadow(
                                color: Color(0xCC000000),
                                blurRadius: 4,
                                offset: Offset(0, 1),
                              ),
                            ],
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (item.typeName != null &&
                            item.typeName!.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            item.typeName!,
                            style: TextStyle(
                              fontSize: AppType.caption,
                              color: Colors.white.withValues(alpha: 0.70),
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 海报右上角的删除收藏按钮。
///
/// 采用微透深底保证在任何亮/暗海报上均清晰可见；
/// 悬停时平滑转为深红警示；内置 FocusRing 支持遥控与键盘焦点无障碍导航。
class _RemoveButton extends StatefulWidget {
  final String itemId;
  final VoidCallback onRemove;

  const _RemoveButton({required this.itemId, required this.onRemove});

  @override
  State<_RemoveButton> createState() => _RemoveButtonState();
}

class _RemoveButtonState extends State<_RemoveButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return FocusRing(
      onTap: widget.onRemove,
      semanticLabel: '移除收藏',
      borderRadius: BorderRadius.circular(AppRadii.pill),
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          key: ValueKey('favorite-remove-${widget.itemId}'),
          onTap: widget.onRemove,
          child: AnimatedContainer(
            duration: _isHovered ? AppMotion.enter : AppMotion.exit,
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _isHovered
                  ? const Color(0xE6C62828)
                  : const Color(0xCC000000),
              border: Border.all(
                color: _isHovered
                    ? Colors.white.withValues(alpha: 0.3)
                    : Colors.white.withValues(alpha: 0.18),
                width: 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.35),
                  blurRadius: 4,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: const Center(
              child: Icon(
                Icons.close_rounded,
                size: 14,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
