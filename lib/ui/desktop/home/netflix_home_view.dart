import 'dart:async';
import 'package:flutter/material.dart';
import '../../../core/api/models/vod_models.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';
import '../widgets/focus_ring.dart';

/// 海报加载规格。
///
/// 横滑轨道里是 154×236 的小卡，512 宽足够（快）；首页大屏要把竖版海报横向
/// 铺满 480 高，必须拿原图 + 按设备像素解码，否则会被放大 2–3 倍糊成一片。
class PosterSpec {
  const PosterSpec({required this.targetWidth, this.highRes = false});

  /// 解码目标宽度（设备像素，只缩不放）
  final int targetWidth;

  /// 是否要原图（豆瓣把 `m_ratio_poster` 提到 `raw`）
  final bool highRes;
}

/// 仿 Netflix 首页视图 (Netflix Home View)
///
/// 架构特性：
/// 1. 顶部 Hero Billboard 巨幅滚动大屏（自动轮播、电影级暗场融合、高对比立即播放/详情动作组）。
/// 2. 垂直流式排列各个分类的横滑画报轨道（Netflix Rows）。
/// 3. 每行配备左右翻页微透胶囊与“查看全部”跳转。
/// 4. 严密遵循 WCAG 2.2 AAA（全量 FocusRing）与 AppPalette / AppMotion 设计规范。
class NetflixHomeView extends StatefulWidget {
  final Map<String, List<VodItem>> categoryItemsMap;
  final List<VodCategory> categories;
  final ValueChanged<VodItem> onItemTap;
  final ValueChanged<VodCategory> onCategoryTap;
  final ImageProvider? Function(VodItem item, PosterSpec spec)? imageProviderFor;
  final bool isLoading;

  /// 垂直滚动控制器（外部传入时由外部持有；用于触底续页判断）。
  final ScrollController? scrollController;

  /// 滚动通知（用于豆瓣首页无限滚动）；为空时不额外包一层监听。
  final NotificationListenerCallback<ScrollNotification>? onScrollNotification;

  const NetflixHomeView({
    super.key,
    required this.categoryItemsMap,
    required this.categories,
    required this.onItemTap,
    required this.onCategoryTap,
    this.imageProviderFor,
    this.isLoading = false,
    this.scrollController,
    this.onScrollNotification,
  });

  @override
  State<NetflixHomeView> createState() => _NetflixHomeViewState();
}

class _NetflixHomeViewState extends State<NetflixHomeView> {
  /// 外部没给控制器时才自己建一个（自建才由自己释放）。
  ScrollController? _ownScrollController;

  ScrollController get _scrollController =>
      widget.scrollController ??
      (_ownScrollController ??= ScrollController());

  @override
  void dispose() {
    _ownScrollController?.dispose();
    super.dispose();
  }

  /// 提取用于大屏轮播的影片列表（从热播电影或首个有数据的分类中取前 6 部）
  List<VodItem> _extractBillboardItems() {
    if (widget.categoryItemsMap.isEmpty) return const [];
    // 优先从首个分类或热播中取
    for (final cat in widget.categories) {
      final list = widget.categoryItemsMap[cat.id];
      if (list != null && list.isNotEmpty) {
        return list.take(6).toList();
      }
    }
    return const [];
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final billboardItems = _extractBillboardItems();

    if (widget.isLoading && billboardItems.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 36,
              height: 36,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                valueColor: AlwaysStoppedAnimation<Color>(palette.accentInk),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              '正在载入热门影视大厅…',
              style: TextStyle(
                color: palette.textSub,
                fontSize: AppType.body,
              ),
            ),
          ],
        ),
      );
    }

    final content = SingleChildScrollView(
      controller: _scrollController,
      physics: const BouncingScrollPhysics(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 1. 顶部 Hero Billboard 巨幅大屏轮播
          if (billboardItems.isNotEmpty)
            _HeroBillboard(
              items: billboardItems,
              onItemTap: widget.onItemTap,
              imageProviderFor: widget.imageProviderFor,
            ),

          const SizedBox(height: 20),

          // 2. 往下翻的各分类横滑画报流 (Netflix Rows)
          for (final category in widget.categories) ...[
            if (widget.categoryItemsMap[category.id] != null &&
                widget.categoryItemsMap[category.id]!.isNotEmpty) ...[
              _NetflixCategoryRow(
                category: category,
                items: widget.categoryItemsMap[category.id]!,
                onItemTap: widget.onItemTap,
                onViewAll: () => widget.onCategoryTap(category),
                imageProviderFor: widget.imageProviderFor,
              ),
              const SizedBox(height: 26),
            ],
          ],

          const SizedBox(height: 40),
        ],
      ),
    );

    final onNotification = widget.onScrollNotification;
    if (onNotification == null) return content;
    // 触底续页：横向画报轨道的通知也会冒泡上来，由回调按 Axis 过滤。
    return NotificationListener<ScrollNotification>(
      onNotification: onNotification,
      child: content,
    );
  }
}

/// 顶部巨幅滚动大屏组件 (Hero Billboard)
class _HeroBillboard extends StatefulWidget {
  final List<VodItem> items;
  final ValueChanged<VodItem> onItemTap;
  final ImageProvider? Function(VodItem item, PosterSpec spec)?
      imageProviderFor;

  const _HeroBillboard({
    required this.items,
    required this.onItemTap,
    this.imageProviderFor,
  });

  @override
  State<_HeroBillboard> createState() => _HeroBillboardState();
}

class _HeroBillboardState extends State<_HeroBillboard> {
  int _currentIndex = 0;
  Timer? _autoPlayTimer;
  bool _isHovering = false;

  @override
  void initState() {
    super.initState();
    _startAutoPlay();
  }

  @override
  void didUpdateWidget(covariant _HeroBillboard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.items.length != oldWidget.items.length) {
      _currentIndex = 0;
      _startAutoPlay();
    }
  }

  @override
  void dispose() {
    _autoPlayTimer?.cancel();
    super.dispose();
  }

  void _startAutoPlay() {
    _autoPlayTimer?.cancel();
    if (widget.items.length <= 1) return;
    _autoPlayTimer = Timer.periodic(const Duration(seconds: 6), (_) {
      if (!mounted || _isHovering) return;
      setState(() {
        _currentIndex = (_currentIndex + 1) % widget.items.length;
      });
    });
  }

  /// 大屏海报的解码宽度：按窗口逻辑宽度 × 设备像素。
  ///
  /// 上限 1600 是内存口径：竖版海报按宽解码后高度约 1.5 倍，1600 宽一张
  /// 约 15MB，而大屏要轮播好几张——再往上翻会让 100MB 的 ImageCache 被占满，
  /// 反而把下方轨道的海报挤掉。
  int _heroTargetWidth(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return (width * dpr).round().clamp(720, 1600);
  }

  void _next() {
    if (widget.items.isEmpty) return;
    setState(() {
      _currentIndex = (_currentIndex + 1) % widget.items.length;
    });
  }

  void _prev() {
    if (widget.items.isEmpty) return;
    setState(() {
      _currentIndex =
          (_currentIndex - 1 + widget.items.length) % widget.items.length;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) return const SizedBox.shrink();
    final palette = AppPalette.of(context);
    final item = widget.items[_currentIndex.clamp(0, widget.items.length - 1)];

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovering = true),
      onExit: (_) => setState(() => _isHovering = false),
      child: SizedBox(
        height: 480,
        width: double.infinity,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 1. 全景海报背景图 (淡入淡出动画)
            AnimatedSwitcher(
              duration: AppMotion.heroFade,
              switchInCurve: Curves.easeInOutCubic,
              switchOutCurve: Curves.easeInOutCubic,
              child: SizedBox(
                key: ValueKey(item.id),
                width: double.infinity,
                height: 480,
                child: Image(
                  image: widget.imageProviderFor?.call(
                        item,
                        PosterSpec(
                          targetWidth: _heroTargetWidth(context),
                          highRes: true,
                        ),
                      ) ??
                      NetworkImage(item.pic),
                  fit: BoxFit.cover,
                  filterQuality: FilterQuality.medium,
                  errorBuilder: (_, __, ___) => Container(
                    color: const Color(0xFF1E2330),
                    child: Center(
                      child: Icon(
                        Icons.movie_creation_outlined,
                        size: 64,
                        color: palette.textDim,
                      ),
                    ),
                  ),
                ),
              ),
            ),

            // 2. 左侧深邃黑色羽化渐变（保证左侧文字极其清晰）
            const Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    stops: [0.0, 0.40, 0.70, 1.0],
                    colors: [
                      Color(0xF5101014),
                      Color(0xD9101014),
                      Color(0x66101014),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),

            // 3. 底部电影级平滑黑场渐变（与下方内容区无缝融合）
            const Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: [0.0, 0.50, 0.82, 1.0],
                    colors: [
                      Colors.transparent,
                      Colors.transparent,
                      Color(0xB3101014),
                      Color(0xFF101014),
                    ],
                  ),
                ),
              ),
            ),

            // 4. 左下角沉浸文字与操作区
            Positioned(
              left: 36,
              right: 120,
              bottom: 36,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 标签组（窄窗自动换行：大屏在 400 宽时会溢出）
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      // Netflix 风格特色热度徽章
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2.5),
                        decoration: BoxDecoration(
                          color: const Color(0xFFE50914),
                          borderRadius: BorderRadius.circular(AppRadii.xs),
                        ),
                        child: const Text(
                          '今日焦点',
                          style: TextStyle(
                            fontSize: AppType.caption,
                            fontWeight: FontWeight.w900,
                            color: Colors.white,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),

                      // 评分胶囊
                      if (item.score != null && item.score!.isNotEmpty) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: const Color(0x99000000),
                            borderRadius: BorderRadius.circular(AppRadii.xs),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.2),
                              width: 0.5,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text(
                                '★ ',
                                style: TextStyle(
                                  color: Color(0xFFFFC107),
                                  fontSize: AppType.micro,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              Text(
                                item.score!,
                                style: const TextStyle(
                                  color: Color(0xFFFFC107),
                                  fontSize: AppType.caption,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(width: 4),
                              const Text(
                                '豆瓣',
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: AppType.micro,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],

                      // 年份/备注
                      if (item.year != null && item.year!.isNotEmpty) ...[
                        Text(
                          item.year!,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.75),
                            fontSize: AppType.caption,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                      if (item.remarks != null && item.remarks!.isNotEmpty)
                        Text(
                          '· ${item.remarks!}',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.75),
                            fontSize: AppType.caption,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  // 巨幅标题
                  Text(
                    item.name,
                    style: const TextStyle(
                      fontSize: AppType.display,
                      fontWeight: FontWeight.w900,
                      color: Colors.white,
                      letterSpacing: -0.5,
                      shadows: [
                        Shadow(
                          color: Color(0x99000000),
                          blurRadius: 12,
                          offset: Offset(0, 2),
                        ),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 8),

                  // 剧情简介/摘要
                  if (item.content != null && item.content!.isNotEmpty)
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 640),
                      child: Text(
                        item.content!.replaceAll(RegExp(r'<[^>]*>'), '').trim(),
                        style: TextStyle(
                          fontSize: AppType.body,
                          color: Colors.white.withValues(alpha: 0.85),
                          height: 1.45,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  const SizedBox(height: 18),

                  // 核心行动按钮组（窄窗自动换行：大屏在 400 宽时会溢出）
                  Wrap(
                    spacing: 14,
                    runSpacing: 10,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      // 主按钮：立即播放（Netflix 经典纯白大药丸）
                      FocusRing(
                        onTap: () => widget.onItemTap(item),
                        semanticLabel: '立即播放 ${item.name}',
                        borderRadius: BorderRadius.circular(AppRadii.pill),
                        child: Material(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(AppRadii.pill),
                          child: InkWell(
                            onTap: () => widget.onItemTap(item),
                            borderRadius: BorderRadius.circular(AppRadii.pill),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 24, vertical: 11),
                              decoration: BoxDecoration(
                                borderRadius:
                                    BorderRadius.circular(AppRadii.pill),
                                boxShadow: const [
                                  BoxShadow(
                                    color: Color(0x55000000),
                                    blurRadius: 16,
                                    offset: Offset(0, 4),
                                  ),
                                ],
                              ),
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.play_arrow_rounded,
                                      color: Color(0xFF101014), size: 22),
                                  SizedBox(width: 6),
                                  Text(
                                    '立即播放',
                                    style: TextStyle(
                                      color: Color(0xFF101014),
                                      fontSize: AppType.lead,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),

                      // 次按钮：详细信息（微透磨砂胶囊）
                      FocusRing(
                        onTap: () => widget.onItemTap(item),
                        semanticLabel: '详细信息',
                        borderRadius: BorderRadius.circular(AppRadii.pill),
                        child: Material(
                          color: Colors.transparent,
                          child: InkWell(
                            onTap: () => widget.onItemTap(item),
                            borderRadius: BorderRadius.circular(AppRadii.pill),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 20, vertical: 10),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.16),
                                borderRadius:
                                    BorderRadius.circular(AppRadii.pill),
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.35),
                                  width: 1,
                                ),
                              ),
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.info_outline_rounded,
                                      color: Colors.white, size: 20),
                                  SizedBox(width: 6),
                                  Text(
                                    '详细信息',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: AppType.title,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // 5. 底部右侧轮播指示条组
            Positioned(
              right: 36,
              bottom: 36,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < widget.items.length; i++) ...[
                    GestureDetector(
                      onTap: () => setState(() => _currentIndex = i),
                      child: AnimatedContainer(
                        duration: AppMotion.enter,
                        margin: const EdgeInsets.symmetric(horizontal: 3),
                        width: _currentIndex == i ? 28 : 10,
                        height: 4,
                        decoration: BoxDecoration(
                          color: _currentIndex == i
                              ? palette.accentInk
                              : Colors.white.withValues(alpha: 0.28),
                          borderRadius:
                              BorderRadius.circular(AppRadii.hairline),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),

            // 6. 左右悬停翻页按钮（鼠标靠近时可见）
            if (_isHovering) ...[
              Positioned(
                left: 12,
                top: 0,
                bottom: 0,
                child: Center(
                  child: FocusOutline(
                    radius: AppRadii.pill,
                    child: IconButton(
                      onPressed: _prev,
                      icon: const Icon(Icons.arrow_back_ios_new_rounded),
                      color: Colors.white,
                      style: IconButton.styleFrom(
                        backgroundColor: const Color(0x66000000),
                        hoverColor: const Color(0x99000000),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                right: 12,
                top: 0,
                bottom: 0,
                child: Center(
                  child: FocusOutline(
                    radius: AppRadii.pill,
                    child: IconButton(
                      onPressed: _next,
                      icon: const Icon(Icons.arrow_forward_ios_rounded),
                      color: Colors.white,
                      style: IconButton.styleFrom(
                        backgroundColor: const Color(0x66000000),
                        hoverColor: const Color(0x99000000),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 分类横向画报流轨道 (Netflix Category Row)
class _NetflixCategoryRow extends StatefulWidget {
  final VodCategory category;
  final List<VodItem> items;
  final ValueChanged<VodItem> onItemTap;
  final VoidCallback onViewAll;
  final ImageProvider? Function(VodItem item, PosterSpec spec)?
      imageProviderFor;

  const _NetflixCategoryRow({
    required this.category,
    required this.items,
    required this.onItemTap,
    required this.onViewAll,
    this.imageProviderFor,
  });

  @override
  State<_NetflixCategoryRow> createState() => _NetflixCategoryRowState();
}

class _NetflixCategoryRowState extends State<_NetflixCategoryRow> {
  final ScrollController _scrollController = ScrollController();
  bool _isHovering = false;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scroll(double delta) {
    if (!_scrollController.hasClients) return;
    final target = (_scrollController.offset + delta)
        .clamp(0.0, _scrollController.position.maxScrollExtent);
    _scrollController.animateTo(
      target,
      duration: AppMotion.rowScroll,
      curve: Curves.easeOutCubic,
    );
  }

  String _formatCategoryTitle(String name) {
    if (name.contains('电影')) return '🔥 $name';
    if (name.contains('剧集') || name.contains('电视剧')) return '📺 $name';
    if (name.contains('综艺')) return '🍿 $name';
    if (name.contains('动漫')) return '⚡ $name';
    if (name.contains('Top')) return '🎬 $name';
    return name;
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovering = true),
      onExit: (_) => setState(() => _isHovering = false),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 轨道标题栏与“查看全部”
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 36),
            child: Row(
              children: [
                Text(
                  _formatCategoryTitle(widget.category.name),
                  style: TextStyle(
                    fontSize: AppType.heading,
                    fontWeight: FontWeight.w700,
                    color: palette.textTitle,
                    letterSpacing: -0.2,
                  ),
                ),
                const Spacer(),
                FocusRing(
                  onTap: widget.onViewAll,
                  semanticLabel: '查看全部 ${widget.category.name}',
                  borderRadius: BorderRadius.circular(AppRadii.sm),
                  child: InkWell(
                    onTap: widget.onViewAll,
                    borderRadius: BorderRadius.circular(AppRadii.sm),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '查看全部',
                            style: TextStyle(
                              fontSize: AppType.caption,
                              fontWeight: FontWeight.w600,
                              color: palette.accentInk,
                            ),
                          ),
                          const SizedBox(width: 2),
                          Icon(
                            Icons.arrow_forward_ios_rounded,
                            size: 11,
                            color: palette.accentInk,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // 横向滚动卡片列表 + 左右悬停翻页按钮
          SizedBox(
            height: 236,
            child: Stack(
              children: [
                ListView.builder(
                  controller: _scrollController,
                  scrollDirection: Axis.horizontal,
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.symmetric(horizontal: 36),
                  itemCount: widget.items.length,
                  itemBuilder: (context, index) {
                    final item = widget.items[index];
                    return Padding(
                      padding: const EdgeInsets.only(right: 14),
                      child: _NetflixRowCard(
                        item: item,
                        onTap: () => widget.onItemTap(item),
                        imageProviderFor: widget.imageProviderFor,
                      ),
                    );
                  },
                ),

                // 左右悬停翻页圆纽
                if (_isHovering) ...[
                  Positioned(
                    left: 12,
                    top: 0,
                    bottom: 0,
                    child: Center(
                      child: FocusOutline(
                        radius: AppRadii.pill,
                        child: IconButton(
                          onPressed: () => _scroll(-460),
                          icon: const Icon(Icons.arrow_back_ios_new_rounded),
                          color: Colors.white,
                          style: IconButton.styleFrom(
                            backgroundColor: const Color(0xB3101014),
                            hoverColor: const Color(0xE6101014),
                            side: BorderSide(
                              color: Colors.white.withValues(alpha: 0.15),
                              width: 0.8,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    right: 12,
                    top: 0,
                    bottom: 0,
                    child: Center(
                      child: FocusOutline(
                        radius: AppRadii.pill,
                        child: IconButton(
                          onPressed: () => _scroll(460),
                          icon: const Icon(Icons.arrow_forward_ios_rounded),
                          color: Colors.white,
                          style: IconButton.styleFrom(
                            backgroundColor: const Color(0xB3101014),
                            hoverColor: const Color(0xE6101014),
                            side: BorderSide(
                              color: Colors.white.withValues(alpha: 0.15),
                              width: 0.8,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 轨道内的影视画报卡片 (Netflix Row Poster Card)
class _NetflixRowCard extends StatefulWidget {
  final VodItem item;
  final VoidCallback onTap;
  final ImageProvider? Function(VodItem item, PosterSpec spec)?
      imageProviderFor;

  const _NetflixRowCard({
    required this.item,
    required this.onTap,
    this.imageProviderFor,
  });

  @override
  State<_NetflixRowCard> createState() => _NetflixRowCardState();
}

class _NetflixRowCardState extends State<_NetflixRowCard> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final item = widget.item;

    return FocusRing(
      onTap: widget.onTap,
      semanticLabel: item.name,
      borderRadius: BorderRadius.circular(AppRadii.lg),
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedScale(
            scale: _isHovered ? 1.04 : 1.0,
            duration: _isHovered ? AppMotion.enter : AppMotion.exit,
            curve: AppMotion.ease,
            child: AnimatedContainer(
              duration: _isHovered ? AppMotion.enter : AppMotion.exit,
              curve: AppMotion.ease,
              width: 154,
              height: 236,
              decoration: BoxDecoration(
                color: palette.card,
                borderRadius: BorderRadius.circular(AppRadii.lg),
                border: Border.all(
                  color: _isHovered
                      ? palette.accentInk
                      : context.glassBorder,
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
                  // 1. 全景海报封面（铺满）
                  Image(
                    image: widget.imageProviderFor?.call(
                          item,
                          const PosterSpec(targetWidth: 512),
                        ) ??
                        NetworkImage(item.pic),
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

                  // 2. 底部电影级平滑黑场渐变
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

                  // 3. 悬停微高光边缘遮罩
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

                  // 4. 左上角评分角标
                  if (item.score != null && item.score!.isNotEmpty)
                    Positioned(
                      left: 7,
                      top: 7,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2.5),
                        decoration: BoxDecoration(
                          color: const Color(0xCC000000),
                          borderRadius: BorderRadius.circular(AppRadii.xs),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.15),
                            width: 0.5,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text(
                              '★ ',
                              style: TextStyle(
                                fontSize: AppType.micro,
                                color: Color(0xFFFFC107),
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              item.score!,
                              style: const TextStyle(
                                fontSize: AppType.caption,
                                color: Color(0xFFFFC107),
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                  // 5. 底部叠印标题与副标题
                  Positioned(
                    left: 9,
                    right: 9,
                    bottom: 9,
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
                        if (item.remarks != null &&
                            item.remarks!.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            item.remarks!,
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
