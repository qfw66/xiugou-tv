import 'dart:async';
import 'package:flutter/material.dart';
import '../../../core/api/models/vod_models.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';
import '../catalog/poster_image.dart';
import '../widgets/focus_ring.dart';

/// 海报加载规格。
///
/// 横滑轨道里是 154×236 的小卡，512 宽足够（快）；首页大屏要把竖版海报横向
/// 铺满 480 高，必须拿原图 + 按设备像素解码，否则会被放大 2–3 倍糊成一片。
class PosterSpec {
  const PosterSpec({
    required this.targetWidth,
    this.highRes = false,
    this.urlOverride,
  });

  /// 解码目标宽度（设备像素，只缩不放）
  final int targetWidth;

  /// 是否要原图（豆瓣把 `m_ratio_poster` 提到 `raw`）
  final bool highRes;

  /// 换一张源图（首页巨幅位用横版剧照）；为空则按 [highRes] 走原海报逻辑。
  ///
  /// 只在**能拿到横图**时填，拿不到就留空 → 调用方回落竖版原图。
  final String? urlOverride;
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

  /// 首页巨幅位专用的横版剧照解析（返回 null 时回落竖版海报）。
  final Future<String?> Function(VodItem item)? stillUrlFor;
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
    this.stillUrlFor,
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
              stillUrlFor: widget.stillUrlFor,
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

  /// 取该片的横版剧照（16:9）；返回 null 表示没有，界面回落竖版海报。
  final Future<String?> Function(VodItem item)? stillUrlFor;

  const _HeroBillboard({
    required this.items,
    required this.onItemTap,
    this.imageProviderFor,
    this.stillUrlFor,
  });

  @override
  State<_HeroBillboard> createState() => _HeroBillboardState();
}

class _HeroBillboardState extends State<_HeroBillboard> {
  int _currentIndex = 0;
  Timer? _autoPlayTimer;
  bool _isHovering = false;

  /// 已拿到的横图地址（键为 `item.id`）；没拿到的不进表，继续走竖版海报。
  final Map<String, String> _stillUrls = <String, String>{};

  /// 已经问过的 id，避免每帧重复请求。
  final Set<String> _stillRequested = <String>{};

  @override
  void initState() {
    super.initState();
    _startAutoPlay();
    _resolveStills();
  }

  @override
  void didUpdateWidget(covariant _HeroBillboard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.items.length != oldWidget.items.length) {
      _currentIndex = 0;
      _startAutoPlay();
    }
    _resolveStills();
  }

  /// 并发问一遍尚未解析过的条目；谁先回来谁先显示，不阻塞首屏。
  void _resolveStills() {
    final resolve = widget.stillUrlFor;
    if (resolve == null) return;
    for (final item in widget.items) {
      if (!_stillRequested.add(item.id)) continue;
      resolve(item).then((url) {
        if (!mounted || url == null || url.isEmpty) return;
        setState(() => _stillUrls[item.id] = url);
      }).catchError((Object _) {
        // 拉不到就用竖版海报，不打扰用户
      });
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
    final tone = _HeroTone.of(context);
    final item = widget.items[_currentIndex.clamp(0, widget.items.length - 1)];
    // 有横版剧照就用剧照；没有则 null → 走原来的竖版原图。
    final stillUrl = _stillUrls[item.id];

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovering = true),
      onExit: (_) => setState(() => _isHovering = false),
      child: SizedBox(
        height: 480,
        width: double.infinity,
        child: Stack(
          key: const ValueKey('hero-billboard'),
          fit: StackFit.expand,
          children: [
            // 1. 全景海报背景图 (淡入淡出动画)
            AnimatedSwitcher(
              duration: AppMotion.heroFade,
              switchInCurve: Curves.easeInOutCubic,
              switchOutCurve: Curves.easeInOutCubic,
              child: SizedBox(
                // 横图到达后 key 变化 → 从竖版海报淡入横图，不闪白
                key: ValueKey('${item.id}|${stillUrl ?? ''}'),
                width: double.infinity,
                height: 480,
                child: Image(
                  image: widget.imageProviderFor?.call(
                        item,
                        PosterSpec(
                          targetWidth: _heroTargetWidth(context),
                          highRes: true,
                          urlOverride: stillUrl,
                        ),
                      ) ??
                      posterImageProvider(item.pic) ??
                      NetworkImage(item.pic),
                  fit: BoxFit.cover,
                  filterQuality: FilterQuality.medium,
                  errorBuilder: (_, __, ___) => Container(
                    color: tone.placeholder,
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

            // 2. 底部接缝渐隐：只把海报下缘溶进页面底色，避免水平硬边。
            //    起点以下整张海报原样可见——浅色主题不再用白场压图，
            //    这正是「海报看得见」的关键；文字对比交给自身阴影。
            //    起点按主题取（浅色 0.58 / 深色 0.40）：白色泛白更扎眼，
            //    底座区收窄到 42% 才不抢画面。
            //    首末同色、只改 alpha，避免 sRGB 插值经过灰色。
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: <double>[0.0, tone.seamStart, 1.0],
                      colors: [
                        palette.background.withValues(alpha: 0),
                        palette.background.withValues(alpha: 0),
                        palette.background,
                      ],
                    ),
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
                            color: tone.capsuleBg,
                            borderRadius: BorderRadius.circular(AppRadii.xs),
                            border: Border.all(
                              color: tone.capsuleBorder,
                              width: 0.5,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                '★ ',
                                style: TextStyle(
                                  color: tone.scoreInk,
                                  fontSize: AppType.micro,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              Text(
                                item.score!,
                                style: TextStyle(
                                  color: tone.scoreInk,
                                  fontSize: AppType.caption,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(width: 4),
                              Text(
                                '豆瓣',
                                style: TextStyle(
                                  color: tone.meta,
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
                            color: tone.meta,
                            fontSize: AppType.caption,
                            fontWeight: FontWeight.w500,
                            shadows: tone.textShadows,
                          ),
                        ),
                      ],
                      if (item.remarks != null && item.remarks!.isNotEmpty)
                        Text(
                          '· ${item.remarks!}',
                          style: TextStyle(
                            color: tone.meta,
                            fontSize: AppType.caption,
                            fontWeight: FontWeight.w500,
                            shadows: tone.textShadows,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  // 巨幅标题
                  Text(
                    item.name,
                    style: TextStyle(
                      fontSize: AppType.display,
                      fontWeight: FontWeight.w900,
                      color: tone.title,
                      letterSpacing: -0.5,
                      shadows: tone.textShadows,
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
                          color: tone.body,
                          height: 1.45,
                          shadows: tone.textShadows,
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
                      // 主按钮：立即播放（深色主题＝纯白药丸，浅色主题＝近黑药丸）
                      FocusRing(
                        onTap: () => widget.onItemTap(item),
                        semanticLabel: '立即播放 ${item.name}',
                        borderRadius: BorderRadius.circular(AppRadii.pill),
                        child: Material(
                          color: tone.ctaBg,
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
                                boxShadow: [
                                  BoxShadow(
                                    color: tone.ctaShadow,
                                    blurRadius: 16,
                                    offset: const Offset(0, 4),
                                  ),
                                ],
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.play_arrow_rounded,
                                      color: tone.ctaInk, size: 22),
                                  const SizedBox(width: 6),
                                  Text(
                                    '立即播放',
                                    style: TextStyle(
                                      color: tone.ctaInk,
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
                                color: tone.ghostBg,
                                borderRadius:
                                    BorderRadius.circular(AppRadii.pill),
                                border: Border.all(
                                  color: tone.ghostBorder,
                                  width: 1,
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.info_outline_rounded,
                                      color: tone.ghostInk, size: 20),
                                  const SizedBox(width: 6),
                                  Text(
                                    '详细信息',
                                    style: TextStyle(
                                      color: tone.ghostInk,
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
                              : tone.dotInactive,
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

/// 巨幅位的「遮罩 + 前景」配色对。
///
/// 遮罩只是背景，可读性靠**前景跟着一起换**：深色主题＝黑场 + 白字，
/// 浅色主题＝白场 + 深字。只把渐变刷白、文字仍留白，就是白底白字（1:1）。
///
/// 两端遮罩 alpha 完全一致（左侧 0.96 / 0.85 / 0.40，底部 0.70），所以两种主题
/// 在文字区拿到同一档强度。最坏情况（整块图纯黑、左侧遮罩 0.96 白）实测：
/// 标题 `#14141A` → **16.8:1**、正文 `#3A3A46` → **10.1:1**、
/// 次级 `#5B5B6C` → **6.1:1**、评分 `#7A4200` 压 82% 白胶囊 → **5.3:1**，
/// 全部 ≥ WCAG AA 的 4.5:1。
///
/// 深色主题取值与 v1.0.1 视觉等价（唯一差别：评分胶囊里的「豆瓣」
/// 从 `white70` 改到 75%，肉眼不可见）。
@immutable
class _HeroTone {
  const _HeroTone({
    required this.title,
    required this.body,
    required this.meta,
    required this.capsuleBg,
    required this.capsuleBorder,
    required this.scoreInk,
    required this.ctaBg,
    required this.ctaInk,
    required this.ctaShadow,
    required this.ghostBg,
    required this.ghostBorder,
    required this.ghostInk,
    required this.dotInactive,
    required this.placeholder,
    required this.textShadows,
    required this.seamStart,
  });

  /// 巨幅位标题
  final Color title;

  /// 剧情简介
  final Color body;

  /// 年份 / 备注 / 胶囊里的「豆瓣」
  final Color meta;

  /// 评分胶囊底与描边
  final Color capsuleBg;
  final Color capsuleBorder;

  /// 星级 / 分数（浅色下必须压深，`#FFC107` 在白底只有 1.7:1）
  final Color scoreInk;

  /// 主按钮（立即播放）
  final Color ctaBg;
  final Color ctaInk;
  final Color ctaShadow;

  /// 次按钮（详细信息）
  final Color ghostBg;
  final Color ghostBorder;
  final Color ghostInk;

  /// 未选中轮播点
  final Color dotInactive;

  /// 海报加载失败的占位底
  final Color placeholder;

  /// 文字描边阴影：不再有压图遮罩后，靠它保证文字压在海报上也清晰。
  ///
  /// 深色＝白字配黑晕，浅色＝深字配白晕；近距硬阴影保边缘、远距柔光保
  /// 暗部，两层叠加在明暗海报上都够用。
  final List<Shadow>? textShadows;

  /// 底部接缝渐隐的起点（0–1，越小＝白色/底色区域越高）。
  ///
  /// 深色压黑不显眼，保持 0.40；浅色用白，60% 高度都泛白会糊住海报，
  /// 收到 0.58（底座区 42%，约 202px）才不抢画面。
  final double seamStart;

  /// 深色：v1.0.1 的白字配色，但遮罩换成文字阴影（不再压黑整幅图）。
  static const _HeroTone dark = _HeroTone(
    title: Colors.white,
    body: Color(0xD9FFFFFF),
    meta: Color(0xBFFFFFFF),
    capsuleBg: Color(0x99000000),
    capsuleBorder: Color(0x33FFFFFF),
    scoreInk: Color(0xFFFFC107),
    ctaBg: Colors.white,
    ctaInk: Color(0xFF101014),
    ctaShadow: Color(0x55000000),
    ghostBg: Color(0x29FFFFFF),
    ghostBorder: Color(0x59FFFFFF),
    ghostInk: Colors.white,
    dotInactive: Color(0x47FFFFFF),
    placeholder: Color(0xFF1E2330),
    textShadows: [
      Shadow(color: Color(0xCC000000), blurRadius: 6, offset: Offset(0, 1)),
      Shadow(color: Color(0x99000000), blurRadius: 16, offset: Offset(0, 3)),
    ],
    seamStart: 0.40,
  );

  static _HeroTone of(BuildContext context) {
    if (Theme.of(context).brightness == Brightness.dark) return dark;
    final palette = AppPalette.of(context);
    return _HeroTone(
      title: palette.textTitle,
      body: palette.textBody,
      meta: palette.textSub,
      capsuleBg: Colors.white.withValues(alpha: 0.82),
      capsuleBorder: Colors.black.withValues(alpha: 0.10),
      scoreInk: const Color(0xFF7A4200),
      ctaBg: palette.textTitle,
      ctaInk: Colors.white,
      ctaShadow: const Color(0x33000000),
      ghostBg: Colors.black.withValues(alpha: 0.05),
      ghostBorder: Colors.black.withValues(alpha: 0.16),
      ghostInk: palette.textMain,
      dotInactive: Colors.black.withValues(alpha: 0.22),
      placeholder: palette.raised,
      textShadows: [
        Shadow(
          color: Colors.white.withValues(alpha: 0.90),
          blurRadius: 6,
          offset: const Offset(0, 1),
        ),
        Shadow(
          color: Colors.white.withValues(alpha: 0.60),
          blurRadius: 16,
          offset: const Offset(0, 3),
        ),
      ],
      seamStart: 0.58,
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
                        posterImageProvider(item.pic, targetWidth: 512) ??
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
