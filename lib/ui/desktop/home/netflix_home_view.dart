import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import '../../../core/api/models/vod_models.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';
import '../catalog/poster_image.dart';
import '../widgets/app_motion.dart';
import '../widgets/focus_ring.dart';

/// 海报加载规格。
///
/// 横滑轨道里是 154×236 的小卡，512 宽足够（快）；首页大屏要把剧照 / 竖版海报
/// 铺满整个首屏，必须拿原图 + 按设备像素解码，否则会被放大 2–3 倍糊成一片。
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
/// 1. 顶部 Hero Billboard 巨幅滚动大屏（自动轮播、电影级暗场融合、胶片条跳转、高对比选集播放动作）。
/// 2. 垂直流式排列各个分类的横滑画报轨道（Netflix Rows）。
/// 3. 每行配备左右翻页微透胶囊与“查看全部”跳转。
/// 4. 严密遵循 WCAG 2.2 AAA（全量 FocusRing）与 AppPalette / AppMotion 设计规范。
class NetflixHomeView extends StatefulWidget {
  final Map<String, List<VodItem>> categoryItemsMap;
  final List<VodCategory> categories;
  final List<VodItem>? billboardItems;
  final ValueChanged<VodItem> onItemTap;
  final ValueChanged<VodCategory> onCategoryTap;
  final ImageProvider? Function(VodItem item, PosterSpec spec)?
      imageProviderFor;

  /// 首页巨幅位专用的横版剧照解析（返回 null 时回落竖版海报）。
  final Future<String?> Function(VodItem item)? stillUrlFor;

  /// 首页巨幅位的剧情简介（条目自带 `content` 时不调用；返回 null 表示没有）。
  final Future<String?> Function(VodItem item)? synopsisFor;
  final bool isLoading;

  /// 垂直滚动控制器（外部传入时由外部持有；用于触底续页判断）。
  final ScrollController? scrollController;

  /// 滚动通知（用于豆瓣首页无限滚动）；为空时不额外包一层监听。
  final NotificationListenerCallback<ScrollNotification>? onScrollNotification;

  const NetflixHomeView({
    super.key,
    required this.categoryItemsMap,
    required this.categories,
    this.billboardItems,
    required this.onItemTap,
    required this.onCategoryTap,
    this.imageProviderFor,
    this.stillUrlFor,
    this.synopsisFor,
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
      widget.scrollController ?? (_ownScrollController ??= ScrollController());

  @override
  void dispose() {
    _ownScrollController?.dispose();
    super.dispose();
  }

  /// 提取用于大屏轮播的影片列表（从热播电影或首个有数据的分类中取前 6 部）
  List<VodItem> _extractBillboardItems() {
    final ranked = widget.billboardItems;
    if (ranked != null) {
      final seen = <String>{};
      return ranked.where((item) => seen.add(item.id)).take(10).toList();
    }
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
              child: AppMotion.reduced(context)
                  ? Icon(Icons.movie_outlined,
                      size: 36, color: palette.accentInk)
                  : CircularProgressIndicator(
                      strokeWidth: 3,
                      valueColor:
                          AlwaysStoppedAnimation<Color>(palette.accentInk),
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

    // 焦点区要铺满首屏：量出视口高度交给它，分类接在首屏之后。
    final content = LayoutBuilder(builder: (context, constraints) {
      final viewportHeight = constraints.maxHeight.isFinite
          ? constraints.maxHeight
          : MediaQuery.sizeOf(context).height;
      return SingleChildScrollView(
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
                synopsisFor: widget.synopsisFor,
                viewportHeight: viewportHeight,
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
    });

    final onNotification = widget.onScrollNotification;
    final scrollContent = onNotification == null
        ? content
        : NotificationListener<ScrollNotification>(
            onNotification: onNotification,
            child: content,
          );
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
      child: scrollContent,
    );
  }
}

/// 大屏高度下限：正常铺满首屏（视口高度），视口比它还矮时不再缩；放大字号时随叠加内容增高。
const double _heroHeight = 480;

/// 顶部巨幅滚动大屏组件 (Hero Billboard)
class _HeroBillboard extends StatefulWidget {
  final List<VodItem> items;
  final ValueChanged<VodItem> onItemTap;
  final ImageProvider? Function(VodItem item, PosterSpec spec)?
      imageProviderFor;

  /// 取该片的横版剧照（16:9）；返回 null 表示没有，界面回落竖版海报。
  final Future<String?> Function(VodItem item)? stillUrlFor;

  /// 条目缺简介时取剧情简介；返回 null 表示没有。
  final Future<String?> Function(VodItem item)? synopsisFor;

  /// 首页视口高度：大屏铺满首屏，分类接在其后。
  final double viewportHeight;

  const _HeroBillboard({
    required this.items,
    required this.onItemTap,
    required this.viewportHeight,
    this.imageProviderFor,
    this.stillUrlFor,
    this.synopsisFor,
  });

  @override
  State<_HeroBillboard> createState() => _HeroBillboardState();
}

class _HeroBillboardState extends State<_HeroBillboard> {
  int _currentIndex = 0;
  Timer? _autoPlayTimer;
  Timer? _wheelDebounce;
  final ScrollController _thumbScrollController = ScrollController();

  /// 子树是否在屏：播放页 / 设置页打开时主视图被 Offstage 挂起（不卸载），TickerMode 随之关闭。
  /// Timer 不受 TickerMode 管，离屏时要自己跳过，否则看片期间仍每 6 s 解码一张约 15 MB 的大图。
  ValueListenable<TickerModeData>? _onScreen;
  bool _reduceMotion = false;

  /// 指针是否在大屏范围内：只决定翻页箭头显隐。
  bool _isHovering = false;

  /// 指针当前所在的交互区（信息区 / 海报栏 / 箭头）；非空时暂停自动轮播。
  final Set<String> _hoveredZones = <String>{};
  bool _hasFocus = false;

  /// 已拿到的横图地址（键为 `item.id`）；没拿到的不进表，继续走竖版海报。
  final Map<String, String> _stillUrls = <String, String>{};

  /// 已经问过的 id，避免每帧重复请求。
  final Set<String> _stillRequested = <String>{};

  /// 拉到的简介（键为 `item.id`）：有键无值 = 确认没有；无键 = 还在拉。
  final Map<String, String?> _synopses = <String, String?>{};
  final Set<String> _synopsisRequested = <String>{};

  @override
  void initState() {
    super.initState();
    _resolveStills();
    _resolveSynopses();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final onScreen = TickerMode.getValuesNotifier(context);
    if (_onScreen != onScreen) {
      _onScreen?.removeListener(_startAutoPlay);
      _onScreen = onScreen..addListener(_startAutoPlay);
    }
    _reduceMotion = AppMotion.reduced(context);
    _startAutoPlay();
  }

  @override
  void didUpdateWidget(covariant _HeroBillboard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.items.length != oldWidget.items.length) {
      _currentIndex = 0;
      _startAutoPlay();
      _revealCurrentThumb();
    }
    _resolveStills();
    _resolveSynopses();
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

  /// 条目自带的简介（站源 `vod_content`，去掉 HTML 标签与多余空白）。
  static String _ownSynopsis(VodItem item) => (item.content ?? '')
      .replaceAll(RegExp(r'<[^>]*>'), ' ')
      .replaceAll(RegExp(r'[\s\u3000]+'), ' ')
      .trim();

  /// 豆瓣合集条目不带简介：缺简介的条目按需问 [_HeroBillboard.synopsisFor]，
  /// 回来后淡入；问过的不再问（结果可能是 null = 确认没有）。
  void _resolveSynopses() {
    final resolve = widget.synopsisFor;
    for (final item in widget.items) {
      if (_ownSynopsis(item).isNotEmpty) continue;
      if (resolve == null || !_synopsisRequested.add(item.id)) continue;
      resolve(item).then((text) {
        if (!mounted) return;
        setState(() => _synopses[item.id] = text?.trim());
      }, onError: (Object _) {
        if (!mounted) return;
        setState(() => _synopses[item.id] = null);
      });
    }
  }

  @override
  void dispose() {
    _onScreen?.removeListener(_startAutoPlay);
    _autoPlayTimer?.cancel();
    _wheelDebounce?.cancel();
    _thumbScrollController.dispose();
    super.dispose();
  }

  void _startAutoPlay() {
    _autoPlayTimer?.cancel();
    _autoPlayTimer = null;
    if (widget.items.length <= 1 ||
        _reduceMotion ||
        !(_onScreen?.value.enabled ?? true)) {
      return;
    }
    _autoPlayTimer = Timer.periodic(const Duration(seconds: 6), (_) {
      if (!mounted || !_shouldAutoAdvance()) return;
      setState(() {
        _currentIndex = (_currentIndex + 1) % widget.items.length;
      });
      _revealCurrentThumb();
    });
  }

  /// 自动翻页的前提：用户没在看这一张（悬停在信息区 / 海报栏 / 箭头上，或键盘焦点在内）、
  /// 大屏真的在屏、系统没要求减少动效。
  ///
  /// 首页是 SingleChildScrollView，大屏滚出视口后仍挂在树上；不判断滚动位置
  /// 的话，用户往下翻分类时每 6 秒还在解码一张看不见的大图。
  bool _shouldAutoAdvance() {
    if (_hoveredZones.isNotEmpty ||
        _hasFocus ||
        !(_onScreen?.value.enabled ?? true)) {
      return false;
    }
    if (_reduceMotion) return false;
    final scrollable = context.findAncestorStateOfType<ScrollableState>();
    final position = scrollable?.position;
    if (position != null &&
        position.hasPixels &&
        position.pixels >= (context.size?.height ?? _heroHeight)) {
      return false;
    }
    return true;
  }

  /// 大屏海报的解码宽度：按窗口逻辑宽度 × 设备像素。
  ///
  /// 上限 1600 是内存口径：竖版海报按宽解码后高度约 1.5 倍，1600 宽一张
  /// 约 15MB，而大屏要轮播好几张——ImageCache 上限只有 48MB（见 main.dart），
  /// 再往上翻三张就占满，反而把下方轨道的海报挤掉。
  int _heroTargetWidth(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return (width * dpr).round().clamp(720, 1600);
  }

  /// 手动切换后重新计时：刚选中的那一部要完整展示一个周期。
  void _goTo(int index) {
    if (widget.items.isEmpty) return;
    setState(() => _currentIndex = index % widget.items.length);
    _startAutoPlay();
    _revealCurrentThumb();
  }

  void _revealCurrentThumb() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_thumbScrollController.hasClients) return;
      final width = context.size?.width;
      if (width == null) return;
      final position = _thumbScrollController.position;
      final metrics =
          _HeroMetrics.of(width: width, height: widget.viewportHeight);
      final count = widget.items.length;
      final content =
          count * metrics.thumbWidth + (count - 1) * metrics.thumbGap;
      // 放得下时整排居中，左侧多出一段留白。
      final leading = math.max(0.0,
          (position.viewportDimension - _thumbStripInset * 2 - content) / 2);
      final center = _thumbStripInset +
          leading +
          _currentIndex * (metrics.thumbWidth + metrics.thumbGap) +
          metrics.thumbWidth / 2;
      final target = (center - position.viewportDimension / 2)
          .clamp(0.0, position.maxScrollExtent)
          .toDouble();
      if ((position.pixels - target).abs() < 0.5) return;
      if (AppMotion.reduced(context)) {
        _thumbScrollController.jumpTo(target);
      } else {
        unawaited(_thumbScrollController.animateTo(target,
            duration: AppMotion.rowScroll, curve: Curves.easeOutCubic));
      }
    });
  }

  void _next() => _goTo(_currentIndex + 1);

  void _prev() => _goTo(_currentIndex - 1 + widget.items.length);

  void _handleWheel(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || widget.items.length < 2) return;
    final delta = event.scrollDelta.dy.abs() >= event.scrollDelta.dx.abs()
        ? event.scrollDelta.dy
        : event.scrollDelta.dx;
    if (delta == 0) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      if (_wheelDebounce?.isActive ?? false) return;
      delta > 0 ? _next() : _prev();
      _wheelDebounce = Timer(const Duration(milliseconds: 220), () {});
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) return const SizedBox.shrink();
    final palette = AppPalette.of(context);
    final tone = _HeroTone.of(context);
    final index = _currentIndex.clamp(0, widget.items.length - 1);
    final item = widget.items[index];
    // 有横版剧照就用剧照；没有则 null → 走原来的竖版原图。
    final stillUrl = _stillUrls[item.id];
    final reduceMotion = AppMotion.reduced(context);

    // 键盘焦点停在海报栏 / 按钮上时同样视为「正在看」，不在用户操作中途翻页。
    return Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: (focused) => _hasFocus = focused,
        child: MouseRegion(
          onEnter: (_) => setState(() => _isHovering = true),
          onExit: (_) => setState(() {
            _isHovering = false;
            // 子区域随大屏一起离开时不一定收得到自己的 onExit，这里统一清掉。
            _hoveredZones.clear();
          }),
          child: LayoutBuilder(builder: (context, constraints) {
            final compact = constraints.maxWidth < 900;
            final metrics = _HeroMetrics.of(
                width: constraints.maxWidth, height: widget.viewportHeight);
            return ColoredBox(
              key: const ValueKey('hero-billboard'),
              color: palette.background,
              child: ConstrainedBox(
                // 铺满首屏；视口太矮时不低于 [_heroHeight]。
                constraints: BoxConstraints(
                    minHeight: math.max(_heroHeight, widget.viewportHeight)),
                child: Stack(
                  fit: StackFit.passthrough,
                  children: [
                    Positioned.fill(
                        child: _buildArtwork(item, stillUrl, tone, palette,
                            reduceMotion, compact)),
                    Padding(
                      // 海报栏四周的焦点环留白伸进左右留白里，不占海报栏的宽度：
                      // 参考尺寸下 7 张海报正好排满，海报左缘也与文字左缘对齐。
                      padding: EdgeInsets.fromLTRB(
                          metrics.gutter - _thumbStripInset,
                          metrics.topInset,
                          metrics.gutter - _thumbStripInset,
                          24),
                      // 信息区靠近底部海报栏，背景留白集中在上方。
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.end,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: _thumbStripInset),
                            child: _pauseOnHover(
                              'copy',
                              SizedBox(
                                key: const ValueKey('hero-copy'),
                                width: metrics.copyWidth,
                                child: _buildCopy(
                                    item, index, tone, palette, metrics.scale),
                              ),
                            ),
                          ),
                          if (widget.items.length > 1)
                            Padding(
                              padding: const EdgeInsets.only(top: 24),
                              child: _pauseOnHover(
                                'strip',
                                // 只在缩略图栏接管滚轮，其余首屏区域允许纵向翻页。
                                Listener(
                                  onPointerSignal: _handleWheel,
                                  child: _buildThumbStrip(index, metrics, tone, palette),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (_isHovering && widget.items.length > 1) ...[
                      Positioned(
                        left: 12,
                        top: 0,
                        bottom: 0,
                        child: Center(
                            child: _pauseOnHover(
                                'previous',
                                _buildArrow(Icons.arrow_back_ios_new_rounded,
                                    '上一部', tone, _prev))),
                      ),
                      Positioned(
                        right: 12,
                        top: 0,
                        bottom: 0,
                        child: Center(
                            child: _pauseOnHover(
                                'next',
                                _buildArrow(Icons.arrow_forward_ios_rounded,
                                    '下一部', tone, _next))),
                      ),
                    ],
                  ],
                ),
              ),
            );
          }),
        ),
    );
  }

  /// 鼠标停在信息区 / 海报栏 / 翻页箭头上才算「正在看」。
  ///
  /// 大屏铺满首屏后，指针几乎总在大屏范围内；再按整块悬停来暂停，轮播就永远不翻页了。
  Widget _pauseOnHover(String zone, Widget child) => MouseRegion(
        onEnter: (_) => _hoveredZones.add(zone),
        onExit: (_) => _hoveredZones.remove(zone),
        child: child,
      );

  Widget _buildArtwork(VodItem item, String? stillUrl, _HeroTone tone,
      AppPalette palette, bool reduceMotion, bool compact) {
    return Stack(
      key: const ValueKey('hero-artwork'),
      fit: StackFit.expand,
      clipBehavior: Clip.none,
      children: [
        AnimatedSwitcher(
          duration: reduceMotion ? Duration.zero : AppMotion.heroFade,
          switchInCurve: Curves.easeInOutCubic,
          switchOutCurve: Curves.easeInOutCubic,
          child: SizedBox.expand(
            key: ValueKey('${item.id}|${stillUrl ?? ''}'),
            child: _buildBackdrop(context, item, stillUrl, tone, palette),
          ),
        ),
        IgnorePointer(
          child: DecoratedBox(
            key: const ValueKey('hero-side-scrim'),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                stops: const [0, 0.52, 0.80, 1],
                colors: tone.sideScrim(compact),
              ),
            ),
          ),
        ),
        IgnorePointer(
          child: DecoratedBox(
            key: const ValueKey('hero-bottom-scrim'),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: const [0.72, 1],
                colors: [
                  tone.bottomScrim.withValues(alpha: 0),
                  tone.bottomScrim,
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBackdrop(BuildContext context, VodItem item, String? stillUrl,
      _HeroTone tone, AppPalette palette) {
    final targetWidth = _heroTargetWidth(context);
    return Image(
      image: widget.imageProviderFor?.call(
            item,
            PosterSpec(
              targetWidth: targetWidth,
              highRes: true,
              urlOverride: stillUrl,
            ),
          ) ??
          posterImageProvider(item.pic, targetWidth: targetWidth) ??
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
    );
  }

  /// 影片信息：眉题、片名、评分 / 元信息、简介、主操作；[s] 为字号 / 间距倍率。
  Widget _buildCopy(
      VodItem item, int index, _HeroTone tone, AppPalette palette, double s) {
    final metaStyle = TextStyle(
      color: tone.meta,
      fontSize: AppType.label * s,
      fontWeight: FontWeight.w500,
      shadows: tone.textShadows,
    );
    final year = item.year?.trim() ?? '';
    final remarks = item.remarks?.trim() ?? '';
    final yearInRemarks = remarks.split(RegExp(r'\s*[/·|]\s*')).contains(year);
    final metaParts = <String>[
      if (year.isNotEmpty && !yearInRemarks) year,
      if (remarks.isNotEmpty) remarks,
    ];
    final hasScore = item.score != null && item.score!.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // 眉题：一笔强调色 + 栏目名 + 位置，替代原来的品牌红徽章
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 3,
              height: 14 * s,
              decoration: BoxDecoration(
                color: palette.accentInk,
                borderRadius: BorderRadius.circular(AppRadii.hairline),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              widget.items.length > 1
                  ? '今日焦点  ${index + 1} / ${widget.items.length}'
                  : '今日焦点',
              style: metaStyle.copyWith(
                color: tone.title,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
        SizedBox(height: 10 * s),
        Text(
          item.name,
          key: const ValueKey('hero-title'),
          style: TextStyle(
            fontSize: AppType.display * s,
            fontWeight: FontWeight.w800,
            height: 1.15,
            color: tone.title,
            letterSpacing: -0.5,
            shadows: tone.textShadows,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        if (hasScore || metaParts.isNotEmpty) ...[
          SizedBox(height: 8 * s),
          // 窄窗自动换行：大屏在 400 宽时会溢出
          Wrap(
            spacing: 10,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (hasScore) _buildScore(item.score!, tone, s),
              for (final part in metaParts) Text(part, style: metaStyle),
            ],
          ),
        ],
        SizedBox(height: 12 * s),
        _buildSynopsis(item, tone, s),
        SizedBox(height: 16 * s),
        _buildCta(item, tone, s),
      ],
    );
  }

  /// 简介位：固定三行高（行高由 strut 钉死），换片 / 简介晚到时信息区不跳。
  ///
  /// 有简介显示简介；确认没有显示占位；还在拉时留空，回来后淡入。
  Widget _buildSynopsis(VodItem item, _HeroTone tone, double s) {
    const lines = 3;
    const lineHeight = 1.55;
    final fontSize = AppType.label * s;
    final own = _ownSynopsis(item);
    final pending = own.isEmpty &&
        widget.synopsisFor != null &&
        !_synopses.containsKey(item.id);
    final fetched = _synopses[item.id] ?? '';
    final text = own.isNotEmpty ? own : fetched;
    final style = TextStyle(
      fontSize: fontSize,
      color: text.isEmpty ? tone.meta : tone.body,
      height: lineHeight,
      shadows: tone.textShadows,
    );
    final strut = StrutStyle(
        fontSize: fontSize, height: lineHeight, forceStrutHeight: true);
    return SizedBox(
      key: const ValueKey('hero-synopsis'),
      height:
          MediaQuery.textScalerOf(context).scale(fontSize) * lineHeight * lines,
      width: double.infinity,
      child: AppContentTransition(
        identity: (item.id, pending, text),
        type: AppTransitionType.fadeThrough,
        alignment: Alignment.topLeft,
        child: pending
            ? const SizedBox.shrink(key: ValueKey('synopsis-pending'))
            : Text(
                text.isEmpty ? '暂无剧情简介' : text,
                key: ValueKey('synopsis-${item.id}-${text.hashCode}'),
                style: style,
                strutStyle: strut,
                maxLines: lines,
                overflow: TextOverflow.ellipsis,
              ),
      ),
    );
  }

  Widget _buildScore(String score, _HeroTone tone, double s) => Container(
        padding: EdgeInsets.symmetric(horizontal: 7 * s, vertical: 2 * s),
        decoration: BoxDecoration(
          color: tone.capsuleBg,
          borderRadius: BorderRadius.circular(AppRadii.xs),
          border: Border.all(color: tone.capsuleBorder, width: 0.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.star_rounded, color: tone.scoreInk, size: 13 * s),
            const SizedBox(width: 3),
            Text(
              score,
              style: TextStyle(
                color: tone.scoreInk,
                fontSize: AppType.caption * s,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(width: 4),
            Text(
              '豆瓣',
              style: TextStyle(color: tone.meta, fontSize: AppType.micro * s),
            ),
          ],
        ),
      );

  /// 点击打开详情后才能选线路 / 选集，所以按钮就叫「选集播放」，
  /// 不再摆两个行为相同的按钮（原「立即播放」「详细信息」都只是打开详情）。
  Widget _buildCta(VodItem item, _HeroTone tone, double s) => FocusRing(
        onTap: () => widget.onItemTap(item),
        semanticLabel: '选集播放 ${item.name}',
        borderRadius: BorderRadius.circular(AppRadii.pill),
        child: Material(
          color: tone.ctaBg,
          borderRadius: BorderRadius.circular(AppRadii.pill),
          child: InkWell(
            onTap: () => widget.onItemTap(item),
            borderRadius: BorderRadius.circular(AppRadii.pill),
            child: Padding(
              padding: EdgeInsets.fromLTRB(20 * s, 11 * s, 24 * s, 11 * s),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.play_arrow_rounded,
                      color: tone.ctaInk, size: 22 * s),
                  const SizedBox(width: 6),
                  Text(
                    '选集播放',
                    style: TextStyle(
                      color: tone.ctaInk,
                      fontSize: AppType.lead * s,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

  /// 底部海报栏：占满左右留白之间的宽度；放得下就整体居中，放不下从左排起、横向滚动。
  Widget _buildThumbStrip(
      int index, _HeroMetrics metrics, _HeroTone tone, AppPalette palette) {
    final spec = _HeroThumb.specFor(
        metrics.thumbWidth, MediaQuery.devicePixelRatioOf(context));
    final titleHeight = _HeroThumb.titleHeight(
        metrics.thumbWidth, MediaQuery.textScalerOf(context));
    return SizedBox(
      key: const ValueKey('hero-thumb-strip'),
      width: double.infinity,
      height: metrics.thumbWidth * _HeroThumb.aspect +
          _HeroThumb.titleGap +
          titleHeight +
          _thumbStripInset * 2,
      child: SingleChildScrollView(
        controller: _thumbScrollController,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.all(_thumbStripInset),
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: metrics.available),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < widget.items.length; i++) ...[
                if (i > 0) SizedBox(width: metrics.thumbGap),
                _HeroThumb(
                  item: widget.items[i],
                  selected: i == index,
                  tone: tone,
                  accent: palette.accentInk,
                  width: metrics.thumbWidth,
                  image: widget.imageProviderFor?.call(widget.items[i], spec) ??
                      posterImageProvider(widget.items[i].pic,
                          targetWidth: spec.targetWidth) ??
                      NetworkImage(widget.items[i].pic),
                  onTap: () => _goTo(i),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildArrow(IconData icon, String tooltip, _HeroTone tone,
          VoidCallback onPressed) =>
      FocusOutline(
        radius: AppRadii.pill,
        child: IconButton(
          onPressed: onPressed,
          tooltip: tooltip,
          icon: Icon(icon),
          color: tone.arrowInk,
          style: IconButton.styleFrom(
            backgroundColor: tone.arrowBg,
            hoverColor: tone.arrowHover,
            side: BorderSide(color: tone.capsuleBorder),
          ),
        ),
      );
}

/// 焦点区版面尺寸：按参考稿（1911×1066）的比例随窗口缩放。
///
/// 文字与底部海报左缘对齐，信息区紧邻海报栏上方。
/// 底部并排约 7 张 2:3 海报，海报高约占窗口高度的三分之一。
@immutable
class _HeroMetrics {
  const _HeroMetrics._({
    required this.gutter,
    required this.available,
    required this.topInset,
    required this.scale,
    required this.copyWidth,
    required this.thumbWidth,
    required this.thumbGap,
  });

  factory _HeroMetrics.of({required double width, required double height}) {
    final gutter = width < 600 ? 24.0 : (width < 1500 ? 36.0 : 44.0);
    final available = math.max(0.0, width - gutter * 2);
    final scale =
        math.min(width / 1280, height / 720).clamp(1.0, 1.4).toDouble();
    final thumbWidth = math
        .min(available * 0.127, height * 0.325 / _HeroThumb.aspect)
        .clamp(112.0, 240.0)
        .toDouble();
    return _HeroMetrics._(
      gutter: gutter,
      available: available,
      topInset: (height * 0.12).clamp(48.0, 140.0).toDouble(),
      scale: scale,
      copyWidth: math.min(width < 900 ? available : width * 0.5, 560.0 * scale),
      thumbWidth: thumbWidth,
      thumbGap: (thumbWidth * 0.147).clamp(10.0, 34.0).toDouble(),
    );
  }

  /// 左右留白。
  final double gutter;

  /// 去掉左右留白后的可用宽度（底部海报栏里能排海报的宽度）。
  final double available;

  /// 信息区上方的最小留白；矮窗或大字时允许焦点区自然增高。
  final double topInset;

  /// 影片信息的字号 / 间距倍率：大窗口放大，否则整屏大图上的字显得太小。
  final double scale;

  /// 影片信息的宽度。
  final double copyWidth;

  /// 底部海报的宽度（高度 = 宽度 × [_HeroThumb.aspect]）。
  final double thumbWidth;

  /// 底部海报之间的间距。
  final double thumbGap;
}

/// 底部海报栏四周留给键盘焦点环的空隙。
const double _thumbStripInset = 4;

/// 底部海报栏的一格：竖版海报 + 片名，看得见下一部是什么，也让键盘能直接跳转。
class _HeroThumb extends StatelessWidget {
  const _HeroThumb({
    required this.item,
    required this.selected,
    required this.tone,
    required this.accent,
    required this.image,
    required this.width,
    required this.onTap,
  });

  /// 竖版海报的高宽比（2:3）。
  static const double aspect = 1.5;

  /// 海报与片名的间距。
  static const double titleGap = 8;

  static const double _titleLineHeight = 1.35;

  /// 片名字号随海报宽度放大；上下限保证小窗可读、大窗不抢主标题。
  static double titleFontSize(double width) =>
      (width * 0.085).clamp(AppType.body, AppType.h2).toDouble();

  /// 片名占的一行高度（由 strut 钉死，换片时海报栏高度不跳）。
  static double titleHeight(double width, TextScaler textScaler) =>
      textScaler.scale(titleFontSize(width)) * _titleLineHeight;

  /// 解码规格：按海报的设备像素宽度取档；档位固定，拖动窗口时不会反复重新解码。
  static PosterSpec specFor(double width, double devicePixelRatio) =>
      PosterSpec(targetWidth: width * devicePixelRatio <= 384 ? 384 : 768);

  final VodItem item;
  final bool selected;
  final _HeroTone tone;
  final Color accent;
  final ImageProvider image;
  final double width;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(AppRadii.sm);
    final fontSize = titleFontSize(width);
    return FocusRing(
      onTap: onTap,
      semanticLabel: '切换到 ${item.name}',
      borderRadius: radius,
      child: Tooltip(
        message: item.name,
        waitDuration: const Duration(milliseconds: 500),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: onTap,
            child: AnimatedOpacity(
              duration: AppMotion.durationOf(context, AppMotion.enter),
              opacity: selected ? 1 : 0.88,
              child: SizedBox(
                width: width,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: width,
                      height: width * aspect,
                      child: AnimatedContainer(
                        duration: AppMotion.durationOf(context, AppMotion.enter),
                        clipBehavior: Clip.antiAlias,
                        decoration: BoxDecoration(
                          color: tone.placeholder,
                          borderRadius: radius,
                        ),
                        foregroundDecoration: BoxDecoration(
                          borderRadius: radius,
                          border: Border.all(
                            color: selected ? accent : tone.thumbBorder,
                            width: selected ? 2 : 1,
                          ),
                        ),
                        child: Image(
                          image: image,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => const SizedBox.expand(),
                        ),
                      ),
                    ),
                    const SizedBox(height: titleGap),
                    SizedBox(
                      height:
                          titleHeight(width, MediaQuery.textScalerOf(context)),
                      // 语义标签已含片名，这里不再重复朗读。
                      child: ExcludeSemantics(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: tone.thumbCaptionBg,
                            borderRadius: BorderRadius.circular(AppRadii.xs),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: Text(
                              item.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: selected ? tone.title : tone.body,
                                fontSize: fontSize,
                                fontWeight: selected
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                                height: _titleLineHeight,
                              ),
                              strutStyle: StrutStyle(
                                fontSize: fontSize,
                                height: _titleLineHeight,
                                forceStrutHeight: true,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

@immutable
class _HeroTone {
  _HeroTone.of(BuildContext context)
      : _palette = AppPalette.of(context),
        _dark = Theme.of(context).brightness == Brightness.dark;

  final AppPalette _palette;
  final bool _dark;

  Color get title => _dark ? Colors.white : _palette.textTitle;
  Color get body => _dark ? const Color(0xE6FFFFFF) : _palette.textBody;
  Color get meta => _dark ? const Color(0xE6FFFFFF) : _palette.textBody;
  Color get capsuleBg =>
      _dark ? const Color(0x66000000) : Colors.white.withValues(alpha: 0.90);
  Color get capsuleBorder =>
      _dark ? const Color(0x66777777) : Colors.black.withValues(alpha: 0.16);
  Color get scoreInk =>
      _dark ? const Color(0xFFFFD27D) : const Color(0xFF704000);
  Color get ctaBg => _dark ? Colors.white : _palette.accentInk;
  Color get ctaInk => _dark ? const Color(0xFF181818) : Colors.white;
  Color get thumbBorder => _dark
      ? Colors.white.withValues(alpha: 0.42)
      : Colors.black.withValues(alpha: 0.30);
  Color get thumbCaptionBg => _dark
      ? _palette.background.withValues(alpha: 0.72)
      : _palette.panel.withValues(alpha: 0.92);
  Color get placeholder => _palette.raised;
  Color get arrowBg => _dark
      ? Colors.black.withValues(alpha: 0.64)
      : Colors.white.withValues(alpha: 0.92);
  Color get arrowHover =>
      _dark ? Colors.black.withValues(alpha: 0.82) : Colors.white;
  Color get arrowInk => _dark ? Colors.white : _palette.textMain;
  Color get bottomScrim => _dark
      ? Colors.black.withValues(alpha: 0.12)
      : _palette.background.withValues(alpha: 0.18);
  List<Color> sideScrim(bool compact) => _dark
      ? [
          Colors.black.withValues(alpha: 0.62),
          Colors.black.withValues(alpha: 0.58),
          Colors.black.withValues(alpha: 0.06),
          Colors.black.withValues(alpha: compact ? 0.10 : 0),
        ]
      : [
          Colors.white.withValues(alpha: 0.82),
          Colors.white.withValues(alpha: 0.72),
          Colors.white.withValues(alpha: 0.06),
          Colors.white.withValues(alpha: compact ? 0.04 : 0),
        ];
  List<Color> get posterScrim => _dark
      ? [
          Colors.black.withValues(alpha: 0),
          Colors.black.withValues(alpha: 0),
          Colors.black.withValues(alpha: 0.28),
          Colors.black.withValues(alpha: 0.72),
        ]
      : [
          Colors.white.withValues(alpha: 0),
          Colors.white.withValues(alpha: 0),
          Colors.white.withValues(alpha: 0.64),
          Colors.white.withValues(alpha: 0.96),
        ];
  List<Shadow> get textShadows => _dark
      ? const [
          Shadow(color: Color(0x99000000), blurRadius: 6, offset: Offset(0, 1)),
          Shadow(
              color: Color(0x66000000), blurRadius: 14, offset: Offset(0, 3)),
        ]
      : [
          Shadow(
            color: Colors.white.withValues(alpha: 0.78),
            blurRadius: 5,
            offset: const Offset(0, 1),
          ),
        ];
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
    if (AppMotion.reduced(context)) {
      _scrollController.jumpTo(target);
    } else {
      unawaited(_scrollController.animateTo(
        target,
        duration: AppMotion.rowScroll,
        curve: Curves.easeOutCubic,
      ));
    }
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
                  // 分类名直接展示：emoji 前缀在不同字体环境渲染不一（会显示成方块），
                  // 与搜索、网格页「emoji 退役」口径一致。
                  widget.category.name,
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
                          tooltip: '向左滚动',
                          icon: const Icon(Icons.arrow_back_ios_new_rounded),
                          color: palette.textMain,
                          style: IconButton.styleFrom(
                            backgroundColor:
                                palette.card.withValues(alpha: 0.94),
                            hoverColor: palette.hover,
                            side: BorderSide(
                              color: palette.borderStrong,
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
                          tooltip: '向右滚动',
                          icon: const Icon(Icons.arrow_forward_ios_rounded),
                          color: palette.textMain,
                          style: IconButton.styleFrom(
                            backgroundColor:
                                palette.card.withValues(alpha: 0.94),
                            hoverColor: palette.hover,
                            side: BorderSide(
                              color: palette.borderStrong,
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
    final tone = _HeroTone.of(context);
    final item = widget.item;
    final hoverMotion = AppMotion.durationOf(
        context, _isHovered ? AppMotion.enter : AppMotion.exit);

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
            scale: _isHovered && !AppMotion.reduced(context) ? 1.02 : 1.0,
            duration: hoverMotion,
            curve: AppMotion.ease,
            child: AnimatedContainer(
              duration: hoverMotion,
              curve: AppMotion.ease,
              width: 154,
              height: 236,
              decoration: BoxDecoration(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(AppRadii.sm),
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

                  Positioned.fill(
                    child: DecoratedBox(
                      key: const ValueKey('home-poster-scrim'),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          stops: const [0.0, 0.62, 0.82, 1.0],
                          colors: tone.posterScrim,
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
                          color: tone.capsuleBg,
                          borderRadius: BorderRadius.circular(AppRadii.xs),
                          border:
                              Border.all(color: tone.capsuleBorder, width: 0.5),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '★ ',
                              style: TextStyle(
                                fontSize: AppType.micro,
                                color: tone.scoreInk,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              item.score!,
                              style: TextStyle(
                                fontSize: AppType.caption,
                                color: tone.scoreInk,
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
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: AppType.body,
                            fontWeight: FontWeight.bold,
                            color: tone.title,
                            shadows: tone.textShadows,
                          ),
                        ),
                        if (item.remarks != null &&
                            item.remarks!.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            item.remarks!,
                            style: TextStyle(
                              fontSize: AppType.caption,
                              color: tone.body,
                              shadows: tone.textShadows,
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
